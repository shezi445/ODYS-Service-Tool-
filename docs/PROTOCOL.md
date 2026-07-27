# Recovered ODYS BLE protocol

The implementation is based on the controller/app pair supplied with this
project. It does not perform cloud login, but normal BLE authentication still
requires the numeric user ID assigned to the ODYS account.

## GATT

- Service: `0000d0ff-3c17-d293-8e48-14fe2e4da212`
- Write: `0000b002-0000-1000-8000-00805f9b34fb`
- Notify: `0000b003-0000-1000-8000-00805f9b34fb`
- Android DFU MTU request: 148 bytes

Normal frames begin `55 AA` and end `FE FD`. The checksum is the low byte of
the sum of all preceding frame bytes. Commands used here are firmware `73`,
battery `72`, car `70`, cruise `52`, and reports `91`/`92`.

The initial request has this layout:

`55 AA 00 30 08 <key-index> 00 <six-byte-user-id> <sum> FE FD`

The official app obtains the six-byte identity from
`longTo6Bytes(userId, 0x88)`. User ID zero produces
`88 00 00 00 00 00`, but that is not an anonymous identity; this scooter
does not issue a challenge for it.

Normal authentication is a multi-step exchange, not a single acknowledgement:

1. Client sends `0x30` with key index and six-byte user field.
2. Controller returns a non-empty `0x30` challenge.
3. Client encrypts/XORs the challenge with the indexed key and sends `0x31`.
4. Controller returns successful `0x31`.
5. Client repeats `0x30`.
6. Controller returns a short `0x30` success frame.

Only step 6 means normal authentication is complete. Five official key slots
are supported; the client tries each index when an earlier attempt is rejected
or times out.

## DFU

BLDC DFU uses:

1. `down dfu_start 2\r`
2. `down ble_rand\r`
3. AES-ECB or XOR challenge response in `down ble_key …\r`
4. Controller sends `C`
5. XMODEM-CRC, 128-byte payloads, `1A` padding, ten retries
6. EOT (`04`)
7. Controller must return `rsq dfu_ok\r`

The app requires the separate final result. An EOT ACK or 100% transfer by
itself is not reported as success.

## Telemetry

Firmware response contains three four-byte dotted versions: meter, BLDC, BMS.
Battery response contains percent, millivolts, signed milliamps and battery
temperature. Live report v1 contains a two-byte deci-km/h speed; v0 contains
one-byte km/h.
This firmware protocol does not expose a controller/MOSFET temperature, so the
UI explicitly shows it as unavailable.

## Firmware invariants

- Image size: 45,184 bytes
- Speed word: little-endian at `0xAA58`
- Inner CRC: CRC-16/XMODEM over `0x100 .. 0xB007`, stored big-endian at `0xB0`
- Outer CRC: CRC-16/XMODEM over `0x80 .. EOF`, stored big-endian at `0x13`
- Stock DE SHA-256:
  `2640a3f4ff96642eb655d046238b4da7dd6c5f0195cf2424867b063dbe2cb5e5`
- Verified 32/Kick1/Normal2 SHA-256:
  `77481c37205cae47d996e109bbeb62521e23fa3d1e190bff25092fd35c265874`
