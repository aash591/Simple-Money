import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/app.dart';
import 'package:simple_money/ui/components/liquid_glass_nav_bar.dart';
import 'package:simple_money/ui/components/private_amount.dart';
import 'package:simple_money/ui/transactions/transactions_screen.dart';
import 'package:simple_money/ui/more/more_screen.dart';
import 'package:simple_money/data/repositories/upi_repository.dart';
import 'package:simple_money/domain/upi_payment.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/home_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/charts/charts.dart';
import 'package:simple_money/domain/currency_scope.dart';
import 'package:simple_money/domain/currency.dart';
import 'package:simple_money/data/repositories/insights_repository.dart';
import 'package:simple_money/data/rates/exchange_rates.dart';
import 'package:simple_money/state/main_currency_controller.dart';
import 'package:simple_money/ui/components/currency_notice.dart';
import 'package:simple_money/ui/home/cards/currency_scope_bar.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'dart:convert';

void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late CategoryStore categories;
  late TransactionStore transactions;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    categories = CategoryStore(CategoryRepository(db));
    transactions = TransactionStore(TransactionRepository(db), accounts);
    await accounts.load();
    await categories.load();
    await transactions.load();
    await accounts.save(
      name: 'Wallet',
      currency: 'INR',
      digits: 2,
      openingBalance: 100000,
    );
  });
  tearDown(() async {
    accounts.dispose();
    categories.dispose();
    transactions.dispose();
    await db.close();
  });
  Future<void> expense(
    int value,
    DateTime date, {
    int? account,
    String? title,
  }) => transactions.addExpenseOrIncome(
    type: TransactionType.expense,
    amountMinor: value,
    accountId: account ?? accounts.accounts.first.id,
    categoryId: categories.categories.firstWhere((c) => c.name == 'Cafe').id,
    title: title,
    date: date,
  );

  testWidgets('Navigation slides in tab order, including non-adjacent tabs', (
    tester,
  ) async {
    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: accounts,
        categoryStore: categories,
        transactionStore: transactions,
      ),
    );
    await tester.pumpAndSettle();
    // Hidden tabs should not filter the ledger or query budgets on Home's
    // first frame. Once visited, they keep their element and scroll state.
    expect(find.byType(TransactionsScreen, skipOffstage: false), findsNothing);
    expect(find.byType(MoreScreen, skipOffstage: false), findsNothing);
    await tester.tap(find.text('More'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(find.byType(MoreScreen)).dx, greaterThan(0));
    await tester.pumpAndSettle();
    final more = tester.element(find.byType(MoreScreen));
    await tester.tap(find.text('Transactions'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.getTopLeft(find.byType(TransactionsScreen)).dx, lessThan(0));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(TransactionsScreen)).dx, 0);
    expect(
      tester.element(find.byType(MoreScreen, skipOffstage: false)),
      same(more),
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Tab follows the finger and a short drag returns to its origin', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({'transactions_range_kind': 'all'});
    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: accounts,
        categoryStore: categories,
        transactionStore: transactions,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(const Offset(400, 300));
    await gesture.moveBy(const Offset(-25, 0));
    await tester.pump();
    final before = tester.getTopLeft(find.byType(TransactionsScreen)).dx;
    await gesture.moveBy(const Offset(-60, 0));
    await tester.pump();
    expect(
      tester.getTopLeft(find.byType(TransactionsScreen)).dx,
      closeTo(before - 60, .1),
    );
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byType(TransactionsScreen)).dx, 0);
    expect(
      tester
          .widget<LiquidGlassNavBar>(find.byType(LiquidGlassNavBar))
          .selectedIndex,
      1,
    );
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final range in ['month', 'all']) {
    testWidgets('Transaction tab swipe respects $range range', (tester) async {
      SharedPreferences.setMockInitialValues({
        'transactions_range_kind': range,
      });
      await tester.pumpWidget(
        SimpleMoneyApp(
          accountStore: accounts,
          categoryStore: categories,
          transactionStore: transactions,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Transactions'));
      await tester.pumpAndSettle();
      await tester.drag(find.byType(TransactionsScreen), const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LiquidGlassNavBar>(find.byType(LiquidGlassNavBar))
            .selectedIndex,
        range == 'all' ? 2 : 1,
      );
      if (range == 'all') {
        // The reverse swipe returns to the adjacent tab.
        await tester.dragFrom(const Offset(200, 300), const Offset(300, 0));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<LiquidGlassNavBar>(find.byType(LiquidGlassNavBar))
              .selectedIndex,
          1,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets('Home automatically restores pending UPI review on cold start', (
    tester,
  ) async {
    await UpiRepository(db).put(
      PendingUpiPayment(
        id: 'restart',
        recipient: UpiRecipient.parse('upi://pay?pa=shop@bank&pn=Shop'),
        amountText: '',
        categoryId: null,
        accountId: null,
        date: DateTime.now(),
      ),
    );
    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: accounts,
        categoryStore: categories,
        transactionStore: transactions,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Is the payment completed?'), findsOneWidget);
    expect(find.text('Enter the amount paid'), findsNothing);
    expect(find.text('Yes'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Review payments later?'), findsOneWidget);
    await tester.tap(find.text('Review later').last);
    await tester.pumpAndSettle();
    expect((await UpiRepository(db).load()).single.id, 'restart');
    expect(transactions.transactions, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Is the payment completed?'), findsOneWidget);
  });

  testWidgets('Back closes transaction search before returning Home', (
    tester,
  ) async {
    await tester.pumpWidget(
      SimpleMoneyApp(
        accountStore: accounts,
        categoryStore: categories,
        transactionStore: transactions,
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search transactions'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('transaction-search')),
      'missing',
    );
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('transaction-search')), findsNothing);
    expect(
      tester
          .widget<LiquidGlassNavBar>(find.byType(LiquidGlassNavBar))
          .selectedIndex,
      1,
    );
    expect(find.byTooltip('Search transactions'), findsOneWidget);

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LiquidGlassNavBar>(find.byType(LiquidGlassNavBar))
          .selectedIndex,
      0,
    );

    // An offstage search must not consume back for another tab.
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search transactions'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(
            find.descendant(
              of: find.byKey(const Key('transaction-search')),
              matching: find.byType(TextField),
            ),
          )
          .controller!
          .text,
      isEmpty,
    );
    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<LiquidGlassNavBar>(find.byType(LiquidGlassNavBar))
          .selectedIndex,
      0,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('Home aggregates month boundaries, parent categories and currencies, excluding transfers', () async {
    await accounts.save(
      name: 'Bank',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
    );
    await accounts.save(
      name: 'Dollars',
      currency: 'USD',
      digits: 2,
      openingBalance: 0,
    );
    await expense(1000, DateTime(2026, 2, 1));
    await expense(
      2500,
      DateTime(2026, 2, 28, 23, 59),
      account: accounts.accounts[1].id,
    );
    await expense(700, DateTime(2026, 1, 31, 23, 59));
    await expense(800, DateTime(2026, 3, 1));
    await expense(
      99999,
      DateTime(2026, 2, 2),
      account: accounts.accounts[2].id,
    );
    await transactions.addExpenseOrIncome(
      type: TransactionType.income,
      amountMinor: 9000,
      accountId: accounts.accounts.first.id,
      categoryId: categories.categories
          .firstWhere((c) => c.name == 'Salary')
          .id,
      date: DateTime(2026, 2, 3),
    );
    await transactions.addTransfer(
      amountMinor: 600,
      fromAccountId: accounts.accounts.first.id,
      toAccountId: accounts.accounts[1].id,
      date: DateTime(2026, 2, 4),
    );
    final result = await HomeRepository(db).load(DateTime(2026, 2), 'INR', 2);
    expect(result.spent, 3500);
    expect(result.income, 9000);
    expect(result.previousSpent, 700);
    expect(result.dailyExpenses.length, 28);
    expect(result.dailyExpenses.first, 1000);
    expect(result.dailyExpenses.last, 2500);
    final food = result.categories.single;
    expect((food.name, food.amount), ('Food & Beverage', 3500));
    expect(result.recent.length, 4);
    expect(result.recent.first.date, DateTime(2026, 2, 28, 23, 59));
    final empty = await HomeRepository(db).load(DateTime(2024, 2), 'INR', 2);
    expect(empty.dailyIncome.length, 29);
    expect(empty.spent, 0);
    expect(empty.categories, isEmpty);
  });

  test(
    'combined queries convert grouped currencies and preserve exclusions',
    () async {
      await accounts.save(
        name: 'USD',
        currency: 'USD',
        digits: 2,
        openingBalance: 1000,
      );
      await accounts.save(
        name: 'JPY',
        currency: 'JPY',
        digits: 0,
        openingBalance: 2000,
      );
      await accounts.save(
        name: 'Bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
      );
      await expense(1000, DateTime(2026, 2, 1));
      await expense(
        125,
        DateTime(2026, 2, 1),
        account: accounts.accounts[1].id,
      );
      await expense(
        200,
        DateTime(2026, 2, 2),
        account: accounts.accounts[2].id,
      );
      await expense(
        100,
        DateTime(2026, 1, 5),
        account: accounts.accounts[2].id,
      );
      final salary = categories.categories
          .firstWhere((c) => c.name == 'Salary')
          .id;
      for (final (id, amount) in [
        (accounts.accounts[0].id, 8000),
        (accounts.accounts[1].id, 100),
      ]) {
        await transactions.addExpenseOrIncome(
          type: TransactionType.income,
          amountMinor: amount,
          accountId: id,
          categoryId: salary,
          date: DateTime(2026, 2, 3),
        );
      }
      await transactions.addTransfer(
        amountMinor: 500,
        fromAccountId: accounts.accounts[0].id,
        toAccountId: accounts.accounts[3].id,
        date: DateTime(2026, 2, 4),
      );
      final debtCategory = await db.customInsert(
        "INSERT INTO categories(name, type, sort_order) VALUES ('Debt test', 'debt_loan', 99)",
      );
      await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 100,
        accountId: accounts.accounts[0].id,
        categoryId: debtCategory,
        date: DateTime(2026, 2, 5),
      );
      const scope = CombinedCurrency('INR', 2, rates: {'USD': .0125, 'JPY': 2});
      final summary = await HomeRepository(db)
          .loadScope(DateTime(2026, 2), scope);
      expect(summary.spent, 21000);
      expect(summary.income, 16000);
      expect(summary.previousSpent, 5000);
      expect(summary.dailyExpenses[0], 11000);
      expect(summary.dailyExpenses[1], 10000);
      expect(summary.categories.single.amount, 21000);
      expect(summary.missingCurrencies, isEmpty);
      final insights = await InsightsRepository(db)
          .loadScope(DateTime(2026, 2), scope);
      expect(insights.flows.last.spent, 21000);
      expect(insights.flows.last.income, 16000);
      expect(insights.previousDailyExpenses[4], 5000);
      expect(
        insights.balances.last,
        269900,
      ); // Debt affects balance, not spending.
      expect(insights.balances[4], 275000);
      final partial = await HomeRepository(db)
          .loadScope(DateTime(2026, 2), const CombinedCurrency('INR', 2));
      expect(partial.spent, 1000);
      expect(partial.missingCurrencies, {'USD', 'JPY'});
      final native = await HomeRepository(db)
          .loadScope(DateTime(2026, 2), const SingleCurrency('USD', 2));
      expect(native.spent, 125);
      expect(native.income, 100);
      expect(
        native.recent.every((t) => t.accountId == accounts.accounts[1].id),
        isTrue,
      );
    },
  );

  testWidgets(
    'mixed Home defaults to all accounts and responds to main currency changes',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(() async {
        await accounts.save(
          name: 'Dollars',
          currency: 'USD',
          digits: 2,
          openingBalance: 1000,
        );
        await expense(
          125,
          DateTime.now(),
          account: accounts.accounts[1].id,
          title: 'Dollar lunch',
        );
      });
      final date = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode(
            request.url.path.endsWith('usd.json')
                ? {
                    'date': date,
                    'usd': {'usd': 1, 'inr': 80},
                  }
                : {
                    'date': date,
                    'inr': {'inr': 1, 'usd': .0125},
                  },
          ),
          200,
        ),
      );
      final controller = MainCurrencyController(
        accounts,
        ExchangeRates(db, client),
        isOnline: () async => true,
      );
      await tester.runAsync(() => controller.start());
      await tester.runAsync(() => controller.refresh(force: true));
      await tester.pumpWidget(
        SimpleMoneyApp(
          accountStore: accounts,
          categoryStore: categories,
          transactionStore: transactions,
          mainCurrencyController: controller,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('All accounts · INR'), findsOneWidget);
      CurrencyScopeBar bar() =>
          tester.widget<CurrencyScopeBar>(find.byType(CurrencyScopeBar));
      expect(bar().scope, isA<CombinedCurrency>());
      // Rates are fresh and cover every account, so nothing is flagged; the
      // date is stated once on the scope bar instead of under every card.
      expect(find.byType(CurrencyNotice), findsWidgets);
      expect(find.textContaining('Excludes'), findsNothing);
      expect(find.textContaining('Rates '), findsOneWidget);
      // Returning from native authentication refreshes the account store.
      // The same amount State must survive the loading frame and the result.
      final amount = find.byWidgetPredicate(
        (widget) => widget is PrivateAmount && widget.label == 'Net savings',
      );
      await tester.ensureVisible(amount);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Show net savings'));
      await tester.pumpAndSettle();
      final revealedState = tester.state(amount);
      final revealedSize = tester.getSize(amount);
      final refresh = accounts.load();
      await tester.pump();
      expect(tester.state(amount), same(revealedState));
      expect(find.byTooltip('Hide net savings'), findsOneWidget);
      await tester.runAsync(() async {
        await refresh;
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(tester.state(amount), same(revealedState));
      expect(tester.getSize(amount), revealedSize);
      expect(find.byTooltip('Hide net savings'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.byType(CurrencyScopeBar),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      // The picker is a sheet, matching the month filter beside it.
      await tester.tap(find.text('All accounts · INR'));
      await tester.pumpAndSettle();
      expect(find.text('Accounts to include'), findsOneWidget);
      await tester.tap(find.text('USD accounts').last);
      await tester.pumpAndSettle();
      expect(bar().scope, const SingleCurrency('USD', 2));
      // A single-currency scope converts nothing, so the rate line goes away.
      expect(find.textContaining('Rates '), findsNothing);
      bar().onChanged(controller.combined);
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await controller.setCurrency(
          const Currency(
            code: 'USD',
            digits: 2,
            territory: 'US',
            country: 'United States',
            name: 'US Dollar',
          ),
        );
        // Let the database queries started by the controller's real-async
        // listener finish before returning to the widget clock.
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.text('All accounts · USD'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
      client.close();
    },
  );

  testWidgets(
    'Home refreshes and opens the chosen month and transaction details',
    (tester) async {
      tester.view.physicalSize = const Size(430, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        SimpleMoneyApp(
          accountStore: accounts,
          categoryStore: categories,
          transactionStore: transactions,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('No spending this month.'), findsOneWidget);
      await tester.runAsync(() async {
        await expense(12345, DateTime.now(), title: 'Lunch today');
        await Future<void>.delayed(const Duration(milliseconds: 150));
      });
      await tester.pumpAndSettle();
      expect(find.byType(CalloutDonutChart), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Lunch today'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Lunch today'));
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      final now = DateTime.now();
      await tester.scrollUntilVisible(
        find.byTooltip('Theme: System default'),
        -300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      final previous = DateTime(now.year, now.month - 1);
      await tester.tap(find.text(DateFormat.yMMMM().format(now)));
      await tester.pumpAndSettle();
      if (previous.year != now.year) {
        await tester.tap(find.text('${now.year}').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('${previous.year}').last);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(DateFormat.MMM().format(previous)).last);
      await tester.pumpAndSettle();
      expect(find.text('No spending this month.'), findsOneWidget);
      await tester.tap(find.byTooltip('View month transactions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widgetList<FractionalTranslation>(
              find.byType(FractionalTranslation),
            )
            .any((w) => w.translation.dx > 0 && w.translation.dx < 1),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.text('No transactions in this period'), findsOneWidget);
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(DateFormat.yMMMM().format(previous)));
      await tester.pumpAndSettle();
      if (previous.year != now.year) {
        await tester.tap(find.text('${previous.year}').last);
        await tester.pumpAndSettle();
        await tester.tap(find.text('${now.year}').last);
        await tester.pumpAndSettle();
      }
      await tester.tap(find.text(DateFormat.MMM().format(now)).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('View month transactions'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        tester
            .widgetList<FractionalTranslation>(
              find.byType(FractionalTranslation),
            )
            .any((w) => w.translation.dx > 0 && w.translation.dx < 1),
        isTrue,
      );
      await tester.pumpAndSettle();
      expect(find.text('Lunch today'), findsOneWidget);
      await tester.tap(find.text('Home'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Theme: System default'));
      await tester.pumpAndSettle();
      tester.view.physicalSize = const Size(320, 640);
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      // Every card and chart lays out at a narrow width and large text.
      for (final card in [
        find.text('Spending pace'),
        find.byType(CalloutDonutChart),
        find.text('Money in vs money out'),
        find.text('Net worth'),
      ]) {
        await tester.scrollUntilVisible(
          card,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
