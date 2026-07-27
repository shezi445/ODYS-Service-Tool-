# ODYS Service Tool 1.0.0 release checklist

## Automated release gate

- `flutter analyze` has no errors.
- `flutter test` passes.
- `node tool/verify_firmware.js` validates both embedded firmware assets,
  hashes, speed words, dual CRCs and all 11 motor-start locations.
- `node tool/source_audit.js` validates the safety/reliability invariants.
- `flutter build apk --release` produces an installable APK.

## Required physical test matrix

Run these once on the supported controller before calling the APK production
ready:

1. Clean install; scan, connect and authenticate without the original ODYS app.
2. Confirm meter, BLDC and BMS version strings.
3. Confirm speed follows the wheel and becomes stale within three seconds when
   reports stop.
4. Confirm Flash cannot unlock from the initial/default zero.
5. Confirm moving the wheel immediately resets the five-second interlock.
6. Confirm low battery, charger connected, unsafe temperature, controller
   error and unsupported BLDC version each block Flash.
7. Enable and disable cruise; verify both the write ACK and 0x70 read-back.
8. Export a log and verify timestamps, stage names and no secrets.
9. Flash the physically proven 32/Kick1/Normal2 image and require final
   `rsq dfu_ok`.
10. Reconnect after controller reboot and verify firmware versions/telemetry.
11. Disconnect BLE before DFU begins; verify automatic reconnect.
12. Do not intentionally disconnect during firmware transfer on the production
    scooter. Test that path only on recoverable bench hardware.

Record phone model, Android version, scooter BLDC version, result and exported
log for each run.

## Experimental 40 km/h interruption matrix

Do not test on public roads. Require BLDC `0.0.0.3`, then first confirm original
restore and the verified 32 km/h reference.

On recoverable bench hardware, interrupt Bluetooth once at each stage, preserve
scooter power, export the report, follow Recovery, and confirm either a normal
return or a safe block-1 retry of the identical image:

1. Before `dfu_start`
2. After `dfu_start`, before challenge
3. During challenge/authentication
4. Before XMODEM `C`
5. Blocks 1–254
6. Block 255 and the ODYS sequence reset to block 1 (zero is skipped)
7. Final transfer block
8. EOT before ACK
9. After ACK, before `rsq dfu_ok`
10. Immediately after `rsq dfu_ok` during controller reboot

Do not mark 40 km/h validated until displayed speed, GPS speed, voltage,
current, temperature, braking behaviour and controller errors have been
recorded under controlled private-property testing.
