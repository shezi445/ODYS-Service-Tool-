# Security and dependency audit

## Completed source checks

- No email, password, bearer token, cookie, release keystore or private
  catalogue key is present in the source package.
- Release signing no longer falls back to the Android debug key.
- The keystore and `key.properties` are excluded from source control.
- Firmware assets require an Ed25519-valid catalogue entry, matching SHA-256,
  exact image size, valid inner CRC and valid outer CRC.
- The experimental profile is additionally gated to BLDC `0.0.0.3`.
- BLE writes are serialized; overlapping connect and cruise operations are
  blocked.
- Flashing requires fresh speed and battery reports, stationary time, battery
  levels, safe temperature, charger removal, adequate RSSI and no controller
  error.
- Exported reports contain BLE protocol packets and may include the scooter
  address or controller identifiers. Users should review/redact reports before
  sharing them publicly.

## Dependency policy

Direct dependency versions are exact rather than open ranges. CI records the
resolved dependency tree with each release. A generated `pubspec.lock` must be
reviewed and committed after the first successful Flutter build.

## Unresolved release gates

- Run `flutter pub get`, inspect the generated lockfile, and perform an
  advisory/vulnerability scan in a network-enabled release environment.
- Run `flutter analyze` and all Dart tests with the pinned Flutter version.
- Validate Android 12–16 BLE permission and reconnect behaviour.
- Validate iOS entitlements, background behaviour and DFU on a physical iPhone.
- Protect the release keystore and firmware-catalogue private key separately,
  with rotation and revocation procedures.
- Add privacy controls if diagnostic reports will ever be uploaded
  automatically. This release exports locally only.
