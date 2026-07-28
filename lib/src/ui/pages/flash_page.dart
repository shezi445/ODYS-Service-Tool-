import 'package:flutter/material.dart';

import '../../ble/odys_ble_client.dart';
import '../../models.dart';
import '../../protocol/firmware_tools.dart';
import '../brand.dart';
import '../odys_theme.dart';

class FlashPage extends StatelessWidget {
  const FlashPage({
    super.key,
    required this.client,
    required this.speed,
    required this.motorStart,
    required this.prepared,
    required this.preparationError,
    required this.stationaryConfirmed,
    required this.experimentalRiskAccepted,
    required this.flashing,
    required this.progress,
    required this.phoneBatteryPercent,
    required this.preflightOk,
    required this.preflightReason,
    required this.attempt,
    required this.onSpeedChanged,
    required this.onMotorStartChanged,
    required this.onStationaryChanged,
    required this.onExperimentalChanged,
    required this.onFlash,
    required this.onRetryFlash,
    required this.onRestore,
    required this.onCancelFlash,
  });

  final OdysBleClient client;
  final SpeedProfile speed;
  final MotorStartProfile motorStart;
  final FirmwareImage? prepared;
  final String? preparationError;
  final bool stationaryConfirmed;
  final bool experimentalRiskAccepted;
  final bool flashing;
  final DfuProgress progress;
  final int? phoneBatteryPercent;
  final bool preflightOk;
  final String preflightReason;
  final int attempt;
  final ValueChanged<SpeedProfile?> onSpeedChanged;
  final ValueChanged<MotorStartProfile?> onMotorStartChanged;
  final ValueChanged<bool?> onStationaryChanged;
  final ValueChanged<bool?> onExperimentalChanged;
  final VoidCallback onFlash;
  final VoidCallback onRetryFlash;
  final VoidCallback onRestore;
  final VoidCallback onCancelFlash;

  bool get _connected => client.phase == ConnectionPhase.connected;

