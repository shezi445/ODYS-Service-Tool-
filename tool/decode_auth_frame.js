#!/usr/bin/env node
'use strict';

const fs = require('fs');

const input = process.argv.slice(2).join(' ') || fs.readFileSync(0, 'utf8');
const matches = input.match(/[0-9a-fA-F]{2}/g) || [];
const bytes = matches.map((value) => Number.parseInt(value, 16));

let start = -1;
for (let i = 0; i + 15 < bytes.length; i += 1) {
  if (
    bytes[i] === 0x55 &&
    bytes[i + 1] === 0xaa &&
    bytes[i + 3] === 0x30 &&
    bytes[i + 4] === 0x08
  ) {
    start = i;
    break;
  }
}

if (start < 0) {
  console.error(
    'No ODYS 0x30 authentication frame found. Paste the complete ' +
      '"Send authData" hex line from the official app.',
  );
  process.exit(1);
}

const frame = bytes.slice(start, start + 16);
if (frame[14] !== 0xfe || frame[15] !== 0xfd) {
  console.error('The authentication frame is incomplete.');
  process.exit(1);
}

const expectedChecksum = frame
  .slice(0, 13)
  .reduce((sum, byte) => (sum + byte) & 0xff, 0);
if (expectedChecksum !== frame[13]) {
  console.error(
    `Checksum mismatch: expected ${expectedChecksum
      .toString(16)
      .padStart(2, '0')}, received ${frame[13]
      .toString(16)
      .padStart(2, '0')}.`,
  );
  process.exit(1);
}

const userBytes = frame.slice(7, 13);
const userId =
  userBytes[2] * 0x1000000 +
  userBytes[3] * 0x10000 +
  userBytes[4] * 0x100 +
  userBytes[5];

if (userId <= 0) {
  console.error(
    'The frame contains user ID 0. Capture a connection made while logged ' +
      'into the official ODYS account.',
  );
  process.exit(2);
}

console.log(`ODYS numeric user ID: ${userId}`);
console.log(`Selected authentication key index: ${frame[5]}`);
