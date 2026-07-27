import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../models.dart';

class FirmwareTools {
  static const imageSize = 45184;
  static const speedOffset = 0xaa58;
  static const innerCrcOffset = 0xb0;
  static const outerCrcOffset = 0x13;
  static const firmwareBodyOffset = 0x100;
  static const firmwareBodyLength = 0xaf08;
  static const outerStart = 0x80;

  static const stockSha256 =
      '2640a3f4ff96642eb655d046238b4da7dd6c5f0195cf2424867b063dbe2cb5e5';
  static const verified32Sha256 =
      '77481c37205cae47d996e109bbeb62521e23fa3d1e190bff25092fd35c265874';
  static const experimental40Sha256 =
      'ec295b947e024adfb2a05ff4bc7d3cc5ef5c33f49f78ed11cbc6d258b7a44585';
  static const experimental40Kick2Sha256 =
      '7dc04de0c4dcd6b3f64fd21559f7509c448843f84099d298fc88ce4cf1bf159c';

  static const kickOffsets = <int>[
    0x1338,
    0x155c,
    0x1572,
    0x1592,
    0x1d88,
    0x1dcc,
    0x1ef0,
    0x1f82,
  ];
  static const normalOffsets = <int>[0x1554, 0x3412, 0x427a];

  static String sha(Uint8List bytes) => sha256.convert(bytes).toString();

  static int crc16Xmodem(List<int> bytes) {
    var crc = 0;
    for (final byte in bytes) {
      crc ^= (byte & 0xff) << 8;
      for (var bit = 0; bit < 8; bit++) {
        crc = (crc & 0x8000) != 0
            ? ((crc << 1) ^ 0x1021) & 0xffff
            : (crc << 1) & 0xffff;
      }
    }
    return crc;
  }

  static FirmwareValidation validate(Uint8List bytes) {
    if (bytes.length != imageSize) {
      return FirmwareValidation(false, 'Wrong size: ${bytes.length}', 0, 0);
    }
    final inner = crc16Xmodem(
      bytes.sublist(
          firmwareBodyOffset, firmwareBodyOffset + firmwareBodyLength),
    );
    final outer = crc16Xmodem(bytes.sublist(outerStart));
    final storedInner = _readBe16(bytes, innerCrcOffset);
    final storedOuter = _readBe16(bytes, outerCrcOffset);
    if (inner != storedInner || outer != storedOuter) {
      return FirmwareValidation(
        false,
        'CRC mismatch: inner ${_hex(storedInner)}/${_hex(inner)}, '
        'outer ${_hex(storedOuter)}/${_hex(outer)}',
        inner,
        outer,
      );
    }
    return FirmwareValidation(true, 'SHA-256 ${sha(bytes)}', inner, outer);
  }

