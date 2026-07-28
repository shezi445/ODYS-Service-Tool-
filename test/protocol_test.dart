import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:odys_service_tool/src/dfu/dfu_engine.dart';
import 'package:odys_service_tool/src/ble/odys_ble_client.dart';
import 'package:odys_service_tool/src/models.dart';
import 'package:odys_service_tool/src/protocol/firmware_tools.dart';
import 'package:odys_service_tool/src/protocol/odys_protocol.dart';

void main() {
  test('read command has ODYS checksum and terminator', () {
    expect(
      OdysProtocol.readCommand(0x73),
      Uint8List.fromList([0x55, 0xaa, 0x00, 0x73, 0x72, 0xfe, 0xfd]),
    );
  });

  test('cruise enable frame is exact', () {
    expect(
      OdysProtocol.writeByte(0x52, 1),
      Uint8List.fromList(
        [0x55, 0xaa, 0x00, 0x52, 0x01, 0x01, 0x53, 0xfe, 0xfd],
      ),
    );
  });

  test('authentication frame includes exact ODYS account user ID', () {
    expect(
      DfuEngine.initialAuthentication(userId: 0x01020304),
      Uint8List.fromList([
        0x55,
        0xaa,
        0x00,
        0x30,
        0x08,
        0x00,
        0x00,
        0x88,
        0x00,
        0x01,
        0x02,
        0x03,
        0x04,
        0xc9,
        0xfe,
        0xfd,
      ]),
    );
  });

  test('authentication supports all five official key indices', () {
    expect(DfuEngine.authenticationKeys.length, 5);
    for (var index = 0; index < DfuEngine.authenticationKeys.length; index++) {
      expect(DfuEngine.authenticationKeys[index].length, 16);
      expect(DfuEngine.initialAuthentication(keyIndex: index)[5], index);
    }
    expect(
      () => DfuEngine.initialAuthentication(keyIndex: 5),
      throwsRangeError,
    );
  });

  test('zero and non-zero user IDs produce different authentication frames',
      () {
    expect(
      DfuEngine.initialAuthentication(userId: 0),
      isNot(DfuEngine.initialAuthentication(userId: 123456)),
    );
  });

  test('properly framed controller reply accepts controller checksum', () {
    final frame = OdysProtocol.parseFrame(
      [0x55, 0xaa, 0x00, 0x30, 0x01, 0x00, 0x5a, 0xfe, 0xfd],
    );
    expect(frame, isNotNull);
    expect(frame!.command, 0x30);
    expect(frame.error, 0);
    expect(frame.payload, isEmpty);
  });

  test('CRC-16/XMODEM canonical vector', () {
    expect(
      FirmwareTools.crc16Xmodem('123456789'.codeUnits),
      0x31c3,
    );
  });

  test('ODYS XMODEM sequence skips zero like the official updater', () {
    expect(DfuEngine.sequenceForBlockIndex(0), 1);
    expect(DfuEngine.sequenceForBlockIndex(253), 254);
    expect(DfuEngine.sequenceForBlockIndex(254), 255);
    expect(DfuEngine.sequenceForBlockIndex(255), 1);
    expect(DfuEngine.sequenceForBlockIndex(256), 2);
    expect(
      () => DfuEngine.sequenceForBlockIndex(-1),
      throwsRangeError,
    );
  });

  test('speed profiles use confirmed raw scale', () {
    expect(SpeedProfile.stock.raw, 476);
    expect(SpeedProfile.limit25.raw, 540);
    expect(SpeedProfile.limit30.raw, 648);
    expect(SpeedProfile.limit32.raw, 692);
    expect(SpeedProfile.experimental40.raw, 864);
  });

  test('BLE UUID matching accepts short and full forms', () {
    expect(
      OdysBleClient.uuidTextMatches(
        'B002',
        OdysProtocol.writeUuid,
      ),
      true,
    );
    expect(
      OdysBleClient.uuidTextMatches(
        '{0000B003-0000-1000-8000-00805F9B34FB}',
        OdysProtocol.notifyUuid,
      ),
      true,
    );
  });

  test('Android connection establishment status 62 is recognized', () {
    expect(
      OdysBleClient.isConnectionEstablishmentFailure(
        'FlutterBluePlusException | connect | '
        'android-code: 62 | CONNECTION_FAILED_ESTABLISHMENT',
      ),
      true,
    );
    expect(
      OdysBleClient.isConnectionEstablishmentFailure(
        'StateError: service not found',
      ),
      false,
    );
  });

  test('firmware response maps meter, BLDC, BMS versions', () {
    final payload = Uint8List.fromList([
      0,
      0,
      0,
      6,
      0,
      0,
      0,
      3,
      1,
      0,
      0,
      3,
    ]);
    final versions = OdysProtocol.firmwareFrom(
      OdysFrame(command: 0x73, error: 0, payload: payload),
    );
    expect(versions?.meter, '0.0.0.6');
    expect(versions?.bldc, '0.0.0.3');
    expect(versions?.bms, '1.0.0.3');
  });

  test('firmware response decodes ASCII version components', () {
    final payload = Uint8List.fromList([
      0x30,
      0x30,
      0x30,
      0x36,
      0x30,
      0x30,
      0x30,
      0x33,
      0x31,
      0x30,
      0x30,
      0x33,
    ]);
    final versions = OdysProtocol.firmwareFrom(
      OdysFrame(command: 0x73, error: 0, payload: payload),
    );
    expect(versions?.meter, '0.0.0.6');
    expect(versions?.bldc, '0.0.0.3');
    expect(versions?.bms, '1.0.0.3');
  });

  test('battery response maps voltage, current and temperature', () {
    final payload = Uint8List(15);
    payload[1] = 81;
    payload.setRange(2, 6, [0xc0, 0xdb, 0x00, 0x00]); // 56,256 mV
    payload.setRange(6, 10, [0x18, 0xfc, 0xff, 0xff]); // -1000 mA
    payload[11] = 29;
    final value = OdysProtocol.batteryFrom(
      OdysFrame(command: 0x72, error: 0, payload: payload),
      const Telemetry(),
    );
    expect(value?.batteryPercent, 81);
    expect(value?.voltage, 56.256);
    expect(value?.current, -1);
    expect(value?.batteryTemperature, 29);
    expect(value?.isCharging, false);
    expect(value?.hasFreshBattery, true);
  });

  test('every selectable firmware profile has valid dual CRCs', () {
    final stock = Uint8List.fromList(
      File('assets/firmware/bldc_stock_de.bin').readAsBytesSync(),
    );
    final verified = Uint8List.fromList(
      File(
        'assets/firmware/BLDC_DE_32kmh_Kick1_Normal2_DualCRC.bin',
      ).readAsBytesSync(),
    );
    final experimental40 = Uint8List.fromList(
      File(
        'assets/firmware/'
        'BLDC_DE_40kmh_EXPERIMENTAL_Kick1_Normal2_DualCRC.bin',
      ).readAsBytesSync(),
    );
    final experimental40Kick2 = Uint8List.fromList(
      File(
        'assets/firmware/BLDC_DE_40kmh_Kick2kmh_Normal2_DualCRC.bin',
      ).readAsBytesSync(),
    );
    for (final speed in SpeedProfile.values) {
      for (final start in MotorStartProfile.values) {
        if (speed == SpeedProfile.stock && start != MotorStartProfile.stock) {
          continue;
        }
        if (speed == SpeedProfile.experimental40 &&
            start != MotorStartProfile.kick1Normal2) {
          continue;
        }
        // The Kick-2 image is a fixed binary with its own motor-start
        // behaviour baked in, so it is only built once rather than once per
        // selectable start profile.
        if (speed == SpeedProfile.experimental40Kick2 &&
            start != MotorStartProfile.stock) {
          continue;
        }
        final image = FirmwareTools.buildProfile(
          stock: stock,
          verified32: verified,
          experimental40: experimental40,
          experimental40Kick2: experimental40Kick2,
          speed: speed,
          motorStart: start,
        );
        expect(FirmwareTools.validate(image.bytes).ok, true);
        expect(
          image.bytes[FirmwareTools.speedOffset] |
              (image.bytes[FirmwareTools.speedOffset + 1] << 8),
          speed.raw,
        );
      }
    }
  });

  test('unknown controller families are blocked', () {
    expect(
      FirmwareTools.compatibilityFor(
        const FirmwareVersions(bldc: '1.2.3.4'),
      ).allowed,
      false,
    );
    expect(
      FirmwareTools.compatibilityFor(
        const FirmwareVersions(bldc: '0.0.0.3'),
      ).allowed,
      true,
    );
    expect(
      FirmwareTools.compatibilityFor(
        const FirmwareVersions(bldc: '0.0.0.4'),
        profile: SpeedProfile.experimental40,
      ).allowed,
      false,
    );
    expect(
      FirmwareTools.compatibilityFor(
        const FirmwareVersions(bldc: '0.0.0.3'),
        profile: SpeedProfile.experimental40,
      ).allowed,
      true,
    );
  });
}
