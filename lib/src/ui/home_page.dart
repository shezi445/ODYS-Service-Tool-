import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../ble/odys_ble_client.dart';
import '../charge_history.dart';
import '../dfu/dfu_engine.dart';
import '../gps_tracker.dart';
import '../models.dart';
import '../protocol/firmware_tools.dart';
import '../protocol/firmware_catalog.dart';
import '../session_log.dart';
import 'odys_theme.dart';
import 'pages/dashboard_page.dart';
import 'pages/flash_page.dart';
import 'pages/stats_page.dart';
import 'pages/tools_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({
    super.key,
    required this.log,
    required this.isDark,
    required this.onThemeToggle,
  });
  final SessionLog log;
  final bool isDark;
  final VoidCallback onThemeToggle;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final OdysBleClient client;
  late final DfuEngine dfu;
  StreamSubscription<DfuProgress>? _dfuSubscription;
  Timer? _clock;
  Timer? _phoneBatteryTimer;
  final Battery _phoneBattery = Battery();
  final TextEditingController _accountIdController = TextEditingController();
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  int? phoneBatteryPercent;

  SpeedProfile speed = SpeedProfile.limit32;
  MotorStartProfile motorStart = MotorStartProfile.kick1Normal2;
  DfuProgress progress = const DfuProgress(stage: 'Ready');
  bool stationaryConfirmed = false;
  bool experimentalRiskAccepted = false;
  bool flashing = false;
  FirmwareImage? prepared;
  String? preparationError;
  int _prepareGeneration = 0;
  int _tabIndex = 0;
  int _flashAttempt = 0;

  RideStats _rideStats = const RideStats();
  double? _lastSpeedForDistance;
  DateTime? _lastSpeedTime;
  final List<ConnectionRecord> _connectionHistory = [];

  // ── Lifetime odometer ──
  // Trip distance resets; this never does. Both come from the same
  // trapezoidal integral of live speed, so they share an accuracy ceiling —
  // the controller reports speed, not wheel revolutions.
  double _lifetimeKm = 0;
  double _unsavedOdometerKm = 0;
  DateTime? _lastOdometerSave;

  /// Writing on every 900 ms telemetry tick would hammer the preference store
  /// for no benefit, so accumulated distance is flushed on this interval.
  static const Duration _odometerSaveInterval = Duration(seconds: 20);

  // ── Charging monitor ──
  ChargeSession? _chargeSession;
  DateTime? _lastChargeSampleTime;

  /// Dedupes the 0x72 battery frame. `notifyListeners` fires several times per
  /// poll cycle, but only one of those carries a new battery reading.
  ///
  /// Shared by the charge and discharge integrators: the two are mutually
  /// exclusive, and whichever one is active is the only one that consumes a
  /// stamp, so one field is enough.
  DateTime? _lastBatteryStamp;

  // ── Ride energy (discharge integral) ──
  // The charging integral run with the sign reversed. Watt-hours divided by
  // trip distance is the consumption figure a range estimate needs.
  RideEnergy _rideEnergy = const RideEnergy();
  DateTime? _lastRideSampleTime;

  // ── Persisted charge history ──
  // A finished session is a capacity measurement; keeping them is the only way
  // this hardware can show real pack degradation over months.
  late final ChargeHistory _chargeHistory = ChargeHistory(_preferences);
  List<ChargeRecord> _chargeRecords = const [];

  /// Below this a session is a plug-in blip rather than a charge worth storing.
  static const int _minSamplesToRecord = 3;

  // ── GPS cross-check ──
  // The controller derives speed from commutation and a wheel constant, so it
  // can only ever confirm its own assumptions. GPS is the independent witness.
  late final GpsTracker _gps = GpsTracker(widget.log);
  bool _gpsEnabled = false;

  // ── Auto-reconnect ──
  bool _autoReconnect = true;
  String? _lastDeviceId;
  String? _lastDeviceName;
  bool _startupReconnectDone = false;

  // ── Auto-cruise ──
  // The controller only exposes a boolean cruise-enable flag (0x52), so this
  // arms and releases that flag around a speed threshold. The controller still
  // performs the actual cruise latch on steady throttle.
  bool _autoCruise = false;
  int _autoCruiseSpeedKmh = 20;
  bool _autoCruiseBusy = false;
  DateTime? _lastAutoCruiseAction;

  /// Release margin below the threshold. Without a band, speed jitter around
  /// the setpoint would issue a cruise command on almost every poll.
  static const double _autoCruiseHysteresisKmh = 3;

  /// A single setCruise round trip is an ack plus a read-back, each with a 4 s
  /// timeout, so commands must not be issued faster than this.
  static const Duration _autoCruiseCooldown = Duration(seconds: 6);

  static const List<int> autoCruiseSpeedOptions = [
    10, 12, 15, 18, 20, 22, 25, 28, 30,
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    client = OdysBleClient(widget.log)..addListener(_changed);
    _gps.addListener(_gpsChanged);
    dfu = DfuEngine(
      write: client.writeRaw,
      notifications: client.rawNotifications,
      log: widget.log,
    );
    _dfuSubscription = dfu.progress.listen((event) {
      if (mounted) setState(() => progress = event);
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && client.connected) setState(() {});
    });
    _refreshPhoneBattery();
    _loadSavedAccountId();
    _loadAutoCruiseSettings();
    _loadPersistedState();
    _phoneBatteryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshPhoneBattery(),
    );
    _prepareFirmware();
  }

  Future<void> _loadSavedAccountId() async {
    final saved = await _preferences.getString('odys_account_id');
    if (mounted && saved != null) _accountIdController.text = saved;
  }

  /// Loads the lifetime odometer and the auto-reconnect preference, then makes
  /// the one startup reconnect attempt. Ordered: the account ID must be in the
  /// controller before a reconnect can authenticate.
  Future<void> _loadPersistedState() async {
    final km = await _preferences.getDouble('odys_lifetime_km');
    final autoReconnect = await _preferences.getBool('odys_auto_reconnect');
    final deviceId = await _preferences.getString('odys_last_device_id');
    final deviceName = await _preferences.getString('odys_last_device_name');
    final accountId = await _preferences.getString('odys_account_id');
    final gpsEnabled = await _preferences.getBool('odys_gps_enabled');
    final records = await _chargeHistory.load();
    if (!mounted) return;
    setState(() {
      _lifetimeKm = km ?? 0;
      _autoReconnect = autoReconnect ?? true;
      _lastDeviceId = deviceId;
      _lastDeviceName = deviceName;
      _chargeRecords = records;
      _gpsEnabled = gpsEnabled ?? false;
      if (accountId != null && _accountIdController.text.isEmpty) {
        _accountIdController.text = accountId;
      }
    });
    client.autoReconnect = _autoReconnect;
    // Restarting tracking on launch is what the switch means; the permission
    // has already been granted, so this raises no dialog.
    if (_gpsEnabled) unawaited(_gps.start());
    if (_autoReconnect && deviceId != null && !_startupReconnectDone) {
      _startupReconnectDone = true;
      // Give the BLE adapter a moment to report itself as on.
      await Future<void>.delayed(const Duration(seconds: 2));
      if (mounted) await _reconnectLast(silent: true);
    }
  }

  void _gpsChanged() {
    if (mounted) setState(() {});
  }

  /// Starts or stops satellite tracking and remembers the choice.
  ///
  /// A refused permission flips the switch back rather than leaving it on over
  /// a tracker that will never produce a fix — that way tapping it again is a
  /// retry instead of a no-op.
  Future<void> _setGpsEnabled(bool value) async {
    setState(() => _gpsEnabled = value);
    await _preferences.setBool('odys_gps_enabled', value);
    if (!value) {
      await _gps.stop();
      return;
    }
    await _gps.start();
    if (!mounted) return;
    final failure = switch (_gps.status) {
      GpsStatus.denied =>
        'Location permission is required for the GPS cross-check. Grant it in '
            'system settings, then switch this back on.',
      GpsStatus.serviceDisabled =>
        'Turn on location services, then switch this back on.',
      GpsStatus.failed => 'GPS unavailable: ${_gps.error ?? "unknown error"}',
      _ => null,
    };
    if (failure == null) {
      _message('GPS cross-check on. Ride at least 300 m before the distance '
          'comparison means anything.');
      return;
    }
    setState(() => _gpsEnabled = false);
    await _preferences.setBool('odys_gps_enabled', false);
    _message(failure);
  }

  /// Reconnects to the last known scooter without scanning. Silent mode is for
  /// the automatic startup attempt, where a failure is expected whenever the
  /// scooter simply is not nearby.
  Future<void> _reconnectLast({bool silent = false}) async {
    final deviceId = _lastDeviceId;
    if (deviceId == null) {
      if (!silent) _message('No saved scooter yet — scan once first.');
      return;
    }
    final accountText = _accountIdController.text.trim();
    final accountId = RegExp(r'^\d+$').hasMatch(accountText)
        ? int.tryParse(accountText)
        : null;
    if (accountId == null || accountId <= 0 || accountId > 0xffffffff) {
      if (!silent) _message('Enter your ODYS account ID before reconnecting.');
      return;
    }
    if (client.phase != ConnectionPhase.disconnected) return;
    try {
      widget.log.add('Direct reconnect to $deviceId '
          '(${silent ? "automatic" : "manual"})');
      await client.connectToDevice(
        BluetoothDevice.fromId(deviceId),
        accountId: accountId,
      );
    } catch (error) {
      widget.log.add('Direct reconnect failed: $error');
      if (!silent) _message('Reconnect failed: $error');
    }
  }

  Future<void> _setAutoReconnect(bool value) async {
    setState(() => _autoReconnect = value);
    client.autoReconnect = value;
    await _preferences.setBool('odys_auto_reconnect', value);
  }

  Future<void> _resetOdometer() async {
    setState(() {
      _lifetimeKm = 0;
      _unsavedOdometerKm = 0;
    });
    _lastOdometerSave = DateTime.now();
    await _preferences.setDouble('odys_lifetime_km', 0);
    _message('Lifetime odometer reset to zero.');
  }

  /// Flushes accumulated distance, rate-limited unless [force] is set.
  Future<void> _saveOdometer({bool force = false}) async {
    if (_unsavedOdometerKm <= 0) return;
    final now = DateTime.now();
    if (!force &&
        _lastOdometerSave != null &&
        now.difference(_lastOdometerSave!) < _odometerSaveInterval) {
      return;
    }
    _lastOdometerSave = now;
    _unsavedOdometerKm = 0;
    await _preferences.setDouble('odys_lifetime_km', _lifetimeKm);
  }

  Future<void> _loadAutoCruiseSettings() async {
    final enabled = await _preferences.getBool('odys_auto_cruise');
    final threshold = await _preferences.getInt('odys_auto_cruise_speed');
    if (!mounted) return;
    setState(() {
      _autoCruise = enabled ?? false;
      if (threshold != null && autoCruiseSpeedOptions.contains(threshold)) {
        _autoCruiseSpeedKmh = threshold;
      }
    });
  }

  /// Arms or releases the controller's cruise-enable flag around the chosen
  /// speed. Never runs while flashing, while disconnected, or while a cruise
  /// command is already in flight.
  Future<void> _evaluateAutoCruise() async {
    if (!_autoCruise || flashing || _autoCruiseBusy) return;
    if (client.phase != ConnectionPhase.connected) return;

    final t = client.telemetry;
    if (!t.hasTrustedSpeed) return;

    final now = DateTime.now();
    if (_lastAutoCruiseAction != null &&
        now.difference(_lastAutoCruiseAction!) < _autoCruiseCooldown) {
      return;
    }

    final target = _autoCruiseSpeedKmh.toDouble();
    final bool? desired = t.speedKmh >= target
        ? true
        : t.speedKmh <= target - _autoCruiseHysteresisKmh
            ? false
            : null; // inside the hysteresis band — leave the flag alone
    if (desired == null || desired == client.cruiseEnabled) return;

    _autoCruiseBusy = true;
    _lastAutoCruiseAction = now;
    try {
      await client.setCruise(desired);
      widget.log.add(
        'Auto-cruise ${desired ? "armed" : "released"} at '
        '${t.speedKmh.toStringAsFixed(1)} km/h '
        '(threshold $_autoCruiseSpeedKmh km/h)',
      );
    } catch (error) {
      widget.log.add('Auto-cruise command failed: $error');
    } finally {
      _autoCruiseBusy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _setAutoCruise(bool value) async {
    setState(() {
      _autoCruise = value;
      _lastAutoCruiseAction = null;
    });
    await _preferences.setBool('odys_auto_cruise', value);
    if (value) {
      _message('Auto-cruise armed above $_autoCruiseSpeedKmh km/h. The '
          'controller still latches on steady throttle.');
      unawaited(_evaluateAutoCruise());
    }
  }

  Future<void> _setAutoCruiseSpeed(int? value) async {
    if (value == null) return;
    setState(() {
      _autoCruiseSpeedKmh = value;
      _lastAutoCruiseAction = null;
    });
    await _preferences.setInt('odys_auto_cruise_speed', value);
    unawaited(_evaluateAutoCruise());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (flashing && state != AppLifecycleState.resumed) {
      widget.log
          .add('App left foreground during DFU; safe cancellation requested');
      dfu.requestCancel();
    }
    if (state != AppLifecycleState.resumed) {
      // Last reliable moment to persist distance before the process may be
      // killed in the background.
      unawaited(_saveOdometer(force: true));
    }
  }

  Future<void> _refreshPhoneBattery() async {
    try {
      final level = await _phoneBattery.batteryLevel;
      if (mounted) setState(() => phoneBatteryPercent = level);
    } catch (error) {
      widget.log.add('Phone battery query failed: $error');
    }
  }

  void _changed() {
    if (!mounted) return;
    setState(() {
      if (!client.stationaryLongEnough) stationaryConfirmed = false;
      _updateRideStats();
      _updateChargeSession();
      _updateRideEnergy();
      _checkConnectionHistory();
    });
    // Fire-and-forget: re-entrancy from setCruise's own notifyListeners is
    // blocked by the _autoCruiseBusy guard.
    unawaited(_evaluateAutoCruise());
    unawaited(_saveOdometer());
  }

  /// Folds the 0x72 battery frame into the current charging session.
  ///
  /// Called from the listener, so it runs several times per poll cycle; the
  /// integration is gated on a new battery timestamp to keep the trapezoid
  /// steps honest and the sample count meaningful.
  void _updateChargeSession() {
    final t = client.telemetry;
    final now = DateTime.now();
    // Deliberately not gated on hasFreshBattery: that window can lapse if one
    // poll is dropped, which would close the session and lose the accumulated
    // integral. Disconnecting clears telemetry, so isCharging goes null there.
    final charging = t.isCharging == true;

    if (!charging) {
      final open = _chargeSession;
      if (open != null && open.active) {
        final closed = open.copyWith(endedAt: now);
        _chargeSession = closed;
        _lastChargeSampleTime = null;
        widget.log.add('Charge session ended: '
            '${open.ampHours.toStringAsFixed(3)} Ah, '
            '${open.wattHours.toStringAsFixed(1)} Wh, '
            'peak ${open.peakAmps.toStringAsFixed(2)} A');
        // Persisting happens here rather than on a timer because this is the
        // only moment the session is both finished and still in memory.
        unawaited(_recordChargeSession(closed, now));
      }
      return;
    }

    // Only a 0x72 frame refreshes batteryLastUpdate, so this is one reading.
    final stamp = t.batteryLastUpdate;
    if (stamp == null || stamp == _lastBatteryStamp) return;
    _lastBatteryStamp = stamp;

    // The frame's current is signed to indicate direction; isCharging already
    // tells us that, so only the magnitude matters here.
    final amps = (t.current ?? 0).abs();
    final volts = t.voltage ?? 0;

    final open = _chargeSession;
    if (open == null || !open.active) {
      _chargeSession = ChargeSession(
        startedAt: now,
        startPercent: t.batteryPercent,
        lastPercent: t.batteryPercent,
        startVolts: volts,
        lastAmps: amps,
        lastVolts: volts,
        peakAmps: amps,
        sampleCount: 1,
      );
      _lastChargeSampleTime = now;
      widget.log.add('Charge session started at '
          '${t.batteryPercent ?? "?"}%, ${amps.toStringAsFixed(2)} A, '
          '${volts.toStringAsFixed(2)} V');
      return;
    }

    var ampHours = open.ampHours;
    var wattHours = open.wattHours;
    final previous = _lastChargeSampleTime;
    if (previous != null) {
      final hours = now.difference(previous).inMilliseconds / 3600000.0;
      // Discard gaps longer than a minute. A backgrounded app or a stalled BLE
      // link would otherwise integrate one stale current reading across the
      // whole gap and wildly overstate delivered charge.
      if (hours > 0 && hours < 1 / 60) {
        final avgAmps = (amps + open.lastAmps) / 2;
        final avgVolts = (volts + open.lastVolts) / 2;
        ampHours += avgAmps * hours;
        wattHours += avgAmps * avgVolts * hours;
      }
    }

    _chargeSession = open.copyWith(
      ampHours: ampHours,
      wattHours: wattHours,
      peakAmps: amps > open.peakAmps ? amps : open.peakAmps,
      lastAmps: amps,
      lastVolts: volts,
      lastPercent: t.batteryPercent ?? open.lastPercent,
      sampleCount: open.sampleCount + 1,
    );
    _lastChargeSampleTime = now;
  }

  /// Appends a finished charge session to the persistent history.
  ///
  /// Trivial sessions are dropped: plugging in and straight back out produces a
  /// one- or two-sample record that adds nothing but noise to the totals.
  Future<void> _recordChargeSession(ChargeSession session, DateTime endedAt) async {
    if (session.sampleCount < _minSamplesToRecord || session.ampHours <= 0) {
      return;
    }
    final record = ChargeRecord.fromSession(session, endedAt);
    final updated = [..._chargeRecords, record];
    try {
      await _chargeHistory.save(updated);
    } catch (error) {
      widget.log.add('Charge history save failed: $error');
      return;
    }
    // Re-read rather than trusting the local list, so what is displayed is
    // exactly what survived the cap.
    final stored = await _chargeHistory.load();
    if (!mounted) return;
    setState(() => _chargeRecords = stored);
    widget.log.add('Charge session stored '
        '(${stored.length} kept, '
        '${record.impliedPackAh?.toStringAsFixed(2) ?? "no"} Ah implied)');
  }

  Future<void> _clearChargeHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Clear charge history?',
            style: TextStyle(fontWeight: FontWeight.w700)),
        content: Text(
          '${_chargeRecords.length} stored charge sessions will be deleted. '
          'Capacity trend and degradation start over from the next full '
          'charge, which takes weeks to rebuild.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _chargeHistory.clear();
    if (!mounted) return;
    setState(() => _chargeRecords = const []);
    _message('Charge history cleared.');
  }

  /// The charging integral, run with the sign reversed.
  ///
  /// Only runs when the pack is explicitly discharging: `isCharging` is null
  /// when telemetry has never arrived or the link dropped, and integrating
  /// across that would invent consumption out of a stale reading.
  void _updateRideEnergy() {
    final t = client.telemetry;
    if (t.isCharging != false) return;

    final stamp = t.batteryLastUpdate;
    if (stamp == null || stamp == _lastBatteryStamp) return;
    _lastBatteryStamp = stamp;

    final amps = (t.current ?? 0).abs();
    final volts = t.voltage ?? 0;
    if (volts <= 0) return;

    final now = DateTime.now();
    var ampHours = _rideEnergy.ampHours;
    var wattHours = _rideEnergy.wattHours;
    final previous = _lastRideSampleTime;
    if (previous != null) {
      final hours = now.difference(previous).inMilliseconds / 3600000.0;
      // Same gap rejection as the charge integral: a backgrounded app must not
      // smear one stale current reading across the whole interruption.
      if (hours > 0 && hours < 1 / 60) {
        final avgAmps = (amps + _rideEnergy.lastAmps) / 2;
        final avgVolts = (volts + _rideEnergy.lastVolts) / 2;
        ampHours += avgAmps * hours;
        wattHours += avgAmps * avgVolts * hours;
      }
    }

    // Re-anchor if the pack was charged mid-trip, otherwise the percent slope
    // used for the fallback pack size would go negative and stay there.
    final percent = t.batteryPercent;
    final anchor = _rideEnergy.startPercent;
    final startPercent = anchor == null || (percent != null && percent > anchor)
        ? percent
        : anchor;

    _rideEnergy = _rideEnergy.copyWith(
      ampHours: ampHours,
      wattHours: wattHours,
      lastAmps: amps,
      lastVolts: volts,
      peakAmps: amps > _rideEnergy.peakAmps ? amps : _rideEnergy.peakAmps,
      startPercent: startPercent,
      lastPercent: percent ?? _rideEnergy.lastPercent,
      sampleCount: _rideEnergy.sampleCount + 1,
    );
    _lastRideSampleTime = now;
  }

  /// Clears everything that belongs to one trip: distance, speed history, the
  /// discharge integral and the GPS odometer, so the two distance figures stay
  /// comparable.
  void _resetTrip() {
    setState(() {
      _rideStats = const RideStats();
      _lastSpeedForDistance = null;
      _lastSpeedTime = null;
      _rideEnergy = const RideEnergy();
      _lastRideSampleTime = null;
    });
    _gps.resetTrip();
  }

  void _updateRideStats() {
    final t = client.telemetry;
    if (!t.hasTrustedSpeed) return;
    final now = DateTime.now();
    final speed = t.speedKmh;

    // accumulate distance
    if (_lastSpeedForDistance != null && _lastSpeedTime != null) {
      final dt = now.difference(_lastSpeedTime!).inMilliseconds / 3600000.0;
      final avgKmh = (speed + _lastSpeedForDistance!) / 2;
      final delta = avgKmh * dt;
      final newHistory = List<SpeedSample>.from(_rideStats.speedHistory)
        ..add(SpeedSample(speedKmh: speed, time: now));
      if (newHistory.length > 200) newHistory.removeAt(0);
      _rideStats = _rideStats.copyWith(
        tripDistanceKm: _rideStats.tripDistanceKm + delta,
        maxSpeedKmh: speed > _rideStats.maxSpeedKmh
            ? speed
            : _rideStats.maxSpeedKmh,
        totalSpeedSum: _rideStats.totalSpeedSum + speed,
        sampleCount: _rideStats.sampleCount + 1,
        speedHistory: newHistory,
        tripStart: _rideStats.tripStart ?? now,
      );
      // Same integral, but this accumulator is never reset by "Reset trip".
      _lifetimeKm += delta;
      _unsavedOdometerKm += delta;
    }
    _lastSpeedForDistance = speed;
    _lastSpeedTime = now;
  }

  void _checkConnectionHistory() {
    if (client.phase == ConnectionPhase.connected &&
        client.device != null &&
        (_connectionHistory.isEmpty ||
            _connectionHistory.last.deviceId !=
                client.device!.remoteId.str)) {
      _connectionHistory.add(ConnectionRecord(
        deviceName: client.device!.platformName,
        deviceId: client.device!.remoteId.str,
        connectedAt: DateTime.now(),
      ));
      _rememberDevice(client.device!);
    }
  }

  /// Persists the remote ID so auto-reconnect can skip the scan next time.
  void _rememberDevice(BluetoothDevice device) {
    final id = device.remoteId.str;
    final name = device.platformName;
    _lastDeviceId = id;
    _lastDeviceName = name;
    unawaited(_preferences.setString('odys_last_device_id', id));
    unawaited(_preferences.setString('odys_last_device_name', name));
  }

  Future<void> _prepareFirmware() async {
    final generation = ++_prepareGeneration;
    try {
      await FirmwareCatalog.verify();
      final stock = await rootBundle.load('assets/firmware/bldc_stock_de.bin');
      final verified = await rootBundle.load(
        'assets/firmware/BLDC_DE_32kmh_Kick1_Normal2_DualCRC.bin',
      );
      final experimental40 = await rootBundle.load(
        'assets/firmware/'
        'BLDC_DE_40kmh_EXPERIMENTAL_Kick1_Normal2_DualCRC.bin',
      );
      final experimental40Kick2 = await rootBundle.load(
        'assets/firmware/'
        'BLDC_DE_40kmh_Kick2kmh_Normal2_DualCRC.bin',
      );
      final image = FirmwareTools.buildProfile(
        stock: stock.buffer.asUint8List(),
        verified32: verified.buffer.asUint8List(),
        experimental40: experimental40.buffer.asUint8List(),
        experimental40Kick2: experimental40Kick2.buffer.asUint8List(),
        speed: speed,
        motorStart:
            speed == SpeedProfile.stock ? MotorStartProfile.stock : motorStart,
      );
      if (mounted && generation == _prepareGeneration) {
        setState(() {
          prepared = image;
          preparationError = null;
        });
      }
    } catch (error) {
      if (mounted && generation == _prepareGeneration) {
        setState(() {
          prepared = null;
          preparationError = '$error';
        });
      }
    }
  }

  Future<void> _scanAndConnect() async {
    final accountText = _accountIdController.text.trim();
    final accountId = RegExp(r'^\d+$').hasMatch(accountText)
        ? int.tryParse(accountText)
        : null;
    if (accountId == null || accountId <= 0 || accountId > 0xffffffff) {
      _message('Enter a positive 32-bit numeric ODYS account ID first.');
      return;
    }
    try {
      await _preferences.setString('odys_account_id', accountText);
      await client.scan();
      if (!mounted) return;
      final result = await showModalBottomSheet<ScanResult>(
        context: context,
        showDragHandle: true,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (context) => _Scanner(results: client.scanResults),
      );
      if (result != null) await client.connect(result, accountId: accountId);
    } catch (error) {
      _message('Bluetooth error: $error');
    }
  }

  Future<void> _flash() async {
    final image = prepared;
    if (image == null) return;
    final preflight = _preflight();
    if (!preflight.$1) {
      _message(preflight.$2);
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Flash BLDC controller?',
            style: TextStyle(fontWeight: FontWeight.w700)),
        content: Text(
          '${image.speed.label}\n${image.motorStart.label}\n\n'
          'Keep the scooter powered, stationary, close to the phone, and do '
          'not leave the app until controller verification completes.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Flash'),
          ),
        ],
      ),
    );
    if (accepted != true) return;

    setState(() {
      flashing = true;
      _flashAttempt++;
      _tabIndex = 1;
    });
    try {
      client.beginFlash();
      await WakelockPlus.enable();
      widget.log.add(
        'PRE-FLASH attempt=$_flashAttempt profile=${image.speed.name} '
        'sha256=${image.sha256} '
        'inner=${image.innerCrc.toRadixString(16)} '
        'outer=${image.outerCrc.toRadixString(16)}',
      );
      await dfu.flash(image.bytes);
      widget.log.add(
        'POST-FLASH controller returned dfu_ok for sha256=${image.sha256}; '
        'this controller does not expose firmware-content readback',
      );
      if (mounted) setState(() => _flashAttempt = 0);
      _message(
        'Controller accepted the image and returned dfu_ok. '
        'Reconnect and verify telemetry before riding.',
      );
    } catch (error) {
      _message('Flash stopped: $error. Retry from the Firmware tab, or open '
          'Recovery in Tools if the scooter is unresponsive.');
    } finally {
      try {
        await WakelockPlus.disable();
      } catch (error) {
        widget.log.add('Wakelock release warning: $error');
      }
      client.finishFlash();
      if (mounted) setState(() => flashing = false);
    }
  }

  (bool, String) _preflight() {
    final t = client.telemetry;
    final compatibility =
        FirmwareTools.compatibilityFor(client.versions, profile: speed);
    if (client.phase != ConnectionPhase.connected) {
      return (false, 'Wait until connection and authentication are complete.');
    }
    if (!compatibility.allowed) return (false, compatibility.reason);
    if (!t.hasTrustedSpeed || !client.stationaryLongEnough) {
      return (
        false,
        'Fresh live-speed packets must show 0 km/h for 5 seconds.'
      );
    }
    if (!t.hasFreshBattery || t.batteryPercent == null) {
      return (false, 'Wait for a fresh battery status packet.');
    }
    if (t.batteryPercent! < 30) {
      return (false, 'Scooter battery must be at least 30%.');
    }
    if (phoneBatteryPercent == null || phoneBatteryPercent! < 30) {
      return (false, 'Phone battery must be at least 30%.');
    }
    if (client.rssi == null || client.rssi! < -85) {
      return (
        false,
        'Move the phone closer; BLE signal must be at least -85 dBm.'
      );
    }
    if (t.isCharging == true) {
      return (false, 'Unplug the scooter charger before flashing.');
    }
    final temperature = t.batteryTemperature;
    if (temperature == null || temperature < 0 || temperature > 50) {
      return (false, 'Battery temperature must be between 0°C and 50°C.');
    }
    if ((t.errorCode ?? 0) != 0) {
      return (false, 'Clear controller error ${t.errorCode} before flashing.');
    }
    if (!stationaryConfirmed) {
      return (false, 'Confirm that the scooter is parked and off throttle.');
    }
    if (speed.experimental && !experimentalRiskAccepted) {
      return (
        false,
        'Acknowledge that the 40 km/h profile is experimental and unvalidated.',
      );
    }
    return (true, 'All pre-flight checks passed.');
  }

  Future<void> _prepareOriginalRestore() async {
    setState(() {
      speed = SpeedProfile.stock;
      motorStart = MotorStartProfile.stock;
      stationaryConfirmed = false;
      experimentalRiskAccepted = false;
    });
    await _prepareFirmware();
    _message(
        'Original DE firmware selected. Complete safety checks, then Flash.');
  }

  Future<void> _retryFlash() async {
    if (flashing) return;
    final preflight = _preflight();
    if (!preflight.$1) {
      _message(preflight.$2);
      return;
    }
    widget.log.add('Retry requested after failed attempt $_flashAttempt');
    setState(() => progress = const DfuProgress(stage: 'Retrying'));
    await _flash();
  }

  void _handleSpeedChange(SpeedProfile? value) {
    if (value == null) return;
    setState(() {
      speed = value;
      if (value == SpeedProfile.stock) {
        motorStart = MotorStartProfile.stock;
      } else if (value.experimental) {
        motorStart = MotorStartProfile.kick1Normal2;
      }
      stationaryConfirmed = false;
      experimentalRiskAccepted = false;
      _flashAttempt = 0;
      progress = const DfuProgress(stage: 'Ready');
    });
    _prepareFirmware();
  }

  /// Quick-switch from the dashboard chips. Selecting a profile only stages
  /// the image — flashing still goes through the full pre-flight on the
  /// Firmware tab.
  void _handleQuickSpeedSelect(SpeedProfile value) {
    if (flashing || value == speed) return;
    _handleSpeedChange(value);
    _message(value.experimental
        ? '${value.label} staged. Acknowledge the experimental warning on the '
            'Firmware tab before flashing.'
        : '${value.label} staged. Complete pre-flight on the Firmware tab to '
            'flash it.');
  }

  void _handleMotorStartChange(MotorStartProfile? value) {    if (value == null) return;
    setState(() => motorStart = value);
    _prepareFirmware();
  }

  Future<void> _handleCruise(bool value) async {
    try {
      await client.setCruise(value);
    } catch (error) {
      _message('Cruise command failed: $error');
    }
  }

  /// The odometer is meant to be permanent, so a reset asks first.
  Future<void> _confirmResetOdometer() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Reset lifetime odometer?',
            style: TextStyle(fontWeight: FontWeight.w700)),
        content: Text(
          '${_lifetimeKm.toStringAsFixed(2)} km will be cleared. This cannot '
          'be undone, and it does not affect anything stored on the scooter.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed == true) await _resetOdometer();
  }

  Future<void> _shareLog() async {
    final file = await widget.log.export();
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'ODYS BLE/DFU diagnostic log',
    );
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: AppColors.surfaceHi,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preflight = _preflight();
    final chargeStats = ChargeHistoryStats(_chargeRecords);

    // GPS distance is the better denominator for consumption when it exists: it
    // carries none of the controller's wheel-size assumption. Below 300 m it is
    // mostly receiver scatter, so the reported figure stands in.
    final consumptionKm = _gps.distanceKm >= 0.3
        ? _gps.distanceKm
        : _rideStats.tripDistanceKm;
    final whPerKm = _rideEnergy.whPerKm(consumptionKm);
    final range = RangeEstimate.compute(
      energy: _rideEnergy,
      tripKm: consumptionKm,
      batteryPercent: client.telemetry.batteryPercent,
      measuredPackWh: chargeStats.packWh,
    );

    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _tabIndex,
          children: [
            DashboardPage(
              client: client,
              phoneBatteryPercent: phoneBatteryPercent,
              flashing: flashing,
              accountIdController: _accountIdController,
              speed: speed,
              onConnect: _scanAndConnect,
              onDisconnect: client.disconnect,
              onCruiseChanged: _handleCruise,
              autoCruise: _autoCruise,
              autoCruiseSpeedKmh: _autoCruiseSpeedKmh,
              autoCruiseSpeedOptions: autoCruiseSpeedOptions,
              autoCruiseBusy: _autoCruiseBusy,
              onAutoCruiseChanged: _setAutoCruise,
              onAutoCruiseSpeedChanged: _setAutoCruiseSpeed,
              onSpeedSelected: _handleQuickSpeedSelect,
              onOpenFlash: () => setState(() => _tabIndex = 1),
              chargeSession: _chargeSession,
              lastDeviceName: _lastDeviceName,
              canReconnect: _lastDeviceId != null,
              onReconnect: _reconnectLast,
              rangeEstimate: range,
              whPerKm: whPerKm,
              gpsSpeedKmh: _gps.hasFreshFix ? _gps.speedKmh : null,
            ),
            FlashPage(
              client: client,
              speed: speed,
              motorStart: motorStart,
              prepared: prepared,
              preparationError: preparationError,
              stationaryConfirmed: stationaryConfirmed,
              experimentalRiskAccepted: experimentalRiskAccepted,
              flashing: flashing,
              progress: progress,
              phoneBatteryPercent: phoneBatteryPercent,
              preflightOk: preflight.$1,
              preflightReason: preflight.$2,
              attempt: _flashAttempt,
              onSpeedChanged: _handleSpeedChange,
              onMotorStartChanged: _handleMotorStartChange,
              onStationaryChanged: (v) =>
                  setState(() => stationaryConfirmed = v ?? false),
              onExperimentalChanged: (v) =>
                  setState(() => experimentalRiskAccepted = v ?? false),
              onFlash: _flash,
              onRetryFlash: _retryFlash,
              onRestore: _prepareOriginalRestore,
              onCancelFlash: dfu.requestCancel,
            ),
            StatsPage(
              rideStats: _rideStats,
              telemetry: client.telemetry,
              connectionHistory: _connectionHistory,
              onResetTrip: _resetTrip,
              lifetimeKm: _lifetimeKm,
              onResetOdometer: _confirmResetOdometer,
              chargeSession: _chargeSession,
              autoReconnect: _autoReconnect,
              onAutoReconnectChanged: _setAutoReconnect,
              lastDeviceName: _lastDeviceName,
              isDark: widget.isDark,
              onThemeToggle: widget.onThemeToggle,
              rideEnergy: _rideEnergy,
              rangeEstimate: range,
              whPerKm: whPerKm,
              consumptionKm: consumptionKm,
              chargeStats: chargeStats,
              onClearChargeHistory: _clearChargeHistory,
              gps: _gps,
              gpsEnabled: _gpsEnabled,
              onGpsEnabledChanged: _setGpsEnabled,
            ),
            ToolsPage(
              client: client,
              flashing: flashing,
              onShareLog: _shareLog,
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        height: 68,
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        surfaceTintColor: Colors.transparent,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.speed_outlined),
            selectedIcon: Icon(Icons.speed),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: flashing,
              backgroundColor: AppColors.warning,
              child: const Icon(Icons.system_update_alt_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: flashing,
              backgroundColor: AppColors.warning,
              child: const Icon(Icons.system_update_alt),
            ),
            label: 'Flash',
          ),
          const NavigationDestination(
            icon: Icon(Icons.bar_chart_outlined),
            selectedIcon: Icon(Icons.bar_chart),
            label: 'Stats',
          ),
          const NavigationDestination(
            icon: Icon(Icons.build_outlined),
            selectedIcon: Icon(Icons.build),
            label: 'Tools',
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_saveOdometer(force: true));
    _accountIdController.dispose();
    _clock?.cancel();
    _phoneBatteryTimer?.cancel();
    _dfuSubscription?.cancel();
    _gps
      ..removeListener(_gpsChanged)
      ..dispose();
    client
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  BLE Scanner bottom sheet
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _Scanner extends StatelessWidget {
  const _Scanner({required this.results});
  final List<ScanResult> results;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text('Nearby devices',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  )),
          const SizedBox(height: 12),
          if (results.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                children: [
                  Icon(Icons.bluetooth_searching_rounded,
                      size: 40, color: AppColors.textDim),
                  const SizedBox(height: 8),
                  const Text('No devices found',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.text)),
                  const Text('Power-cycle the scooter and scan again.',
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textDim)),
                ],
              ),
            ),
          for (final result in results)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primaryDim,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.electric_scooter_rounded,
                      size: 20, color: AppColors.primary),
                ),
                title: Text(
                  result.advertisementData.advName.isEmpty
                      ? 'Unnamed device'
                      : result.advertisementData.advName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                    '${result.device.remoteId.str}  ${result.rssi} dBm',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textDim)),
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textDim),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                onTap: () => Navigator.pop(context, result),
              ),
            ),
        ],
      ),
    );
  }
}
