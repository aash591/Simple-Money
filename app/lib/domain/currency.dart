import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

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

  /// The country the phone is set up for, from its language and region
  /// settings (for example `IN` for English (India)). No permission is
  /// needed, and it follows what the person chose, not where they are.
  static String? deviceRegion() {
    for (final locale in PlatformDispatcher.instance.locales) {
      final region = locale.countryCode;
      if (region != null && region.length == 2) return region.toUpperCase();
    }
    return null;
  }

  /// The currency of [region] in [all], or null when there is none.
  static Currency? forRegion(List<Currency> all, String? region) {
    if (region == null) return null;
    for (final currency in all) {
      if (currency.territory == region) return currency;
    }
    return null;
  }

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
