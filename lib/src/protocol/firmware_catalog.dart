import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';

class FirmwareCatalog {
  FirmwareCatalog._();

  static const _catalogPath = 'assets/firmware/catalog.json';
  static const _signaturePath = 'assets/firmware/catalog.sig';
  static const _publicKeyBase64 =
      '6SrUgCZrmiI30Ib0ayE6OVSx19S+Hwr4bUaBCGLvTM8=';

  static Future<void>? _verification;

  static Future<void> verify() => _verification ??= _verify();

  static Future<void> _verify() async {
    final catalogData = await rootBundle.load(_catalogPath);
    final signatureData = await rootBundle.load(_signaturePath);
    final catalogBytes = catalogData.buffer.asUint8List(
      catalogData.offsetInBytes,
      catalogData.lengthInBytes,
    );
    final signatureBytes = signatureData.buffer.asUint8List(
      signatureData.offsetInBytes,
      signatureData.lengthInBytes,
    );
    final publicKey = SimplePublicKey(
      base64Decode(_publicKeyBase64),
      type: KeyPairType.ed25519,
    );
    final validSignature = await Ed25519().verify(
      catalogBytes,
      signature: Signature(signatureBytes, publicKey: publicKey),
    );
    if (!validSignature) {
      throw StateError('Firmware catalogue signature is invalid.');
    }

    final document =
        jsonDecode(utf8.decode(catalogBytes)) as Map<String, dynamic>;
    if (document['format'] != 1) {
      throw StateError('Unsupported firmware catalogue format.');
    }
    final entries = document['entries'] as List<dynamic>? ?? const [];
    if (entries.isEmpty) {
      throw StateError('Signed firmware catalogue is empty.');
    }
    for (final value in entries) {
      final entry = value as Map<String, dynamic>;
      final path = entry['path'] as String;
      final expected = entry['sha256'] as String;
      final asset = await rootBundle.load(path);
      final bytes = asset.buffer.asUint8List(
        asset.offsetInBytes,
        asset.lengthInBytes,
      );
      final actual = sha256.convert(bytes).toString();
      if (actual != expected) {
        throw StateError('Signed firmware asset hash mismatch: $path');
      }
    }
  }
}
