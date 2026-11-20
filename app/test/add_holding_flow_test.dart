import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/prices/price_service.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/holding_repository.dart';
import 'package:simple_money/domain/holding.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/domain/markets.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/holding_store.dart';
import 'package:simple_money/ui/more/portfolio/add_holding_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

String _chart({required String currency, required double close}) => jsonEncode({
  'chart': {
    'result': [
      {
        'meta': {'currency': currency, 'gmtoffset': 19800},
        'timestamp': [1763500000],
        'indicators': {
          'quote': [
            {
              'close': [close],
            },
          ],
        },
      },
    ],
  },
});

const _searchResponse = {
  'quotes': [
    {
      'symbol': 'TCS.NS',
      'longname': 'Tata Consultancy Services',
      'exchDisp': 'NSE',
      'quoteType': 'EQUITY',
    },
    {
      'symbol': 'AAPL',
      'shortname': 'Apple Inc.',
      'exchDisp': 'NASDAQ',
      'quoteType': 'EQUITY',
    },
    {
      'symbol': 'NIFTYBEES.NS',
      'shortname': 'Nippon Nifty BeES',
      'exchDisp': 'NSE',
      'quoteType': 'ETF',
    },
  ],
};

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late HoldingStore store;
  late int broker;
  late List<Uri> requested;
  AddedHolding? result;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    result = null;
    requested = [];
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    final client = MockClient((request) async {
      requested.add(request.url);
      if (request.url.path.contains('/search')) {
        return http.Response(jsonEncode(_searchResponse), 200);
      }
      if (request.url.path.contains('TCS.NS')) {
        return http.Response(_chart(currency: 'INR', close: 3550.25), 200);
      }
      if (request.url.path.contains('AAPL')) {
        return http.Response(_chart(currency: 'USD', close: 190.5), 200);
      }
      return http.Response('', 404);
    });
    store = HoldingStore(
      HoldingRepository(db),
      accountStore: accounts,
      prices: PriceService(client),
    );
    await accounts.save(
      name: 'Zerodha',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      broker: true,
    );
    await accounts.load();
    broker = accounts.accounts.single.id;
    await store.load();
  });

  tearDown(() async {
    store.dispose();
    accounts.dispose();
    await db.close();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await Navigator.of(context).push(
                    MaterialPageRoute<AddedHolding>(
                      builder: (_) => AddHoldingScreen(
                        store: store,
                        broker: accounts.byId(broker)!,
                      ),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// The search and price lookups answer outside the test clock.
  Future<void> settleNetwork(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 800));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('type, then a search narrowed to the account\'s market', (
    tester,
  ) async {
    await mount(tester);
    expect(find.text('What are you adding?'), findsOneWidget);
    await tester.tap(find.byKey(const Key('holding-type-stock')));
    await tester.pumpAndSettle();

    // Nothing typed yet: a prompt with tappable examples, not an empty list.
    expect(find.textContaining('Step 2'), findsNothing); // no step counter
    expect(find.text('Type a company name or a ticker'), findsOneWidget);
    expect(find.text('TCS'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('holding-search')), 'tata');
    await settleNetwork(tester);
    // A rupee account starts on India: the Nasdaq stock and the ETF are out.
    expect(find.byKey(const Key('hit-TCS.NS')), findsOneWidget);
    expect(find.byKey(const Key('hit-AAPL')), findsNothing);
    expect(find.byKey(const Key('hit-NIFTYBEES.NS')), findsNothing);

    await tester.tap(find.byKey(const Key('market-us')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('hit-AAPL')), findsOneWidget);
    expect(find.byKey(const Key('hit-TCS.NS')), findsNothing);
    // A US stock in a rupee account is marked with its currency.
    expect(find.text('USD'), findsOneWidget);
  });

  testWidgets('pick a result, see its price, save it priced', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('holding-type-stock')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('holding-search')), 'tata');
    await settleNetwork(tester);
    await tester.tap(find.byKey(const Key('hit-TCS.NS')));
    await tester.pumpAndSettle();
    await settleNetwork(tester);

    // Details are filled in and the price is looked up before saving.
    expect(find.widgetWithText(TextField, 'Tata Consultancy Services'),
        findsOneWidget);
    expect(find.byKey(const Key('holding-price')), findsOneWidget);
    expect(find.textContaining('₹ 3,550.25'), findsOneWidget);

    await tester.tap(find.text('Save'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();

    final saved = store.holdings.single;
    expect(saved.name, 'Tata Consultancy Services');
    expect(saved.symbol, 'TCS.NS');
    expect(saved.kind, HoldingKind.stock);
    expect(saved.priceSource, PriceSourceId.yahoo);
    // Worth something at once, from the price the person just saw.
    expect(saved.lastPriceE4, 35502500);
    expect(result, (id: saved.id, addPurchase: false));
  });

  testWidgets('a price in another currency is kept in that currency', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('holding-type-stock')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('holding-search')), 'apple');
    await settleNetwork(tester);
    await tester.tap(find.byKey(const Key('market-us')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('hit-AAPL')));
    await tester.pumpAndSettle();
    await settleNetwork(tester);

    await tester.pumpAndSettle();
    await tester.tap(find.text('Add purchase'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    final saved = store.holdings.single;
    expect(saved.currency, 'USD');
    expect(saved.lastPriceE4, 1905000);
    expect(result?.addPurchase, isTrue);
  });

  testWidgets('adding by hand needs only a name', (tester) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('holding-type-etf')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('holding-manual')));
    await tester.pumpAndSettle();

    // No ticker: the price stays by hand, and Save waits for a name.
    expect(
      find.textContaining('No ticker, so the price stays'),
      findsOneWidget,
    );
    final cont = find.widgetWithText(GlassButton, 'Save');
    expect(tester.widget<GlassButton>(cont).onPressed, isNull);
    await tester.enterText(find.byKey(const Key('holding-name')), 'My ETF');
    await tester.pump();
    expect(tester.widget<GlassButton>(cont).onPressed, isNotNull);
  });

  testWidgets('moving between steps slides, rather than swapping', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('holding-type-stock')));
    await tester.pump(const Duration(milliseconds: 120));
    // Part-way through: the page leaving and the page arriving are both here.
    expect(find.text('What are you adding?'), findsOneWidget);
    expect(find.byKey(const Key('holding-search')), findsOneWidget);
    await tester.pumpAndSettle();
    // Once it has finished, only the new page is left.
    expect(find.text('What are you adding?'), findsNothing);
    expect(find.byKey(const Key('holding-search')), findsOneWidget);
  });

  testWidgets('back steps through the flow and leaves from the first', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byKey(const Key('holding-type-fund')));
    await tester.pumpAndSettle();
    expect(find.text('Type a fund name'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('What are you adding?'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('What are you adding?'), findsNothing);
    expect(result, isNull);
  });

  test('a ticker\'s market is read from its ending', () {
    expect(marketOfSymbol('TCS.NS')?.id, 'in');
    expect(marketOfSymbol('RELIANCE.BO')?.id, 'in');
    expect(marketOfSymbol('AAPL')?.id, 'us');
    expect(marketOfSymbol('VOD.L')?.id, 'uk');
    expect(marketOfSymbol('XYZ.ZZ'), isNull);
    expect(defaultMarketFor('INR')?.id, 'in');
    expect(defaultMarketFor('USD')?.id, 'us');
    expect(defaultMarketFor('BTC'), isNull);
    expect(marketOfSymbol('7203.T')?.id, 'jp');
    expect(marketOfSymbol('005930.KS')?.id, 'kr');
    expect(marketOfSymbol('2330.TW')?.id, 'tw');
    expect(marketOfSymbol('PETR4.SA')?.id, 'br');
    expect(marketOfSymbol('NESN.SW')?.id, 'ch');
  });

  test('every market is complete, and no ticker ending is in two', () {
    final endings = <String>{};
    for (final market in markets) {
      expect(market.stocks, isNotEmpty, reason: market.label);
      expect(market.currency, hasLength(3), reason: market.label);
      for (final ending in market.suffixes) {
        expect(endings.add(ending), isTrue, reason: 'duplicate $ending');
      }
    }
    expect(markets.length, greaterThan(30));
  });

  test('a fund listed as a stock is still recognised by its name', () {
    expect(looksLikeEtf('Nippon India ETF Nifty BeES'), isTrue);
    expect(looksLikeEtf('Nippon India ETF Gold BeES'), isTrue);
    expect(looksLikeEtf('Tata Consultancy Services'), isFalse);
    expect(looksLikeEtf('Indexa Capital'), isFalse);
  });

  test('every market lists only funds it can show, and none repeat', () {
    for (final market in markets) {
      expect(market.etfs.toSet().length, market.etfs.length);
    }
    expect(markets.firstWhere((m) => m.id == 'in').etfs, contains('GOLDBEES'));
  });
}
