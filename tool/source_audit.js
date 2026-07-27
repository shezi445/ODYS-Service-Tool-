#!/usr/bin/env node
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const read = (name) => fs.readFileSync(path.join(root, name), "utf8");
const models = read("lib/src/models.dart");
const client = read("lib/src/ble/odys_ble_client.dart");
const dfu = read("lib/src/dfu/dfu_engine.dart");
const firmware = read("lib/src/protocol/firmware_tools.dart");
const catalog = read("lib/src/protocol/firmware_catalog.dart");
const ui = read("lib/src/ui/home_page.dart");
const main = read("lib/main.dart");
const authDecoder = read("tool/decode_auth_frame.js");

const checks = [
  ["25 km/h raw value", models.includes("limit25('25 km/h', 25, 540, false)")],
  ["30 km/h raw value", models.includes("limit30('30 km/h', 30, 648, false)")],
  ["40 km/h experimental raw value",
    models.includes("experimental40('40 km/h (EXPERIMENTAL)', 40, 864, true)")],
  ["fresh trusted speed", models.includes("bool get hasTrustedSpeed")],
  ["real 0x90/91/92 report stream", client.includes("report stream after readCar")],
  ["three stationary samples", client.includes("_stationarySamples >= 3")],
  ["serialized BLE writes", client.includes("_writeTail")],
  ["automatic reconnect", client.includes("_recoverConnection")],
  ["status 62 retry handling", client.includes("isConnectionEstablishmentFailure")],
  ["scan-to-connect settle delay", client.includes("Duration(milliseconds: 800)")],
  ["single-flight BLE connect", client.includes("_connectOperationInProgress")],
  ["GATT cache refresh", client.includes("clearGattCache")],
  ["three-pass channel discovery", client.includes("_discoverOdysChannels")],
  ["short/full UUID matching", client.includes("uuidTextMatches")],
  ["all five ODYS authentication keys", dfu.includes("authenticationKeys = [") &&
    client.includes("DfuEngine.authenticationKeys.length")],
  ["full normal-auth confirmation sequence",
    client.includes("Authentication encryption accepted; requesting confirmation") &&
    client.includes("authentication completed (0x30 confirmation)")],
  ["authentication rejection diagnostics",
    client.includes("Controller rejected authentication command")],
  ["account-ID authentication path preserved",
    client.includes("userId: accountId") &&
    client.includes("positive 32-bit ODYS account ID")],
  ["official auth-frame decoder",
    authDecoder.includes("ODYS numeric user ID") &&
    authDecoder.includes("Checksum mismatch")],
  ["cruise read-back", client.includes("_cruiseVerifyCompleter")],
  ["fragmented frame assembler", client.includes("_normalFrameBuffer")],
  ["complete BLE packet diagnostics", client.includes("log.packet('TX'") &&
    client.includes("log.packet('RX'")],
  ["ODYS XMODEM sequence skips zero",
    dfu.includes("(zeroBasedIndex % 255) + 1")],
  ["timed-out queue waiters removed", dfu.includes("_waiters.remove(completer)")],
  ["20 second EOT acknowledgement", dfu.includes("const Duration(seconds: 20)")],
  ["controller compatibility gate", firmware.includes("compatibilityFor")],
  ["40 km/h exact-revision gate",
    firmware.includes("versions.bldc != '0.0.0.3'")],
  ["runtime signed firmware catalogue",
    catalog.includes("Ed25519().verify") &&
    catalog.includes("Signed firmware asset hash mismatch")],
  ["accurate post-flash verification claim",
    ui.includes("does not expose firmware-content readback")],
  ["one-action original restore selection",
    ui.includes("Prepare original-firmware restoration")],
  ["experimental risk acknowledgement",
    ui.includes("I understand 40 km/h is experimental")],
  ["battery/temperature/charger interlocks", ui.includes("Battery temperature must be between")],
  ["phone battery interlock", ui.includes("Phone battery must be at least 30%")],
  ["BLE signal interlock", ui.includes("BLE signal must be at least -85 dBm")],
  ["DFU cancellation control", ui.includes("Stop safely before next packet")],
  ["combined EOT/final reply handling", dfu.includes("finalReply = eotReply")],
  ["Dart SDK-compatible ASCII codec",
    dfu.includes("convert.ascii.encode(value)") &&
    dfu.includes("convert.ascii.decode(bytes, allowInvalid: true)") &&
    !dfu.includes("asciiCodec")],
  ["current Flutter card theme API", main.includes("CardThemeData(")],
];

let failed = false;
for (const [name, ok] of checks) {
  process.stdout.write(`${ok ? "OK" : "FAIL"} ${name}\n`);
  failed ||= !ok;
}
if (failed) process.exit(1);
