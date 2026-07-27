# Changelog

## 1.0.1+111 — 2026-07-26

- Fixed DFU failure after transmitted block 255 by matching the official ODYS
  updater's controller-specific sequence numbering: `1…255,1,2…`.
- Added regression coverage for logical blocks 254–257.
- DFU logs now distinguish logical block numbers from wrapped wire sequences.
- Firmware assets and their signed catalogue remain unchanged.

## 1.0.0+110 — 2026-07-26

- Preserved the supplied build-101 BLE authentication path.
- Added reproducible experimental 40 km/h / Kick1-Normal2 firmware.
- Added exact BLDC `0.0.0.3` gating and explicit experimental consent.
- Added Ed25519-signed firmware catalogue and runtime asset verification.
- Added one-action original-firmware restore selection.
- Added complete BLE TX/RX packet diagnostics.
- Corrected post-flash wording to distinguish `dfu_ok` from content readback.
- Added production release signing configuration, exact direct dependency
  versions, release checksums and symbol artifacts.
- Added attached-APK, security and physical interruption audit documents.
