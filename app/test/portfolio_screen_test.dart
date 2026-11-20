import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/holding_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/holding.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/holding_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/domain/app_icons.dart';
import 'package:simple_money/domain/bank_institution_icon.dart';
import 'package:simple_money/ui/components/action_buttons.dart';
import 'package:simple_money/ui/components/app_icon.dart';
import 'package:simple_money/ui/more/portfolio/add_broker_screen.dart';
import 'package:simple_money/ui/more/portfolio/portfolio_screens.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late HoldingStore holdings;
  late TransactionStore transactions;
  late CategoryStore categories;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    categories = CategoryStore(CategoryRepository(db));
    accounts = AccountStore(AccountRepository(db));
    holdings = HoldingStore(HoldingRepository(db), accountStore: accounts);
    transactions = TransactionStore(TransactionRepository(db), accounts);
    await accounts.save(
      name: 'Zerodha',
      currency: 'INR',
      digits: 2,
      openingBalance: 1000000,
      broker: true,
    );
    await accounts.load();
    final broker = accounts.accounts.single;
    final id = await holdings.saveHolding(
      accountId: broker.id,
      kind: HoldingKind.stock,
      name: 'TCS',
    );
    await holdings.addTrade(
      holding: holdings.byId(id)!,
      type: TradeType.buy,
      date: DateTime(2026, 2, 1),
      unitsE6: 10 * unitScale,
      priceE4: 100 * priceScale,
      amountMinor: 100000,
    );
    await holdings.setPrice(
      holdings.byId(id)!,
      120 * priceScale,
      DateTime(2026, 2, 2),
    );
  });

  tearDown(() async {
    categories.dispose();
    accounts.dispose();
    holdings.dispose();
    transactions.dispose();
    await db.close();
  });

  testWidgets('portfolio shows value, gain, then the holding behind it', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: PortfolioScreen(
          accounts: accounts,
          holdings: holdings,
          transactions: transactions,
          categories: categories,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // The holding is worth 1,200 (bought for 1,000); that is the value shown,
    // with the 9,000 of cash left beside it as funds.
    expect(find.text('₹1,200'), findsWidgets);
    expect(find.text('Portfolio value'), findsOneWidget);
    expect(find.text('Zerodha'), findsOneWidget);

    await tester.tap(find.text('Zerodha'));
    await tester.pumpAndSettle();
    expect(find.text('TCS'), findsOneWidget);
    expect(find.textContaining('+20.0%'), findsWidgets);

    await tester.tap(find.text('TCS'));
    await tester.pumpAndSettle();
    expect(find.text('Buy'), findsWidgets);
    expect(find.text('Sell'), findsOneWidget);
    expect(find.text('Dividend'), findsOneWidget);
    expect(find.textContaining('Buy 10 @'), findsOneWidget);
  });

  testWidgets('the broker list shows a broker\'s logo when it has one', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await accounts.save(
      name: 'Groww',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      broker: true,
      icon: brandIconKey('groww'),
    );
    await accounts.load();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: PortfolioScreen(
          accounts: accounts,
          holdings: holdings,
          transactions: transactions,
          categories: categories,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Groww has a logo; Zerodha, saved without one, keeps the chart icon.
    expect(find.byType(AppIcon), findsOneWidget);
    expect(find.text('Groww'), findsOneWidget);
    expect(find.text('Zerodha'), findsOneWidget);
  });

  Future<void> openAddInvestment(WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: PortfolioScreen(
          accounts: accounts,
          holdings: holdings,
          transactions: transactions,
          categories: categories,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add investment account'));
    await tester.pumpAndSettle();
  }

  Future<void> saveBroker(WidgetTester tester, String name) async {
    await tester.enterText(find.byKey(const Key('broker-name')), name);
    await tester.enterText(find.byKey(const Key('broker-cash')), '2500');
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(ActionButtonBar),
        matching: find.text('Add account'),
      ),
    );
    // The database answers outside the test clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('adding an account first asks where it is held', (
    tester,
  ) async {
    await openAddInvestment(tester);
    expect(find.text('Account type'), findsOneWidget);
    // An intro fills the top half; the choices start at the middle.
    expect(find.text('Where do you hold it?'), findsOneWidget);
    final screenMiddle = tester.view.physicalSize.height / 2;
    expect(
      tester.getCenter(find.text('Where do you hold it?')).dy,
      lessThan(screenMiddle),
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('place-broker'))).dy,
      greaterThan(screenMiddle),
    );
    // Only the broker place exists so far, with what it holds.
    expect(find.text('Broker or app'), findsOneWidget);
    expect(find.text('Stocks, ETFs and mutual funds'), findsOneWidget);
    expect(find.text('Cash in this account'), findsNothing);

    await tester.tap(find.byKey(const Key('place-broker')));
    await tester.pumpAndSettle();
    // Then the account's details, and on saving, its own screen.
    expect(find.text('Add account'), findsWidgets);
    expect(find.text('Cash in this account'), findsOneWidget);
    await saveBroker(tester, 'Groww');
    expect(find.byTooltip('Add holding'), findsOneWidget);
    expect(find.text('Nothing held here yet.'), findsNothing);
    // The kind of holding is chosen when adding one, not up front.
    await tester.tap(find.byTooltip('Add holding'));
    await tester.pumpAndSettle();
    expect(find.text('What are you adding?'), findsOneWidget);
    expect(find.text('Stocks'), findsOneWidget);
    expect(find.text('ETFs'), findsOneWidget);
    expect(find.text('Mutual funds'), findsOneWidget);
  });

  testWidgets('the portfolio tags each account with its kind', (tester) async {
    await openAddInvestment(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Accounts'), findsOneWidget);
    expect(find.textContaining('Broker · '), findsOneWidget);
  });

  testWidgets('a broker\'s screen lists its deposits and withdrawals', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await accounts.save(
      name: 'Bank',
      currency: 'INR',
      digits: 2,
      openingBalance: 500000,
    );
    await accounts.load();
    await categories.load();
    final broker = accounts.accounts.firstWhere((a) => a.name == 'Zerodha');
    final bank = accounts.accounts.firstWhere((a) => a.name == 'Bank');
    await transactions.addTransfer(
      amountMinor: 55500,
      fromAccountId: bank.id,
      toAccountId: broker.id,
      date: DateTime(2026, 3, 1, 10),
    );
    await transactions.addTransfer(
      amountMinor: 20000,
      fromAccountId: broker.id,
      toAccountId: bank.id,
      date: DateTime(2026, 3, 2, 10),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: BrokerScreen(
          brokerId: broker.id,
          accounts: accounts,
          holdings: holdings,
          transactions: transactions,
          categories: categories,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // They live on their own tab, beside the holdings.
    expect(find.text('₹555'), findsNothing);
    await tester.tap(find.text('Transfers'));
    await tester.pumpAndSettle();
    // Both entries are here, in the broker's own currency.
    expect(find.text('₹555'), findsOneWidget);
    expect(find.text('₹200'), findsOneWidget);
    // Money in and money out carry the Deposit and Withdraw arrows, not the
    // transfer swap arrows.
    expect(find.byIcon(Icons.swap_horiz_rounded), findsNothing);
    expect(
      find.descendant(
        of: find.byType(TabBarView),
        matching: find.byIcon(Icons.south_west_rounded),
      ),
      findsWidgets,
    );
    expect(
      find.descendant(
        of: find.byType(TabBarView),
        matching: find.byIcon(Icons.north_east_rounded),
      ),
      findsWidgets,
    );

    // The search narrows the list, and says so when nothing is left.
    await tester.enterText(find.byType(TextField), '555');
    await tester.pumpAndSettle();
    expect(find.text('₹555'), findsOneWidget);
    expect(find.text('₹200'), findsNothing);
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pumpAndSettle();
    expect(find.text('No transfers match.'), findsOneWidget);
    await tester.enterText(find.byType(TextField), '');

    // Swiping sideways goes back to the holdings tab.
    await tester.fling(find.byType(TabBarView), const Offset(400, 0), 1500);
    await tester.pumpAndSettle();
    expect(find.text('₹555'), findsNothing);
  });

  testWidgets('deleting a broker lives in the more menu, and still asks', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final broker = accounts.accounts.single;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: BrokerScreen(
          brokerId: broker.id,
          accounts: accounts,
          holdings: holdings,
          transactions: transactions,
          categories: categories,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // No delete button in the top bar; it is behind the more menu.
    expect(find.byTooltip('Delete account'), findsNothing);
    expect(find.text('Delete account'), findsNothing);
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    expect(find.text('Delete account'), findsOneWidget);
    await tester.tap(find.text('Delete account'));
    await tester.pumpAndSettle();
    expect(find.text('Delete Zerodha?'), findsOneWidget);
    // Nothing is removed until it is confirmed.
    expect(accounts.accounts.single.name, 'Zerodha');
  });

  testWidgets('a broker\'s own screen shows its logo in the header', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await accounts.save(
      name: 'Groww',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      broker: true,
      icon: brandIconKey('groww'),
    );
    await accounts.load();
    final groww = accounts.accounts.firstWhere((a) => a.name == 'Groww');
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: BrokerScreen(
          brokerId: groww.id,
          accounts: accounts,
          holdings: holdings,
          transactions: transactions,
          categories: categories,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppIcon), findsOneWidget);
    expect(find.text('Groww'), findsOneWidget);
    // Nothing held: no empty-state text or big button, just the add button.
    expect(find.text('Nothing held here yet.'), findsNothing);
    expect(find.text('Add stock or fund'), findsNothing);
    expect(find.byTooltip('Add holding'), findsOneWidget);
  });

  testWidgets('adding a broker is a full screen, like adding an account', (
    tester,
  ) async {
    await openAddInvestment(tester);
    await tester.tap(find.byKey(const Key('place-broker')));
    await tester.pumpAndSettle();
    expect(find.text('Add account'), findsWidgets);
    expect(find.text('Cash in this account'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('broker-name')), 'Groww');
    await tester.enterText(find.byKey(const Key('broker-cash')), '2500');
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(ActionButtonBar),
        matching: find.text('Add account'),
      ),
    );
    // The database answers outside the test clock.
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    final groww = accounts.accounts.firstWhere((a) => a.name == 'Groww');
    expect(groww.isBroker, isTrue);
    expect(groww.balanceMinor, 250000);
  });

  testWidgets('typing a broker we have a logo for picks that logo', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: AddBrokerScreen(accounts: accounts),
      ),
    );
    await tester.enterText(find.byKey(const Key('broker-name')), 'Zerodha Kite');
    await tester.enterText(find.byKey(const Key('broker-cash')), '10');
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(ActionButtonBar),
        matching: find.text('Add account'),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pumpAndSettle();
    final saved = accounts.accounts.firstWhere((a) => a.name == 'Zerodha Kite');
    expect(saved.icon, brandIconKey('zerodha'));
    for (final typed in ['zerodha', 'ZERODHA', '  Zerodha ', 'Zerodha Kite']) {
      expect(matchingInstitutionIcon(typed), brandIconKey('zerodha'), reason: typed);
    }
    expect(matchingInstitutionIcon('My Own Broker'), isNull);
    expect(matchingInstitutionIcon('Zer'), isNull);
  });
}
