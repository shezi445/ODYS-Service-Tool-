import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../dfu/dfu_engine.dart';
import '../models.dart';
import '../protocol/odys_protocol.dart';
import '../session_log.dart';

class OdysBleClient extends ChangeNotifier {
  OdysBleClient(this.log);

  final SessionLog log;
  final List<ScanResult> scanResults = [];
  final _rawNotifications = StreamController<Uint8List>.broadcast();
  Stream<Uint8List> get rawNotifications => _rawNotifications.stream;

  ConnectionPhase phase = ConnectionPhase.disconnected;
  BluetoothDevice? device;
  BluetoothCharacteristic? _writeCharacteristic;
  bool _writeWithoutResponse = false;
  StreamSubscription<List<int>>? _notifySubscription;
  StreamSubscription<List<ScanResult>>? _scanSubscription;
  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;
  Timer? _pollTimer;
  Completer<void>? _authCompleter;
  int _authKeyIndex = 0;
  bool _authChallengeSeen = false;
  bool _authEncryptionAccepted = false;
  int? _accountId;
  Completer<void>? _cruiseCompleter;
  Completer<void>? _cruiseVerifyCompleter;
  bool? _pendingCruiseValue;
  Future<void> _writeTail = Future<void>.value();
  bool _manualDisconnect = false;
  bool _connectOperationInProgress = false;
  bool _suppressAutoRecovery = false;
  int _pollTick = 0;
  bool _recoveringConnection = false;
  final List<int> _normalFrameBuffer = [];

  Telemetry telemetry = const Telemetry();
  FirmwareVersions versions = const FirmwareVersions();
  bool cruiseEnabled = false;
  DateTime? _stationarySince;
  DateTime? _lastRealSpeedSample;
  int _stationarySamples = 0;
  String? lastConnectionError;
  int? rssi;

  /// When true, a dropped link is retried more persistently. Set from the
  /// user's auto-reconnect preference; a drop is always retried at least
  /// three times regardless, because that path predates the setting.
  bool autoReconnect = true;

  bool get connected =>
      phase == ConnectionPhase.authenticating ||
      phase == ConnectionPhase.connected ||
      phase == ConnectionPhase.flashing;
  bool get stationaryLongEnough =>
      telemetry.hasTrustedSpeed &&
      _lastRealSpeedSample != null &&
      DateTime.now().difference(_lastRealSpeedSample!) <
          const Duration(seconds: 3) &&
      _stationarySamples >= 3 &&
      _stationarySince != null &&
      DateTime.now().difference(_stationarySince!) >=
          const Duration(seconds: 5);

