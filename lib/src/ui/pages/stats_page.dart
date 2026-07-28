import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../charge_history.dart';
import '../../gps_tracker.dart';
import '../../models.dart';
import '../brand.dart';
import '../odys_theme.dart';

class StatsPage extends StatelessWidget {
  const StatsPage({
    super.key,
    required this.rideStats,
    required this.telemetry,
    required this.connectionHistory,
    required this.onResetTrip,
    required this.lifetimeKm,
    required this.onResetOdometer,
    required this.chargeSession,
    required this.autoReconnect,
    required this.onAutoReconnectChanged,
    required this.lastDeviceName,
    required this.isDark,
    required this.onThemeToggle,
    required this.rideEnergy,
    required this.rangeEstimate,
    required this.whPerKm,
    required this.consumptionKm,
    required this.chargeStats,
    required this.onClearChargeHistory,
    required this.gps,
    required this.gpsEnabled,
    required this.onGpsEnabledChanged,
  });

  final RideStats rideStats;
  final Telemetry telemetry;
  final List<ConnectionRecord> connectionHistory;
  final VoidCallback onResetTrip;
  final double lifetimeKm;
  final Future<void> Function() onResetOdometer;
  final ChargeSession? chargeSession;
  final bool autoReconnect;
  final Future<void> Function(bool) onAutoReconnectChanged;
  final String? lastDeviceName;
  final bool isDark;
  final VoidCallback onThemeToggle;
  final RideEnergy rideEnergy;
  final RangeEstimate? rangeEstimate;
  final double? whPerKm;

  /// Distance the consumption figure was divided by — GPS when it has enough
  /// travel to be trusted, otherwise the controller's own number.
  final double consumptionKm;
  final ChargeHistoryStats chargeStats;
  final Future<void> Function() onClearChargeHistory;
  final GpsTracker gps;
  final bool gpsEnabled;
  final Future<void> Function(bool) onGpsEnabledChanged;

  bool get _usingGpsDistance => gps.distanceKm >= 0.3;

  SpeedCrossCheck get _crossCheck => SpeedCrossCheck(
        reportedKmh: telemetry.speedKmh,
        gpsKmh: gps.hasFreshFix ? gps.speedKmh : null,
        reportedTripKm: rideStats.tripDistanceKm,
        gpsTripKm: gps.distanceKm,
        reportedMaxKmh: rideStats.maxSpeedKmh,
        gpsMaxKmh: gps.maxSpeedKmh,
      );

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        PageHeader(
          title: 'Stats',
          needleFraction: (telemetry.speedKmh / 45).clamp(0.0, 1.0),
          trailing: IconButton(
            onPressed: onThemeToggle,
            icon: Icon(
              isDark ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
              color: AppColors.primary,
            ),
            tooltip: isDark ? 'Light mode' : 'Dark mode',
          ),
        ),

