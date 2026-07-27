# ODYS Service Tool 1.0.0 — Experimental 40

Offline Android-first Flutter client for the supplied ODYS controller. The same
source targets iOS, but iOS DFU must be tested on the physical scooter before
distribution.

This is a guarded experimental source release, not a production-certified
flasher. Automated checks and packaging cannot replace scooter, phone and
closed-course validation.

## Included

- BLE scan/connect and firmware version display
- Live speed, battery, pack voltage/current and battery temperature
- Cruise-control switch
- Original DE restoration / 25 / 30 / verified 32 km/h selection
- Separate 40 km/h experimental profile (raw 864), locked to BLDC revision
  `0.0.0.3` and Kick 1 / Normal 2 start thresholds
- Stock or Kick 1 / Normal 2 motor-start profiles
- Exact successful `BLDC_DE_32kmh_Kick1_Normal2_DualCRC.bin`
- SHA-256, image-size, inner-CRC and outer-CRC preflight validation
- Guarded BLDC XMODEM-CRC updater with retry and final `dfu_ok` verification
- Fresh-telemetry stationary interlock: at least three real speed samples and
  five continuous seconds at 0 km/h
- Battery ≥30%, battery temperature 0–50°C, charger-disconnected, controller
  error-free and compatible-BLDC-family gates
- Serialized BLE writes, fragmented-frame reassembly and automatic reconnect
- Cruise-control ACK plus read-back confirmation
- Android status-62 connection recovery with scanner-settle delay, single-flight
  connection control, clean GATT teardown, and 1.5/3/5-second retries
- Three-pass GATT discovery, Android cache refresh, short/full UUID matching,
  characteristic-property checks, and discovered-service diagnostics
- Account-bound ODYS normal-authentication state machine: `0x30` challenge,
  `0x31` encrypted response, accepted-encryption callback, repeated `0x30`,
  and final short `0x30` confirmation
- Fallback through all five official ODYS authentication keys with explicit
  challenge/rejection/confirmation diagnostics
- Controller-specific XMODEM 1…255,1,2 sequence wrapping (matching the
  official updater, which skips zero), cancellable transfer, 20-second
  block/EOT waits and final `dfu_ok` verification
- Downloadable timestamped diagnostic logs
- Complete BLE TX/RX packet capture in exported diagnostic reports
- Ed25519-signed firmware catalogue with runtime asset-hash checks
- One-action original-firmware selection; flashing still requires all safety
  interlocks and explicit confirmation

## 40 km/h status

The included 40 km/h image is reproducibly generated from the untouched stock
DE baseline. Its speed word is `864`; inner CRC is `AF79`; outer CRC is `E430`;
SHA-256 is:

```text
ec295b947e024adfb2a05ff4bc7d3cc5ef5c33f49f78ed11cbc6d258b7a44585
```

Only the binary transformation, catalogue signature, hashes and both controller
CRC layers have been validated. The scooter has **not** been physically tested
at 40 km/h. Stored speed does not guarantee attainable road speed. Thermal
load, braking distance, stability, battery current and controller durability
remain unknown. Use only on closed private property.

## Verification boundary

Before flashing, the app validates the signed catalogue, exact SHA-256, image
size and both CRC layers. After flashing, it requires and records the
controller's `rsq dfu_ok` response. This controller protocol does not expose a
safe full firmware-content readback, so the app does not claim byte-for-byte
post-flash verification.

## ODYS authentication

The normal BLE authentication path is intentionally preserved from build 101,
the supplied APK reported to connect successfully. The 40 km/h work does not
change its challenge parsing, key fallback, encryption response, connection
timing or GATT discovery. The service tool does not request an ODYS email,
password, bearer token or cookie.

`Stock DE` flashes the untouched official baseline: raw speed `476` (about
22 km/h), stock kick/normal thresholds and its original dual CRCs. Correct
speed words are 25=`540`, 30=`648`, and 32=`692`. The 25 and 30 profiles are
generated only from the hash-pinned official baseline, and both CRC layers are
recomputed and verified before Flash becomes available. They still require
physical validation. The 32/Kick1/Normal2 image is the physically successful
reference supplied with this project.

## Build

Install Flutter stable with Android Studio, then run:

```sh
flutter create --platforms=android,ios .
flutter pub get
flutter test
node tool/verify_firmware.js
node tool/source_audit.js
flutter build apk --release
```

If `flutter create` asks to replace files, keep this project's `lib/`,
`assets/`, `pubspec.yaml`, Android manifest and iOS `Info.plist`.

The generated Android APK is
`build/app/outputs/flutter-apk/app-release.apk`. For iOS, open
`ios/Runner.xcworkspace` in Xcode, select your signing team and test on a real
iPhone; BLE is not available in the iOS simulator.

On Windows, double-click `build_apk_windows.bat`. The included GitHub Actions
workflow performs scaffolding, analysis, tests, independent firmware
verification and a properly signed release build. Configure
`ODYS_KEYSTORE_B64`, `ODYS_STORE_PASSWORD`, `ODYS_KEY_ALIAS`, and
`ODYS_KEY_PASSWORD` as repository secrets. Release builds no longer use the
Android debug signing key.

## Safe test order

1. Test scan/connect and observe telemetry without flashing.
2. Test the cruise switch with the wheel stationary.
3. Export a log to confirm notifications and firmware versions.
4. Confirm the app identifies the BLDC as the compatible `0.0.0.x` family.
5. Flash only the already-proven 32 / Kick 1 / Normal 2 profile first.
6. Keep the scooter powered and phone close until `dfu_ok` appears.

Do not flash with the drive wheel moving, throttle pressed, charger attached,
low phone battery, or an unverified controller hardware revision.

## Release boundary

Automated checks cover protocol frames, telemetry parsing, all selectable
firmware profiles, SHA-256, both controller CRC layers, all 11 motor-start
patch locations, XMODEM block wrapping, source safety invariants, static
analysis and Android compilation in CI. Final release acceptance still requires
a real-device matrix: Android 12–16, reconnect during scan/telemetry, cruise
enable/disable/read-back, one successful reference flash, one intentional
disconnect before DFU, and post-flash firmware/telemetry refresh.

English, German and Urdu localization, deliberate BLE interruption at every
DFU stage, official-app telemetry comparison, and physical iPhone testing remain
release-validation work; they are not falsely marked complete in this package.
