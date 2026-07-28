import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';

import 'session_log.dart';

enum GpsStatus {
  /// Tracking has not been switched on.
  off('Off'),

  /// Waiting on the permission dialog or the first fix.
  starting('Starting…'),

  /// The user declined, or the OS refused.
  denied('Permission denied'),

  /// Location services are switched off device-wide.
  serviceDisabled('Location services off'),

  /// Running, but no usable fix yet.
  acquiring('Acquiring fix…'),

  /// Producing fixes.
  tracking('Tracking'),

  /// Something else went wrong; see [GpsTracker.error].
  failed('Unavailable');

  const GpsStatus(this.label);
  final String label;
}

/// Optional satellite cross-check of what the controller reports.
///
/// The controller derives speed from motor commutation and a wheel-size
/// constant, so a flashed speed profile changes what it *claims* without
/// necessarily changing what the scooter *does*. GPS is the only independent
/// measurement available on a phone, which makes it the only way to confirm
/// that a 40 km/h image really produces 40 km/h.
class GpsTracker extends ChangeNotifier {
  GpsTracker(this._log);

  final SessionLog _log;

  StreamSubscription<Position>? _subscription;
  Position? _previous;

  GpsStatus _status = GpsStatus.off;
  double? _speedKmh;
  double? _accuracyMetres;
  double _distanceKm = 0;
  double _maxSpeedKmh = 0;
  int _sampleCount = 0;
  DateTime? _lastFix;
  String? _error;

  GpsStatus get status => _status;
  double? get speedKmh => _speedKmh;
  double? get accuracyMetres => _accuracyMetres;
  double get distanceKm => _distanceKm;
  double get maxSpeedKmh => _maxSpeedKmh;
  int get sampleCount => _sampleCount;
  DateTime? get lastFix => _lastFix;
  String? get error => _error;

  bool get running => _subscription != null;

  /// A fix older than this is stale — under trees or indoors the stream simply
  /// stops delivering rather than reporting a failure.
  bool get hasFreshFix =>
      _lastFix != null &&
      DateTime.now().difference(_lastFix!) < const Duration(seconds: 5);

  /// Fixes worse than this are folded into speed but not into distance: at
  /// walking pace, 25 m of scatter would invent hundreds of metres per minute.
  static const double _distanceAccuracyLimitM = 25;

  /// Minimum step before a movement counts. Below this it is almost always
  /// receiver noise rather than travel.
  static const double _minStepM = 2.5;

  /// Anything above this is a fix jump, not a scooter.
  static const double _maxPlausibleKmh = 120;

  Future<void> start() async {
    if (_subscription != null) return;
    _set(() {
      _status = GpsStatus.starting;
      _error = null;
    });

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _set(() => _status = GpsStatus.serviceDisabled);
        return;
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _set(() => _status = GpsStatus.denied);
        return;
      }

      _subscription = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 0,
        ),
      ).listen(
        _onPosition,
        onError: (Object error) {
          _log.add('GPS stream error: $error');
          _set(() {
            _status = GpsStatus.failed;
            _error = '$error';
          });
        },
        cancelOnError: false,
      );

      _set(() => _status = GpsStatus.acquiring);
      _log.add('GPS cross-check started');
    } catch (error) {
      _log.add('GPS start failed: $error');
      _set(() {
        _status = GpsStatus.failed;
        _error = '$error';
      });
    }
  }

  Future<void> stop() async {
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    _previous = null;
    _set(() {
      _status = GpsStatus.off;
      _speedKmh = null;
      _accuracyMetres = null;
    });
    _log.add('GPS cross-check stopped');
  }

  /// Clears accumulated distance and peak speed without dropping the fix.
  /// Paired with "Reset trip" so both distance figures restart together.
  void resetTrip() {
    _previous = null;
    _set(() {
      _distanceKm = 0;
      _maxSpeedKmh = 0;
      _sampleCount = 0;
    });
  }

  void _onPosition(Position position) {
    final accuracy = position.accuracy;
    // geolocator reports metres per second, and -1 where the platform has no
    // speed estimate at all.
    final rawSpeed = position.speed;
    final speedKmh = rawSpeed.isFinite && rawSpeed >= 0 ? rawSpeed * 3.6 : null;

    final previous = _previous;
    var distance = _distanceKm;
    if (previous != null && accuracy <= _distanceAccuracyLimitM) {
      final metres = Geolocator.distanceBetween(
        previous.latitude,
        previous.longitude,
        position.latitude,
        position.longitude,
      );
      final seconds = position.timestamp
              .difference(previous.timestamp)
              .inMilliseconds /
          1000.0;
      // Reject both receiver jitter and teleports: a step is only counted when
      // it is big enough to be real and slow enough to be possible.
      final impliedKmh = seconds > 0 ? metres / seconds * 3.6 : 0;
      if (metres >= _minStepM && impliedKmh <= _maxPlausibleKmh) {
        distance += metres / 1000;
      }
    }
    if (accuracy <= _distanceAccuracyLimitM) _previous = position;

    _set(() {
      _accuracyMetres = accuracy;
      _speedKmh = speedKmh;
      _distanceKm = distance;
      if (speedKmh != null && speedKmh <= _maxPlausibleKmh) {
        _maxSpeedKmh = math.max(_maxSpeedKmh, speedKmh);
      }
      _sampleCount++;
      _lastFix = DateTime.now();
      _status = GpsStatus.tracking;
    });
  }

  void _set(void Function() mutate) {
    mutate();
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    super.dispose();
  }
}

/// Side-by-side comparison of the controller's numbers against GPS.
class SpeedCrossCheck {
  const SpeedCrossCheck({
    required this.reportedKmh,
    required this.gpsKmh,
    required this.reportedTripKm,
    required this.gpsTripKm,
    required this.reportedMaxKmh,
    required this.gpsMaxKmh,
  });

  final double reportedKmh;
  final double? gpsKmh;
  final double reportedTripKm;
  final double gpsTripKm;
  final double reportedMaxKmh;
  final double gpsMaxKmh;

  /// Instantaneous difference, positive when the controller over-reports.
  double? get liveDeltaKmh => gpsKmh == null ? null : reportedKmh - gpsKmh!;

  /// How much the controller over- or under-states distance, as a ratio.
  ///
  /// Distance is the honest basis for calibration: instantaneous speed samples
  /// are noisy and never quite simultaneous, whereas both distance figures
  /// integrate the same journey. Needs enough travel to mean anything.
  double? get distanceRatio {
    if (gpsTripKm < 0.3 || reportedTripKm <= 0) return null;
    return reportedTripKm / gpsTripKm;
  }

  /// Percentage error in the controller's distance, positive when it
  /// over-reports. This is the wheel-size / speed-constant correction.
  double? get distanceErrorPercent {
    final ratio = distanceRatio;
    return ratio == null ? null : (ratio - 1) * 100;
  }

  /// Peak speed difference — the number that answers whether a flashed
  /// profile actually delivers the speed on its label.
  double? get maxDeltaKmh =>
      gpsMaxKmh <= 0 ? null : reportedMaxKmh - gpsMaxKmh;
}
