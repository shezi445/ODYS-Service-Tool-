import 'package:flutter/material.dart';

import '../../ble/odys_ble_client.dart';
import '../../models.dart';
import '../brand.dart';
import '../odys_theme.dart';

class ToolsPage extends StatelessWidget {
  const ToolsPage({
    super.key,
    required this.client,
    required this.flashing,
    required this.onShareLog,
  });

  final OdysBleClient client;
  final bool flashing;
  final VoidCallback onShareLog;

  @override
  Widget build(BuildContext context) {
    final connected = client.phase == ConnectionPhase.connected ||
        client.phase == ConnectionPhase.flashing;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
      children: [
        // ── Header ──
        const PageHeader(title: 'Tools'),

        // ── Firmware versions ──
        _Section(
          title: 'FIRMWARE VERSIONS',
          child: Row(
            children: [
              Expanded(
                  child: _VersionTile('Meter', client.versions.meter)),
              Container(width: 1, height: 44, color: AppColors.border),
              Expanded(
                  child: _VersionTile('BLDC', client.versions.bldc)),
              Container(width: 1, height: 44, color: AppColors.border),
              Expanded(
                  child: _VersionTile('BMS', client.versions.bms)),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // ── Connection info ──
        _Section(
          title: 'CONNECTION',
          child: connected
              ? Column(
                  children: [
                    _InfoRow(
                        'Device',
                        client.device?.platformName.isNotEmpty == true
                            ? client.device!.platformName
                            : client.device?.remoteId.str ?? '—'),
                    _InfoRow('Phase', client.phase.name),
                    _InfoRow(
                        'Signal',
                        client.rssi == null
                            ? '—'
                            : '${client.rssi} dBm'),
                    _InfoRow('MTU',
                        client.device?.mtuNow.toString() ?? '—'),
                  ],
                )
              : const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('No scooter connected',
                      style: TextStyle(
                          color: AppColors.textDim, fontSize: 14)),
                ),
        ),

        const SizedBox(height: 8),

        // ── Diagnostics ──
        _Section(
          title: 'DIAGNOSTICS',
          child: _ActionTile(
            icon: Icons.description_outlined,
            iconColor: AppColors.primary,
            title: 'Export diagnostic log',
            subtitle: 'Share full BLE/DFU session log',
            onTap: onShareLog,
          ),
        ),

        const SizedBox(height: 8),

        // ── Recovery ──
        _Section(
          title: 'RECOVERY',
          child: _ActionTile(
            icon: Icons.health_and_safety_outlined,
            iconColor: AppColors.warning,
            title: 'Emergency recovery',
            subtitle: 'Step-by-step guide for failed updates',
            onTap: () => showDialog<void>(
              context: context,
              builder: (_) => const _RecoveryDialog(),
            ),
          ),
        ),

        // ── App version ──
        const SizedBox(height: 32),
        const Center(
          child: Text('ODYS Service Tool v1.0.1',
              style: TextStyle(
                fontSize: 12,
                color: AppColors.textDim,
                letterSpacing: 0.5,
              )),
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
//  Version tile
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _VersionTile extends StatelessWidget {
  const _VersionTile(this.label, this.value);
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Column(
        children: [
          Text(value,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                fontFamily: 'monospace',
                color: AppColors.text,
              )),
          const SizedBox(height: 4),
          Text(label,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textDim,
              )),
        ],
      );
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Info row
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Action tile
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: iconColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, size: 20, color: iconColor),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title,
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.text,
                        )),
                    Text(subtitle,
                        style: const TextStyle(
                          fontSize: 12,
                          color: AppColors.textDim,
                        )),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right_rounded,
                  color: AppColors.textDim, size: 20),
            ],
          ),
        ),
      );
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  Recovery dialog
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _RecoveryDialog extends StatelessWidget {
  const _RecoveryDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      title: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.warningDim,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.health_and_safety_rounded,
                size: 18, color: AppColors.warning),
          ),
          const SizedBox(width: 12),
          const Text('Emergency Recovery',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _recoveryStep('1', 'Do not ride or press the throttle.'),
            _recoveryStep(
              '2',
              'Keep the scooter powered for 30 seconds. A controller '
              'reboot or temporary Bluetooth disappearance after EOT '
              'can be normal.',
            ),
            _recoveryStep(
              '3',
              'If it does not return, switch the scooter off, wait '
              '15 seconds, switch it on, then Scan again.',
            ),
            _recoveryStep(
              '4',
              'If the dashboard shows its normal firmware version, the '
              'update did not commit. Reselect the same profile and '
              'retry from block 1.',
            ),
            _recoveryStep(
              '5',
              'If the controller remains in DFU mode, reconnect and '
              'retry the same validated image. Never change profile '
              'during recovery.',
            ),
            _recoveryStep(
              '6',
              'Export the log before closing the app. It records the '
              'final ACK, EOT, timeout, and controller response.',
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Understood'),
        ),
      ],
    );
  }

  static Widget _recoveryStep(String number, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 24,
              height: 24,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: AppColors.surfaceHi,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(number,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textDim,
                  )),
            ),
            const SizedBox(width: 10),
            Expanded(
                child: Text(text,
                    style: const TextStyle(
                      fontSize: 14,
                      color: AppColors.text,
                      height: 1.4,
                    ))),
          ],
        ),
      );
}
