import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../statements/statement_table.dart';

/// A statement layout the app couldn't read by itself: its column names and
/// a few rows, so a connected AI can say which column is which.
class StatementSample {
  const StatementSample({
    required this.id,
    required this.fileName,
    required this.signature,
    required this.header,
    required this.rows,
  });
  final String id, fileName;

  /// [tableSignature] of [header]: a saved mapping is found by it.
  final String signature;
  final List<String> header;
  final List<List<String>> rows;

  Map<String, Object?> toJson() => {
    'id': id,
    'fileName': fileName,
    'signature': signature,
    'header': header,
    'rows': rows,
  };

  static StatementSample? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      return StatementSample(
        id: json['id'] as String,
        fileName: json['fileName'] as String,
        signature: json['signature'] as String,
        header: (json['header'] as List).cast<String>(),
        rows: [
          for (final row in json['rows'] as List) (row as List).cast<String>(),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}

/// Device-local: the few statement layouts waiting for a mapping. Each holds
/// only its column names and [sampleRows] rows, and goes once its layout is
/// saved.
class StatementSampleRepository {
  static const key = 'ai.statement_samples';
  static const sampleRows = 5;
  static const _kept = 5;

  Future<List<StatementSample>> load() async {
    final prefs = await SharedPreferences.getInstance();
    try {
      final saved = jsonDecode(prefs.getString(key) ?? '[]') as List;
      return [for (final s in saved) ?StatementSample.fromJson(s)];
    } catch (_) {
      return [];
    }
  }

  /// Keeps [rows]' layout, read with its header at [headerRow]. The newest
  /// few are kept; the same layout again replaces the older copy.
  Future<void> add(
    String fileName,
    List<List<String>> rows,
    int headerRow,
  ) async {
    final header = rows.elementAtOrNull(headerRow);
    if (header == null) return;
    final signature = tableSignature(header);
    if (signature.isEmpty) return;
    final body = [
      for (final row in rows.skip(headerRow + 1))
        if (row.any((c) => c.trim().isNotEmpty)) row,
    ].take(sampleRows).toList();
    final sample = StatementSample(
      id: 's${signature.hashCode.toUnsigned(32).toRadixString(36)}',
      fileName: fileName,
      signature: signature,
      header: header,
      rows: body,
    );
    final kept = [
      sample,
      for (final s in await load())
        if (s.signature != signature) s,
    ].take(_kept);
    await _write(kept);
  }

  /// Forgets the layout with [signature], once it has a mapping.
  Future<void> remove(String signature) async {
    final all = await load();
    if (all.every((s) => s.signature != signature)) return;
    await _write([
      for (final s in all)
        if (s.signature != signature) s,
    ]);
  }

  Future<void> _write(Iterable<StatementSample> samples) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      key,
      jsonEncode([for (final s in samples) s.toJson()]),
    );
  }
}
