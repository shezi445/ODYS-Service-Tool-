import 'dart:async';
import 'dart:convert' as convert;
import 'dart:typed_data';

import 'package:encrypt/encrypt.dart' as crypt;

import '../models.dart';
import '../protocol/firmware_tools.dart';
import '../session_log.dart';

typedef RawWriter = Future<void> Function(Uint8List bytes);

class DfuEngine {
  DfuEngine({
    required this.write,
    required this.notifications,
    required this.log,
  });

  final RawWriter write;
  final Stream<Uint8List> notifications;
  final SessionLog log;
  final _progress = StreamController<DfuProgress>.broadcast();
  bool _cancelRequested = false;
  int _lastAcknowledgedBlock = 0;

  Stream<DfuProgress> get progress => _progress.stream;
  int get lastAcknowledgedBlock => _lastAcknowledgedBlock;

  void requestCancel() {
    _cancelRequested = true;
    log.add('DFU cancellation requested; stopping before next write');
  }

  // All five normal/DFU authentication keys recovered from the official app.
  // The key index is included in command 0x30, so the response must use the
  // same indexed key.
  static final List<Uint8List> authenticationKeys = [
    Uint8List.fromList(List<int>.generate(16, (i) => 0xa0 + i)),
    Uint8List.fromList(const [
      0x44,
      0x6d,
      0x10,
      0x72,
      0x6d,
      0xbe,
      0x05,
      0xf6,
      0x62,
      0xdf,
      0xaa,
      0xf0,
      0x13,
      0x27,
      0x30,
      0x3f,
    ]),
    Uint8List.fromList(const [
      0xa2,
      0x85,
      0xcc,
      0xec,
      0x81,
      0x4f,
      0xe9,
      0x61,
      0x74,
      0x29,
      0x95,
      0xe8,
      0xeb,
      0xa9,
      0x22,
      0x47,
    ]),
    Uint8List.fromList(const [
      0x3f,
      0xee,
      0x80,
      0xff,
      0x96,
      0xdf,
      0x5c,
      0xf5,
      0x42,
      0xea,
      0xac,
      0x93,
      0x28,
      0x1f,
      0xe5,
      0x29,
    ]),
    Uint8List.fromList(const [
      0x4e,
      0xb4,
      0xd4,
      0x64,
      0xd6,
      0xef,
      0x53,
      0xed,
      0x6c,
      0xe9,
      0x45,
      0x58,
      0xde,
      0x9a,
      0x5e,
      0xe3,
    ]),
  ];

  static Uint8List get _key0 => authenticationKeys.first;

