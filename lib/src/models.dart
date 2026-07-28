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
  limit20('20 km/h', 20, 432, false),
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

class SpeedSample {
  const SpeedSample({required this.speedKmh, required this.time});
  final double speedKmh;
  final DateTime time;
}

class RideStats {
  const RideStats({
    this.tripDistanceKm = 0,
    this.maxSpeedKmh = 0,
    this.totalSpeedSum = 0,
    this.sampleCount = 0,
    this.speedHistory = const [],
    this.tripStart,
  });

  final double tripDistanceKm;
  final double maxSpeedKmh;
  final double totalSpeedSum;
  final int sampleCount;
  final List<SpeedSample> speedHistory;
  final DateTime? tripStart;

  double get avgSpeedKmh => sampleCount == 0 ? 0 : totalSpeedSum / sampleCount;

  RideStats copyWith({
    double? tripDistanceKm,
    double? maxSpeedKmh,
    double? totalSpeedSum,
    int? sampleCount,
    List<SpeedSample>? speedHistory,
    DateTime? tripStart,
  }) =>
      RideStats(
        tripDistanceKm: tripDistanceKm ?? this.tripDistanceKm,
        maxSpeedKmh: maxSpeedKmh ?? this.maxSpeedKmh,
        totalSpeedSum: totalSpeedSum ?? this.totalSpeedSum,
        sampleCount: sampleCount ?? this.sampleCount,
        speedHistory: speedHistory ?? this.speedHistory,
        tripStart: tripStart ?? this.tripStart,
      );

  RideStats reset() => const RideStats();
}

/// Drive mode reported in byte 1 of the 0x90 dashboard frame.
///
/// The numeric values come straight off the wire. Only the raw code is
/// authoritative — the friendly names are the conventional ODYS/M365-family
/// mapping and have not been confirmed against a controller, so the UI always
/// shows the raw code alongside the label.
enum DriveMode {
  eco(0, 'Eco'),
  normal(1, 'Normal'),
  sport(2, 'Sport');

  const DriveMode(this.code, this.label);
  final int code;
  final String label;

  static DriveMode? fromCode(int? code) {
    if (code == null) return null;
    for (final mode in values) {
      if (mode.code == code) return mode;
    }
    return null;
  }

  /// Always includes the raw code so an unverified label can be checked.
  static String describe(int? code) {
    if (code == null) return '—';
    final known = fromCode(code);
    return known == null ? 'Mode $code' : '${known.label} ($code)';
  }
}

/// One charging session, integrated from the 0x72 battery frame.
///
/// The frame reports pack voltage and a *signed* current, so magnitudes are
/// used throughout: the sign convention only tells us direction, and
/// [Telemetry.isCharging] already carries that.
class ChargeSession {
  const ChargeSession({
    required this.startedAt,
    this.endedAt,
    this.startPercent,
    this.lastPercent,
    this.ampHours = 0,
    this.wattHours = 0,
    this.peakAmps = 0,
    this.lastAmps = 0,
    this.lastVolts = 0,
    this.startVolts,
    this.sampleCount = 0,
  });

  final DateTime startedAt;
  final DateTime? endedAt;
  final int? startPercent;
  final int? lastPercent;
  final double ampHours;
  final double wattHours;
  final double peakAmps;
  final double lastAmps;
  final double lastVolts;
  final double? startVolts;

  /// Number of distinct 0x72 battery frames folded into this session. Used to
  /// gate the phase heuristic, which is meaningless on one or two samples.
  final int sampleCount;

  bool get active => endedAt == null;

  Duration get elapsed => (endedAt ?? DateTime.now()).difference(startedAt);

  double get watts => lastAmps * lastVolts;

  int? get percentGained => startPercent == null || lastPercent == null
      ? null
      : lastPercent! - startPercent!;

  /// Signed so a dip in the reported percentage reads correctly rather than
  /// rendering as "+-1".
  String get percentGainedLabel {
    final gained = percentGained;
    if (gained == null) return '—';
    return gained >= 0 ? '+$gained' : '$gained';
  }

  /// Constant-current versus constant-voltage, inferred from how far current
  /// has fallen below the session peak. A Li-ion charger holds current flat
  /// while it can (CC) and then tapers it to hold voltage (CV).
  ChargePhase get phase {
    if (sampleCount < 3 || peakAmps < 0.2) return ChargePhase.unknown;
    if (lastAmps < 0.15) return ChargePhase.complete;
    if (lastAmps >= peakAmps * 0.9) return ChargePhase.constantCurrent;
    return ChargePhase.constantVoltage;
  }

