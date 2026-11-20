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
  PriceService(this.client, {DateTime Function()? now})
    : now = now ?? DateTime.now;
  final http.Client client;
  final DateTime Function() now;

  static const _doneKey = 'prices_refreshed_on';
  static const _parallel = 4;

  String? _amfiBody;

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

  /// Funds with an AMFI scheme code use AMFI; everything else, Yahoo.
  static bool usesAmfi(Holding h) =>
      h.kind == HoldingKind.fund &&
      h.symbol != null &&
      RegExp(r'^\d+$').hasMatch(h.symbol!);

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

    final withSymbol = [
      for (final t in targets)
        if (t.holding.symbol?.trim().isNotEmpty ?? false) t,
    ];
    final amfi = [for (final t in withSymbol) if (usesAmfi(t.holding)) t];
    if (amfi.isNotEmpty) {
      final body = await AmfiNav.download(client);
      final quotes = body == null
          ? const <String, PriceQuote>{}
          : AmfiNav.quotesFor(body, {for (final t in amfi) t.holding.symbol!});
      for (final t in amfi) {
        take(t.holding.id, quotes[t.holding.symbol], t.currency);
      }
    }

    final yahoo = [for (final t in withSymbol) if (!usesAmfi(t.holding)) t];
    for (var i = 0; i < yahoo.length; i += _parallel) {
      final batch = yahoo.skip(i).take(_parallel).toList();
      final quotes = await Future.wait([
        for (final t in batch)
          YahooQuotes.quote(
            client,
            YahooQuotes.yahooSymbol(t.holding.symbol!, t.holding.exchange),
          ),
      ]);
      for (var n = 0; n < batch.length; n++) {
        take(batch[n].holding.id, quotes[n], batch[n].currency);
      }
    }
    return PriceRefreshResult(
      updated: updated,
      failed: failed,
      mismatched: mismatched,
    );
  }

  /// Search for the add-holding sheet. Funds come from AMFI when
  /// [indianFunds] is set (the broker's currency is INR), everything else
  /// from Yahoo.
  Future<List<SymbolHit>> search(String query, {required bool indianFunds}) async {
    final text = query.trim();
    if (text.length < 2) return const [];
    final yahoo = await YahooQuotes.search(client, text);
    if (!indianFunds) return yahoo;
    _amfiBody ??= await AmfiNav.download(client);
    final funds = _amfiBody == null
        ? const <SymbolHit>[]
        : AmfiNav.search(_amfiBody!, text);
    return [
      ...funds,
      for (final h in yahoo)
        if (h.kind != HoldingKind.fund) h,
    ];
  }
}
