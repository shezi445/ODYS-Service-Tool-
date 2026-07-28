import 'package:flutter_test/flutter_test.dart';

import 'package:odys_service_tool/src/charge_history.dart';
import 'package:odys_service_tool/src/gps_tracker.dart';
import 'package:odys_service_tool/src/models.dart';
import 'package:odys_service_tool/src/session_log.dart';

ChargeRecord _charge({
  required DateTime at,
  required double ah,
  double? wh,
  int start = 10,
  int end = 95,
  int samples = 400,
}) =>
    ChargeRecord(
      startedAt: at,
      endedAt: at.add(const Duration(hours: 4)),
      ampHours: ah,
      wattHours: wh ?? ah * 50,
      peakAmps: 2,
      startPercent: start,
      endPercent: end,
      sampleCount: samples,
    );

void main() {
  group('SessionLog ring buffer', () {
    test('never grows past the cap and counts what it dropped', () {
      final log = SessionLog();
      for (var i = 0; i < 25000; i++) {
        log.add('line $i');
      }

      expect(log.length, lessThanOrEqualTo(log.maxLines));
      expect(log.truncated, true);
      expect(log.length + log.droppedLines, 25000);
      // The tail is the part that matters when diagnosing a failed flash.
      expect(log.lines.last, contains('line 24999'));
    });

    test('stays untruncated below the cap', () {
      final log = SessionLog();
      for (var i = 0; i < 500; i++) {
        log.add('line $i');
      }
      expect(log.truncated, false);
      expect(log.droppedLines, 0);
      expect(log.length, 500);
    });
  });

  group('RideEnergy', () {
    test('refuses consumption over a distance too short to divide by', () {
      const energy = RideEnergy(wattHours: 12, ampHours: 0.3);
      expect(energy.whPerKm(0.1), isNull);
      expect(energy.whPerKm(1), 12);
    });

    test('will not extrapolate pack size from a couple of percent', () {
      const shallow =
          RideEnergy(wattHours: 40, startPercent: 100, lastPercent: 98);
      expect(shallow.impliedPackWh, isNull);

      const deep =
          RideEnergy(wattHours: 100, startPercent: 100, lastPercent: 80);
      expect(deep.impliedPackWh, closeTo(500, 0.001));
    });
  });

  group('RangeEstimate', () {
    const energy = RideEnergy(
      wattHours: 100,
      ampHours: 2,
      startPercent: 100,
      lastPercent: 80,
    );

    test('prefers a measured pack size and says so', () {
      final estimate = RangeEstimate.compute(
        energy: energy,
        tripKm: 5,
        batteryPercent: 80,
        measuredPackWh: 600,
      );

      expect(estimate, isNotNull);
      expect(estimate!.basis, EnergyBasis.chargeHistory);
      expect(estimate.whPerKm, closeTo(20, 0.001));
      expect(estimate.remainingWh, closeTo(480, 0.001));
      expect(estimate.km, closeTo(24, 0.001));
    });

    test('falls back to this ride and labels the guess', () {
      final estimate = RangeEstimate.compute(
        energy: energy,
        tripKm: 5,
        batteryPercent: 80,
      );

      expect(estimate!.basis, EnergyBasis.thisRide);
      // 100 Wh for 20 points implies a 500 Wh pack; 80% of it at 20 Wh/km.
      expect(estimate.km, closeTo(20, 0.001));
    });

    test('returns null rather than inventing a figure', () {
      expect(
        RangeEstimate.compute(
          energy: energy,
          tripKm: 0.1,
          batteryPercent: 80,
        ),
        isNull,
      );
      expect(
        RangeEstimate.compute(
          energy: energy,
          tripKm: 5,
          batteryPercent: null,
        ),
        isNull,
      );
      expect(
        RangeEstimate.compute(
          energy: const RideEnergy(wattHours: 100),
          tripKm: 5,
          batteryPercent: 80,
        ),
        isNull,
        reason: 'no percent span and no measured pack means no pack size',
      );
    });
  });

  group('ChargeRecord', () {
    final at = DateTime(2026, 1, 1);

    test('only wide sessions imply a capacity', () {
      expect(_charge(at: at, ah: 8.5).measuresCapacity, true);
      expect(_charge(at: at, ah: 1, start: 80).measuresCapacity, false,
          reason: 'a 15-point top-up is too narrow');
      expect(_charge(at: at, ah: 8.5, samples: 3).measuresCapacity, false,
          reason: 'three samples is a plug-in blip');
    });

    test('extrapolates the full pack from the span it covered', () {
      final record = _charge(at: at, ah: 8.5, start: 10, end: 95);
      expect(record.percentGained, 85);
      expect(record.impliedPackAh, closeTo(10, 0.001));
    });

    test('survives a round trip through JSON', () {
      final record = _charge(at: at, ah: 8.5);
      final restored = ChargeRecord.fromJson(record.toJson());

      expect(restored, isNotNull);
      expect(restored!.startedAt, record.startedAt);
      expect(restored.ampHours, record.ampHours);
      expect(restored.endPercent, record.endPercent);
      expect(restored.sampleCount, record.sampleCount);
    });

    test('drops a corrupted entry instead of throwing', () {
      expect(ChargeRecord.fromJson(null), isNull);
      expect(ChargeRecord.fromJson('nonsense'), isNull);
      expect(ChargeRecord.fromJson(<String, dynamic>{'ah': 3}), isNull);
    });
  });

  group('ChargeHistoryStats', () {
    final base = DateTime(2026, 1, 1);

    test('is silent until a wide charge has been seen', () {
      final stats =
          ChargeHistoryStats([_charge(at: base, ah: 1, start: 80)]);
      expect(stats.hasCapacityData, false);
      expect(stats.packAh, isNull);
      expect(stats.observedCycles, isNull);
      expect(stats.totalAhDelivered, closeTo(1, 0.001));
    });

    test('takes the median so one bad session cannot drag the figure', () {
      final stats = ChargeHistoryStats([
        _charge(at: base, ah: 8.5),
        _charge(at: base.add(const Duration(days: 3)), ah: 8.6),
        _charge(at: base.add(const Duration(days: 6)), ah: 17),
      ]);
      // Implied packs are 10.0, 10.12 and 20.0 Ah.
      expect(stats.packAh, closeTo(10.117, 0.01));
    });

    test('withholds a degradation trend from sessions days apart', () {
      final stats = ChargeHistoryStats([
        _charge(at: base, ah: 8.5),
        _charge(at: base.add(const Duration(days: 2)), ah: 8.0),
      ]);
      expect(stats.degradationPercent, isNull);
    });

    test('reports degradation once the sessions are far enough apart', () {
      final stats = ChargeHistoryStats([
        _charge(at: base, ah: 8.5),
        _charge(at: base.add(const Duration(days: 120)), ah: 7.65),
      ]);
      // 10.0 Ah down to 9.0 Ah.
      expect(stats.degradationPercent, closeTo(-10, 0.01));
    });
  });

  group('SpeedCrossCheck', () {
    test('needs enough travel before judging the controller', () {
      const check = SpeedCrossCheck(
        reportedKmh: 20,
        gpsKmh: 19,
        reportedTripKm: 0.2,
        gpsTripKm: 0.2,
        reportedMaxKmh: 25,
        gpsMaxKmh: 0,
      );
      expect(check.distanceRatio, isNull);
      expect(check.distanceErrorPercent, isNull);
      expect(check.maxDeltaKmh, isNull);
      expect(check.liveDeltaKmh, closeTo(1, 0.001));
    });

    test('quantifies an over-reporting controller', () {
      const check = SpeedCrossCheck(
        reportedKmh: 20,
        gpsKmh: 18.5,
        reportedTripKm: 10.5,
        gpsTripKm: 10,
        reportedMaxKmh: 41,
        gpsMaxKmh: 38.6,
      );
      expect(check.distanceErrorPercent, closeTo(5, 0.001));
      expect(check.maxDeltaKmh, closeTo(2.4, 0.001));
    });

    test('has no live delta without a fix', () {
      const check = SpeedCrossCheck(
        reportedKmh: 20,
        gpsKmh: null,
        reportedTripKm: 10,
        gpsTripKm: 10,
        reportedMaxKmh: 25,
        gpsMaxKmh: 24,
      );
      expect(check.liveDeltaKmh, isNull);
      expect(check.distanceErrorPercent, closeTo(0, 0.001));
    });
  });
}