  /// Extrapolated from the observed percent-per-hour slope. Deliberately
  /// refuses to answer until there is enough signal, and returns null past a
  /// day because that means the slope is noise.
  ///
  /// This under-estimates: the CV taper at the top of the pack is much slower
  /// than the CC slope this is measured from.
  Duration? get estimatedTimeToFull {
    final start = startPercent;
    final last = lastPercent;
    if (start == null || last == null) return null;
    if (last >= 100) return Duration.zero;
    final hours = elapsed.inMilliseconds / 3600000.0;
    final gained = last - start;
    if (gained < 2 || hours < 0.05) return null;
    final perHour = gained / hours;
    if (perHour <= 0) return null;
    final minutes = ((100 - last) / perHour * 60).round();
    return minutes > 24 * 60 ? null : Duration(minutes: minutes);
  }

  ChargeSession copyWith({
    DateTime? endedAt,
    int? startPercent,
    int? lastPercent,
    double? ampHours,
    double? wattHours,
    double? peakAmps,
    double? lastAmps,
    double? lastVolts,
    double? startVolts,
    int? sampleCount,
  }) =>
      ChargeSession(
        startedAt: startedAt,
        endedAt: endedAt ?? this.endedAt,
        startPercent: startPercent ?? this.startPercent,
        lastPercent: lastPercent ?? this.lastPercent,
        ampHours: ampHours ?? this.ampHours,
        wattHours: wattHours ?? this.wattHours,
        peakAmps: peakAmps ?? this.peakAmps,
        lastAmps: lastAmps ?? this.lastAmps,
        lastVolts: lastVolts ?? this.lastVolts,
        startVolts: startVolts ?? this.startVolts,
        sampleCount: sampleCount ?? this.sampleCount,
      );
}

enum ChargePhase {
  unknown('Measuring…'),
  constantCurrent('Constant current (bulk)'),
  constantVoltage('Constant voltage (taper)'),
  complete('Complete / trickle');

  const ChargePhase(this.label);
  final String label;
}

/// A completed charge session, reduced to the fields worth keeping forever.
///
/// The reason to persist these is capacity: charge a pack from near-empty to
/// full and the delivered amp-hours *are* a measurement of what the pack holds
/// today. Repeat over months and the trend is real degradation, which nothing
/// the controller reports can tell you.
class ChargeRecord {
  const ChargeRecord({
    required this.startedAt,
    required this.endedAt,
    required this.ampHours,
    required this.wattHours,
    required this.peakAmps,
    this.startPercent,
    this.endPercent,
    this.startVolts,
    this.endVolts,
    this.sampleCount = 0,
  });

  factory ChargeRecord.fromSession(ChargeSession session, DateTime endedAt) =>
      ChargeRecord(
        startedAt: session.startedAt,
        endedAt: session.endedAt ?? endedAt,
        ampHours: session.ampHours,
        wattHours: session.wattHours,
        peakAmps: session.peakAmps,
        startPercent: session.startPercent,
        endPercent: session.lastPercent,
        startVolts: session.startVolts,
        endVolts: session.lastVolts,
        sampleCount: session.sampleCount,
      );

  final DateTime startedAt;
  final DateTime endedAt;
  final double ampHours;
  final double wattHours;
  final double peakAmps;
  final int? startPercent;
  final int? endPercent;
  final double? startVolts;
  final double? endVolts;
  final int sampleCount;

  Duration get duration => endedAt.difference(startedAt);

  int? get percentGained => startPercent == null || endPercent == null
      ? null
      : endPercent! - startPercent!;

  /// Percentage span a session must cover before its implied capacity means
  /// anything. A 5% top-up divided by 0.05 amplifies every integration error
  /// twentyfold; requiring a wide span keeps the extrapolation honest.
  static const int minSpanForCapacity = 40;

  /// Whether this session is wide enough to infer pack capacity from.
  bool get measuresCapacity {
    final gained = percentGained;
    return gained != null &&
        gained >= minSpanForCapacity &&
        ampHours > 0 &&
        sampleCount >= 10;
  }

  /// Full-pack amp-hours extrapolated from this session's delivered charge.
  ///
  /// Assumes the reported percentage is linear in charge, which is only
  /// roughly true — treat the trend across sessions as the signal, not any
  /// single number.
  double? get impliedPackAh =>
      measuresCapacity ? ampHours / (percentGained! / 100) : null;

  double? get impliedPackWh =>
      measuresCapacity && wattHours > 0 ? wattHours / (percentGained! / 100) : null;

  Map<String, dynamic> toJson() => {
        'startedAt': startedAt.millisecondsSinceEpoch,
        'endedAt': endedAt.millisecondsSinceEpoch,
        'ah': ampHours,
        'wh': wattHours,
        'peakA': peakAmps,
        'startPct': startPercent,
        'endPct': endPercent,
        'startV': startVolts,
        'endV': endVolts,
        'samples': sampleCount,
      };

