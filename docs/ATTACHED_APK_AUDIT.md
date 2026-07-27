# Attached APK audit

Input: `app-release(1).apk`

- SHA-256:
  `00a8a371d043f6171a5bf496b0e524a3d8537ae424bf9a9215d0c297408e4940`
- Package: `com.odys.servicetool`
- Android version code: `101`
- Flutter AOT release containing ARM64, ARMv7 and x86_64 libraries
- Embedded original firmware SHA-256:
  `2640a3f4ff96642eb655d046238b4da7dd6c5f0195cf2424867b063dbe2cb5e5`
- Embedded 32 km/h firmware SHA-256:
  `77481c37205cae47d996e109bbeb62521e23fa3d1e190bff25092fd35c265874`

Version code 101 corresponds to the available v0.9.11 source lineage. This
release therefore preserves that build's normal BLE authentication sequence.
It does not binary-patch or redistribute the supplied APK because Flutter AOT
logic pins the 32 km/h asset hash, and editing the APK would invalidate its
signature. A fresh build and release signature are required.
