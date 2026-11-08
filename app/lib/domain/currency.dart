import 'dart:convert';

import 'package:flutter/services.dart';

class Currency {
  const Currency({
    required this.country,
    required this.territory,
    required this.code,
    required this.name,
    required this.digits,
  });
  final String country, territory, code, name;
  final int digits;

  static Future<List<Currency>>? _cached;

  /// Parsed once per session and reused afterwards. The list is a static
  /// asset, and decoding ~260 entries is enough work to drop frames if it
  /// runs while the currency screen is animating open.
  static Future<List<Currency>> load() => _cached ??= _read();

  static Future<List<Currency>> _read() async {
    try {
      final rows = jsonDecode(
        await rootBundle.loadString('assets/data/currencies.json'),
      ) as List;
      return rows
          .map(
            (row) => Currency(
              country: row['country'] as String,
              territory: row['territory'] as String,
              code: row['code'] as String,
              name: row['name'] as String,
              digits: row['digits'] as int,
            ),
          )
          .toList();
    } catch (_) {
      _cached = null; // so the screen's "Try again" can re-read the asset
      rethrow;
    }
  }
}
