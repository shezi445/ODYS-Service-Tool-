import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

class SessionLog {
  final List<String> _lines = [];

  List<String> get lines => List.unmodifiable(_lines);

  void add(String message) {
    final stamp = DateTime.now().toIso8601String();
    _lines.add('$stamp  $message');
  }

  void packet(String direction, Uint8List bytes, {String channel = 'B002/B003'}) {
    final payload = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    add('BLE $direction $channel len=${bytes.length} [$payload]');
  }

  Future<File> export() async {
    final directory = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File('${directory.path}/odys-dfu-$stamp.log');
    return file.writeAsString('${_lines.join('\n')}\n', flush: true);
  }
}