  @override
  Widget build(BuildContext context) {
    final t = client.telemetry;
    final compatibility =
        FirmwareTools.compatibilityFor(client.versions, profile: speed);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // ── Header ──
        const PageHeader(title: 'Firmware'),

        // ── Profile section ──
        _Section(
          title: 'PROFILE',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DropdownButtonFormField<SpeedProfile>(
                initialValue: speed,
                decoration: const InputDecoration(labelText: 'Speed limit'),
                dropdownColor: AppColors.surfaceHi,
                items: SpeedProfile.values
                    .map((p) =>
                        DropdownMenuItem(value: p, child: Text(p.label)))
                    .toList(),
                onChanged: flashing ? null : onSpeedChanged,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<MotorStartProfile>(
                initialValue: motorStart,
                decoration:
                    const InputDecoration(labelText: 'Motor-start profile'),
                dropdownColor: AppColors.surfaceHi,
                items: MotorStartProfile.values
                    .map((p) =>
                        DropdownMenuItem(value: p, child: Text(p.label)))
                    .toList(),
                onChanged: flashing ||
                        speed == SpeedProfile.stock ||
                        speed.experimental
                    ? null
                    : onMotorStartChanged,
              ),
              const SizedBox(height: 14),
              if (preparationError != null)
                _ErrorText(preparationError!)
              else if (prepared != null)
                _FirmwareId(image: prepared!),
              if (speed.experimental) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.dangerDim,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: AppColors.danger.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(Icons.warning_rounded,
                          color: AppColors.danger, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '40 km/h is experimental. Speed, thermal load, '
                          'braking and stability are unvalidated. '
                          'Private property only.',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.text.withValues(alpha: 0.85),
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 8),

        // ── Pre-flight checks ──
        _Section(
          title: 'PRE-FLIGHT',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Check(
                ok: _connected,
                label: _connected
                    ? 'Scooter connected'
                    : 'Scooter not connected',
              ),
              _Check(
                ok: compatibility.allowed,
                label: compatibility.reason,
              ),
              _Check(
                ok: t.hasFreshBattery && (t.batteryPercent ?? 0) >= 30,
                label: t.batteryPercent == null
                    ? 'Waiting for battery status'
                    : 'Scooter battery ${t.batteryPercent}%'
                        '${(t.batteryPercent ?? 0) < 30 ? " (min 30%)" : ""}',
              ),
              _Check(
                ok: phoneBatteryPercent != null &&
                    phoneBatteryPercent! >= 30,
                label: phoneBatteryPercent == null
                    ? 'Checking phone battery'
                    : 'Phone battery $phoneBatteryPercent%'
                        '${phoneBatteryPercent! < 30 ? " (min 30%)" : ""}',
              ),
              _Check(
                ok: client.rssi != null && client.rssi! >= -85,
                label: client.rssi == null
                    ? 'Waiting for signal reading'
                    : 'Signal ${client.rssi} dBm'
                        '${client.rssi! < -85 ? " (min -85)" : ""}',
              ),
              _Check(
                ok: t.isCharging == false,
                label: t.isCharging == null
                    ? 'Checking charger state'
                    : t.isCharging!
                        ? 'Unplug charger before flashing'
                        : 'Charger disconnected',
              ),
              _Check(
                ok: t.batteryTemperature != null &&
                    t.batteryTemperature! >= 0 &&
                    t.batteryTemperature! <= 50,
                label: t.batteryTemperature == null
                    ? 'Waiting for temperature'
                    : 'Temperature '
                        '${t.batteryTemperature!.toStringAsFixed(0)}°C',
              ),
              _Check(
                ok: client.stationaryLongEnough,
                label: client.stationaryLongEnough
                    ? 'Stationary interlock ready'
                    : 'Waiting for 0 km/h for 5 seconds',
              ),

              const SizedBox(height: 8),
              const Divider(color: AppColors.border, height: 1),
              const SizedBox(height: 4),

              // ── Confirmations ──
              CheckboxListTile(
                value: stationaryConfirmed,
                onChanged: _connected &&
                        client.stationaryLongEnough &&
                        !flashing
                    ? onStationaryChanged
                    : null,
                title: const Text('Scooter is parked and off throttle',
                    style: TextStyle(fontSize: 14)),
                dense: true,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                visualDensity: VisualDensity.compact,
              ),
              if (speed.experimental)
                CheckboxListTile(
                  value: experimentalRiskAccepted,
                  onChanged:
                      _connected && !flashing ? onExperimentalChanged : null,
                  title: const Text(
                      '40 km/h is experimental and not for public roads',
                      style: TextStyle(fontSize: 14)),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // ── Flash progress ──
        if (flashing || progress.done || progress.failed) ...[
          Card(
            color: progress.failed ? AppColors.dangerDim : AppColors.surface,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          progress.stage,
                          style: const TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: AppColors.text,
                          ),
                        ),
                      ),
                      if (attempt > 1)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceHi,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text('Attempt $attempt',
                              style: const TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textDim,
                              )),
                        ),
                    ],
                  ),
                  if (progress.detail.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(progress.detail,
                        style: const TextStyle(
                            fontSize: 13, color: AppColors.textDim)),
                  ],
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: LinearProgressIndicator(
                      value: progress.failed ? null : progress.fraction,
                      minHeight: 8,
                      backgroundColor: AppColors.border,
                      color: progress.failed
                          ? AppColors.danger
                          : progress.done
                              ? AppColors.primary
                              : AppColors.teal,
                    ),
                  ),
                  if (progress.fraction > 0) ...[
                    const SizedBox(height: 6),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        '${(progress.fraction * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textDim,
                        ),
                      ),
                    ),
                  ],

                  // ── Retry after failure ──
                  if (progress.failed && !flashing) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'The transfer stopped before the controller confirmed '
                      'the image. Run Recovery in Tools if the scooter is '
                      'unresponsive, otherwise retry with the same image.',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppColors.textDim,
                        height: 1.4,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: prepared != null && preflightOk
                                ? onRetryFlash
                                : null,
                            icon: const Icon(Icons.refresh_rounded, size: 18),
                            label: const Text('Retry flash'),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: onRestore,
                            icon: const Icon(Icons.restore_rounded, size: 18),
                            label: const Text('Restore'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
        ],

        // ── Flash button ──
        SizedBox(
          width: double.infinity,
          height: 52,
          child: FilledButton.icon(
            onPressed:
                !flashing && prepared != null && preflightOk ? onFlash : null,
            icon: Icon(flashing
                ? Icons.hourglass_top_rounded
                : Icons.system_update_alt_rounded),
            label: Text(
              flashing ? 'FLASHING — KEEP APP OPEN' : 'Flash BLDC',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
            ),
          ),
        ),

        const SizedBox(height: 8),

        // ── Cancel / Restore ──
        if (flashing)
          TextButton.icon(
            onPressed: onCancelFlash,
            icon: const Icon(Icons.stop_circle_outlined,
                color: AppColors.danger),
            label: const Text('Stop safely before next packet',
                style: TextStyle(color: AppColors.danger)),
          ),

        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: flashing ? null : onRestore,
            icon: const Icon(Icons.restore_rounded),
            label: const Text('Restore original firmware'),
          ),
        ),

        // ── Preflight status ──
        if (!flashing && !preflightOk)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              preflightReason,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.textDim),
            ),
          ),
      ],
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Section card
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textDim,
                    letterSpacing: 1.2,
                  )),
              const SizedBox(height: 12),
              child,
            ],
          ),
        ),
      );
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Safety check row
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _Check extends StatelessWidget {
  const _Check({required this.ok, required this.label});
  final bool ok;
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          children: [
            Icon(
              ok
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 20,
              color: ok ? AppColors.primary : AppColors.textDim,
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Text(label,
                    style: TextStyle(
                      fontSize: 14,
                      color: ok ? AppColors.text : AppColors.textDim,
                    ))),
          ],
        ),
      );
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Firmware identity (compact)
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _FirmwareId extends StatelessWidget {
  const _FirmwareId({required this.image});
  final FirmwareImage image;

  @override
  Widget build(BuildContext context) {
    String hex(int v) => v.toRadixString(16).padLeft(4, '0').toUpperCase();
    final isVerified = image.verifiedReference;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isVerified
              ? AppColors.primary.withValues(alpha: 0.25)
              : AppColors.border,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isVerified
                    ? Icons.verified_rounded
                    : Icons.build_circle_outlined,
                size: 16,
                color: isVerified ? AppColors.primary : AppColors.textDim,
              ),
              const SizedBox(width: 6),
              Text(
                isVerified ? 'Verified image' : 'Derived from stock baseline',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isVerified ? AppColors.primary : AppColors.textDim,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            'SHA-256 ${image.sha256}\n'
            'CRC ${hex(image.innerCrc)} · ${hex(image.outerCrc)}',
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 11,
              color: AppColors.textDim,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Error text
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _ErrorText extends StatelessWidget {
  const _ErrorText(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(fontSize: 13, color: AppColors.danger),
      );
}