        // ── Ride statistics ──
        _Section(
          title: 'RIDE STATISTICS',
          trailing: TextButton(
            onPressed: onResetTrip,
            child: const Text('Reset trip'),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                      child: _StatTile(
                    icon: Icons.route_rounded,
                    label: 'TRIP',
                    value:
                        '${rideStats.tripDistanceKm.toStringAsFixed(2)} km',
                  )),
                  Container(width: 1, height: 48, color: AppColors.border),
                  Expanded(
                      child: _StatTile(
                    icon: Icons.speed_rounded,
                    label: 'MAX SPEED',
                    value: '${rideStats.maxSpeedKmh.toStringAsFixed(1)} km/h',
                  )),
                  Container(width: 1, height: 48, color: AppColors.border),
                  Expanded(
                      child: _StatTile(
                    icon: Icons.moving_rounded,
                    label: 'AVG SPEED',
                    value: '${rideStats.avgSpeedKmh.toStringAsFixed(1)} km/h',
                  )),
                ],
              ),
              if (rideStats.speedHistory.isNotEmpty) ...[
                const SizedBox(height: 16),
                const Text('SPEED HISTORY',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDim,
                      letterSpacing: 1.0,
                    )),
                const SizedBox(height: 8),
                SizedBox(
                  height: 80,
                  child: CustomPaint(
                    painter: _SpeedChartPainter(
                        samples: rideStats.speedHistory),
                    size: const Size(double.infinity, 80),
                  ),
                ),
              ],

              // ── Lifetime odometer ──
              const SizedBox(height: 12),
              const Divider(color: AppColors.border, height: 1),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(Icons.timeline_rounded,
                      size: 18, color: AppColors.primary),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text('LIFETIME ODOMETER',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: AppColors.textDim,
                          letterSpacing: 1.0,
                        )),
                  ),
                  Text('${lifetimeKm.toStringAsFixed(2)} km',
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      )),
                  IconButton(
                    onPressed: () => onResetOdometer(),
                    icon: const Icon(Icons.restart_alt_rounded, size: 18),
                    color: AppColors.textDim,
                    tooltip: 'Reset lifetime odometer',
                    visualDensity: VisualDensity.compact,
                  ),
                ],
              ),
              const Text(
                'Integrated from reported speed, not wheel revolutions, so it '
                'only counts distance covered while the app was connected.',
                style: TextStyle(
                    fontSize: 11, color: AppColors.textDim, height: 1.4),
              ),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // ── Energy and range ──
        _buildEnergySection(),

        const SizedBox(height: 8),

        // ── GPS cross-check ──
        _buildGpsSection(),

        const SizedBox(height: 8),

        // ── Charging ──
        if (chargeSession != null)
          _Section(
            title: chargeSession!.active
                ? 'CHARGING (LIVE)'
                : 'LAST CHARGE SESSION',
            child: Column(
              children: [
                _InfoRow('Phase', chargeSession!.phase.label),
                _InfoRow('Current',
                    '${chargeSession!.lastAmps.toStringAsFixed(2)} A'),
                _InfoRow('Peak current',
                    '${chargeSession!.peakAmps.toStringAsFixed(2)} A'),
                _InfoRow(
                    'Power', '${chargeSession!.watts.toStringAsFixed(0)} W'),
                _InfoRow('Delivered',
                    '${chargeSession!.ampHours.toStringAsFixed(3)} Ah'
                    ' · ${chargeSession!.wattHours.toStringAsFixed(1)} Wh'),
                _InfoRow('Duration', _durationLabel(chargeSession!.elapsed)),
                _InfoRow('Samples', '${chargeSession!.sampleCount}'),
              ],
            ),
          ),

        if (chargeSession != null) const SizedBox(height: 8),

        // ── Battery health ──
        _buildBatteryHealthSection(),

        const SizedBox(height: 8),

        // ── Error codes ──
        _Section(
          title: 'DIAGNOSTICS',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _InfoRow('Drive mode', DriveMode.describe(telemetry.mode)),
              if (telemetry.mode != null &&
                  DriveMode.fromCode(telemetry.mode) == null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 4),
                  child: Text(
                    'Unrecognised mode code. The raw value is what the '
                    'controller reported in the 0x90 frame.',
                    style: TextStyle(
                        fontSize: 11,
                        color: AppColors.textDim,
                        height: 1.4),
                  ),
                ),
              if (telemetry.errorCode == null || telemetry.errorCode == 0)
                const _InfoRow('Error code', 'None')
              else
                _ErrorCodeRow(code: telemetry.errorCode!),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // ── Connection history ──
        _Section(
          title: 'CONNECTION HISTORY',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SwitchListTile(
                value: autoReconnect,
                onChanged: (value) => onAutoReconnectChanged(value),
                title: const Text('Auto-reconnect',
                    style: TextStyle(
                        fontSize: 14, fontWeight: FontWeight.w600)),
                subtitle: Text(
                  lastDeviceName?.isNotEmpty == true
                      ? 'Reconnect to $lastDeviceName on launch and after a '
                          'dropped link'
                      : 'Reconnect to the last scooter on launch and after a '
                          'dropped link',
                  style: const TextStyle(
                      fontSize: 12, color: AppColors.textDim),
                ),
                contentPadding: EdgeInsets.zero,
                dense: true,
              ),
              const Divider(color: AppColors.border, height: 1),
              const SizedBox(height: 8),
              if (connectionHistory.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 4),
                  child: Text('No connections yet',
                      style:
                          TextStyle(color: AppColors.textDim, fontSize: 14)),
                )
              else
                ...connectionHistory.reversed
                    .take(10)
                    .map((r) => _ConnectionRow(record: r)),
            ],
          ),
        ),
      ],
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  //  Energy and range
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Widget _buildEnergySection() {
    final range = rangeEstimate;
    final consumption = whPerKm;
    return _Section(
      title: 'ENERGY & RANGE',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                  child: _StatTile(
                icon: Icons.social_distance_rounded,
                label: 'RANGE LEFT',
                value: range == null
                    ? '—'
                    : '${range.km.toStringAsFixed(1)} km',
              )),
              Container(width: 1, height: 48, color: AppColors.border),
              Expanded(
                  child: _StatTile(
                icon: Icons.eco_rounded,
                label: 'CONSUMPTION',
                value: consumption == null
                    ? '—'
                    : '${consumption.toStringAsFixed(1)} Wh/km',
              )),
              Container(width: 1, height: 48, color: AppColors.border),
              Expanded(
                  child: _StatTile(
                icon: Icons.bolt_rounded,
                label: 'DRAWN',
                value: '${rideEnergy.wattHours.toStringAsFixed(1)} Wh',
              )),
            ],
          ),
          const SizedBox(height: 12),
          const Divider(color: AppColors.border, height: 1),
          const SizedBox(height: 4),
          _InfoRow('Charge drawn',
              '${rideEnergy.ampHours.toStringAsFixed(3)} Ah'),
          _InfoRow('Power now', '${rideEnergy.watts.toStringAsFixed(0)} W'),
          _InfoRow('Peak current',
              '${rideEnergy.peakAmps.toStringAsFixed(2)} A'),
          _InfoRow(
            'Battery used',
            rideEnergy.percentUsed == null
                ? '—'
                : '${rideEnergy.percentUsed} pts '
                    '(${rideEnergy.startPercent}% → '
                    '${rideEnergy.lastPercent}%)',
          ),
          _InfoRow(
            'Measured over',
            '${consumptionKm.toStringAsFixed(2)} km '
                '(${_usingGpsDistance ? "GPS" : "reported"})',
          ),
          _InfoRow('Samples', '${rideEnergy.sampleCount}'),
          const SizedBox(height: 8),
          _Note(
            range == null
                ? 'A range figure needs consumption over at least 300 m and a '
                    'pack size. Pack size comes from charge history once a '
                    'wide charge has been logged, or from this ride once '
                    '${RideEnergy.minPercentForSlope} percentage points have '
                    'been used.'
                : 'Pack energy ${range.basis.label}: '
                    '${range.remainingWh.toStringAsFixed(0)} Wh remaining at '
                    '${range.whPerKm.toStringAsFixed(1)} Wh/km. Hills, wind '
                    'and speed move this figure more than anything else.',
          ),
        ],
      ),
    );
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  //  GPS cross-check
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Widget _buildGpsSection() {
    final check = _crossCheck;
    final errorPercent = check.distanceErrorPercent;
    final maxDelta = check.maxDeltaKmh;

    return _Section(
      title: 'GPS CROSS-CHECK',
      trailing: Text(
        gps.status.label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: gps.status == GpsStatus.tracking
              ? AppColors.primary
              : AppColors.textDim,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            value: gpsEnabled,
            onChanged: (value) => onGpsEnabledChanged(value),
            title: const Text('Satellite tracking',
                style:
                    TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: const Text(
              'Independent speed and distance, to check what the controller '
              'reports against what the scooter actually does',
              style: TextStyle(fontSize: 12, color: AppColors.textDim),
            ),
            contentPadding: EdgeInsets.zero,
            dense: true,
          ),
          if (gpsEnabled) ...[
            const Divider(color: AppColors.border, height: 1),
            const SizedBox(height: 4),
            _InfoRow(
              'Fix accuracy',
              gps.accuracyMetres == null
                  ? '—'
                  : '±${gps.accuracyMetres!.toStringAsFixed(0)} m',
            ),
            _InfoRow(
              'Speed now',
              check.gpsKmh == null
                  ? 'No fix'
                  : '${check.reportedKmh.toStringAsFixed(1)} vs '
                      '${check.gpsKmh!.toStringAsFixed(1)} km/h'
                      '${_signed(check.liveDeltaKmh)}',
            ),
            _InfoRow(
              'Peak speed',
              gps.maxSpeedKmh <= 0
                  ? '—'
                  : '${check.reportedMaxKmh.toStringAsFixed(1)} vs '
                      '${check.gpsMaxKmh.toStringAsFixed(1)} km/h'
                      '${_signed(maxDelta)}',
            ),
            _InfoRow(
              'Trip distance',
              '${check.reportedTripKm.toStringAsFixed(2)} vs '
                  '${check.gpsTripKm.toStringAsFixed(2)} km',
            ),
            _InfoRow(
              'Distance error',
              errorPercent == null
                  ? 'Ride 300 m to compare'
                  : '${errorPercent >= 0 ? "+" : ""}'
                      '${errorPercent.toStringAsFixed(1)}%',
            ),
            _InfoRow('Fixes', '${gps.sampleCount}'),
            const SizedBox(height: 8),
            _Note(_gpsVerdict(errorPercent, maxDelta)),
          ] else
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: _Note(
                'The controller works out speed from motor commutation and an '
                'assumed wheel size, so a flashed profile changes what it '
                'claims without proving what it delivers. Satellites are the '
                'only independent witness a phone has. Uses location only '
                'while the app is open.',
              ),
            ),
        ],
      ),
    );
  }

  static String _signed(double? delta) {
    if (delta == null) return '';
    final sign = delta >= 0 ? '+' : '−';
    return '  ($sign${delta.abs().toStringAsFixed(1)})';
  }

  static String _gpsVerdict(double? errorPercent, double? maxDelta) {
    if (errorPercent == null) {
      return 'Ride at least 300 m with a clear view of the sky. Distance is '
          'the honest basis for comparison: single speed readings are noisy '
          'and never quite simultaneous, whereas both distance figures '
          'integrate the same journey.';
    }
    final magnitude = errorPercent.abs();
    final direction = errorPercent >= 0 ? 'over' : 'under';
    if (magnitude < 3) {
      return 'The controller is within ${magnitude.toStringAsFixed(1)}% of '
          'GPS, which is inside GPS scatter. Its speed and distance can be '
          'taken at face value, so a speed profile that reads 40 km/h really '
          'is doing 40.';
    }
    final peak = maxDelta == null
        ? ''
        : ' Peak speed differed by ${maxDelta.abs().toStringAsFixed(1)} km/h.';
    return 'The controller $direction-reports distance by '
        '${magnitude.toStringAsFixed(1)}%, so its speed is off by roughly the '
        'same proportion — a wheel-size or speed-constant mismatch rather '
        'than anything the profile changed.$peak Divide any displayed speed '
        'by ${(1 + errorPercent / 100).toStringAsFixed(3)} for the real one.';
  }

  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
  //  Battery health
  // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  Widget _buildBatteryHealthSection() {
    final packAh = chargeStats.packAh;
    final packWh = chargeStats.packWh;
    final degradation = chargeStats.degradationPercent;
    final cycles = chargeStats.observedCycles;
    final recent = chargeStats.records.reversed.take(5).toList();

    return _Section(
      title: 'BATTERY HEALTH',
      trailing: chargeStats.records.isEmpty
          ? null
          : TextButton(
              onPressed: () => onClearChargeHistory(),
              child: const Text('Clear'),
            ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Capacity, measured across stored charges ──
          _InfoRow(
            'Measured capacity',
            packAh == null
                ? 'Not measured yet'
                : '${packAh.toStringAsFixed(2)} Ah'
                    '${packWh == null ? "" : " · ${packWh.toStringAsFixed(0)} Wh"}',
          ),
          _InfoRow(
            'Capacity trend',
            degradation == null
                ? '—'
                : '${degradation >= 0 ? "+" : ""}'
                    '${degradation.toStringAsFixed(1)}% since first measurement',
          ),
          _InfoRow(
            'Observed cycles',
            cycles == null ? '—' : cycles.toStringAsFixed(1),
          ),
          _InfoRow(
            'Charges logged',
            '${chargeStats.records.length}'
                '${chargeStats.capacityRecords.isEmpty ? "" : " (${chargeStats.capacityRecords.length} wide enough to measure)"}',
          ),
          _InfoRow('Total delivered',
              '${chargeStats.totalAhDelivered.toStringAsFixed(1)} Ah'),
          const SizedBox(height: 8),
          _Note(chargeStats.hasCapacityData
              ? 'Capacity is the median of every charge spanning at least '
                  '${ChargeRecord.minSpanForCapacity} percentage points, '
                  'extrapolated to a full pack. The trend across months is the '
                  'signal; any single number carries the state-of-charge '
                  'gauge\'s own error.'
              : 'A charge has to add at least '
                  '${ChargeRecord.minSpanForCapacity} percentage points before '
                  'the delivered amp-hours say anything about capacity. Run '
                  'the pack low, then charge it to full with the app '
                  'connected.'),

          if (recent.isNotEmpty) ...[
            const SizedBox(height: 12),
            const Divider(color: AppColors.border, height: 1),
            const SizedBox(height: 8),
            const Text('RECENT CHARGES',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textDim,
                  letterSpacing: 1.0,
                )),
            const SizedBox(height: 4),
            ...recent.map((r) => _ChargeRecordRow(record: r)),
          ],

          // ── Instantaneous readings ──
          const SizedBox(height: 12),
          const Divider(color: AppColors.border, height: 1),
          const SizedBox(height: 8),
          const Text('RIGHT NOW',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: AppColors.textDim,
                letterSpacing: 1.0,
              )),
          const SizedBox(height: 4),
          _InfoRow(
            'Voltage',
            telemetry.voltage == null
                ? '—'
                : '${telemetry.voltage!.toStringAsFixed(2)} V',
          ),
          _InfoRow(
            'Temperature',
            telemetry.batteryTemperature == null
                ? '—'
                : '${telemetry.batteryTemperature!.toStringAsFixed(0)} °C',
          ),
          _InfoRow(
            'Current',
            telemetry.current == null
                ? '—'
                : '${telemetry.current!.toStringAsFixed(2)} A',
          ),
          _InfoRow(
            'State',
            telemetry.isCharging == null
                ? '—'
                : telemetry.isCharging!
                    ? 'Charging'
                    : 'Discharging',
          ),
        ],
      ),
    );
  }

  static String _durationLabel(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m}m';
    return m > 0 ? '${m}m ${s}s' : '${s}s';
  }
}

