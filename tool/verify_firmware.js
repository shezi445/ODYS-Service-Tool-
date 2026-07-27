#!/usr/bin/env node
const crypto = require("node:crypto");
const fs = require("node:fs");
const path = require("node:path");

const root = path.resolve(__dirname, "..");
const stockPath = path.join(root, "assets/firmware/bldc_stock_de.bin");
const verifiedPath = path.join(
  root,
  "assets/firmware/BLDC_DE_32kmh_Kick1_Normal2_DualCRC.bin",
);
const experimental40Path = path.join(
  root,
  "assets/firmware/BLDC_DE_40kmh_EXPERIMENTAL_Kick1_Normal2_DualCRC.bin",
);
const catalogPath = path.join(root, "assets/firmware/catalog.json");
const catalogSignaturePath = path.join(root, "assets/firmware/catalog.sig");
const catalogPublicKeyRaw =
  "e92ad480266b9a2237d086f46b213a3954b1d7d4be1f0af86d46810862ef4ccf";

const expected = {
  stock: "2640a3f4ff96642eb655d046238b4da7dd6c5f0195cf2424867b063dbe2cb5e5",
  verified:
    "77481c37205cae47d996e109bbeb62521e23fa3d1e190bff25092fd35c265874",
};

function verifySignedCatalog() {
  const spki = Buffer.from(
    `302a300506032b6570032100${catalogPublicKeyRaw}`,
    "hex",
  );
  const key = crypto.createPublicKey({
    key: spki,
    format: "der",
    type: "spki",
  });
  const bytes = fs.readFileSync(catalogPath);
  const signature = fs.readFileSync(catalogSignaturePath);
  if (!crypto.verify(null, bytes, key, signature)) {
    throw new Error("Firmware catalogue Ed25519 signature is invalid");
  }
  const catalog = JSON.parse(bytes.toString("utf8"));
  for (const entry of catalog.entries) {
    const asset = fs.readFileSync(path.join(root, entry.path));
    if (sha(asset) !== entry.sha256) {
      throw new Error(`Signed catalogue hash mismatch: ${entry.path}`);
    }
  }
  process.stdout.write(
    `OK signed firmware catalogue (${catalog.entries.length} entries)\n`,
  );
}

function crc16Xmodem(bytes) {
  let crc = 0;
  for (const byte of bytes) {
    crc ^= byte << 8;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff;
    }
  }
  return crc;
}

function sha(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}

function verify(file, expectedSha, expectedSpeed, expectedInner, expectedOuter) {
  const bytes = fs.readFileSync(file);
  if (bytes.length !== 45184) throw new Error(`${file}: wrong size`);
  if (sha(bytes) !== expectedSha) throw new Error(`${file}: SHA-256 mismatch`);
  if (bytes.readUInt16LE(0xaa58) !== expectedSpeed) {
    throw new Error(`${file}: speed word mismatch`);
  }
  const inner = crc16Xmodem(bytes.subarray(0x100, 0x100 + 0xaf08));
  const outer = crc16Xmodem(bytes.subarray(0x80));
  if (inner !== bytes.readUInt16BE(0xb0) || inner !== expectedInner) {
    throw new Error(`${file}: inner CRC mismatch`);
  }
  if (outer !== bytes.readUInt16BE(0x13) || outer !== expectedOuter) {
    throw new Error(`${file}: outer CRC mismatch`);
  }
  process.stdout.write(
    `OK ${path.basename(file)} sha=${sha(bytes)} speed=${expectedSpeed} ` +
      `inner=${inner.toString(16)} outer=${outer.toString(16)}\n`,
  );
}

verify(stockPath, expected.stock, 476, 0x0b09, 0x063a);
verify(verifiedPath, expected.verified, 692, 0x757a, 0xe444);

const stock = fs.readFileSync(stockPath);
const verified = fs.readFileSync(verifiedPath);
const kickOffsets = [0x1338, 0x155c, 0x1572, 0x1592, 0x1d88, 0x1dcc, 0x1ef0, 0x1f82];
const normalOffsets = [0x1554, 0x3412, 0x427a];
for (const offset of kickOffsets) {
  if (stock[offset] !== 64 || verified[offset] !== 22) {
    throw new Error(`kick threshold mismatch at 0x${offset.toString(16)}`);
  }
}
for (const offset of normalOffsets) {
  if (stock[offset] !== 108 || verified[offset] !== 43) {
    throw new Error(`normal threshold mismatch at 0x${offset.toString(16)}`);
  }
}
process.stdout.write("OK all 11 motor-start patch locations\n");

function buildDerived(speed, kick, normal) {
  const output = Buffer.from(stock);
  output.writeUInt16LE(speed, 0xaa58);
  for (const offset of kickOffsets) output[offset] = kick;
  for (const offset of normalOffsets) output[offset] = normal;
  output.writeUInt16BE(0, 0xb0);
  output.writeUInt16BE(0, 0x13);
  output.writeUInt16BE(
    crc16Xmodem(output.subarray(0x100, 0x100 + 0xaf08)),
    0xb0,
  );
  output.writeUInt16BE(crc16Xmodem(output.subarray(0x80)), 0x13);
  return output;
}

const experimental40 = buildDerived(864, 22, 43);
if (process.argv.includes("--write-experimental-40")) {
  fs.writeFileSync(experimental40Path, experimental40);
  process.stdout.write(`WROTE ${experimental40Path}\n`);
}
if (!fs.existsSync(experimental40Path)) {
  throw new Error("Experimental 40 km/h asset is missing");
}
const storedExperimental40 = fs.readFileSync(experimental40Path);
if (!storedExperimental40.equals(experimental40)) {
  throw new Error("Experimental 40 km/h asset differs from reproducible output");
}
process.stdout.write(
  `OK experimental 40kmh/kick1-normal2 sha=${sha(experimental40)} ` +
    `inner=${experimental40.readUInt16BE(0xb0).toString(16)} ` +
    `outer=${experimental40.readUInt16BE(0x13).toString(16)}\n`,
);

verifySignedCatalog();

for (const [label, speed] of [["25", 540], ["30", 648], ["32", 692], ["40", 864]]) {
  for (const [startLabel, kick, normal] of [
    ["stock", 64, 108],
    ["kick1-normal2", 22, 43],
  ]) {
    const image = buildDerived(speed, kick, normal);
    const inner = crc16Xmodem(image.subarray(0x100, 0x100 + 0xaf08));
    const outer = crc16Xmodem(image.subarray(0x80));
    if (image.readUInt16BE(0xb0) !== inner ||
        image.readUInt16BE(0x13) !== outer) {
      throw new Error(`${label}/${startLabel}: generated CRC mismatch`);
    }
    process.stdout.write(
      `OK derived ${label}kmh/${startLabel} sha=${sha(image)} ` +
      `inner=${inner.toString(16)} outer=${outer.toString(16)}\n`,
    );
  }
}
