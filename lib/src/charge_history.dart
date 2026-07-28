import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'models.dart';

/// Persistent store of finished charge sessions.
///
/// Kept deliberately small and dependency-free: a JSON array in shared
/// preferences. Even at the cap this is a few kilobytes, and the read happens
/// once at startup.
class ChargeHistory {
  ChargeHistory(this._preferences);

  static const String _key = 'odys_charge_history';

  /// Enough to cover a couple of years of ordinary use. Oldest records are
  /// dropped first, which is the right end to lose — the recent trend is what
  /// indicates current pack health.
  static const int maxRecords = 60;

  final SharedPreferencesAsync _preferences;

  Future<List<ChargeRecord>> load() async {
    final raw = await _preferences.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return [];
      return decoded
          .map(ChargeRecord.fromJson)
          .whereType<ChargeRecord>()
          .toList()
        ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
    } catch (_) {
      // A corrupt blob is not worth crashing over, and not worth keeping.
      return [];
    }
  }

  Future<void> save(List<ChargeRecord> records) async {
    final trimmed = records.length > maxRecords
        ? records.sublist(records.length - maxRecords)
        : records;
    await _preferences.setString(
      _key,
      jsonEncode(trimmed.map((r) => r.toJson()).toList()),
    );
  }

  Future<void> clear() => _preferences.remove(_key);
}

/// Read-only view over the stored records, with the capacity maths in one
/// place so the UI does not re-derive it.
class ChargeHistoryStats {
  const ChargeHistoryStats(this.records);

  final List<ChargeRecord> records;

  /// Sessions wide enough to infer pack capacity from, oldest first.
  List<ChargeRecord> get capacityRecords =>
      records.where((r) => r.measuresCapacity).toList();

  bool get hasCapacityData => capacityRecords.isNotEmpty;

  /// Median rather than mean: one session interrupted mid-charge, or one where
  /// the percentage gauge jumped, would drag an average badly.
  double? get packAh => _median(
      capacityRecords.map((r) => r.impliedPackAh!).toList());

  double? get packWh => _median(capacityRecords
      .map((r) => r.impliedPackWh)
      .whereType<double>()
      .toList());

  /// Capacity of the most recent qualifying session.
  double? get latestPackAh =>
      capacityRecords.isEmpty ? null : capacityRecords.last.impliedPackAh;

  /// Capacity of the oldest qualifying session, for a first-versus-latest
  /// comparison.
  double? get firstPackAh =>
      capacityRecords.isEmpty ? null : capacityRecords.first.impliedPackAh;

  /// Change in implied capacity from the first qualifying session to the
  /// latest, as a percentage. Needs at least two spread-out sessions before it
  /// says anything; a fortnight apart is the minimum for the difference to be
  /// degradation rather than measurement scatter.
  double? get degradationPercent {
    final qualifying = capacityRecords;
    if (qualifying.length < 2) return null;
    final first = qualifying.first;
    final last = qualifying.last;
    if (last.startedAt.difference(first.startedAt) <
        const Duration(days: 14)) {
      return null;
    }
    final from = first.impliedPackAh!;
    final to = last.impliedPackAh!;
    if (from <= 0) return null;
    return (to - from) / from * 100;
  }

  double get totalAhDelivered =>
      records.fold(0, (sum, r) => sum + r.ampHours);

  double get totalWhDelivered =>
      records.fold(0, (sum, r) => sum + r.wattHours);

  /// Rough full-charge-equivalent count. Not the BMS cycle counter — this only
  /// sees sessions the app was present for.
  double? get observedCycles {
    final capacity = packAh;
    if (capacity == null || capacity <= 0) return null;
    return totalAhDelivered / capacity;
  }

  static double? _median(List<double> values) {
    if (values.isEmpty) return null;
    final sorted = List<double>.from(values)..sort();
    final middle = sorted.length ~/ 2;
    return sorted.length.isOdd
        ? sorted[middle]
        : (sorted[middle - 1] + sorted[middle]) / 2;
  }
}
