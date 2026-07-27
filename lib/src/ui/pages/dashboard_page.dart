import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../ble/odys_ble_client.dart';
import '../../models.dart';
import '../odys_theme.dart';

class DashboardPage extends StatelessWidget {
  const DashboardPage({
    super.key,
    required this.client,
    required this.phoneBatteryPercent,
    required this.flashing,
    required this.accountIdController,
    required this.onConnect,
    required this.onDisconnect,
    required this.onCruiseChanged,
  });

  final OdysBleClient client;
  final int? phoneBatteryPercent;
  final bool flashing;
  final TextEditingController accountIdController;
  final VoidCallback onConnect;
  final VoidCallback onDisconnect;
  final Future<void> Function(bool) onCruiseChanged;

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
        Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            children: [
              const Text('Dashboard',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: AppColors.text,
                    letterSpacing: -0.5,
                  )),
              const Spacer(),
              _StatusChip(phase: client.phase),
            ],
          ),
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

        // ── Cruise control ──
        if (_connected) ...[
          const SizedBox(height: 8),
          _buildCruiseCard(context),
        ],
      ],
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
    return Card(
      child: SwitchListTile(
        value: client.cruiseEnabled,
        onChanged: _connected && !flashing
            ? (value) => onCruiseChanged(value)
            : null,
        title: const Text('Cruise control',
            style: TextStyle(fontWeight: FontWeight.w600)),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
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
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
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
  });

  final double speed;
  final bool connected;
  final int? battery;
  final double? voltage;
  final double? temperature;

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
        ..color = color.withOpacity(0.20)
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
                color: accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, size: 18, color: accent),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
            ),
          ],
        ),
      ),
    );
  }
}