  static FirmwareImage buildProfile({
    required Uint8List stock,
    required Uint8List verified32,
    required Uint8List experimental40,
    required Uint8List experimental40Kick2,
    required SpeedProfile speed,
    required MotorStartProfile motorStart,
  }) {
    if (sha(stock) != stockSha256) {
      throw StateError('Stock firmware hash is not the approved baseline.');
    }
    if (sha(verified32) != verified32Sha256) {
      throw StateError('Embedded verified 32 km/h firmware hash mismatch.');
    }
    if (sha(experimental40) != experimental40Sha256) {
      throw StateError('Embedded experimental 40 km/h firmware hash mismatch.');
    }
    if (sha(experimental40Kick2) != experimental40Kick2Sha256) {
      throw StateError(
        'Embedded experimental 40 km/h Kick 2 firmware hash mismatch.',
      );
    }
    if (speed == SpeedProfile.stock) {
      final validation = validate(stock);
      if (!validation.ok) throw StateError(validation.message);
      return FirmwareImage(
        bytes: Uint8List.fromList(stock),
        name: 'BLDC_DE_Stock_22kmh.bin',
        sha256: stockSha256,
        innerCrc: validation.innerCrc,
        outerCrc: validation.outerCrc,
        speed: speed,
        motorStart: MotorStartProfile.stock,
        verifiedReference: true,
      );
    }

    if (speed == SpeedProfile.limit32 &&
        motorStart == MotorStartProfile.kick1Normal2) {
      final validation = validate(verified32);
      if (!validation.ok) throw StateError(validation.message);
      return FirmwareImage(
        bytes: Uint8List.fromList(verified32),
        name: 'BLDC_DE_32kmh_Kick1_Normal2_DualCRC.bin',
        sha256: verified32Sha256,
        innerCrc: validation.innerCrc,
        outerCrc: validation.outerCrc,
        speed: speed,
        motorStart: motorStart,
        verifiedReference: true,
      );
    }

    if (speed == SpeedProfile.experimental40) {
      if (motorStart != MotorStartProfile.kick1Normal2) {
        throw StateError(
          'The experimental 40 km/h image is locked to Kick 1 / Normal 2.',
        );
      }
      final validation = validate(experimental40);
      if (!validation.ok) throw StateError(validation.message);
      return FirmwareImage(
        bytes: Uint8List.fromList(experimental40),
        name: 'BLDC_DE_40kmh_EXPERIMENTAL_Kick1_Normal2_DualCRC.bin',
        sha256: experimental40Sha256,
        innerCrc: validation.innerCrc,
        outerCrc: validation.outerCrc,
        speed: speed,
        motorStart: motorStart,
        verifiedReference: false,
      );
    }

    if (speed == SpeedProfile.experimental40Kick2) {
      final validation = validate(experimental40Kick2);
      if (!validation.ok) throw StateError(validation.message);
      return FirmwareImage(
        bytes: Uint8List.fromList(experimental40Kick2),
        name: 'BLDC_DE_40kmh_Kick2kmh_Normal2_DualCRC.bin',
        sha256: experimental40Kick2Sha256,
        innerCrc: validation.innerCrc,
        outerCrc: validation.outerCrc,
        speed: speed,
        motorStart: motorStart,
        verifiedReference: false,
      );
    }

    final output = Uint8List.fromList(stock);
    _writeLe16(output, speedOffset, speed.raw!);
    for (final offset in kickOffsets) {
      _expectOneOf(output[offset], const [64, 22], offset);
      output[offset] = motorStart.kickRaw;
    }
    for (final offset in normalOffsets) {
      _expectOneOf(output[offset], const [108, 43], offset);
      output[offset] = motorStart.normalRaw;
    }
    _writeBe16(output, innerCrcOffset, 0);
    _writeBe16(output, outerCrcOffset, 0);
    final inner = crc16Xmodem(
      output.sublist(
        firmwareBodyOffset,
        firmwareBodyOffset + firmwareBodyLength,
      ),
    );
    _writeBe16(output, innerCrcOffset, inner);
    final outer = crc16Xmodem(output.sublist(outerStart));
    _writeBe16(output, outerCrcOffset, outer);
    final validation = validate(output);
    if (!validation.ok) throw StateError(validation.message);
    return FirmwareImage(
      bytes: output,
      name: 'BLDC_DE_${speed.kmh}kmh_${motorStart.name}_DualCRC.bin',
      sha256: sha(output),
      innerCrc: inner,
      outerCrc: outer,
      speed: speed,
      motorStart: motorStart,
      verifiedReference: false,
    );
  }

  static ControllerCompatibility compatibilityFor(
    FirmwareVersions versions, {
    SpeedProfile? profile,
  }) {
    if (versions.bldc == '—') {
      return const ControllerCompatibility(
        allowed: false,
        reason: 'BLDC version has not been read from the connected scooter.',
      );
    }
    // The physically verified controller reports the 0.0.0.x BLDC family.
    if (!versions.bldc.startsWith('0.0.0.')) {
      return ControllerCompatibility(
        allowed: false,
        reason: 'Unsupported BLDC family ${versions.bldc}; expected 0.0.0.x.',
      );
    }
    final isExperimental40 = profile == SpeedProfile.experimental40 ||
        profile == SpeedProfile.experimental40Kick2;
    if (isExperimental40 && versions.bldc != '0.0.0.3') {
      return ControllerCompatibility(
        allowed: false,
        reason: 'Experimental 40 km/h is restricted to the tested controller '
            'revision 0.0.0.3; detected ${versions.bldc}.',
      );
    }
    return ControllerCompatibility(
      allowed: true,
      reason: isExperimental40
          ? 'Exact experimental controller revision detected: ${versions.bldc}.'
          : 'Compatible BLDC family detected: ${versions.bldc}.',
    );
  }

  static void _expectOneOf(int actual, List<int> expected, int offset) {
    if (!expected.contains(actual)) {
      throw StateError(
        'Unexpected baseline byte 0x${actual.toRadixString(16)} '
        'at 0x${offset.toRadixString(16)}.',
      );
    }
  }

  static int _readBe16(List<int> b, int o) => (b[o] << 8) | b[o + 1];
  static void _writeBe16(Uint8List b, int o, int v) {
    b[o] = (v >> 8) & 0xff;
    b[o + 1] = v & 0xff;
  }

  static void _writeLe16(Uint8List b, int o, int v) {
    b[o] = v & 0xff;
    b[o + 1] = (v >> 8) & 0xff;
  }

  static String _hex(int value) =>
      value.toRadixString(16).padLeft(4, '0').toUpperCase();
}

class FirmwareValidation {
  const FirmwareValidation(
    this.ok,
    this.message,
    this.innerCrc,
    this.outerCrc,
  );

  final bool ok;
  final String message;
  final int innerCrc;
  final int outerCrc;
}
