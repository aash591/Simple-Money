import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/holding.dart';

/// A closing price (or a fund's NAV) for one day.
class PriceQuote {
  const PriceQuote({required this.priceE4, required this.date, this.currency});
  final int priceE4;
  final DateTime date;

  /// What the source says the price is in, when it says.
  final String? currency;
}

/// Something a person can pick when adding a holding.
class SymbolHit {
  const SymbolHit({
    required this.name,
    required this.symbol,
    required this.kind,
    this.exchange,
    this.priceSource,
  });
  final String name, symbol;
  final String? exchange;
  final HoldingKind kind;

  /// The [PriceSourceId] that found it, saved on the holding.
  final String? priceSource;
}

/// One place prices come from. To add one (crypto, gold, forex…): implement
/// this, give it an id in [PriceSourceId] and list it in
/// [PriceService.defaultSources]. Holdings name their source, so nothing
/// else needs to change.
abstract class PriceSource {
  String get id;

  /// Closes for [holdings], by holding id. A holding left out got no price.
  Future<Map<int, PriceQuote>> quotes(
    http.Client client,
    List<Holding> holdings,
  );

  /// Matches for the add-holding search. [currency] is the broker's.
  Future<List<SymbolHit>> search(
    http.Client client,
    String query, {
    required String currency,
  }) async => const [];
}

int? _toE4(num? value) {
  if (value == null || !value.isFinite || value <= 0) return null;
  return (value * priceScale).round();
}

/// India's mutual fund NAVs from AMFI, the industry body: one public text
/// file covering every scheme, updated each evening. No account, no key; the
/// only thing the app ever asks for is that file.
class AmfiNav {
  static final url = Uri.https('www.amfiindia.com', '/spages/NAVAll.txt');

  static const _months = {
    'jan': 1,
    'feb': 2,
    'mar': 3,
    'apr': 4,
    'may': 5,
    'jun': 6,
    'jul': 7,
    'aug': 8,
    'sep': 9,
    'oct': 10,
    'nov': 11,
    'dec': 12,
  };

  /// "18-Nov-2026" -> the date, or null.
  static DateTime? parseDate(String text) {
    final parts = text.trim().split('-');
    if (parts.length != 3) return null;
    final month = _months[parts[1].toLowerCase()];
    final day = int.tryParse(parts[0]), year = int.tryParse(parts[2]);
    if (month == null || day == null || year == null) return null;
    return DateTime(year, month, day);
  }

  /// One line: `code;isin;isin;name;nav;date`.
  static ({String code, String name, PriceQuote? quote})? parseLine(
    String line,
  ) {
    final f = line.split(';');
    if (f.length < 6 || !RegExp(r'^\d+$').hasMatch(f[0].trim())) return null;
    final nav = double.tryParse(f[4].trim());
    final date = parseDate(f[5]);
    return (
      code: f[0].trim(),
      name: f[3].trim(),
      quote: nav == null || date == null
          ? null
          : PriceQuote(priceE4: _toE4(nav) ?? 0, date: date, currency: 'INR'),
    );
  }

  /// Quotes for just the [codes] asked for, so the whole file is never held.
  static Map<String, PriceQuote> quotesFor(String body, Set<String> codes) {
    final found = <String, PriceQuote>{};
    for (final line in const LineSplitter().convert(body)) {
      final semi = line.indexOf(';');
      if (semi < 1 || !codes.contains(line.substring(0, semi).trim())) continue;
      final parsed = parseLine(line);
      if (parsed?.quote != null && parsed!.quote!.priceE4 > 0) {
        found[parsed.code] = parsed.quote!;
      }
      if (found.length == codes.length) break;
    }
    return found;
  }