  /// Returns null on anything malformed rather than throwing — a corrupted
  /// entry should cost one record, not the whole history.
  static ChargeRecord? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final started = raw['startedAt'];
    final ended = raw['endedAt'];
    if (started is! int || ended is! int) return null;
    double asDouble(Object? v) => v is num ? v.toDouble() : 0;
    double? asNullableDouble(Object? v) => v is num ? v.toDouble() : null;
    int? asNullableInt(Object? v) => v is num ? v.toInt() : null;
    return ChargeRecord(
      startedAt: DateTime.fromMillisecondsSinceEpoch(started),
      endedAt: DateTime.fromMillisecondsSinceEpoch(ended),
      ampHours: asDouble(raw['ah']),
      wattHours: asDouble(raw['wh']),
      peakAmps: asDouble(raw['peakA']),
      startPercent: asNullableInt(raw['startPct']),
      endPercent: asNullableInt(raw['endPct']),
      startVolts: asNullableDouble(raw['startV']),
      endVolts: asNullableDouble(raw['endV']),
      sampleCount: asNullableInt(raw['samples']) ?? 0,
    );
  }
}

/// Energy drawn from the pack while riding, integrated from the same 0x72
/// battery frame the charging monitor uses — just with the sign reversed.
///
/// Consumption is what turns trip distance into something useful: watt-hours
/// per kilometre, and from that a range estimate.
class RideEnergy {
  const RideEnergy({
    this.ampHours = 0,
    this.wattHours = 0,
    this.sampleCount = 0,
    this.lastAmps = 0,
    this.lastVolts = 0,
    this.peakAmps = 0,
    this.startPercent,
    this.lastPercent,
  });

  final double ampHours;
  final double wattHours;
  final int sampleCount;
  final double lastAmps;
  final double lastVolts;
  final double peakAmps;
  final int? startPercent;
  final int? lastPercent;

  double get watts => lastAmps * lastVolts;

  /// Percentage points consumed so far, positive while draining.
  int? get percentUsed => startPercent == null || lastPercent == null
      ? null
      : startPercent! - lastPercent!;

  /// Minimum drain before the percent slope is worth extrapolating from. The
  /// gauge moves in whole percent steps, so a 1-2 point drop is mostly
  /// quantisation noise.
  static const int minPercentForSlope = 5;

  /// Pack watt-hours implied by this ride alone. A measured value from charge
  /// history is strictly better; this is the fallback when none exists yet.
  double? get impliedPackWh {
    final used = percentUsed;
    if (used == null || used < minPercentForSlope || wattHours <= 0) {
      return null;
    }
    return wattHours / (used / 100);
  }

  /// Consumption over the given distance. Refuses to answer over very short
  /// distances, where the ratio swings wildly.
  double? whPerKm(double tripKm) {
    if (tripKm < 0.3 || wattHours <= 0) return null;
    return wattHours / tripKm;
  }

  RideEnergy copyWith({
    double? ampHours,
    double? wattHours,
    int? sampleCount,
    double? lastAmps,
    double? lastVolts,
    double? peakAmps,
    int? startPercent,
    int? lastPercent,
  }) =>
      RideEnergy(
        ampHours: ampHours ?? this.ampHours,
        wattHours: wattHours ?? this.wattHours,
        sampleCount: sampleCount ?? this.sampleCount,
        lastAmps: lastAmps ?? this.lastAmps,
        lastVolts: lastVolts ?? this.lastVolts,
        peakAmps: peakAmps ?? this.peakAmps,
        startPercent: startPercent ?? this.startPercent,
        lastPercent: lastPercent ?? this.lastPercent,
      );
}

/// Where a pack-capacity figure came from. Shown alongside the range estimate
/// so a number extrapolated from a few percent of drain is never mistaken for
/// one measured across a full charge.
enum EnergyBasis {
  chargeHistory('measured over a full charge'),
  thisRide('estimated from this ride');

  const EnergyBasis(this.label);
  final String label;
}

/// Remaining range, with the provenance of the numbers behind it.
class RangeEstimate {
  const RangeEstimate({
    required this.km,
    required this.whPerKm,
    required this.remainingWh,
    required this.basis,
  });

  final double km;
  final double whPerKm;
  final double remainingWh;
  final EnergyBasis basis;

  /// Builds an estimate only when every input is trustworthy; returns null
  /// otherwise so the UI can say "measuring" instead of inventing a figure.
  static RangeEstimate? compute({
    required RideEnergy energy,
    required double tripKm,
    required int? batteryPercent,
    double? measuredPackWh,
  }) {
    final consumption = energy.whPerKm(tripKm);
    if (consumption == null || consumption <= 0) return null;
    if (batteryPercent == null || batteryPercent <= 0) return null;

    final packWh = measuredPackWh ?? energy.impliedPackWh;
    if (packWh == null || packWh <= 0) return null;

    final remaining = packWh * (batteryPercent / 100);
    return RangeEstimate(
      km: remaining / consumption,
      whPerKm: consumption,
      remainingWh: remaining,
      basis: measuredPackWh != null
          ? EnergyBasis.chargeHistory
          : EnergyBasis.thisRide,
    );
  }
}

class ConnectionRecord {
  const ConnectionRecord({
    required this.deviceName,
    required this.deviceId,
    required this.connectedAt,
  });

  final String deviceName;
  final String deviceId;
  final DateTime connectedAt;
}
