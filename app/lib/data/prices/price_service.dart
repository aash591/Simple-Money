import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/holding.dart';
import 'price_sources.dart';

/// What a refresh did, for the message shown afterwards.
class PriceRefreshResult {
  const PriceRefreshResult({
    this.updated = const {},
    this.failed = 0,
    this.mismatched = 0,
  });

  /// New closes by holding id.
  final Map<int, PriceQuote> updated;

  /// Holdings that got no price: offline, unknown ticker, source down.
  final int failed;

  /// Holdings whose price is in another currency than their broker.
  final int mismatched;

  bool get anyUpdated => updated.isNotEmpty;
}

/// Finds the last close for holdings. Only a ticker or an AMFI scheme code is
/// ever sent, never a name, amount, unit count or account. Prices are daily
/// closes, so the app asks at most once a day unless told to.
class PriceService {
  PriceService(
    this.client, {
    DateTime Function()? now,
    List<PriceSource>? sources,
  }) : now = now ?? DateTime.now,
       _sources = {
         for (final s in sources ?? defaultSources()) s.id: s,
       };
  final http.Client client;
  final DateTime Function() now;
  final Map<String, PriceSource> _sources;

  static const _doneKey = 'prices_refreshed_on';

  /// Every place prices come from, in the order search results appear.
  /// `manual` has no entry: a holding priced by hand is never fetched.
  static List<PriceSource> defaultSources() => [AmfiSource(), YahooSource()];

  static String _day(DateTime t) => '${t.year}-${t.month}-${t.day}';

  /// Whether today's refresh hasn't happened yet.
  Future<bool> due() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_doneKey) != _day(now());
  }

  Future<void> markRefreshed() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_doneKey, _day(now()));
  }

  /// Fetches closes for [targets], each paired with its broker's currency.
  Future<PriceRefreshResult> fetch(
    List<({Holding holding, String currency})> targets,
  ) async {
    final updated = <int, PriceQuote>{};
    var failed = 0, mismatched = 0;

    void take(int id, PriceQuote? quote, String currency) {
      if (quote == null || quote.priceE4 <= 0) {
        failed++;
      } else if (quote.currency != null && quote.currency != currency) {
        mismatched++;
      } else {
        updated[id] = quote;
      }
    }

    // Each holding goes to the source it names (or, for one that names none,
    // the one inferred). A source this version doesn't have, or a holding
    // priced by hand, is skipped: nothing to fetch isn't a failure.
    final bySource = <PriceSource, List<({Holding holding, String currency})>>{};
    for (final t in targets) {
      if (t.holding.symbol?.trim().isEmpty ?? true) continue;
      final source = _sources[t.holding.effectivePriceSource];
      if (source != null) (bySource[source] ??= []).add(t);
    }
    for (final MapEntry(key: source, value: group) in bySource.entries) {
      final quotes = await source.quotes(client, [
        for (final t in group) t.holding,
      ]);
      for (final t in group) {
        take(t.holding.id, quotes[t.holding.id], t.currency);
      }
    }
    return PriceRefreshResult(
      updated: updated,
      failed: failed,
      mismatched: mismatched,
    );
  }

  /// The latest close for something not saved yet, so the add-holding flow can
  /// show what it would be priced at. Null when it has no ticker, no source
  /// knows it, or the lookup failed.
  Future<PriceQuote?> quoteFor({
    required HoldingKind kind,
    String? symbol,
    String? exchange,
    String? priceSource,
  }) async {
    final code = symbol?.trim() ?? '';
    if (code.isEmpty) return null;
    final holding = Holding(
      id: 0,
      accountId: 0,
      kind: kind,
      name: '',
      symbol: code,
      exchange: exchange,
      priceSource: priceSource,
    );
    final source = _sources[holding.effectivePriceSource];
    if (source == null) return null;
    return (await source.quotes(client, [holding]))[0];
  }

  /// Search for the add-holding flow, across every source. [currency] is
  /// the broker's, which decides what each source offers.
  Future<List<SymbolHit>> search(
    String query, {
    required String currency,
  }) async {
    final text = query.trim();
    if (text.length < 2) return const [];
    return [
      for (final source in _sources.values)
        ...await source.search(client, text, currency: currency),
    ];
  }
}