  /// Schemes whose name holds every word of [query], best matches first.
  static List<SymbolHit> search(String body, String query, {int limit = 25}) {
    final words = query
        .toLowerCase()
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isEmpty) return const [];
    final hits = <SymbolHit>[];
    for (final line in const LineSplitter().convert(body)) {
      final parsed = parseLine(line);
      if (parsed == null) continue;
      final name = parsed.name.toLowerCase();
      if (words.every(name.contains)) {
        hits.add(
          SymbolHit(
            name: parsed.name,
            symbol: parsed.code,
            kind: HoldingKind.fund,
            exchange: 'AMFI',
            priceSource: PriceSourceId.amfi,
          ),
        );
      }
    }
    // Shorter names first: "Direct Growth" before long variants.
    hits.sort((a, b) => a.name.length.compareTo(b.name.length));
    return hits.take(limit).toList();
  }

  static Future<String?> download(http.Client client) async {
    try {
      final response = await client
          .get(url)
          .timeout(const Duration(seconds: 30));
      return response.statusCode == 200 ? response.body : null;
    } catch (_) {
      return null;
    }
  }
}

/// Closing prices for stocks and ETFs worldwide from Yahoo Finance's public
/// chart data. It is not an official, supported API, so every call can fail
/// and the app treats that as "no new price", never as an error.
class YahooQuotes {
  static const _headers = {'User-Agent': 'Mozilla/5.0'};

  /// Where each exchange's tickers carry a suffix on Yahoo.
  static const _suffix = {
    'NSE': '.NS',
    'BSE': '.BO',
    'LSE': '.L',
    'TSX': '.TO',
    'TSXV': '.V',
    'ASX': '.AX',
    'HKEX': '.HK',
    'SGX': '.SI',
    'XETRA': '.DE',
    'FRA': '.F',
    'EPA': '.PA',
    'AMS': '.AS',
    'BIT': '.MI',
    'BME': '.MC',
    'SIX': '.SW',
    'TSE': '.T',
    'KRX': '.KS',
    'NZX': '.NZ',
    'JSE': '.JO',
    'B3': '.SA',
    'TADAWUL': '.SR',
    'DFM': '.AE',
    'IDX': '.JK',
    'BKK': '.BK',
    'SET': '.BK',
  };

  /// The Yahoo ticker for [symbol] on [exchange]. A ticker that already has
  /// its suffix (`TCS.NS`) or sits on a US exchange stays as typed.
  static String yahooSymbol(String symbol, String? exchange) {
    final clean = symbol.trim().toUpperCase();
    if (clean.contains('.') || exchange == null) return clean;
    return '$clean${_suffix[exchange.trim().toUpperCase()] ?? ''}';
  }

  /// The latest close in a chart response, or null if it has none.
  static PriceQuote? parseChart(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final result = (json['chart']?['result'] as List?)?.firstOrNull;
      if (result is! Map<String, dynamic>) return null;
      final meta = result['meta'] as Map<String, dynamic>? ?? const {};
      final stamps = (result['timestamp'] as List?)?.cast<num?>() ?? const [];
      final closes =
          ((result['indicators']?['quote'] as List?)?.firstOrNull?['close']
                  as List?)
              ?.cast<num?>() ??
          const [];
      var currency = meta['currency'] as String?;
      num? price;
      DateTime? date;
      // The last day that has a close; today's still-open day has none.
      for (var i = closes.length - 1; i >= 0; i--) {
        if (closes[i] != null && i < stamps.length && stamps[i] != null) {
          price = closes[i];
          date = _day(stamps[i]!.toInt(), meta['gmtoffset'] as num?);
          break;
        }
      }
      if (price == null || date == null) return null;
      // London quotes in pence, Johannesburg in cents, Tel Aviv in agorot.
      const subunits = {
        'GBp': 'GBP',
        'GBX': 'GBP',
        'ZAc': 'ZAR',
        'ZAC': 'ZAR',
        'ILA': 'ILS',
      };
      if (subunits[currency] case final whole?) {
        price = price / 100;
        currency = whole;
      }
      final e4 = _toE4(price);
      return e4 == null
          ? null
          : PriceQuote(priceE4: e4, date: date, currency: currency);
    } catch (_) {
      return null;
    }
  }

  /// The exchange-local calendar day of a UNIX time.
  static DateTime _day(int seconds, num? offset) {
    final local = DateTime.fromMillisecondsSinceEpoch(
      (seconds + (offset?.toInt() ?? 0)) * 1000,
      isUtc: true,
    );
    return DateTime(local.year, local.month, local.day);
  }

  static Future<PriceQuote?> quote(
    http.Client client,
    String yahooSymbol,
  ) async {
    try {
      final response = await client
          .get(
            Uri.https(
              'query1.finance.yahoo.com',
              '/v8/finance/chart/${Uri.encodeComponent(yahooSymbol)}',
              {'range': '5d', 'interval': '1d'},
            ),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 15));
      return response.statusCode == 200 ? parseChart(response.body) : null;
    } catch (_) {
      return null;
    }
  }

  static List<SymbolHit> parseSearch(String body) {
    try {
      final quotes = (jsonDecode(body) as Map<String, dynamic>)['quotes'];
      return [
        for (final q in (quotes as List? ?? const []).cast<Map>())
          if (q['symbol'] is String && _kind(q['quoteType']) != null)
            SymbolHit(
              name: (q['longname'] ?? q['shortname'] ?? q['symbol']) as String,
              symbol: q['symbol'] as String,
              kind: _kind(q['quoteType'])!,
              exchange: q['exchDisp'] as String?,
              priceSource: PriceSourceId.yahoo,
            ),
      ];
    } catch (_) {
      return const [];
    }
  }

  static HoldingKind? _kind(Object? quoteType) => switch (quoteType) {
    'EQUITY' => HoldingKind.stock,
    'ETF' => HoldingKind.etf,
    'MUTUALFUND' => HoldingKind.fund,
    _ => null,
  };

  static Future<List<SymbolHit>> search(
    http.Client client,
    String query,
  ) async {
    try {
      final response = await client
          .get(
            Uri.https('query1.finance.yahoo.com', '/v1/finance/search', {
              'q': query,
              'quotesCount': '25',
              'newsCount': '0',
            }),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 10));
      return response.statusCode == 200 ? parseSearch(response.body) : const [];
    } catch (_) {
      return const [];
    }
  }
}