  Future<void> scan() async {
    try {
      if (Platform.isAndroid) {
        final statuses = await <Permission>[
          Permission.bluetoothScan,
          Permission.bluetoothConnect,
          Permission.locationWhenInUse,
        ].request();

        final denied = statuses.values.any(
          (status) => status.isDenied || status.isPermanentlyDenied,
        );

        if (denied) {
          throw StateError(
            'Bluetooth permission was denied. Enable it in phone settings.',
          );
        }
      }

      final supported = await FlutterBluePlus.isSupported;
      if (!supported) {
        throw StateError('Bluetooth is not supported on this device.');
      }

      BluetoothAdapterState adapterState =
          await FlutterBluePlus.adapterState.first;

      if (adapterState == BluetoothAdapterState.unknown) {
        adapterState = await FlutterBluePlus.adapterState
            .where((state) => state != BluetoothAdapterState.unknown)
            .first
            .timeout(const Duration(seconds: 10));
      }

      if (adapterState != BluetoothAdapterState.on) {
        throw StateError(
          'Bluetooth must be turned on. Current state: $adapterState',
        );
      }

      if (FlutterBluePlus.isScanningNow) {
        await FlutterBluePlus.stopScan();
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }

      scanResults.clear();
      lastConnectionError = null;
      phase = ConnectionPhase.scanning;
      notifyListeners();

      await _scanSubscription?.cancel();
      _scanSubscription = FlutterBluePlus.scanResults.listen(
        (results) {
          scanResults
            ..clear()
            ..addAll(results.where((result) {
              final name =
                  result.advertisementData.advName.toLowerCase();

              return name.isNotEmpty ||
                  result.advertisementData.serviceUuids.any(
                    (uuid) =>
                        uuid.str.toLowerCase() == OdysProtocol.serviceUuid,
                  );
            }));

          notifyListeners();
        },
        onError: (Object error) {
          lastConnectionError = 'Bluetooth scan failed: $error';
          log.add(lastConnectionError!);

          if (phase == ConnectionPhase.scanning) {
            phase = ConnectionPhase.disconnected;
          }

          notifyListeners();
        },
      );

      await FlutterBluePlus.startScan(
        timeout: const Duration(seconds: 12),
      );

      await FlutterBluePlus.isScanning
          .where((isScanning) => !isScanning)
          .first;
    } on TimeoutException {
      lastConnectionError =
          'Bluetooth initialization timed out. Turn Bluetooth on and try again.';
      log.add(lastConnectionError!);
      throw StateError(lastConnectionError!);
    } catch (error) {
      lastConnectionError = error.toString();
      log.add('Bluetooth scan error: $error');
      rethrow;
    } finally {
      if (phase == ConnectionPhase.scanning) {
        phase = ConnectionPhase.disconnected;
        notifyListeners();
      }
    }
  }

  Future<void> connect(ScanResult result, {required int accountId}) =>
      connectToDevice(result.device, accountId: accountId);

