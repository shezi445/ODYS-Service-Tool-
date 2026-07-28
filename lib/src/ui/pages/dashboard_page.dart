import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ble/odys_ble_client.dart';
import '../../models.dart';
import '../brand.dart';
import '../odys_theme.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
    required this.client,
    required this.phoneBatteryPercent,
    required this.flashing,
    required this.accountIdController,
    required this.speed,
    required this.onConnect,
    required this.onDisconnect,
    required this.onCruiseChanged,
    required this.autoCruise,
    required this.autoCruiseSpeedKmh,
    required this.autoCruiseSpeedOptions,
    required this.autoCruiseBusy,
    required this.onAutoCruiseChanged,
    required this.onAutoCruiseSpeedChanged,
    required this.onSpeedSelected,
    required this.onOpenFlash,
    required this.chargeSession,
    required this.lastDeviceName,
    required this.canReconnect,
    required this.onReconnect,
    required this.rangeEstimate,
    required this.whPerKm,
    required this.gpsSpeedKmh,
  });

  final OdysBleClient client;
  final int? phoneBatteryPercent;
  final bool flashing;
  final TextEditingController accountIdController;
  final SpeedProfile speed;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final Future<void> Function(bool) onCruiseChanged;
  final bool autoCruise;
  final int autoCruiseSpeedKmh;
  final List<int> autoCruiseSpeedOptions;
  final bool autoCruiseBusy;
  final Future<void> Function(bool) onAutoCruiseChanged;
  final ValueChanged<int?> onAutoCruiseSpeedChanged;
  final ValueChanged<SpeedProfile> onSpeedSelected;
  final VoidCallback onOpenFlash;
  final ChargeSession? chargeSession;
  final String? lastDeviceName;
  final bool canReconnect;
  final Future<void> Function() onReconnect;
  final RangeEstimate? rangeEstimate;
  final double? whPerKm;

  /// Live satellite speed, or null when tracking is off or the fix is stale.
  final double? gpsSpeedKmh;

  bool get _connected =>
      client.phase == ConnectionPhase.connected ||
      client.phase == ConnectionPhase.flashing;

  @override
  Widget build(BuildContext context) {
    final t = client.telemetry;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // ── Header ──
        PageHeader(
          title: 'Dashboard',
          needleFraction: (t.speedKmh / 45).clamp(0.0, 1.0),
          trailing: _StatusChip(phase: client.phase),
        ),

        // ── Connection ──
        if (!_connected) _buildConnectCard(context),
        if (_connected) _buildConnectedBanner(context),
        if (client.lastConnectionError != null) ...[
          const SizedBox(height: 8),
          _buildErrorBanner(context),
        ],

        const SizedBox(height: 8),

        // ── Speedometer ──
        _SpeedometerCard(
          speed: t.speedKmh,
          connected: _connected,
          battery: t.batteryPercent,
          voltage: t.voltage,
          temperature: t.batteryTemperature,
          gpsSpeedKmh: gpsSpeedKmh,
        ),

        const SizedBox(height: 8),

        // ── Mini stat cards ──
        Row(
          children: [
            Expanded(
                child: _MiniStat(
              icon: Icons.phone_android_rounded,
              label: 'PHONE',
              value: phoneBatteryPercent == null
                  ? '—'
                  : '$phoneBatteryPercent%',
              ok: phoneBatteryPercent != null && phoneBatteryPercent! >= 30,
            )),
            const SizedBox(width: 8),
            Expanded(
                child: _MiniStat(
              icon: Icons.signal_cellular_alt_rounded,
              label: 'SIGNAL',
              value: client.rssi == null ? '—' : '${client.rssi} dBm',
              ok: client.rssi != null && client.rssi! >= -85,
            )),
          ],
        ),

        const SizedBox(height: 8),

        Row(
          children: [
            Expanded(
                child: _MiniStat(
              icon: Icons.tune_rounded,
              label: 'DRIVE MODE',
              value: DriveMode.describe(t.mode),
              ok: true,
            )),
            const SizedBox(width: 8),
            Expanded(
                child: _MiniStat(
              icon: Icons.error_outline_rounded,
              label: 'ERROR',
              value: t.errorCode == null
                  ? '—'
                  : t.errorCode == 0
                      ? 'None'
                      : '0x${t.errorCode!.toRadixString(16).padLeft(2, "0").toUpperCase()}',
              ok: (t.errorCode ?? 0) == 0,
            )),
          ],
        ),

        // ── Range and consumption ──
        // Only shown once there is enough travel to divide by; an invented
        // range figure is worse than none.
        if (rangeEstimate != null || whPerKm != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                  child: _MiniStat(
                icon: Icons.social_distance_rounded,
                label: rangeEstimate == null
                    ? 'RANGE'
                    : 'RANGE · ${rangeEstimate!.basis == EnergyBasis.chargeHistory ? "MEASURED" : "THIS RIDE"}',
                value: rangeEstimate == null
                    ? '—'
                    : '${rangeEstimate!.km.toStringAsFixed(1)} km',
                ok: true,
              )),
              const SizedBox(width: 8),
              Expanded(
                  child: _MiniStat(
                icon: Icons.eco_rounded,
                label: 'CONSUMPTION',
                value: whPerKm == null
                    ? '—'
                    : '${whPerKm!.toStringAsFixed(1)} Wh/km',
                ok: true,
              )),
            ],
          ),
        ],

        // ── Charging monitor ──
        if (chargeSession != null) ...[
          const SizedBox(height: 8),
          _ChargingCard(session: chargeSession!),
        ],

        // ── Cruise control ──
        if (_connected) ...[
          const SizedBox(height: 8),
          _buildCruiseCard(context),
        ],

        // ── Speed limit quick-switch ──
        const SizedBox(height: 8),
        _buildSpeedProfileCard(context),
      ],
    );
  }

  // ── Speed limit profile quick-switch ──
  Widget _buildSpeedProfileCard(BuildContext context) {
    const quick = [
      SpeedProfile.limit20,
      SpeedProfile.stock,
      SpeedProfile.limit25,
      SpeedProfile.limit30,
      SpeedProfile.limit32,
      SpeedProfile.experimental40,
    ];

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Text('SPEED LIMIT PROFILE',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textDim,
                      letterSpacing: 1.2,
                    )),
                const Spacer(),
                if (speed.experimental)
                  const Icon(Icons.warning_amber_rounded,
                      size: 16, color: AppColors.danger),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in quick)
                  _ProfileChip(
                    label: p == SpeedProfile.stock
                        ? '22 stock'
                        : '${p.kmh}${p.experimental ? " ⚠" : ""}',
                    selected: speed == p,
                    danger: p.experimental,
                    onTap: flashing ? null : () => onSpeedSelected(p),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              speed.label,
              style: const TextStyle(fontSize: 13, color: AppColors.textDim),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: flashing ? null : onOpenFlash,
                icon: const Icon(Icons.system_update_alt_rounded, size: 18),
                label: const Text('Review pre-flight and flash'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Connection card (disconnected) ──
  Widget _buildConnectCard(BuildContext context) {
    final busy = client.phase == ConnectionPhase.scanning ||
        client.phase == ConnectionPhase.connecting ||
        client.phase == ConnectionPhase.authenticating;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: AppColors.primaryDim,
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.electric_scooter_rounded,
                  size: 32, color: AppColors.primary),
            ),
            const SizedBox(height: 16),
            const Text('Connect your scooter',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppColors.text,
                )),
            const SizedBox(height: 4),
            Text(
                busy
                    ? _phaseLabel(client.phase)
                    : 'Enter your account ID to begin',
                style: const TextStyle(
                    fontSize: 14, color: AppColors.textDim)),
            const SizedBox(height: 20),
            TextField(
              controller: accountIdController,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              maxLength: 10,
              enabled: !busy,
              style: const TextStyle(color: AppColors.text),
              decoration: const InputDecoration(
                labelText: 'Account ID',
                counterText: '',
              ),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: busy ? null : onConnect,
                child: busy
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2.5, color: AppColors.bg),
                      )
                    : const Text('Scan for scooters'),
              ),
            ),
            // Direct reconnect skips the scan entirely by using the saved
            // remote ID from the last successful connection.
            if (canReconnect) ...[
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: busy ? null : () => onReconnect(),
                  icon: const Icon(Icons.autorenew_rounded, size: 18),
                  label: Text(
                    lastDeviceName?.isNotEmpty == true
                        ? 'Reconnect to $lastDeviceName'
                        : 'Reconnect to last scooter',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Connected banner ──
  Widget _buildConnectedBanner(BuildContext context) {
    final name = client.device?.platformName;
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: AppColors.primaryDim,
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.bluetooth_connected_rounded,
                  size: 20, color: AppColors.primary),
            ),
            const SizedBox(width: 12),
            Expanded(
                child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name?.isNotEmpty == true ? name! : 'ODYS Scooter',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: AppColors.text,
                  ),
                ),
                Text(_phaseLabel(client.phase),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textDim)),
              ],
            )),
            TextButton(
              onPressed: flashing ? null : onDisconnect,
              child: const Text('Disconnect'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Error banner ──
  Widget _buildErrorBanner(BuildContext context) {
    return Card(
      color: AppColors.dangerDim,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            const Icon(Icons.warning_amber_rounded,
                color: AppColors.danger, size: 20),
            const SizedBox(width: 12),
            Expanded(
                child: Text(client.lastConnectionError!,
                    style: const TextStyle(
                        fontSize: 13, color: AppColors.text))),
          ],
        ),
      ),
    );
  }

  // ── Cruise control ──
  Widget _buildCruiseCard(BuildContext context) {
    final armed = autoCruise &&
        client.telemetry.speedKmh >= autoCruiseSpeedKmh.toDouble();

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SwitchListTile(
            value: client.cruiseEnabled,
            onChanged: _connected && !flashing && !autoCruise
                ? (value) => onCruiseChanged(value)
                : null,
            title: const Text('Cruise control',
                style: TextStyle(fontWeight: FontWeight.w600)),
            subtitle: autoCruise
                ? const Text('Managed by auto-cruise',
                    style: TextStyle(fontSize: 12))
                : null,
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          ),

          const Divider(color: AppColors.border, height: 1),

          // ── Auto-cruise ──
          SwitchListTile(
            value: autoCruise,
            onChanged: _connected && !flashing
                ? (value) => onAutoCruiseChanged(value)
                : null,
            title: Row(
              children: [
                const Text('Auto-cruise',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                if (autoCruiseBusy) ...[
                  const SizedBox(width: 8),
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: AppColors.primary),
                  ),
                ] else if (armed) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.primaryDim,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('ARMED',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          color: AppColors.primary,
                          letterSpacing: 0.6,
                        )),
                  ),
                ],
              ],
            ),
            subtitle: const Text(
              'Enable cruise once speed reaches the threshold',
              style: TextStyle(fontSize: 12, color: AppColors.textDim),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          ),

          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DropdownButtonFormField<int>(
                  initialValue: autoCruiseSpeedKmh,
                  decoration: const InputDecoration(
                    labelText: 'Engage at speed',
                    isDense: true,
                  ),
                  dropdownColor: AppColors.surfaceHi,
                  items: autoCruiseSpeedOptions
                      .map((kmh) => DropdownMenuItem(
                            value: kmh,
                            child: Text('$kmh km/h'),
                          ))
                      .toList(),
                  onChanged: autoCruise && !flashing
                      ? onAutoCruiseSpeedChanged
                      : null,
                ),
                if (autoCruise) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Cruise is enabled at or above $autoCruiseSpeedKmh km/h '
                    'and released below '
                    '${autoCruiseSpeedKmh - 3} km/h. The controller still '
                    'latches cruise on steady throttle — this only opens the '
                    'gate.',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textDim,
                      height: 1.4,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _phaseLabel(ConnectionPhase phase) => switch (phase) {
        ConnectionPhase.disconnected => 'Disconnected',
        ConnectionPhase.scanning => 'Scanning for devices…',
        ConnectionPhase.connecting => 'Connecting…',
        ConnectionPhase.authenticating => 'Authenticating…',
        ConnectionPhase.connected => 'Connected',
        ConnectionPhase.reconnecting => 'Reconnecting…',
        ConnectionPhase.flashing => 'Firmware update in progress',
        ConnectionPhase.recovering => 'Recovering connection…',
      };
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Speed profile chip
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _ProfileChip extends StatelessWidget {
  const _ProfileChip({
    required this.label,
    required this.selected,
    required this.danger,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final bool danger;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final accent = danger ? AppColors.danger : AppColors.primary;
    final enabled = onTap != null;
    return Material(
      color: selected
          ? accent.withValues(alpha: 0.16)
          : Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? accent : AppColors.border,
              width: selected ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: !enabled
                  ? AppColors.border
                  : selected
                      ? accent
                      : AppColors.textDim,
            ),
          ),
        ),
      ),
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Status chip
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.phase});
  final ConnectionPhase phase;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (phase) {
      ConnectionPhase.disconnected => ('OFFLINE', AppColors.textDim),
      ConnectionPhase.scanning ||
      ConnectionPhase.connecting ||
      ConnectionPhase.authenticating =>
        ('CONNECTING', AppColors.warning),
      ConnectionPhase.connected => ('LIVE', AppColors.primary),
      ConnectionPhase.reconnecting => ('RECONNECT', AppColors.warning),
      ConnectionPhase.flashing => ('FLASHING', AppColors.warning),
      ConnectionPhase.recovering => ('RECOVERY', AppColors.danger),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: color,
                letterSpacing: 0.8,
              )),
        ],
      ),
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Speedometer card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _SpeedometerCard extends StatelessWidget {
  const _SpeedometerCard({
    required this.speed,
    required this.connected,
    required this.battery,
    required this.voltage,
    required this.temperature,
    required this.gpsSpeedKmh,
  });

  final double speed;
  final bool connected;
  final int? battery;
  final double? voltage;
  final double? temperature;
  final double? gpsSpeedKmh;

  @override
  Widget build(BuildContext context) {
    final displaySpeed = speed.clamp(0.0, 45.0);
    final color = _speedColor(displaySpeed);

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          children: [
            // Gauge
            SizedBox(
              height: 210,
              child: LayoutBuilder(builder: (context, constraints) {
                return Stack(
                  alignment: Alignment.center,
                  children: [
                    CustomPaint(
                      size: Size(constraints.maxWidth, 210),
                      painter: _GaugePainter(
                        fraction: displaySpeed / 45.0,
                        color: color,
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          displaySpeed.toStringAsFixed(0),
                          style: TextStyle(
                            fontSize: 76,
                            fontWeight: FontWeight.w800,
                            color: connected
                                ? AppColors.text
                                : AppColors.textDim,
                            height: 0.85,
                            letterSpacing: -3,
                          ),
                        ),
                        Text('KM/H',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: connected
                                  ? AppColors.textDim
                                  : AppColors.border,
                              letterSpacing: 3,
                            )),
                        // The independent number, right next to the claimed
                        // one — the whole point of the cross-check.
                        if (gpsSpeedKmh != null) ...[
                          const SizedBox(height: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 3),
                            decoration: BoxDecoration(
                              color: AppColors.surfaceHi,
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(color: AppColors.border),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.satellite_alt_rounded,
                                    size: 12, color: AppColors.teal),
                                const SizedBox(width: 5),
                                Text(
                                  'GPS ${gpsSpeedKmh!.toStringAsFixed(1)}',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    color: AppColors.teal,
                                    letterSpacing: 0.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                );
              }),
            ),

            const SizedBox(height: 4),
            const Divider(color: AppColors.border, height: 1),
            const SizedBox(height: 12),

            // Bottom stats
            Row(
              children: [
                Expanded(
                    child: _GaugeStat(
                  icon: Icons.battery_charging_full_rounded,
                  value: battery == null ? '—' : '$battery%',
                  label: 'BATTERY',
                )),
                Container(width: 1, height: 36, color: AppColors.border),
                Expanded(
                    child: _GaugeStat(
                  icon: Icons.bolt_rounded,
                  value: voltage == null
                      ? '—'
                      : '${voltage!.toStringAsFixed(1)}V',
                  label: 'VOLTAGE',
                )),
                Container(width: 1, height: 36, color: AppColors.border),
                Expanded(
                    child: _GaugeStat(
                  icon: Icons.thermostat_rounded,
                  value: temperature == null
                      ? '—'
                      : '${temperature!.toStringAsFixed(0)}°C',
                  label: 'TEMP',
                )),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static Color _speedColor(double speed) {
    if (speed <= 25) return AppColors.primary;
    if (speed <= 32) return AppColors.teal;
    if (speed <= 38) return AppColors.warning;
    return AppColors.danger;
  }
}

class _GaugeStat extends StatelessWidget {
  const _GaugeStat(
      {required this.icon, required this.value, required this.label});
  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Icon(icon, size: 18, color: AppColors.primary),
          const SizedBox(height: 4),
          Text(value,
              style: const TextStyle(
                fontSize: 16,
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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Gauge painter with glow
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _GaugePainter extends CustomPainter {
  _GaugePainter({required this.fraction, required this.color});
  final double fraction;
  final Color color;

  // Arc from ~7:40 to ~3:45 sweeping through 12 o'clock (≈243°)
  static const _start = 2.44;
  static const _sweep = 4.24;

  @override
  void paint(Canvas canvas, Size size) {
    final centerX = size.width / 2;
    final centerY = size.height * 0.48;
    final radius = math.min(size.width, size.height) * 0.42;
    final rect =
        Rect.fromCircle(center: Offset(centerX, centerY), radius: radius);

    // Track
    final track = Paint()
      ..color = const Color(0xff1A2535)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, _start, _sweep, false, track);

    if (fraction > 0.005) {
      // Glow
      final glow = Paint()
        ..color = color.withValues(alpha: 0.20)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 32
        ..strokeCap = StrokeCap.round
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14);
      canvas.drawArc(rect, _start, _sweep * fraction, false, glow);

      // Active arc
      final active = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 18
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(rect, _start, _sweep * fraction, false, active);
    }
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) =>
      old.fraction != fraction || old.color != color;
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Charging monitor card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _ChargingCard extends StatelessWidget {
  const _ChargingCard({required this.session});
  final ChargeSession session;

  static String _duration(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    return h > 0 ? '${h}h ${m}m' : '${m}m';
  }

  @override
  Widget build(BuildContext context) {
    final active = session.active;
    final accent = active ? AppColors.teal : AppColors.textDim;
    final eta = session.estimatedTimeToFull;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Icon(
                  active
                      ? Icons.battery_charging_full_rounded
                      : Icons.power_off_rounded,
                  size: 16,
                  color: accent,
                ),
                const SizedBox(width: 8),
                Text(active ? 'CHARGING' : 'LAST CHARGE SESSION',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: accent,
                      letterSpacing: 1.2,
                    )),
                const Spacer(),
                Text(_duration(session.elapsed),
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textDim)),
              ],
            ),
            const SizedBox(height: 14),

            // Live electrical readings
            Row(
              children: [
                Expanded(
                    child: _GaugeStat(
                  icon: Icons.electric_bolt_rounded,
                  value: '${session.lastAmps.toStringAsFixed(2)} A',
                  label: 'CURRENT',
                )),
                Container(width: 1, height: 36, color: AppColors.border),
                Expanded(
                    child: _GaugeStat(
                  icon: Icons.power_rounded,
                  value: '${session.watts.toStringAsFixed(0)} W',
                  label: 'POWER',
                )),
                Container(width: 1, height: 36, color: AppColors.border),
                Expanded(
                    child: _GaugeStat(
                  icon: Icons.battery_5_bar_rounded,
                  value: '${session.ampHours.toStringAsFixed(2)} Ah',
                  label: 'DELIVERED',
                )),
              ],
            ),

            const SizedBox(height: 14),
            const Divider(color: AppColors.border, height: 1),
            const SizedBox(height: 10),

            _ChargeRow('Phase', session.phase.label),
            _ChargeRow('Peak current',
                '${session.peakAmps.toStringAsFixed(2)} A'),
            _ChargeRow('Pack voltage',
                '${session.lastVolts.toStringAsFixed(2)} V'),
            _ChargeRow('Energy',
                '${session.wattHours.toStringAsFixed(1)} Wh'),
            _ChargeRow(
              'Charge level',
              session.startPercent == null || session.lastPercent == null
                  ? '—'
                  : '${session.startPercent}% → ${session.lastPercent}%'
                      ' (${session.percentGainedLabel})',
            ),
            _ChargeRow(
              'Est. time to full',
              eta == null
                  ? 'Measuring…'
                  : eta == Duration.zero
                      ? 'Full'
                      : _duration(eta),
            ),

            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.surfaceHi,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _bottleneckHint(session),
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textDim,
                  height: 1.45,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The whole point of measuring peak current: it tells you which of the three
  /// series limits (charger brick, BMS charge FET, cell C-rate) is actually
  /// binding. The app cannot change any of them, so this is diagnostic only.
  static String _bottleneckHint(ChargeSession session) {
    if (session.sampleCount < 3) {
      return 'Collecting samples. Peak current during the constant-current '
          'phase is the number to compare against your charger.';
    }
    final peak = session.peakAmps.toStringAsFixed(2);
    if (session.phase == ChargePhase.constantVoltage) {
      return 'Current is tapering, which is normal near a full pack. Peak this '
          'session was $peak A — compare that with the amp rating printed on '
          'your charger. Matching means the charger is the limit; well below '
          'means the BMS is capping it and a bigger charger buys nothing.';
    }
    return 'Holding $peak A. Compare with the amp rating on your charger '
        'label: equal means the charger is the bottleneck, clearly below '
        'means the BMS is throttling and a larger charger would not help.';
  }
}

class _ChargeRow extends StatelessWidget {
  const _ChargeRow(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Text(label,
                style: const TextStyle(
                    fontSize: 13, color: AppColors.textDim)),
            const Spacer(),
            Text(value,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.text,
                )),
          ],
        ),
      );
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Mini stat card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _MiniStat extends StatelessWidget {
  const _MiniStat({
    required this.icon,
    required this.label,
    required this.value,
    required this.ok,
  });
  final IconData icon;
  final String label;
  final String value;
  final bool ok;

  @override
  Widget build(BuildContext context) {
    final accent = ok ? AppColors.primary : AppColors.warning;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: accent),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: AppColors.text,
                      )),
                  Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textDim,
                        letterSpacing: 0.5,
                      )),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
