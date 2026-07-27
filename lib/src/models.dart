import 'dart:typed_data';

enum ConnectionPhase {
  disconnected,
  scanning,
  connecting,
  authenticating,
  connected,
  reconnecting,
  flashing,
  recovering,
}

enum SpeedProfile {
  stock('Original DE firmware (22 km/h)', 22, 476, false),
  limit25('25 km/h', 25, 540, false),
  limit30('30 km/h', 30, 648, false),
  limit32('32 km/h (verified reference)', 32, 692, false),
  experimental40('40 km/h · Kick 1 (EXPERIMENTAL)', 40, 864, true),
  experimental40Kick2('40 km/h · Kick 2 (EXPERIMENTAL)', 40, 864, true);

  const SpeedProfile(this.label, this.kmh, this.raw, this.experimental);
  final String label;
  final int? kmh;
  final int? raw;
  final bool experimental;
}

enum MotorStartProfile {
  stock('Stock: kick ~3 / normal ~5 km/h', 64, 108),
  kick1Normal2('Kick ~1 / normal ~2 km/h', 22, 43);

  const MotorStartProfile(this.label, this.kickRaw, this.normalRaw);
  final String label;
  final int kickRaw;
  final int normalRaw;
}

class FirmwareVersions {
  const FirmwareVersions({
    this.meter = '—',
    this.bldc = '—',
    this.bms = '—',
  });

  final String meter;
  final String bldc;
  final String bms;
}

class Telemetry {
  const Telemetry({
    this.speedKmh = 0,
    this.batteryPercent,
    this.voltage,
    this.current,
    this.batteryTemperature,
    this.controllerTemperature,
    this.lastUpdate,
    this.speedLastUpdate,
    this.batteryLastUpdate,
    this.speedSampleCount = 0,
    this.isCharging,
    this.errorCode,
    this.mode,
  });

  final double speedKmh;
  final int? batteryPercent;
  final double? voltage;
  final double? current;
  final double? batteryTemperature;
  final double? controllerTemperature;
  final DateTime? lastUpdate;
  final DateTime? speedLastUpdate;
  final DateTime? batteryLastUpdate;
  final int speedSampleCount;
  final bool? isCharging;
  final int? errorCode;
  final int? mode;

  bool get hasTrustedSpeed =>
      speedLastUpdate != null &&
      speedSampleCount >= 2 &&
      DateTime.now().difference(speedLastUpdate!) <
          const Duration(seconds: 3);

  bool get hasFreshBattery =>
      batteryLastUpdate != null &&
      DateTime.now().difference(batteryLastUpdate!) <
          const Duration(seconds: 10);

  Telemetry copyWith({
    double? speedKmh,
    int? batteryPercent,
    double? voltage,
    double? current,
    double? batteryTemperature,
    double? controllerTemperature,
    DateTime? lastUpdate,
    DateTime? speedLastUpdate,
    DateTime? batteryLastUpdate,
    int? speedSampleCount,
    bool? isCharging,
    int? errorCode,
    int? mode,
  }) =>
      Telemetry(
        speedKmh: speedKmh ?? this.speedKmh,
        batteryPercent: batteryPercent ?? this.batteryPercent,
        voltage: voltage ?? this.voltage,
        current: current ?? this.current,
        batteryTemperature: batteryTemperature ?? this.batteryTemperature,
        controllerTemperature:
            controllerTemperature ?? this.controllerTemperature,
        lastUpdate: lastUpdate ?? this.lastUpdate,
        speedLastUpdate: speedLastUpdate ?? this.speedLastUpdate,
        batteryLastUpdate: batteryLastUpdate ?? this.batteryLastUpdate,
        speedSampleCount: speedSampleCount ?? this.speedSampleCount,
        isCharging: isCharging ?? this.isCharging,
        errorCode: errorCode ?? this.errorCode,
        mode: mode ?? this.mode,
      );
}

class ControllerCompatibility {
  const ControllerCompatibility({
    required this.allowed,
    required this.reason,
    this.warningOnly = false,
  });

  final bool allowed;
  final String reason;
  final bool warningOnly;
}

class FirmwareImage {
  const FirmwareImage({
    required this.bytes,
    required this.name,
    required this.sha256,
    required this.innerCrc,
    required this.outerCrc,
    required this.speed,
    required this.motorStart,
    required this.verifiedReference,
  });

  final Uint8List bytes;
  final String name;
  final String sha256;
  final int innerCrc;
  final int outerCrc;
  final SpeedProfile speed;
  final MotorStartProfile motorStart;
  final bool verifiedReference;
}

class DfuProgress {
  const DfuProgress({
    required this.stage,
    this.fraction = 0,
    this.detail = '',
    this.done = false,
    this.failed = false,
  });

  final String stage;
  final double fraction;
  final String detail;
  final bool done;
  final bool failed;
}