  Future<void> flash(Uint8List firmware) async {
    _cancelRequested = false;
    _lastAcknowledgedBlock = 0;
    final validation = FirmwareTools.validate(firmware);
    if (!validation.ok) throw StateError(validation.message);
    final inbox = StreamQueue<Uint8List>(notifications);
    try {
      _emit('Pre-flight validation', 0, validation.message);
      log.add('DFU image accepted: ${FirmwareTools.sha(firmware)}');

      _emit('Enter BLDC bootloader', .01, 'down dfu_start 2');
      await _commandWithRetry(inbox, ascii('down dfu_start 2\r'), _isOk);

      _emit('Controller challenge', .02, 'down ble_rand');
      await write(ascii('down ble_rand\r'));
      final challengePacket = await _waitFor(
        inbox,
        _isChallenge,
        const Duration(seconds: 20),
        'BLE_RAND_TIMEOUT',
      );
      final challenge = _decodeChallenge(challengePacket);
      final encrypted = challenge.algorithm == 0
          ? _xor(challenge.bytes, _key0)
          : _aesEcb(challenge.bytes, _key0);

      _emit('Authenticate bootloader', .03, 'down ble_key');
      await _commandWithRetry(
        inbox,
        Uint8List.fromList([
          ...ascii('down ble_key '),
          ...encrypted,
          0x0d,
        ]),
        _isOk,
      );

      _emit('Wait for XMODEM', .04, 'Controller must send C');
      await _waitFor(
        inbox,
        (b) => b.contains(0x43),
        const Duration(seconds: 20),
        'XMODEM_C_TIMEOUT',
      );

      final blocks = (firmware.length / 128).ceil();
      for (var index = 0; index < blocks; index++) {
        _checkCancelled();
        // The ODYS controller uses a non-standard XMODEM sequence:
        // 1..255, then 1 again. Its official updater explicitly skips 0.
        final blockNumber = sequenceForBlockIndex(index);
        final start = index * 128;
        final payload = Uint8List(128)..fillRange(0, 128, 0x1a);
        final available = firmware.length - start;
        final count = available > 128 ? 128 : available;
        payload.setRange(0, count, firmware, start);
        final packet = _xmodemPacket(blockNumber, payload);
        await _sendBlock(
          inbox,
          packet,
          logicalBlock: index + 1,
          wireSequence: blockNumber,
        );
        _lastAcknowledgedBlock = index + 1;
        final fraction = (index + 1) / blocks;
        _emit(
          'Transfer firmware',
          .04 + fraction * .93,
          'Block ${index + 1}/$blocks',
        );
      }

      _emit('Finalize controller', .98, 'EOT and final controller validation');
      var eotAck = false;
      Uint8List? finalReply;
      for (var attempt = 1; attempt <= 4 && !eotAck; attempt++) {
        _checkCancelled();
        await write(Uint8List.fromList(const [0x04]));
        log.add('TX EOT attempt $attempt');
        try {
          final eotReply = await _waitFor(
            inbox,
            (b) =>
                b.contains(0x06) ||
                _safeAscii(b).contains('rsq dfu_ok\r') ||
                _safeAscii(b).contains('rsq dfu_error\r'),
            const Duration(seconds: 20),
            'EOT_ACK_TIMEOUT',
          );
          final eotText = _safeAscii(eotReply);
          if (eotText.contains('rsq dfu_ok\r') ||
              eotText.contains('rsq dfu_error\r')) {
            finalReply = eotReply;
          }
          eotAck = true;
        } on TimeoutException {
          // Some controller revisions skip the EOT ACK and send dfu_ok later.
        }
      }

      finalReply ??= await _waitFor(
        inbox,
        (b) {
          final s = _safeAscii(b);
          return s.contains('rsq dfu_ok\r') || s.contains('rsq dfu_error\r');
        },
        const Duration(seconds: 25),
        'FINAL_TIMEOUT_25S_NO_DFU_OK',
      );
      final confirmedReply = finalReply;
      if (_safeAscii(confirmedReply).contains('dfu_error')) {
        throw StateError('CONTROLLER_DFU_ERROR');
      }
      log.add('SUCCESS controller returned rsq dfu_ok');
      _progress.add(const DfuProgress(
        stage: 'Updated successfully',
        fraction: 1,
        detail: 'Controller verified and accepted the firmware.',
        done: true,
      ));
    } catch (error, stack) {
      log.add('DFU FAILURE: $error\n$stack');
      _progress.add(DfuProgress(
        stage: 'Update failed',
        detail: '$error',
        failed: true,
      ));
      rethrow;
    } finally {
      await inbox.cancel(immediate: true);
    }
  }

  Future<void> _sendBlock(
    StreamQueue<Uint8List> inbox,
    Uint8List packet, {
    required int logicalBlock,
    required int wireSequence,
  }) async {
    for (var attempt = 1; attempt <= 10; attempt++) {
      _checkCancelled();
      await write(packet);
      log.add(
        'TX logical block $logicalBlock '
        'wire sequence $wireSequence attempt $attempt',
      );
      try {
        final reply = await _waitFor(
          inbox,
          (b) => b.contains(0x06) || b.contains(0x15),
          const Duration(seconds: 20),
          'BLOCK_${logicalBlock}_SEQ_${wireSequence}_TIMEOUT',
        );
        if (reply.contains(0x06)) {
          log.add(
            'RX ACK logical block $logicalBlock '
            'wire sequence $wireSequence ${_hex(reply)}',
          );
          return;
        }
        log.add(
          'RX NAK logical block $logicalBlock '
          'wire sequence $wireSequence',
        );
      } on TimeoutException {
        log.add(
          'TIMEOUT logical block $logicalBlock '
          'wire sequence $wireSequence attempt $attempt',
        );
      }
    }
    throw StateError(
      'BLOCK_${logicalBlock}_SEQ_${wireSequence}_RETRY_LIMIT',
    );
  }

