import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;

import '../db/app_database.dart';

class ExchangeRateTable {
  ExchangeRateTable({
    required this.base,
    required this.date,
    required this.fetchedOn,
    required Map<String, double> rates,
  }) : rates = Map.unmodifiable(rates);
  final String base;
  final DateTime date, fetchedOn;
  final Map<String, double> rates;
}

/// Public rates only: no account names, balances or transactions leave the app.
/// The caller owns the injected client and decides when networking is allowed.
class ExchangeRates {
  ExchangeRates(this.database, this.client, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  final AppDatabase database;
  final http.Client client;
  final DateTime Function() now;
  final Map<String, Future<ExchangeRateTable?>> _pending = {};

  Future<ExchangeRateTable?> cached(String base) async {
    final rows = await database
        .customSelect(
          'SELECT quote, rate, fetched_on, rate_date FROM exchange_rates WHERE base = ?',
          variables: [Variable(base)],
        )
        .get();
    if (rows.isEmpty) return null;
    return ExchangeRateTable(
      base: base,
      date: DateTime.parse(rows.first.read<String>('rate_date')),
      fetchedOn: DateTime.parse(rows.first.read<String>('fetched_on')),
      rates: {
        for (final row in rows)
          row.read<String>('quote'): row.read<double>('rate'),
      },
    );
  }

  Future<ExchangeRateTable?> refresh(String base, {bool force = false}) =>
      _pending.putIfAbsent(
        base,
        () => _refresh(base, force: force).whenComplete(() {
          _pending.remove(base);
        }),
      );

  Future<ExchangeRateTable?> _refresh(
    String base, {
    required bool force,
  }) async {
    if (!RegExp(r'^[A-Z]{3}$').hasMatch(base)) {
      throw ArgumentError('Invalid currency');
    }
    final previous = await cached(base);
    final today = now().toUtc();
    if (!force &&
        previous != null &&
        !previous.fetchedOn.toUtc().isBefore(
          DateTime.utc(today.year, today.month, today.day),
        )) {
      return previous;
    }
    final code = base.toLowerCase();
    for (final url in [
      'https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@latest/v1/currencies/$code.json',
      'https://latest.currency-api.pages.dev/v1/currencies/$code.json',
    ]) {
      try {
        final response = await client
            .get(Uri.parse(url))
            .timeout(const Duration(seconds: 10));
        if (response.statusCode != 200) continue;
        final json = jsonDecode(response.body) as Map<String, dynamic>;
        final dateText = json['date'] as String;
        if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(dateText)) continue;
        final date = DateTime.parse('${dateText}T00:00:00Z');
        if (date.toIso8601String().substring(0, 10) != dateText ||
            date.isAfter(today)) {
          continue;
        }
        if (previous != null && date.isBefore(previous.date)) continue;
        final raw = json[code] as Map<String, dynamic>;
        final rates = <String, double>{};
        for (final entry in raw.entries) {
          if (!RegExp(r'^[a-z]{3}$').hasMatch(entry.key)) continue;
          final rate = (entry.value as num).toDouble();
          if (!rate.isFinite || rate <= 0) {
            throw const FormatException('Invalid rate');
          }
          rates[entry.key.toUpperCase()] = rate;
        }
        if (rates.length < 2 || rates[base] != 1) continue;
        final table = ExchangeRateTable(
          base: base,
          date: date,
          fetchedOn: today,
          rates: rates,
        );
        await database.transaction(() async {
          await database.customStatement(
            'DELETE FROM exchange_rates WHERE base = ?',
            [base],
          );
          for (final entry in rates.entries) {
            await database.customStatement(
              'INSERT INTO exchange_rates(base, quote, rate, fetched_on, rate_date) VALUES (?, ?, ?, ?, ?)',
              [base, entry.key, entry.value, today.toIso8601String(), dateText],
            );
          }
        });
        return table;
      } catch (_) {
        // A failed provider or invalid document falls through to the fallback.
      }
    }
    return previous;
  }
}
