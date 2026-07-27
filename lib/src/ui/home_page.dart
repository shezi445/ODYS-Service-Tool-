import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../ble/odys_ble_client.dart';
import '../dfu/dfu_engine.dart';
import '../models.dart';
import '../protocol/firmware_tools.dart';
import '../protocol/firmware_catalog.dart';
import '../session_log.dart';
import 'odys_theme.dart';
import 'pages/dashboard_page.dart';
import 'pages/flash_page.dart';
import 'pages/tools_page.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.log});
  final SessionLog log;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  late final OdysBleClient client;
  late final DfuEngine dfu;
  StreamSubscription<DfuProgress>? _dfuSubscription;
  Timer? _clock;
  Timer? _phoneBatteryTimer;
  final Battery _phoneBattery = Battery();
  final TextEditingController _accountIdController = TextEditingController();
  final SharedPreferencesAsync _preferences = SharedPreferencesAsync();
  int? phoneBatteryPercent;

  SpeedProfile speed = SpeedProfile.limit32;
  MotorStartProfile motorStart = MotorStartProfile.kick1Normal2;
  DfuProgress progress = const DfuProgress(stage: 'Ready');
  bool stationaryConfirmed = false;
  bool experimentalRiskAccepted = false;
  bool flashing = false;
  FirmwareImage? prepared;
  String? preparationError;
  int _prepareGeneration = 0;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    client = OdysBleClient(widget.log)..addListener(_changed);
    dfu = DfuEngine(
      write: client.writeRaw,
      notifications: client.rawNotifications,
      log: widget.log,
    );
    _dfuSubscription = dfu.progress.listen((event) {
      if (mounted) setState(() => progress = event);
    });
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && client.connected) setState(() {});
    });
    _refreshPhoneBattery();
    _loadSavedAccountId();
    _phoneBatteryTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => _refreshPhoneBattery(),
    );
    _prepareFirmware();
  }

  Future<void> _loadSavedAccountId() async {
    final saved = await _preferences.getString('odys_account_id');
    if (mounted && saved != null) _accountIdController.text = saved;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (flashing && state != AppLifecycleState.resumed) {
      widget.log
          .add('App left foreground during DFU; safe cancellation requested');
      dfu.requestCancel();
    }
  }

  Future<void> _refreshPhoneBattery() async {
    try {
      final level = await _phoneBattery.batteryLevel;
      if (mounted) setState(() => phoneBatteryPercent = level);
    } catch (error) {
      widget.log.add('Phone battery query failed: $error');
    }
  }

  void _changed() {
    if (mounted) {
      setState(() {
        if (!client.stationaryLongEnough) stationaryConfirmed = false;
      });
    }
  }

  Future<void> _prepareFirmware() async {
    final generation = ++_prepareGeneration;
    try {
      await FirmwareCatalog.verify();
      final stock = await rootBundle.load('assets/firmware/bldc_stock_de.bin');
      final verified = await rootBundle.load(
        'assets/firmware/BLDC_DE_32kmh_Kick1_Normal2_DualCRC.bin',
      );
      final experimental40 = await rootBundle.load(
        'assets/firmware/'
        'BLDC_DE_40kmh_EXPERIMENTAL_Kick1_Normal2_DualCRC.bin',
      );
      final experimental40Kick2 = await rootBundle.load(
        'assets/firmware/'
        'BLDC_DE_40kmh_Kick2kmh_Normal2_DualCRC.bin',
      );
      final image = FirmwareTools.buildProfile(
        stock: stock.buffer.asUint8List(),
        verified32: verified.buffer.asUint8List(),
        experimental40: experimental40.buffer.asUint8List(),
        experimental40Kick2: experimental40Kick2.buffer.asUint8List(),
        speed: speed,
        motorStart:
            speed == SpeedProfile.stock ? MotorStartProfile.stock : motorStart,
      );
      if (mounted && generation == _prepareGeneration) {
        setState(() {
          prepared = image;
          preparationError = null;
        });
      }
    } catch (error) {
      if (mounted && generation == _prepareGeneration) {
        setState(() {
          prepared = null;
          preparationError = '$error';
        });
      }
    }
  }

  Future<void> _scanAndConnect() async {
    final accountText = _accountIdController.text.trim();
    final accountId = RegExp(r'^\d+$').hasMatch(accountText)
        ? int.tryParse(accountText)
        : null;
    if (accountId == null || accountId <= 0 || accountId > 0xffffffff) {
      _message('Enter a positive 32-bit numeric ODYS account ID first.');
      return;
    }
    try {
      await _preferences.setString('odys_account_id', accountText);
      await client.scan();
      if (!mounted) return;
      final result = await showModalBottomSheet<ScanResult>(
        context: context,
        showDragHandle: true,
        backgroundColor: AppColors.surface,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        builder: (context) => _Scanner(results: client.scanResults),
      );
      if (result != null) await client.connect(result, accountId: accountId);
    } catch (error) {
      _message('Bluetooth error: $error');
    }
  }

  Future<void> _flash() async {
    final image = prepared;
    if (image == null) return;
    final preflight = _preflight();
    if (!preflight.$1) {
      _message(preflight.$2);
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text('Flash BLDC controller?',
            style: TextStyle(fontWeight: FontWeight.w700)),
        content: Text(
          '${image.speed.label}\n${image.motorStart.label}\n\n'
          'Keep the scooter powered, stationary, close to the phone, and do '
          'not leave the app until controller verification completes.',
          style: const TextStyle(height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Flash'),
          ),
        ],
      ),
    );
    if (accepted != true) return;

    setState(() {
      flashing = true;
      _tabIndex = 1; // Switch to Flash tab
    });
    try {
      client.beginFlash();
      await WakelockPlus.enable();
      widget.log.add(
        'PRE-FLASH profile=${image.speed.name} sha256=${image.sha256} '
        'inner=${image.innerCrc.toRadixString(16)} '
        'outer=${image.outerCrc.toRadixString(16)}',
      );
      await dfu.flash(image.bytes);
      widget.log.add(
        'POST-FLASH controller returned dfu_ok for sha256=${image.sha256}; '
        'this controller does not expose firmware-content readback',
      );
      _message(
        'Controller accepted the image and returned dfu_ok. '
        'Reconnect and verify telemetry before riding.',
      );
    } catch (error) {
      _message('Flash stopped: $error. Open Recovery before trying again.');
    } finally {
      try {
        await WakelockPlus.disable();
      } catch (error) {
        widget.log.add('Wakelock release warning: $error');
      }
      client.finishFlash();
      if (mounted) setState(() => flashing = false);
    }
  }

  (bool, String) _preflight() {
    final t = client.telemetry;
    final compatibility =
        FirmwareTools.compatibilityFor(client.versions, profile: speed);
    if (client.phase != ConnectionPhase.connected) {
      return (false, 'Wait until connection and authentication are complete.');
    }
    if (!compatibility.allowed) return (false, compatibility.reason);
    if (!t.hasTrustedSpeed || !client.stationaryLongEnough) {
      return (
        false,
        'Fresh live-speed packets must show 0 km/h for 5 seconds.'
      );
    }
    if (!t.hasFreshBattery || t.batteryPercent == null) {
      return (false, 'Wait for a fresh battery status packet.');
    }
    if (t.batteryPercent! < 30) {
      return (false, 'Scooter battery must be at least 30%.');
    }
    if (phoneBatteryPercent == null || phoneBatteryPercent! < 30) {
      return (false, 'Phone battery must be at least 30%.');
    }
    if (client.rssi == null || client.rssi! < -85) {
      return (
        false,
        'Move the phone closer; BLE signal must be at least -85 dBm.'
      );
    }
    if (t.isCharging == true) {
      return (false, 'Unplug the scooter charger before flashing.');
    }
    final temperature = t.batteryTemperature;
    if (temperature == null || temperature < 0 || temperature > 50) {
      return (false, 'Battery temperature must be between 0°C and 50°C.');
    }
    if ((t.errorCode ?? 0) != 0) {
      return (false, 'Clear controller error ${t.errorCode} before flashing.');
    }
    if (!stationaryConfirmed) {
      return (false, 'Confirm that the scooter is parked and off throttle.');
    }
    if (speed.experimental && !experimentalRiskAccepted) {
      return (
        false,
        'Acknowledge that the 40 km/h profile is experimental and unvalidated.',
      );
    }
    return (true, 'All pre-flight checks passed.');
  }

  Future<void> _prepareOriginalRestore() async {
    setState(() {
      speed = SpeedProfile.stock;
      motorStart = MotorStartProfile.stock;
      stationaryConfirmed = false;
      experimentalRiskAccepted = false;
    });
    await _prepareFirmware();
    _message(
        'Original DE firmware selected. Complete safety checks, then Flash.');
  }

  void _handleSpeedChange(SpeedProfile? value) {
    if (value == null) return;
    setState(() {
      speed = value;
      if (value == SpeedProfile.stock) {
        motorStart = MotorStartProfile.stock;
      } else if (value.experimental) {
        motorStart = MotorStartProfile.kick1Normal2;
      }
      stationaryConfirmed = false;
      experimentalRiskAccepted = false;
    });
    _prepareFirmware();
  }

  void _handleMotorStartChange(MotorStartProfile? value) {
    if (value == null) return;
    setState(() => motorStart = value);
    _prepareFirmware();
  }

  Future<void> _handleCruise(bool value) async {
    try {
      await client.setCruise(value);
    } catch (error) {
      _message('Cruise command failed: $error');
    }
  }

  Future<void> _shareLog() async {
    final file = await widget.log.export();
    await Share.shareXFiles(
      [XFile(file.path)],
      subject: 'ODYS BLE/DFU diagnostic log',
    );
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        backgroundColor: AppColors.surfaceHi,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final preflight = _preflight();

    return Scaffold(
      body: SafeArea(
        child: IndexedStack(
          index: _tabIndex,
          children: [
            DashboardPage(
              client: client,
              phoneBatteryPercent: phoneBatteryPercent,
              flashing: flashing,
              accountIdController: _accountIdController,
              onConnect: _scanAndConnect,
              onDisconnect: client.disconnect,
              onCruiseChanged: _handleCruise,
            ),
            FlashPage(
              client: client,
              speed: speed,
              motorStart: motorStart,
              prepared: prepared,
              preparationError: preparationError,
              stationaryConfirmed: stationaryConfirmed,
              experimentalRiskAccepted: experimentalRiskAccepted,
              flashing: flashing,
              progress: progress,
              phoneBatteryPercent: phoneBatteryPercent,
              preflightOk: preflight.$1,
              preflightReason: preflight.$2,
              onSpeedChanged: _handleSpeedChange,
              onMotorStartChanged: _handleMotorStartChange,
              onStationaryChanged: (v) =>
                  setState(() => stationaryConfirmed = v ?? false),
              onExperimentalChanged: (v) =>
                  setState(() => experimentalRiskAccepted = v ?? false),
              onFlash: _flash,
              onRestore: _prepareOriginalRestore,
              onCancelFlash: dfu.requestCancel,
            ),
            ToolsPage(
              client: client,
              flashing: flashing,
              onShareLog: _shareLog,
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        height: 68,
        selectedIndex: _tabIndex,
        onDestinationSelected: (i) => setState(() => _tabIndex = i),
        surfaceTintColor: Colors.transparent,
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.speed_outlined),
            selectedIcon: Icon(Icons.speed),
            label: 'Dashboard',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: flashing,
              backgroundColor: AppColors.warning,
              child: const Icon(Icons.system_update_alt_outlined),
            ),
            selectedIcon: Badge(
              isLabelVisible: flashing,
              backgroundColor: AppColors.warning,
              child: const Icon(Icons.system_update_alt),
            ),
            label: 'Flash',
          ),
          const NavigationDestination(
            icon: Icon(Icons.build_outlined),
            selectedIcon: Icon(Icons.build),
            label: 'Tools',
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _accountIdController.dispose();
    _clock?.cancel();
    _phoneBatteryTimer?.cancel();
    _dfuSubscription?.cancel();
    client
      ..removeListener(_changed)
      ..dispose();
    super.dispose();
  }
}

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
//  BLE Scanner bottom sheet
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

class _Scanner extends StatelessWidget {
  const _Scanner({required this.results});
  final List<ScanResult> results;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Text('Nearby devices',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: AppColors.text,
                  )),
          const SizedBox(height: 12),
          if (results.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Column(
                children: [
                  Icon(Icons.bluetooth_searching_rounded,
                      size: 40, color: AppColors.textDim),
                  const SizedBox(height: 8),
                  const Text('No devices found',
                      style: TextStyle(
                          fontWeight: FontWeight.w600,
                          color: AppColors.text)),
                  const Text('Power-cycle the scooter and scan again.',
                      style: TextStyle(
                          fontSize: 13, color: AppColors.textDim)),
                ],
              ),
            ),
          for (final result in results)
            Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: AppColors.primaryDim,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.electric_scooter_rounded,
                      size: 20, color: AppColors.primary),
                ),
                title: Text(
                  result.advertisementData.advName.isEmpty
                      ? 'Unnamed device'
                      : result.advertisementData.advName,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                subtitle: Text(
                    '${result.device.remoteId.str}  ${result.rssi} dBm',
                    style: const TextStyle(
                        fontSize: 12, color: AppColors.textDim)),
                trailing: const Icon(Icons.chevron_right_rounded,
                    color: AppColors.textDim),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
                onTap: () => Navigator.pop(context, result),
              ),
            ),
        ],
      ),
    );
  }
}