// ── Section ──

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Text(title,
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: AppColors.textDim,
                        letterSpacing: 1.2,
                      )),
                  if (trailing != null) ...[
                    const Spacer(),
                    trailing!,
                  ],
                ],
              ),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      );
}

// ── Stat tile ──

class _StatTile extends StatelessWidget {
  const _StatTile(
      {required this.icon, required this.label, required this.value});
  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: AppColors.text,
              )),
          Text(label,
              style: const TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w600,
                color: AppColors.textDim,
                letterSpacing: 0.5,
              )),
        ],
      );
}

// ── Info row ──

class _InfoRow extends StatelessWidget {
  const _InfoRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 14, color: AppColors.textDim)),
            const Spacer(),
            Text(value,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.text,
                )),
          ],
        ),
      );
}

// ── Error code row ──

class _ErrorCodeRow extends StatelessWidget {
  const _ErrorCodeRow({required this.code});
  final int code;

  static String _describe(int code) => switch (code) {
        0x01 => 'Over-voltage',
        0x02 => 'Under-voltage',
        0x03 => 'Over-current',
        0x04 => 'Motor stall',
        0x05 => 'Hall sensor fault',
        0x06 => 'Over-temperature',
        0x07 => 'BMS communication fault',
        _ => 'Unknown error (0x${code.toRadixString(16).padLeft(2, "0")})',
      };

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: AppColors.danger, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '0x${code.toRadixString(16).padLeft(2, "0").toUpperCase()} — ${_describe(code)}',
                style: const TextStyle(
                    fontSize: 14, color: AppColors.danger),
              ),
            ),
          ],
        ),
      );
}

