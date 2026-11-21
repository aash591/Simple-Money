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
import 'package:simple_money/domain/metal.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/holding_store.dart';
import 'package:simple_money/ui/more/portfolio/add_holding_screen.dart';
import 'package:simple_money/ui/more/portfolio/portfolio_sheets.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

String _chart(String currency, double close) => jsonEncode({
  'chart': {
    'result': [
      {
        'meta': {'currency': currency, 'gmtoffset': 0},
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

http.Client _yahoo() => MockClient((request) async {
  final path = Uri.decodeComponent(request.url.path);
  if (path.contains('GC=F')) return http.Response(_chart('USD', 3000), 200);
  if (path.contains('SI=F')) return http.Response(_chart('USD', 40), 200);
  if (path.contains('INR=X')) return http.Response(_chart('INR', 80), 200);
  return http.Response('', 404);
});

void main() {
  test('purity reads in carats for gold and as a number for the rest', () {
    expect(MetalType.gold.purityLabel(916), '22K');
    expect(MetalType.gold.purityLabel(999), '24K');
    expect(MetalType.silver.purityLabel(925), '925');
    expect(MetalType.fraction(999), 1.0);
    expect(MetalType.fraction(916), 0.916);
  });

  test('a typed purity reads as parts per thousand', () {
    int? gold(String t) => MetalType.gold.parsePurity(t);
    // K is carats, 1 to 24; a plain number is fineness.
    expect(gold('22K'), 916);
    expect(gold('22k'), 916);
    expect(gold('24K'), 999);
    expect(gold('18K'), 750);
    expect(gold('21K'), 875);
    expect(gold('916'), 916);
    expect(gold('750'), 750);
    expect(gold('30K'), isNull);
    expect(gold('0K'), isNull);
    expect(gold('1000'), isNull);
    expect(gold('abc'), isNull);
    expect(gold(''), isNull);
    expect(gold('0'), isNull);
    // The same for every metal.
    expect(MetalType.silver.parsePurity('925'), 925);
    expect(MetalType.silver.parsePurity('22K'), 916);
    expect(MetalType.silver.parsePurity('1000'), isNull);
    expect(MetalType.silver.parsePurity('30K'), isNull);
    expect(MetalType.platinum.parsePurity('950'), 950);
    expect(MetalType.platinum.parsePurity('1200'), isNull);
  });

  test('a purity is shown the other way round', () {
    expect(MetalType.gold.purityEquals('22K', 916), '22K = 916');
    expect(MetalType.gold.purityEquals('916', 916), '916 = 22K');
    expect(MetalType.gold.purityEquals('750', 750), '750 = 18K');
    expect(MetalType.gold.purityEquals('800', 800), '800 = 19.2K');
    expect(MetalType.silver.purityEquals('925', 925), '925 = 22.2K');
    expect(MetalType.silver.purityEquals('22K', 916), '22K = 916');
    expect(MetalType.gold.purityLabel(875), '21K');
  });

  test('metal details round-trip and make one symbol per metal and purity', () {
    const d = MetalDetails(metal: MetalType.gold, fineness: 916);
    expect(d.summary, 'Gold · 22K');
    expect(d.symbol, 'gold-916');
    final back = MetalDetails.parse(jsonEncode(d.toJson()))!;
    expect(back.metal, MetalType.gold);
    expect(back.fineness, 916);
    expect(MetalDetails.parse('not json'), isNull);
    expect(MetalDetails.parse(null), isNull);
  });

  test(
    'the international price is per gram of the purity, in dollars',
    () async {
      final quote = await PriceService(_yahoo()).quoteFor(
        kind: HoldingKind.metal,
        symbol: 'gold-916',
        meta: '{"metal":"gold","purity":916}',
      );
      // 3000 USD an ounce, a troy ounce being 31.1035 g, of 22K gold.
      expect(quote!.currency, 'USD');
      expect(quote.priceE4 / 10000, closeTo(3000 / 31.1034768 * .916, .001));
    },
  );

  test('priced in the account currency, converted from dollars', () async {
    final quote = await PriceService(_yahoo()).quoteFor(
      kind: HoldingKind.metal,
      symbol: 'silver-999',
      currency: 'INR',
      meta: '{"metal":"silver","purity":999}',
    );
    expect(quote!.currency, 'INR');
    expect(quote.priceE4 / 10000, closeTo(40 / 31.1034768 * 80, .01));
  });

  test('a currency with no rate gets no price', () async {
    final quote = await PriceService(_yahoo()).quoteFor(
      kind: HoldingKind.metal,
      symbol: 'silver-999',
      currency: 'XYZ',
      meta: '{"metal":"silver","purity":999}',
    );
    expect(quote, isNull);
  });

  group('adding metal', () {
    late AppDatabase db;
    late AccountStore accounts;
    late HoldingStore store;
    late int broker;
    AddedHolding? result;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      result = null;
      db = AppDatabase(NativeDatabase.memory());
      accounts = AccountStore(AccountRepository(db));
      store = HoldingStore(
        HoldingRepository(db),
        accountStore: accounts,
        prices: PriceService(_yahoo()),
      );
      await accounts.save(
        name: 'Home locker',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
        broker: true,
        place: 'inHand',
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

    Future<void> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
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
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
    }

    Future<void> settleNetwork(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('metals are listed ready, then gold saves with its purity and '
        'the international price', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('holding-type-metal')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hit-gold')), findsOneWidget);
      expect(find.byKey(const Key('hit-silver')), findsOneWidget);
      expect(find.byKey(const Key('hit-platinum')), findsOneWidget);
      expect(find.byKey(const Key('hit-palladium')), findsOneWidget);

      await tester.enterText(find.byKey(const Key('holding-search')), 'plat');
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('hit-gold')), findsNothing);
      expect(find.byKey(const Key('hit-platinum')), findsOneWidget);
      await tester.enterText(find.byKey(const Key('holding-search')), '');
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const Key('hit-gold')));
      await tester.pumpAndSettle();
      await settleNetwork(tester);
      expect(find.byKey(const Key('holding-price')), findsOneWidget);
      expect(find.text('Gold 22K'), findsOneWidget);
      expect(find.text('Physical'), findsNothing);

      await tester.enterText(find.byKey(const Key('metal-purity')), '18k');
      await tester.pump(const Duration(milliseconds: 700));
      await settleNetwork(tester);
      expect(find.text('Gold 18K'), findsOneWidget);

      // Something that isn't a purity can't be saved.
      await tester.enterText(find.byKey(const Key('metal-purity')), 'abc');
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter carats'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('metal-purity')), '30k');
      await tester.pumpAndSettle();
      expect(find.textContaining('Enter carats'), findsOneWidget);
      await tester.enterText(find.byKey(const Key('metal-purity')), '750');
      await tester.pump(const Duration(milliseconds: 700));
      await settleNetwork(tester);

      await tester.tap(find.text('Save'));
      await settleNetwork(tester);
      final holding = store.byId(result!.id)!;
      expect(holding.kind, HoldingKind.metal);
      expect(holding.name, 'Gold 18K');
      expect(holding.priceSource, 'metal_world');
      // Priced in the account's own currency, so there is no conversion.
      expect(holding.currency, 'INR');
      expect(holding.metalDetails!.fineness, 750);
      expect(holding.lastPriceE4, isNotNull);
    });

    test('a purchase never replaces the price from its source', () async {
      final id = await store.saveHolding(
        accountId: broker,
        kind: HoldingKind.metal,
        name: 'Gold 22K',
        symbol: 'gold-916',
        exchange: '',
        priceSource: 'metal_world',
        currency: 'INR',
        meta: '{"metal":"gold","purity":916}',
      );
      var holding = store.byId(id)!;
      await store.setPrice(holding, 100000000, DateTime(2026, 11, 20));
      holding = store.byId(id)!;
      await store.addTrade(
        holding: holding,
        type: TradeType.buy,
        date: DateTime(2026, 11, 21),
        unitsE6: 1000000,
        priceE4: 80000000,
        amountMinor: 800000,
      );
      expect(store.byId(id)!.lastPriceE4, 100000000);
    });

    testWidgets('the price sheet fetches the latest price from the source', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final id = await store.saveHolding(
        accountId: broker,
        kind: HoldingKind.metal,
        name: 'Gold 22K',
        symbol: 'gold-916',
        exchange: '',
        priceSource: 'metal_world',
        currency: 'INR',
        meta: '{"metal":"gold","purity":916}',
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showPriceSheet(
                  context,
                  store: store,
                  holding: store.byId(id)!,
                  broker: accounts.byId(broker)!,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fetch-latest')));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      // 3000 USD an ounce, in rupees at 80, for 22K gold.
      expect(
        find.text((3000 / 31.1034768 * .916 * 80).toStringAsFixed(4)),
        findsOneWidget,
      );
      expect(find.textContaining('international gold price'), findsOneWidget);
      await tester.tap(find.text('Save price'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 150)),
      );
      await tester.pumpAndSettle();
      expect(
        store.byId(id)!.lastPriceE4! / 10000,
        closeTo(3000 / 31.1034768 * .916 * 80, .01),
      );
    });

    testWidgets('a metal added by hand is priced by hand', (tester) async {
      await open(tester);
      await tester.tap(find.byKey(const Key('holding-type-metal')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('holding-manual')));
      await tester.pumpAndSettle();
      expect(find.text('Purity'), findsNothing);
      await tester.enterText(find.byKey(const Key('holding-name')), 'Copper');
      await tester.pump();
      await tester.tap(find.text('Save'));
      await settleNetwork(tester);
      final holding = store.byId(result!.id)!;
      expect(holding.name, 'Copper');
      expect(holding.kind, HoldingKind.metal);
      expect(holding.metalDetails, isNull);
      expect(holding.lastPriceE4, isNull);
    });
  });
}
