import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// In-memory diagnostic log, bounded so a long session cannot exhaust memory.
///
/// Every BLE poll writes roughly three hex-dump lines and a DFU run adds
/// several hundred more, so an unbounded list grows by megabytes per hour
/// connected. The buffer keeps the most recent [maxLines] and counts what it
/// discarded; the tail is the part that matters for diagnosis, and the export
/// says so explicitly rather than silently presenting a partial log as whole.
class SessionLog {
  SessionLog({this.maxLines = 20000})
      : assert(maxLines >= _trimChunk * 2, 'cap must leave room to trim');

  /// Upper bound on retained lines. At ~120 characters each, 20 000 lines is
  /// on the order of a few MB — enough to cover a full flash plus hours of
  /// telemetry around it.
  final int maxLines;

  /// Lines dropped in one pass once the cap is hit. Trimming in blocks keeps
  /// `add` amortised O(1); removing a single element per call would make every
  /// subsequent write shift the whole list.
  static const int _trimChunk = 2000;

  final List<String> _lines = [];
  int _dropped = 0;

  List<String> get lines => List.unmodifiable(_lines);

  /// Lines evicted by the cap so far. Non-zero means [lines] is a tail.
  int get droppedLines => _dropped;

  int get length => _lines.length;

  bool get truncated => _dropped > 0;

  void add(String message) {
    final stamp = DateTime.now().toIso8601String();
    _lines.add('$stamp  $message');
    if (_lines.length > maxLines) {
      _lines.removeRange(0, _trimChunk);
      _dropped += _trimChunk;
    }
  }

  void packet(String direction, Uint8List bytes,
      {String channel = 'B002/B003'}) {
    final payload = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    add('BLE $direction $channel len=${bytes.length} [$payload]');
  }

  void clear() {
    _lines.clear();
    _dropped = 0;
  }

  Future<File> export() async {
    final directory = await getTemporaryDirectory();
    final stamp = DateTime.now().toIso8601String().replaceAll(':', '-');
    final file = File('${directory.path}/odys-dfu-$stamp.log');
    final sink = file.openWrite();
    try {
      if (_dropped > 0) {
        sink.writeln('# ODYS session log (truncated)');
        sink.writeln('# $_dropped earlier lines were dropped by the '
            '$maxLines-line cap; this file starts mid-session.');
      } else {
        sink.writeln('# ODYS session log (complete)');
      }
      sink.writeln('# ${_lines.length} lines');
      // Streamed rather than joined: a single join would materialise a second
      // copy of the whole buffer at the moment memory is already at its peak.
      for (final line in _lines) {
        sink.writeln(line);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    return file;
  }
}