// ── Connection history row ──

class _ConnectionRow extends StatelessWidget {
  const _ConnectionRow({required this.record});
  final ConnectionRecord record;

  @override
  Widget build(BuildContext context) {
    final time = record.connectedAt;
    final label =
        '${time.year}-${time.month.toString().padLeft(2, "0")}-${time.day.toString().padLeft(2, "0")} '
        '${time.hour.toString().padLeft(2, "0")}:${time.minute.toString().padLeft(2, "0")}';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          const Icon(Icons.bluetooth_rounded,
              size: 16, color: AppColors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              record.deviceName.isNotEmpty
                  ? record.deviceName
                  : record.deviceId,
              style: const TextStyle(fontSize: 14, color: AppColors.text),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(label,
              style: const TextStyle(
                  fontSize: 11, color: AppColors.textDim)),
        ],
      ),
    );
  }
}

// ── Explanatory note ──

class _Note extends StatelessWidget {
  const _Note(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
          fontSize: 11.5,
          color: AppColors.textDim,
          height: 1.45,
        ),
      );
}

// ── Stored charge session row ──

class _ChargeRecordRow extends StatelessWidget {
  const _ChargeRecordRow({required this.record});
  final ChargeRecord record;

  @override
  Widget build(BuildContext context) {
    final t = record.startedAt;
    final date = '${t.year}-${t.month.toString().padLeft(2, "0")}-'
        '${t.day.toString().padLeft(2, "0")}';
    final span = record.percentGained == null
        ? '—'
        : '${record.startPercent}→${record.endPercent}%';
    final implied = record.impliedPackAh;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            record.measuresCapacity
                ? Icons.check_circle_outline_rounded
                : Icons.remove_circle_outline_rounded,
            size: 15,
            color: record.measuresCapacity
                ? AppColors.primary
                : AppColors.textDim,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text('$date  ·  $span',
                style: const TextStyle(fontSize: 12.5, color: AppColors.text),
                overflow: TextOverflow.ellipsis),
          ),
          Text(
            '${record.ampHours.toStringAsFixed(2)} Ah'
            '${implied == null ? "" : "  →  ${implied.toStringAsFixed(1)} Ah pack"}',
            style: const TextStyle(fontSize: 11.5, color: AppColors.textDim),
          ),
        ],
      ),
    );
  }
}

// ── Speed chart painter ──

class _SpeedChartPainter extends CustomPainter {
  const _SpeedChartPainter({required this.samples});
  final List<SpeedSample> samples;

  @override
  void paint(Canvas canvas, Size size) {
    if (samples.length < 2) return;
    final maxSpeed =
        samples.map((s) => s.speedKmh).reduce(math.max).clamp(1.0, 60.0);

    final linePaint = Paint()
      ..color = AppColors.primary
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final fillPaint = Paint()
      ..color = AppColors.primary.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;

    final path = Path();
    final fill = Path();

    for (var i = 0; i < samples.length; i++) {
      final x = i / (samples.length - 1) * size.width;
      final y = size.height -
          (samples[i].speedKmh / maxSpeed) * size.height * 0.9;
      if (i == 0) {
        path.moveTo(x, y);
        fill.moveTo(x, size.height);
        fill.lineTo(x, y);
      } else {
        path.lineTo(x, y);
        fill.lineTo(x, y);
      }
    }
    fill.lineTo(size.width, size.height);
    fill.close();

    canvas.drawPath(fill, fillPaint);
    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _SpeedChartPainter old) =>
      old.samples != samples;
}