/// [AmfiNav] as a [PriceSource]: funds by scheme code, downloaded once per
/// refresh. Search only offers Indian funds to a broker that holds rupees.
class AmfiSource extends PriceSource {
  @override
  String get id => PriceSourceId.amfi;

  String? _body;

  @override
  Future<Map<int, PriceQuote>> quotes(
    http.Client client,
    List<Holding> holdings,
  ) async {
    final body = await AmfiNav.download(client);
    if (body == null) return const {};
    final byCode = AmfiNav.quotesFor(body, {
      for (final h in holdings) h.symbol!.trim(),
    });
    return {
      for (final h in holdings)
        if (byCode[h.symbol!.trim()] case final quote?) h.id: quote,
    };
  }

  @override
  Future<List<SymbolHit>> search(
    http.Client client,
    String query, {
    required String currency,
  }) async {
    if (currency != 'INR') return const [];
    _body ??= await AmfiNav.download(client);
    return _body == null ? const [] : AmfiNav.search(_body!, query);
  }
}

/// [YahooQuotes] as a [PriceSource]: stocks and ETFs on any exchange.
class YahooSource extends PriceSource {
  static const _parallel = 4;

  @override
  String get id => PriceSourceId.yahoo;

  @override
  Future<Map<int, PriceQuote>> quotes(
    http.Client client,
    List<Holding> holdings,
  ) async {
    final found = <int, PriceQuote>{};
    for (var i = 0; i < holdings.length; i += _parallel) {
      final batch = holdings.skip(i).take(_parallel).toList();
      final quotes = await Future.wait([
        for (final h in batch)
          YahooQuotes.quote(
            client,
            YahooQuotes.yahooSymbol(h.symbol!, h.exchange),
          ),
      ]);
      for (var n = 0; n < batch.length; n++) {
        if (quotes[n] case final quote?) found[batch[n].id] = quote;
      }
    }
    return found;
  }

  @override
  Future<List<SymbolHit>> search(
    http.Client client,
    String query, {
    required String currency,
  }) async {
    final hits = await YahooQuotes.search(client, query);
    // A rupee broker's funds come from AMFI, which knows them better.
    return currency == 'INR'
        ? [
            for (final h in hits)
              if (h.kind != HoldingKind.fund) h,
          ]
        : hits;
  }
}
