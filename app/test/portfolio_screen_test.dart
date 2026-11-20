import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/holding_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/holding.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/holding_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/domain/app_icons.dart';
import 'package:simple_money/domain/bank_institution_icon.dart';
import 'package:simple_money/ui/components/action_buttons.dart';
import 'package:simple_money/ui/more/portfolio/add_broker_screen.dart';
import 'package:simple_money/ui/more/portfolio/portfolio_screens.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late HoldingStore holdings;
  late TransactionStore transactions;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
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
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Cash 9,000 left after buying 1,000, holding worth 1,200.
    expect(find.text('₹10,200'), findsWidgets);
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

  testWidgets('adding a broker is a full screen, like adding an account', (
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
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Add broker'));
    await tester.pumpAndSettle();
    expect(find.text('Add broker'), findsWidgets);
    expect(find.text('Cash in this account'), findsOneWidget);

    await tester.enterText(find.byKey(const Key('broker-name')), 'Groww');
    await tester.enterText(find.byKey(const Key('broker-cash')), '2500');
    await tester.pump();
    await tester.tap(
      find.descendant(
        of: find.byType(ActionButtonBar),
        matching: find.text('Add broker'),
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
        matching: find.text('Add broker'),
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