  /// Connects to a device by object rather than by scan result, so a saved
  /// remote ID can be reconnected to without scanning first.
  Future<void> connectToDevice(
    BluetoothDevice target, {
    required int accountId,
  }) async {
    if (accountId <= 0 || accountId > 0xffffffff) {
      throw ArgumentError.value(
        accountId,
        'accountId',
        'must be a positive 32-bit ODYS account ID',
      );
    }
    if (_connectOperationInProgress) {
      throw StateError('A Bluetooth connection attempt is already running');
    }
    // A direct connect may be the first BLE operation of the session, so the
    // runtime permissions scan() normally asks for are not guaranteed yet.
    if (Platform.isAndroid) {
      await <Permission>[
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();
    }
    _connectOperationInProgress = true;
    _suppressAutoRecovery = true;
    _manualDisconnect = false;
    _accountId = accountId;
    lastConnectionError = null;
    phase = ConnectionPhase.connecting;
    notifyListeners();
    try {
      await FlutterBluePlus.stopScan();
      // Several Android BLE stacks fail with status 62 when connect is started
      // while the scanner is still being torn down.
      await Future<void>.delayed(const Duration(milliseconds: 800));
      device = target;
      await _connectionSubscription?.cancel();
      _connectionSubscription = target.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected &&
            !_manualDisconnect &&
            !_suppressAutoRecovery &&
            device != null) {
          unawaited(_recoverConnection());
        }
      });
      await _connectWithRetry(target);
    } catch (error, stack) {
      lastConnectionError = _friendlyConnectionError(error);
      log.add(lastConnectionError!);
      await _safeDisconnect(target);
      device = null;
      _writeCharacteristic = null;
      _writeWithoutResponse = false;
      phase = ConnectionPhase.disconnected;
      _resetMotionTrust();
      notifyListeners();
      Error.throwWithStackTrace(
        StateError(lastConnectionError!),
        stack,
      );
    } finally {
      _suppressAutoRecovery = false;
      _connectOperationInProgress = false;
    }
  }

  Future<void> _connectWithRetry(BluetoothDevice target) async {
    const retryDelays = <Duration>[
      Duration(milliseconds: 1500),
      Duration(seconds: 3),
      Duration(seconds: 5),
    ];
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 0; attempt <= retryDelays.length; attempt++) {
      try {
        log.add('BLE connection attempt ${attempt + 1}/'
            '${retryDelays.length + 1}');
        await _connectDevice(target);
        return;
      } catch (error, stack) {
        lastError = error;
        lastStack = stack;
        final status62 = isConnectionEstablishmentFailure('$error');
        log.add('BLE attempt ${attempt + 1} failed'
            '${status62 ? " (Android status 62)" : ""}: $error');
        await _safeDisconnect(target);
        _writeCharacteristic = null;
        _writeWithoutResponse = false;
        await _notifySubscription?.cancel();
        _notifySubscription = null;
        if (attempt == retryDelays.length) break;
        await Future<void>.delayed(retryDelays[attempt]);
      }
    }
    Error.throwWithStackTrace(
      lastError ?? StateError('Bluetooth connection failed'),
      lastStack ?? StackTrace.current,
    );
  }

  Future<void> _connectDevice(BluetoothDevice target) async {
    try {
      // Disable FlutterBluePlus' automatic Android MTU request. Requesting MTU
      // is deliberately done after the GATT link has settled.
      await target.connect(
        timeout: const Duration(seconds: 15),
        mtu: null,
      );
    } catch (_) {
      // A device already connected by Android reports an exception here.
      if (!target.isConnected) rethrow;
    }
    await Future<void>.delayed(const Duration(milliseconds: 350));
    if (Platform.isAndroid) {
      try {
        await target.requestMtu(148);
      } catch (error) {
        log.add('MTU request warning: $error');
      }
    }
    final channels = await _discoverOdysChannels(target);
    _writeCharacteristic = channels.$1;
    _writeWithoutResponse = !channels.$1.properties.write &&
        channels.$1.properties.writeWithoutResponse;
    await _notifySubscription?.cancel();
    _notifySubscription = channels.$2.lastValueStream.listen(_onNotification);
    await channels.$2.setNotifyValue(true);
    device = target;
    log.add('Connected to ${target.remoteId.str}; MTU ${target.mtuNow}');
    phase = ConnectionPhase.authenticating;
    _resetMotionTrust();
    notifyListeners();

    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _authenticateWithKeyFallback();
    phase = ConnectionPhase.connected;
    notifyListeners();
    await refresh();
    _startPolling();
  }

  Future<(BluetoothCharacteristic, BluetoothCharacteristic)>
      _discoverOdysChannels(BluetoothDevice target) async {
    List<BluetoothService> services = const [];
    for (var attempt = 1; attempt <= 3; attempt++) {
      try {
        services = await target.discoverServices();
      } catch (error) {
        log.add('Service discovery attempt $attempt/3 failed: $error');
        if (attempt == 3) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 450 * attempt));
        continue;
      }
      final odysServices = services
          .where((service) =>
              uuidTextMatches(service.uuid.str, OdysProtocol.serviceUuid))
          .toList();
      final searchServices = <BluetoothService>[
        ...odysServices,
        ...services.where((service) => !odysServices.contains(service)),
      ];
      BluetoothCharacteristic? write;
      BluetoothCharacteristic? notify;
      for (final service in searchServices) {
        for (final characteristic in service.characteristics) {
          if (uuidTextMatches(
            characteristic.uuid.str,
            OdysProtocol.writeUuid,
          )) {
            write = characteristic;
          }
          if (uuidTextMatches(
            characteristic.uuid.str,
            OdysProtocol.notifyUuid,
          )) {
            notify = characteristic;
          }
        }
      }
      if (write != null && notify != null) {
        if (!write.properties.write && !write.properties.writeWithoutResponse) {
          throw StateError(
            'ODYS B002 exists but is not writable on this controller',
          );
        }
        if (!notify.properties.notify && !notify.properties.indicate) {
          throw StateError(
            'ODYS B003 exists but does not support notifications',
          );
        }
        return (write, notify);
      }

      final inventory = _serviceInventory(services);
      log.add('ODYS channel discovery attempt $attempt/3 incomplete: '
          'write=${write != null}, notify=${notify != null}; $inventory');
      if (attempt == 1 && Platform.isAndroid) {
        try {
          await target.clearGattCache();
          log.add('Android GATT cache cleared before rediscovery');
        } catch (error) {
          log.add('GATT cache refresh warning: $error');
        }
      }
      await Future<void>.delayed(Duration(milliseconds: 450 * attempt));
    }
    throw StateError(
      'ODYS GATT channels not found after 3 discoveries. '
      'Expected service ${OdysProtocol.serviceUuid}, write '
      '${OdysProtocol.writeUuid}, notify ${OdysProtocol.notifyUuid}. '
      'Discovered: ${_serviceInventory(services)}',
    );
  }

  static String _serviceInventory(List<BluetoothService> services) {
    if (services.isEmpty) return 'no services';
    return services.map((service) {
      final characteristics =
          service.characteristics.map((c) => c.uuid.str).join(',');
      return '${service.uuid.str}[$characteristics]';
    }).join('; ');
  }

  @visibleForTesting
  static bool uuidTextMatches(String actual, String expected) =>
      _normalizeUuid(actual) == _normalizeUuid(expected);

  static String _normalizeUuid(String value) {
    var compact = value
        .trim()
        .toLowerCase()
        .replaceAll('{', '')
        .replaceAll('}', '')
        .replaceAll('-', '');
    if (compact.length == 4) {
      compact = '0000${compact}00001000800000805f9b34fb';
    }
    return compact;
  }

  @visibleForTesting
  static bool isConnectionEstablishmentFailure(String text) {
    final normalized = text.toLowerCase();
    return normalized.contains('connection_failed_establishment') ||
        RegExp(r'(android[- ]code|code|status)\s*[:=]?\s*62\b')
            .hasMatch(normalized);
  }

  static String _friendlyConnectionError(Object error) {
    if (isConnectionEstablishmentFailure('$error')) {
      return 'Android could not establish the BLE link (status 62). '
          'All retries failed. Close other scooter apps, power-cycle the '
          'scooter, and try again.';
    }
    return 'Bluetooth connection failed: $error';
  }

  static Future<void> _safeDisconnect(BluetoothDevice target) async {
    try {
      await target.disconnect();
    } catch (_) {
      // Cleanup is best-effort because Android may already have closed GATT.
    }
  }

  Future<void> refresh() async {
    await writeRaw(OdysProtocol.readCommand(OdysProtocol.readFirmware));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await writeRaw(OdysProtocol.readCommand(OdysProtocol.readBattery));
    await Future<void>.delayed(const Duration(milliseconds: 100));
    // The controller begins its 0x90/0x91/0x92 report stream after readCar.
    // Those report IDs are not themselves read commands.
    await writeRaw(OdysProtocol.readCommand(OdysProtocol.readCar));
  }

  Future<void> setCruise(bool enabled) async {
    if (_cruiseCompleter != null) {
      throw StateError('Another cruise-control command is still pending');
    }
    _pendingCruiseValue = enabled;
    _cruiseCompleter = Completer<void>();
    try {
      await writeRaw(OdysProtocol.writeByte(
        OdysProtocol.cruiseControl,
        enabled ? 1 : 0,
      ));
      log.add('Cruise control requested: ${enabled ? "enabled" : "disabled"}; '
          'waiting for controller acknowledgement');
      await _cruiseCompleter!.future.timeout(const Duration(seconds: 4));
      _cruiseVerifyCompleter = Completer<void>();
      await writeRaw(OdysProtocol.readCommand(OdysProtocol.readCar));
      await _cruiseVerifyCompleter!.future.timeout(const Duration(seconds: 4));
      log.add('Cruise control read-back confirmed: '
          '${enabled ? "enabled" : "disabled"}');
      notifyListeners();
    } finally {
      _cruiseCompleter = null;
      _cruiseVerifyCompleter = null;
      _pendingCruiseValue = null;
    }
  }

  Future<void> writeRaw(Uint8List bytes) async {
    if (_writeCharacteristic == null || !connected) {
      throw StateError('Scooter is not connected');
    }
    final completion = Completer<void>();
    log.packet('TX', bytes);
    _writeTail = _writeTail.catchError((Object _) {}).then((_) async {
      try {
        final characteristic = _writeCharacteristic;
        if (characteristic == null || !connected) {
          throw StateError('Scooter disconnected before queued BLE write');
        }
        await characteristic.write(
          bytes,
          withoutResponse: _writeWithoutResponse,
        );
        completion.complete();
      } catch (error, stack) {
        completion.completeError(error, stack);
      }
    });
    await completion.future;
  }

  Future<void> _writeDirect(Uint8List bytes) async {
    final characteristic = _writeCharacteristic;
    if (characteristic == null) throw StateError('Write channel unavailable');
    log.packet('TX', bytes);
    await characteristic.write(
      bytes,
      withoutResponse: _writeWithoutResponse,
    );
  }

  Future<void> _authenticateWithKeyFallback() async {
    final accountId = _accountId;
    if (accountId == null) {
      throw StateError('A valid ODYS account ID is required before connecting');
    }
    Object? lastError;
    for (var keyIndex = 0;
        keyIndex < DfuEngine.authenticationKeys.length;
        keyIndex++) {
      _authKeyIndex = keyIndex;
      _authChallengeSeen = false;
      _authEncryptionAccepted = false;
      _authCompleter = Completer<void>();
      log.add('Authentication attempt ${keyIndex + 1}/'
          '${DfuEngine.authenticationKeys.length}; key index $keyIndex');
      try {
        await _writeDirect(
          DfuEngine.initialAuthentication(
            keyIndex: keyIndex,
            userId: accountId,
          ),
        );
        await _authCompleter!.future.timeout(const Duration(seconds: 5));
        log.add('Authentication confirmed with key index $keyIndex');
        _authCompleter = null;
        return;
      } catch (error) {
        lastError = error;
        log.add('Authentication key $keyIndex failed: $error; '
            'challenge=$_authChallengeSeen, '
            'encryptionAccepted=$_authEncryptionAccepted');
        _authCompleter = null;
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
    throw TimeoutException(
      'Scooter authentication timed out after all five ODYS keys. '
      'Last stage: challenge=$_authChallengeSeen, '
      'encryptionAccepted=$_authEncryptionAccepted. Last error: $lastError',
    );
  }

  void beginFlash() {
    if (!stationaryLongEnough) {
      throw StateError('Scooter must remain at 0 km/h for five seconds');
    }
    phase = ConnectionPhase.flashing;
    _pollTimer?.cancel();
    _normalFrameBuffer.clear();
    _cruiseCompleter = null;
    _cruiseVerifyCompleter = null;
    _pendingCruiseValue = null;
    notifyListeners();
  }

  void finishFlash() {
    if (device?.isConnected == true) {
      phase = ConnectionPhase.connected;
      _resetMotionTrust();
      _startPolling();
      unawaited(refresh().catchError((Object error) {
        log.add('Post-flash refresh failed: $error');
      }));
    }
    notifyListeners();
  }

  void _onNotification(List<int> value) {
    if (value.isEmpty) return;
    final bytes = Uint8List.fromList(value);
    log.packet('RX', bytes);
    if (bytes.length >= 4 && bytes[0] == 0x55 && bytes[1] == 0xaa) {
      log.add(
        'RX command=0x${bytes[3].toRadixString(16).padLeft(2, '0')} '
        'length=${bytes.length}',
      );
    }
    _rawNotifications.add(bytes);
    if (phase == ConnectionPhase.flashing) return;
    _normalFrameBuffer.addAll(bytes);
    while (true) {
      final header = _findHeader(_normalFrameBuffer);
      if (header < 0) {
        if (_normalFrameBuffer.length > 1) {
          _normalFrameBuffer.removeRange(
            0,
            _normalFrameBuffer.length - 1,
          );
        }
        return;
      }
      if (header > 0) _normalFrameBuffer.removeRange(0, header);
      if (_normalFrameBuffer.length < 5) return;
      final totalLength = (_normalFrameBuffer[4] & 0xff) + 8;
      if (totalLength < 9 || totalLength > 260) {
        _normalFrameBuffer.removeAt(0);
        continue;
      }
      if (_normalFrameBuffer.length < totalLength) return;
      final packet = Uint8List.fromList(
        _normalFrameBuffer.sublist(0, totalLength),
      );
      _normalFrameBuffer.removeRange(0, totalLength);
      _handleFrame(packet);
    }
  }

  void _handleFrame(Uint8List bytes) {
    final frame = OdysProtocol.parseFrame(bytes);
    if (frame == null) {
      log.add('Ignored malformed notification (${bytes.length} bytes)');
      return;
    }
    if (frame.error != 0) {
      log.add('Controller error command=0x${frame.command.toRadixString(16)} '
          'error=${frame.error}');
      if ((frame.command == 0x30 || frame.command == 0x31) &&
          _authCompleter?.isCompleted == false) {
        _authCompleter!.completeError(StateError(
          'Controller rejected authentication command '
          '0x${frame.command.toRadixString(16)} with error ${frame.error}',
        ));
      }
      return;
    }
    if (frame.command == 0x30) {
      // The official controller finishes authentication with a short 0x30
      // success frame. A non-empty payload is the encryption challenge.
      if (frame.payload.isEmpty) {
        if (_authCompleter?.isCompleted == false) {
          _authCompleter!.complete();
        }
        log.add('Scooter authentication completed (0x30 confirmation)');
        return;
      }
      _authChallengeSeen = true;
      log.add('Authentication challenge received: '
          '${frame.payload.length} bytes, key index $_authKeyIndex');
      unawaited(Future<void>(() async {
        try {
          // The official app waits 200 ms before returning command 0x31.
          await Future<void>.delayed(const Duration(milliseconds: 200));
          final response = DfuEngine.normalAuthenticationResponse(
            frame.payload,
            keyIndex: _authKeyIndex,
          );
          await writeRaw(response);
          log.add('Authentication challenge response sent');
        } catch (error, stack) {
          log.add('Authentication response failed: $error');
          if (_authCompleter?.isCompleted == false) {
            _authCompleter!.completeError(error, stack);
          }
        }
      }));
      return;
    }
    if (frame.command == 0x31) {
      // 0x31 means the encrypted challenge was accepted. The official app
      // then repeats 0x30 and waits for the short 0x30 completion frame.
      _authEncryptionAccepted = true;
      log.add('Authentication encryption accepted; requesting confirmation');
      unawaited(Future<void>(() async {
        try {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await writeRaw(
            DfuEngine.initialAuthentication(
              keyIndex: _authKeyIndex,
              userId: _accountId!,
            ),
          );
        } catch (error, stack) {
          if (_authCompleter?.isCompleted == false) {
            _authCompleter!.completeError(error, stack);
          }
        }
      }));
      return;
    }
    final pendingCruise = _pendingCruiseValue;
    if (pendingCruise != null &&
        OdysProtocol.cruiseAcknowledged(frame, pendingCruise)) {
      if (_cruiseCompleter?.isCompleted == false) {
        _cruiseCompleter!.complete();
      }
      return;
    }
    if (frame.command == OdysProtocol.readCar && frame.payload.length >= 4) {
      cruiseEnabled = frame.payload[3] != 0;
      if (pendingCruise != null &&
          cruiseEnabled == pendingCruise &&
          _cruiseVerifyCompleter?.isCompleted == false) {
        _cruiseVerifyCompleter!.complete();
      }
    }
    final firmware = OdysProtocol.firmwareFrom(frame);
    if (firmware != null) versions = firmware;
    final battery = OdysProtocol.batteryFrom(frame, telemetry);
    if (battery != null) telemetry = battery;
    final beforeSpeedSamples = telemetry.speedSampleCount;
    final live = OdysProtocol.liveFrom(frame, telemetry);
    if (live != null) {
      telemetry = live;
      if (telemetry.speedSampleCount > beforeSpeedSamples) {
        final now = DateTime.now();
        if (_lastRealSpeedSample == null ||
            now.difference(_lastRealSpeedSample!) >=
                const Duration(seconds: 3)) {
          _stationarySamples = 0;
          _stationarySince = null;
        }
        _lastRealSpeedSample = now;
        if (telemetry.speedKmh <= 0.1) {
          _stationarySamples++;
          _stationarySince ??= now;
        } else {
          _stationarySamples = 0;
          _stationarySince = null;
        }
      }
    }
    notifyListeners();
  }

  static int _findHeader(List<int> bytes) {
    for (var i = 0; i + 1 < bytes.length; i++) {
      if (bytes[i] == 0x55 && bytes[i + 1] == 0xaa) return i;
    }
    return -1;
  }

  Future<void> disconnect() async {
    _manualDisconnect = true;
    _suppressAutoRecovery = true;
    _pollTimer?.cancel();
    await _notifySubscription?.cancel();
    await _connectionSubscription?.cancel();
    final target = device;
    if (target != null) await _safeDisconnect(target);
    device = null;
    _writeCharacteristic = null;
    _writeWithoutResponse = false;
    phase = ConnectionPhase.disconnected;
    _resetMotionTrust();
    _suppressAutoRecovery = false;
    notifyListeners();
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTick = 0;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 900), (_) async {
      if (phase != ConnectionPhase.connected) return;
      final command = _pollTick++ % 5 == 4
          ? OdysProtocol.readBattery
          : OdysProtocol.readCar;
      try {
        await writeRaw(OdysProtocol.readCommand(command));
        if (command == OdysProtocol.readBattery && device != null) {
          rssi = await device!.readRssi();
          notifyListeners();
        }
      } catch (error) {
        log.add('Telemetry poll error: $error');
      }
    });
  }

  Future<void> _recoverConnection() async {
    if (_manualDisconnect ||
        _suppressAutoRecovery ||
        device == null ||
        _recoveringConnection) {
      return;
    }
    _recoveringConnection = true;
    _suppressAutoRecovery = true;
    _pollTimer?.cancel();
    _resetMotionTrust();
    final interruptedFlash = phase == ConnectionPhase.flashing;
    phase = interruptedFlash
        ? ConnectionPhase.recovering
        : ConnectionPhase.reconnecting;
    notifyListeners();
    final target = device!;
    final maxAttempts = autoReconnect ? 6 : 3;
    for (var attempt = 1; attempt <= maxAttempts && !_manualDisconnect; attempt++) {
      log.add('Reconnect attempt $attempt/$maxAttempts');
      // Back off linearly, capped so a long retry tail does not stretch the
      // gap between attempts past a minute.
      await Future<void>.delayed(
        Duration(seconds: (attempt * 2).clamp(2, 20)),
      );
      try {
        await _connectDevice(target);
        log.add('Reconnect successful');
        if (interruptedFlash) {
          lastConnectionError =
              'BLE disconnected during DFU. Controller state was refreshed; '
              'do not retry until Recovery guidance is reviewed.';
        }
        _suppressAutoRecovery = false;
        _recoveringConnection = false;
        return;
      } catch (error) {
        lastConnectionError = 'Reconnect attempt $attempt failed: $error';
        log.add(lastConnectionError!);
      }
    }
    phase = ConnectionPhase.disconnected;
    _suppressAutoRecovery = false;
    _recoveringConnection = false;
    notifyListeners();
  }

  void _resetMotionTrust() {
    telemetry = const Telemetry();
    rssi = null;
    _normalFrameBuffer.clear();
    _stationarySince = null;
    _lastRealSpeedSample = null;
    _stationarySamples = 0;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _scanSubscription?.cancel();
    _notifySubscription?.cancel();
    _connectionSubscription?.cancel();
    _rawNotifications.close();
    super.dispose();
  }
}
