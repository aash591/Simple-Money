import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/prices/price_service.dart';
import 'package:simple_money/data/prices/price_sources.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/holding_repository.dart';
import 'package:simple_money/domain/holding.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/holding_store.dart';

const amfi = '''Scheme Code;ISIN Div Payout/ ISIN Growth;ISIN Div Reinvestment;Scheme Name;Net Asset Value;Date

Open Ended Schemes(Equity Scheme - Flexi Cap Fund)

Parag Parikh Mutual Fund

122639;INF879O01019;-;Parag Parikh Flexi Cap Fund - Direct Plan - Growth;82.4567;18-Nov-2026
122640;INF879O01027;-;Parag Parikh Flexi Cap Fund - Regular Plan - Growth;74.1;18-Nov-2026
999999;-;-;Broken Fund;N.A.;18-Nov-2026
''';

String chart({
  String currency = 'INR',
  List<num?> closes = const [3500.5, 3550.25, null],
}) => jsonEncode({
  'chart': {
    'result': [
      {
        'meta': {'currency': currency, 'gmtoffset': 19800},
        'timestamp': [1790000000, 1790086400, 1790172800],
        'indicators': {
          'quote': [
            {'close': closes},
          ],
        },
      },
    ],
  },
});

void main() {
  test('AMFI: reads a NAV line, skips ones without a number', () {
    final q = AmfiNav.quotesFor(amfi, {'122639', '999999', '000'});
    expect(q.keys, ['122639']);
    expect(q['122639']!.priceE4, 824567);
    expect(q['122639']!.date, DateTime(2026, 11, 18));
  });

  test('AMFI search needs every word, shortest names first', () {
    final hits = AmfiNav.search(amfi, 'parag flexi direct');
    expect(hits.map((h) => h.symbol), ['122639']);
    expect(AmfiNav.search(amfi, 'parag flexi').length, 2);
    expect(AmfiNav.search(amfi, ''), isEmpty);
  });

  test('Yahoo chart: last close that exists, not the open day', () {
    final q = YahooQuotes.parseChart(chart())!;
    expect(q.priceE4, 35502500);
    expect(q.currency, 'INR');
    expect(YahooQuotes.parseChart(chart(closes: [null, null, null])), isNull);
    expect(YahooQuotes.parseChart('not json'), isNull);
  });

  test('Yahoo: London pence become pounds, tickers get their suffix', () {
    final q = YahooQuotes.parseChart(
      chart(currency: 'GBp', closes: [250, 251, null]),
    )!;
    expect(q.currency, 'GBP');
    expect(q.priceE4, 25100);
    expect(YahooQuotes.yahooSymbol('tcs', 'NSE'), 'TCS.NS');
    expect(YahooQuotes.yahooSymbol('TCS.BO', 'NSE'), 'TCS.BO');
    expect(YahooQuotes.yahooSymbol('AAPL', 'NASDAQ'), 'AAPL');
    expect(YahooQuotes.yahooSymbol('AAPL', null), 'AAPL');
  });

  test('Yahoo search keeps stocks, ETFs and funds only', () {
    final hits = YahooQuotes.parseSearch(
      jsonEncode({
        'quotes': [
          {
            'symbol': 'TCS.NS',
            'longname': 'Tata Consultancy',
            'quoteType': 'EQUITY',
            'exchDisp': 'NSE',
          },
          {
            'symbol': 'BTC-USD',
            'shortname': 'Bitcoin',
            'quoteType': 'CRYPTOCURRENCY',
          },
          {
            'symbol': 'NIFTYBEES.NS',
            'shortname': 'Nifty ETF',
            'quoteType': 'ETF',
          },
        ],
      }),
    );
    expect(hits.map((h) => h.symbol), ['TCS.NS', 'NIFTYBEES.NS']);
    expect(hits.first.kind, HoldingKind.stock);
  });

  group('refreshing holdings', () {
    late AppDatabase db;
    late AccountStore accounts;
    late HoldingStore store;
    late List<Uri> requested;
    var today = DateTime(2026, 11, 19);

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      today = DateTime(2026, 11, 19);
      requested = [];
      db = AppDatabase(NativeDatabase.memory());
      accounts = AccountStore(AccountRepository(db));
      final client = MockClient((request) async {
        requested.add(request.url);
        if (request.url.host == 'www.amfiindia.com') {
          return http.Response(amfi, 200);
        }
        if (request.url.path.contains('TCS.NS')) {
          return http.Response(chart(), 200);
        }
        if (request.url.path.contains('AAPL')) {
          return http.Response(chart(currency: 'USD'), 200);
        }
        return http.Response('', 404);
      });
      store = HoldingStore(
        HoldingRepository(db),
        accountStore: accounts,
        prices: PriceService(client, now: () => today),
      );
      await accounts.save(
        name: 'Zerodha',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
        broker: true,
      );
      await accounts.load();
      final broker = accounts.accounts.single.id;
      await store.saveHolding(
        accountId: broker,
        kind: HoldingKind.stock,
        name: 'TCS',
        symbol: 'TCS',
        exchange: 'NSE',
      );
      await store.saveHolding(
        accountId: broker,
        kind: HoldingKind.fund,
        name: 'PPFAS',
        symbol: '122639',
      );
      await store.saveHolding(
        accountId: broker,
        kind: HoldingKind.stock,
        name: 'Apple',
        symbol: 'AAPL',
        exchange: 'NASDAQ',
      );
      await store.saveHolding(
        accountId: broker,
        kind: HoldingKind.stock,
        name: 'Typed by hand',
      );
    });

    tearDown(() async {
      store.dispose();
      accounts.dispose();
      await db.close();
    });

    test(
      'sets prices, skips another currency, once a day unless forced',
      () async {
        final first = await store.refreshPrices();
        expect(first!.updated.length, 2);
        expect(
          first.mismatched,
          1,
          reason: 'Apple is in USD, the broker in INR',
        );
        Holding named(String n) =>
            store.holdings.firstWhere((h) => h.name == n);
        expect(named('TCS').lastPriceE4, 35502500);
        expect(named('PPFAS').lastPriceE4, 824567);
        expect(named('Apple').lastPriceE4, isNull);
        expect(named('Typed by hand').lastPriceE4, isNull);
        // Only tickers and scheme codes go out.
        for (final url in requested) {
          expect('$url'.toLowerCase(), isNot(contains('zerodha')));
        }

        final count = requested.length;
        expect(await store.refreshPrices(), isNull, reason: 'done today');
        expect(requested.length, count);
        expect(await store.refreshPrices(force: true), isNotNull);

        today = DateTime(2026, 11, 20);
        expect(await store.refreshPrices(), isNotNull, reason: 'a new day');
      },
    );

    test('a failed fetch is not counted as done, so it tries again', () async {
      final offline = MockClient(
        (_) async => throw http.ClientException('offline'),
      );
      final store2 = HoldingStore(
        HoldingRepository(db),
        accountStore: accounts,
        prices: PriceService(offline, now: () => today),
      );
      await store2.load();
      final result = await store2.refreshPrices();
      expect(result!.anyUpdated, isFalse);
      expect(result.failed, greaterThan(0));
      expect(await store2.prices!.due(), isTrue);
      store2.dispose();
    });
  });

  group('CoinGecko crypto', () {
    final client = MockClient((request) async {
      if (request.url.path == '/api/v3/search') {
        return http.Response(
          jsonEncode({
            'coins': [
              {
                'id': 'ethereum',
                'name': 'Ethereum',
                'symbol': 'ETH',
                'large': 'https://coin-images.coingecko.com/coins/images/279/large/ethereum.png',
              },
            ],
          }),
          200,
        );
      }
      return http.Response(
        jsonEncode({
          'ethereum': {'usd': 3200.5, 'last_updated_at': 1795241536},
        }),
        200,
      );
    });

    test('search finds a coin with its logo, only for crypto', () async {
      final service = PriceService(client);
      final hits = await service.search(
        'ethereum',
        currency: 'USD',
        kind: HoldingKind.crypto,
      );
      expect(hits.single.symbol, 'ethereum');
      expect(hits.single.kind, HoldingKind.crypto);
      expect(hits.single.exchange, 'ETH');
      expect(hits.single.image, contains('coin-images.coingecko.com'));
      final stocks = await service.search('ethereum', currency: 'USD');
      expect(stocks.where((h) => h.kind == HoldingKind.crypto), isEmpty);
    });

    test('a coin is priced in dollars by its id', () async {
      final quote = await PriceService(client)
          .quoteFor(kind: HoldingKind.crypto, symbol: 'ethereum');
      expect(quote!.priceE4, 32005000);
      expect(quote.currency, 'USD');
    });

    test('only a CoinGecko logo address is trusted', () {
      Holding withMeta(String meta) => Holding(
        id: 1,
        accountId: 1,
        kind: HoldingKind.crypto,
        name: 'Ethereum',
        meta: meta,
      );
      expect(
        withMeta('{"image":"https://coin-images.coingecko.com/a.png"}')
            .imageUrl,
        isNotNull,
      );
      expect(
        withMeta('{"image":"https://evil.example/a.png"}').imageUrl,
        isNull,
      );
      expect(withMeta('not json').imageUrl, isNull);
    });
  });
}