  Future<void> _commandWithRetry(
    StreamQueue<Uint8List> inbox,
    Uint8List command,
    bool Function(Uint8List) accept,
  ) async {
    for (var attempt = 1; attempt <= 6; attempt++) {
      _checkCancelled();
      await write(command);
      log.add('TX command ${_safeAscii(command).trim()} attempt $attempt');
      try {
        await _waitFor(
          inbox,
          accept,
          const Duration(seconds: 5),
          'COMMAND_TIMEOUT',
        );
        return;
      } on TimeoutException {
        log.add('Command response timeout');
      }
    }
    throw StateError('COMMAND_RETRY_LIMIT');
  }

  Future<Uint8List> _waitFor(
    StreamQueue<Uint8List> inbox,
    bool Function(Uint8List) accept,
    Duration timeout,
    String reason,
  ) async {
    final deadline = DateTime.now().add(timeout);
    final assembled = <int>[];
    while (DateTime.now().isBefore(deadline)) {
      final remaining = deadline.difference(DateTime.now());
      Uint8List chunk;
      try {
        chunk = await inbox.nextWithTimeout(remaining, reason);
      } on TimeoutException {
        throw TimeoutException(reason);
      }
      log.add('RX ${_hex(chunk)} ${_safeAscii(chunk)}');
      if (accept(chunk)) return chunk;
      assembled.addAll(chunk);
      final joined = Uint8List.fromList(assembled);
      if (accept(joined)) return joined;
      if (assembled.length > 256) {
        assembled.removeRange(0, assembled.length - 128);
      }
    }
    throw TimeoutException(reason);
  }

  void _checkCancelled() {
    if (_cancelRequested) throw StateError('DFU_CANCELLED_BY_USER');
  }

  static Uint8List initialAuthentication({
    int keyIndex = 0,
    int userId = 0,
    int authType = 0,
  }) {
    if (keyIndex < 0 || keyIndex >= authenticationKeys.length) {
      throw RangeError.range(
        keyIndex,
        0,
        authenticationKeys.length - 1,
        'keyIndex',
      );
    }
    // This exactly mirrors ByteUtil.longTo6Bytes(userId, 0x88) in the
    // official client. The controller authenticates the account identifier;
    // 0x88 is only a prefix fallback for the high byte, not an anonymous ID.
    final user = <int>[
      0x88,
      (userId >> 32) & 0xff,
      (userId >> 24) & 0xff,
      (userId >> 16) & 0xff,
      (userId >> 8) & 0xff,
      userId & 0xff,
    ];
    final head = <int>[
      0x55,
      0xaa,
      0x00,
      0x30,
      0x08,
      keyIndex,
      authType & 0xff,
    ];
    final body = [...head, ...user];
    final checksum = body.fold<int>(0, (a, b) => (a + b) & 0xff);
    return Uint8List.fromList([...body, checksum, 0xfe, 0xfd]);
  }

  static Uint8List normalAuthenticationResponse(
    Uint8List challengePayload, {
    int keyIndex = 0,
  }) {
    if (challengePayload.isEmpty) {
      throw FormatException('Empty normal-auth challenge');
    }
    if (keyIndex < 0 || keyIndex >= authenticationKeys.length) {
      throw RangeError.range(
        keyIndex,
        0,
        authenticationKeys.length - 1,
        'keyIndex',
      );
    }
    final key = authenticationKeys[keyIndex];
    late final Uint8List encrypted;
    if (challengePayload.length <= 16) {
      encrypted = _aesEcb(challengePayload, key);
    } else {
      final algorithm = challengePayload.first;
      final challenge = Uint8List.fromList(challengePayload.sublist(1));
      encrypted =
          algorithm == 0 ? _xor(challenge, key) : _aesEcb(challenge, key);
    }
    final body = <int>[
      0x55,
      0xaa,
      0x00,
      0x31,
      encrypted.length & 0xff,
      ...encrypted,
    ];
    final checksum = body.fold<int>(0, (a, b) => (a + b) & 0xff);
    return Uint8List.fromList([...body, checksum, 0xfe, 0xfd]);
  }

