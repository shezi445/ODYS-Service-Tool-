import 'dart:typed_data';

import '../models.dart';

class OdysProtocol {
  static const serviceUuid = '0000d0ff-3c17-d293-8e48-14fe2e4da212';
  static const writeUuid = '0000b002-0000-1000-8000-00805f9b34fb';
  static const notifyUuid = '0000b003-0000-1000-8000-00805f9b34fb';

  static const readCar = 0x70;
  static const readBattery = 0x72;
  static const readFirmware = 0x73;
  static const readDashboard = 0x90;
  static const readLegacyLive = 0x91;
  static const readLive = 0x92;
  static const cruiseControl = 0x52;

  static Uint8List readCommand(int command) {
    final frame = <int>[0x55, 0xaa, 0x00, command];
    return Uint8List.fromList([...frame, _sum(frame), 0xfe, 0xfd]);
  }

  static Uint8List writeByte(int command, int value) {
    final frame = <int>[0x55, 0xaa, 0x00, command, 0x01, value & 0xff];
    return Uint8List.fromList([...frame, _sum(frame), 0xfe, 0xfd]);
  }

  static int _sum(List<int> bytes) =>
      bytes.fold<int>(0, (sum, byte) => (sum + byte) & 0xff);

  static OdysFrame? parseFrame(List<int> bytes) {
    if (bytes.length < 9 ||
        bytes[0] != 0x55 ||
        bytes[1] != 0xaa ||
        bytes[bytes.length - 2] != 0xfe ||
        bytes.last != 0xfd) {
      return null;
    }
    final length = bytes[4] & 0xff;
    final checksumIndex = length + 5;
    if (checksumIndex + 2 >= bytes.length) return null;
    // The controller's reply checksum is not the additive checksum used by
    // outbound commands. Validate the complete frame envelope instead; known
    // controllers otherwise reject a valid short 0x30 success reply.
    return OdysFrame(
      command: bytes[3] & 0xff,
      error: bytes[5] & 0xff,
      payload: Uint8List.fromList(bytes.sublist(6, checksumIndex)),
    );
  }

  static FirmwareVersions? firmwareFrom(OdysFrame frame) {
    if (frame.command != readFirmware || frame.payload.length < 12) return null;
    String version(int start) {
      final bytes = frame.payload.sublist(start, start + 4);
      // Some controllers return each version component as an ASCII digit.
      // For example, 48.48.48.51 on the wire is the version 0.0.0.3.
      final components = bytes.every((byte) => byte >= 0x30 && byte <= 0x39)
          ? bytes.map((byte) => byte - 0x30)
          : bytes;
      return components.join('.');
    }

    return FirmwareVersions(
      meter: version(0),
      bldc: version(4),
      bms: version(8),
    );
  }

  static Telemetry? batteryFrom(OdysFrame frame, Telemetry previous) {
    if (frame.command != readBattery || frame.payload.length < 13) return null;
    final p = frame.payload;
    return previous.copyWith(
      batteryPercent: p[1],
      voltage: _le(p, 2, 4) / 1000,
      current: _signed(_le(p, 6, 4), 32) / 1000,
      batteryTemperature: _signed(p[11], 8).toDouble(),
      isCharging: p[12] != 0,
      lastUpdate: DateTime.now(),
      batteryLastUpdate: DateTime.now(),
    );
  }

  static Telemetry? liveFrom(OdysFrame frame, Telemetry previous) {
    final p = frame.payload;
    if (frame.command == 0x92 && p.length >= 14) {
      return previous.copyWith(
        batteryPercent: p[0],
        speedKmh: _le(p, 2, 2) / 10,
        lastUpdate: DateTime.now(),
        speedLastUpdate: DateTime.now(),
        speedSampleCount: previous.speedSampleCount + 1,
      );
    }
    if (frame.command == 0x91 && p.length >= 9) {
      return previous.copyWith(
        batteryPercent: p[0],
        speedKmh: p[2].toDouble(),
        lastUpdate: DateTime.now(),
        speedLastUpdate: DateTime.now(),
        speedSampleCount: previous.speedSampleCount + 1,
      );
    }
    if (frame.command == 0x90 && p.length >= 7) {
      return previous.copyWith(
        errorCode: p[0],
        mode: p[1],
        batteryPercent: p[2],
        isCharging: p[4] != 0,
        lastUpdate: DateTime.now(),
      );
    }
    return null;
  }

  static bool cruiseAcknowledged(OdysFrame frame, bool requested) {
    if (frame.command != cruiseControl || frame.error != 0) return false;
    return frame.payload.isEmpty || frame.payload.last == (requested ? 1 : 0);
  }

  static int _le(List<int> bytes, int offset, int count) {
    var value = 0;
    for (var i = 0; i < count; i++) {
      value |= (bytes[offset + i] & 0xff) << (8 * i);
    }
    return value;
  }

  static int _signed(int value, int bits) {
    final sign = 1 << (bits - 1);
    return (value & sign) == 0 ? value : value - (1 << bits);
  }
}

class OdysFrame {
  const OdysFrame({
    required this.command,
    required this.error,
    required this.payload,
  });

  final int command;
  final int error;
  final Uint8List payload;
}
