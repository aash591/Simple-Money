import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/holding_repository.dart';
import 'package:simple_money/domain/holding.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/holding_store.dart';
import 'package:simple_money/state/pro_controller.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/ui/more/portfolio/add_holding_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  final pro = ProController.instance;
  setUp(() => ProController.enforceLimits = true);
  tearDown(() {
    pro.subscribed = false;
    ProController.enforceLimits = true;
  });

  group('Pro in a debug build', () {
    test('is the free plan, whatever the account bought, unless asked', () {
      // flutter run: a purchase does not count; PRO_IN_DEBUG=true makes it Pro.
      expect(
        ProController.purchaseCounts(debug: true, proInDebug: false),
        isFalse,
      );
      expect(
        ProController.purchaseCounts(debug: true, proInDebug: true),
        isTrue,
      );
      // Profile and release builds follow what was bought.
      expect(
        ProController.purchaseCounts(debug: false, proInDebug: false),
        isTrue,
      );
    });

    test('tests still count a purchase', () {
      pro.subscribed = true;
      expect(pro.isPro, isTrue);
    });
  });

  group('the free limits', () {
    test('are 7 for funds and ETFs, 3 for crypto, metal and forex', () {
      expect(ProController.freeHoldingsOf(HoldingKind.stock), isNull);
      expect(ProController.freeHoldingsOf(HoldingKind.etf), 7);
      expect(ProController.freeHoldingsOf(HoldingKind.fund), 7);
      expect(ProController.freeHoldingsOf(HoldingKind.crypto), 3);
      expect(ProController.freeHoldingsOf(HoldingKind.metal), 3);
      expect(ProController.freeHoldingsOf(HoldingKind.forex), 3);
    });

    test('hold back only the holding after the last free one', () {
      expect(pro.mayAddHolding(HoldingKind.crypto, 2), isTrue);
      expect(pro.mayAddHolding(HoldingKind.crypto, 3), isFalse);
      // Already over (kept from before): nothing more, nothing taken away.
      expect(pro.mayAddHolding(HoldingKind.crypto, 9), isFalse);
      expect(pro.mayAddHolding(HoldingKind.fund, 6), isTrue);
      expect(pro.mayAddHolding(HoldingKind.fund, 7), isFalse);
      expect(pro.mayAddHolding(HoldingKind.stock, 500), isTrue);
    });

    test('every second holding of a kind takes a short ad', () {
      // The 1st is free, the 2nd takes an ad, the 3rd is free, the 4th...
      expect(
        [for (var held = 0; held < 6; held++) pro.holdingTakesAd(held)],
        [false, true, false, true, false, true],
      );
      pro.subscribed = true;
      expect(pro.holdingTakesAd(1), isFalse);
      pro.subscribed = false;
      ProController.enforceLimits = false;
      expect(pro.holdingTakesAd(1), isFalse);
    });

    test('do not hold with Pro, or while limits are off', () {
      pro.subscribed = true;
      expect(pro.mayAddHolding(HoldingKind.forex, 50), isTrue);
      pro.subscribed = false;
      ProController.enforceLimits = false;
      expect(pro.mayAddHolding(HoldingKind.forex, 50), isTrue);
    });
  });

  group('adding a holding', () {
    late AppDatabase db;
    late AccountStore accounts;
    late HoldingStore store;
    late int broker;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      db = AppDatabase(NativeDatabase.memory());
      accounts = AccountStore(AccountRepository(db));
      store = HoldingStore(HoldingRepository(db), accountStore: accounts);
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

    Future<void> have(HoldingKind kind, int count) async {
      for (var i = 0; i < count; i++) {
        await store.saveHolding(
          accountId: broker,
          kind: kind,
          name: '${kind.label} $i',
          symbol: 'S$i',
        );
      }
    }

    Future<void> mount(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: AddHoldingScreen(store: store, broker: accounts.byId(broker)!),
        ),
      );
      await tester.pumpAndSettle();
    }

    Future<void> choose(WidgetTester tester, HoldingKind kind) async {
      await tester.tap(find.byKey(Key('holding-type-${kind.name}')));
      await tester.pumpAndSettle();
    }

    testWidgets('stops at the free limit and offers Pro', (tester) async {
      await have(HoldingKind.crypto, 3);
      await mount(tester);
      await choose(tester, HoldingKind.crypto);
      expect(find.text('3 crypto holdings is the free limit'), findsOneWidget);
      expect(find.text('See Pro'), findsOneWidget);

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      // Still choosing what to add.
      expect(find.text('What are you adding?'), findsOneWidget);
    });

    testWidgets('lets the last free one through', (tester) async {
      await have(HoldingKind.crypto, 2);
      await mount(tester);
      await choose(tester, HoldingKind.crypto);
      expect(find.textContaining('free limit'), findsNothing);
      expect(find.text('What are you adding?'), findsNothing);
    });

    testWidgets('counts each kind on its own, and never stocks', (
      tester,
    ) async {
      await have(HoldingKind.crypto, 3);
      await have(HoldingKind.stock, 12);
      await mount(tester);
      await choose(tester, HoldingKind.stock);
      expect(find.textContaining('free limit'), findsNothing);
      expect(find.text('What are you adding?'), findsNothing);
    });

    testWidgets('holds funds and ETFs at 7', (tester) async {
      await have(HoldingKind.fund, 7);
      await mount(tester);
      await choose(tester, HoldingKind.fund);
      expect(find.text('7 mutual funds is the free limit'), findsOneWidget);
    });

    /// Through to the Save button, typing the name of an ETF by hand.
    Future<void> saveByHand(WidgetTester tester, HoldingKind kind) async {
      await choose(tester, kind);
      await tester.tap(find.byKey(const Key('holding-manual')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('holding-name')), 'My one');
      await tester.pump();
      await tester.tap(find.widgetWithText(GlassButton, 'Save'));
      await tester.pumpAndSettle();
    }

    testWidgets('the first of a kind saves with no ad', (tester) async {
      await mount(tester);
      await saveByHand(tester, HoldingKind.etf);
      expect(find.textContaining('short ad'), findsNothing);
      expect(
        store.holdings.where((h) => h.kind == HoldingKind.etf),
        hasLength(1),
      );
    });

    testWidgets('the second takes a short ad, saying how many are left', (
      tester,
    ) async {
      await have(HoldingKind.etf, 1);
      await mount(tester);
      await saveByHand(tester, HoldingKind.etf);
      expect(find.text('Watch a short ad to add this holding'), findsOneWidget);
      expect(find.textContaining('ETF 2 of 7'), findsOneWidget);
      expect(find.text('Get Pro instead'), findsOneWidget);
      // Nothing is saved until the ad was watched.
      expect(
        store.holdings.where((h) => h.kind == HoldingKind.etf),
        hasLength(1),
      );

      await tester.tap(find.text('Watch ad'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      expect(
        store.holdings.where((h) => h.kind == HoldingKind.etf),
        hasLength(2),
      );
    });

    testWidgets('saying no to the ad saves nothing', (tester) async {
      await have(HoldingKind.etf, 1);
      await mount(tester);
      await saveByHand(tester, HoldingKind.etf);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(
        store.holdings.where((h) => h.kind == HoldingKind.etf),
        hasLength(1),
      );
      // Still on the form.
      expect(find.byKey(const Key('holding-name')), findsOneWidget);
    });

    testWidgets('stocks have no limit but still take an ad every second one', (
      tester,
    ) async {
      await have(HoldingKind.stock, 3);
      await mount(tester);
      await saveByHand(tester, HoldingKind.stock);
      expect(find.text('Watch a short ad to add this holding'), findsOneWidget);
      expect(find.textContaining('Every second one'), findsOneWidget);
    });

    testWidgets('Pro adds with no ad', (tester) async {
      pro.subscribed = true;
      await have(HoldingKind.etf, 1);
      await mount(tester);
      await saveByHand(tester, HoldingKind.etf);
      expect(find.textContaining('short ad'), findsNothing);
      expect(
        store.holdings.where((h) => h.kind == HoldingKind.etf),
        hasLength(2),
      );
    });

    testWidgets('is open with Pro', (tester) async {
      pro.subscribed = true;
      await have(HoldingKind.metal, 5);
      await mount(tester);
      await choose(tester, HoldingKind.metal);
      expect(find.textContaining('free limit'), findsNothing);
      expect(find.text('What are you adding?'), findsNothing);
    });
  });
}