  static Uint8List _xmodemPacket(int block, Uint8List payload) {
    final crc = FirmwareTools.crc16Xmodem(payload);
    return Uint8List.fromList([
      0x01,
      block & 0xff,
      (~block) & 0xff,
      ...payload,
      (crc >> 8) & 0xff,
      crc & 0xff,
    ]);
  }

  static int sequenceForBlockIndex(int zeroBasedIndex) {
    if (zeroBasedIndex < 0) {
      throw RangeError.value(zeroBasedIndex, 'zeroBasedIndex');
    }
    return (zeroBasedIndex % 255) + 1;
  }

  static _Challenge _decodeChallenge(Uint8List packet) {
    if (!_isChallenge(packet)) throw FormatException('Invalid DFU challenge');
    if (packet.length <= 20) {
      return _Challenge(
          1, Uint8List.fromList(packet.sublist(3, packet.length - 1)));
    }
    return _Challenge(
      packet[3],
      Uint8List.fromList(packet.sublist(4, packet.length - 1)),
    );
  }

  static Uint8List _aesEcb(Uint8List input, Uint8List keyBytes) {
    if (input.length % 16 != 0) {
      throw FormatException('AES challenge is not a whole block');
    }
    final encrypter = crypt.Encrypter(
      crypt.AES(crypt.Key(keyBytes), mode: crypt.AESMode.ecb, padding: null),
    );
    return Uint8List.fromList(
      encrypter.encryptBytes(input, iv: crypt.IV.fromLength(0)).bytes,
    );
  }

  static Uint8List _xor(Uint8List input, Uint8List key) {
    if (input.length != key.length) {
      throw FormatException('XOR challenge/key length mismatch');
    }
    return Uint8List.fromList(
      List.generate(input.length, (i) => input[i] ^ key[i]),
    );
  }

  static bool _isOk(Uint8List bytes) => _safeAscii(bytes).contains('ok\r');
  static bool _isChallenge(Uint8List bytes) =>
      bytes.length >= 20 &&
      bytes[0] == 0x6f &&
      bytes[1] == 0x6b &&
      bytes[2] == 0x20 &&
      bytes.last == 0x0d;

  static Uint8List ascii(String value) =>
      Uint8List.fromList(convert.ascii.encode(value));
  static String _safeAscii(List<int> bytes) =>
      convert.ascii.decode(bytes, allowInvalid: true);
  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');

  void _emit(String stage, double fraction, String detail) {
    log.add('$stage ${(fraction * 100).toStringAsFixed(1)}% $detail');
    _progress.add(DfuProgress(
      stage: stage,
      fraction: fraction,
      detail: detail,
    ));
  }
}

class _Challenge {
  const _Challenge(this.algorithm, this.bytes);
  final int algorithm;
  final Uint8List bytes;
}

// A small single-subscription stream queue avoids an additional package.
class StreamQueue<T> {
  StreamQueue(Stream<T> source) {
    _subscription = source.listen(
      (event) {
        if (_waiters.isNotEmpty) {
          _waiters.removeAt(0).complete(event);
        } else {
          _events.add(event);
        }
      },
      onError: (Object e, StackTrace s) {
        for (final waiter in _waiters) {
          waiter.completeError(e, s);
        }
        _waiters.clear();
      },
    );
  }

  late final StreamSubscription<T> _subscription;
  final List<T> _events = [];
  final List<Completer<T>> _waiters = [];

  Future<T> get next {
    if (_events.isNotEmpty) return Future.value(_events.removeAt(0));
    final completer = Completer<T>();
    _waiters.add(completer);
    return completer.future;
  }

  Future<T> nextWithTimeout(Duration timeout, String reason) {
    if (_events.isNotEmpty) return Future.value(_events.removeAt(0));
    final completer = Completer<T>();
    _waiters.add(completer);
    Timer? timer;
    timer = Timer(timeout, () {
      if (!completer.isCompleted) {
        _waiters.remove(completer);
        completer.completeError(TimeoutException(reason));
      }
    });
    return completer.future.whenComplete(() => timer?.cancel());
  }

  Future<void> cancel({bool immediate = false}) => _subscription.cancel();
}
