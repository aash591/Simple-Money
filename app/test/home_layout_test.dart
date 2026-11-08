import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/insights_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/home_layout.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/more/home_layout_screen.dart';
import 'package:simple_money/ui/more/home_card_preview.dart';

void main() {
  testWidgets('Every card has a preview at narrow width with large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final id in HomeCardId.values) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: HomeCardPreview(id: id),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: id.name);
    }
  });
  group('HomeLayout', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('starts with every card shown in the default order', () async {
      final layout = HomeLayout();
      await layout.restore();
      expect(layout.order, HomeCardId.values);
      expect(layout.visible, HomeCardId.values);
      expect(layout.isDefault, isTrue);
      layout.dispose();
    });

    test('saves order and hidden cards, and restores them', () async {
      final layout = HomeLayout();
      await layout.restore();
      layout.move(HomeCardId.recentTransactions.index, 0);
      layout.setVisible(HomeCardId.netWorth, false);
      expect(layout.order.first, HomeCardId.recentTransactions);
      expect(layout.visible, isNot(contains(HomeCardId.netWorth)));
      expect(layout.isDefault, isFalse);
      await Future<void>.delayed(Duration.zero);
      layout.dispose();

      final restored = HomeLayout();
      await restored.restore();
      expect(restored.order.first, HomeCardId.recentTransactions);
      expect(restored.isVisible(HomeCardId.netWorth), isFalse);
      restored.reset();
      expect(restored.isDefault, isTrue);
      restored.dispose();
    });

    test('drops unknown saved cards and slots new ones in after their '
        'default neighbour', () async {
      SharedPreferences.setMockInitialValues({
        HomeLayout.orderKey: ['recentTransactions', 'gone', 'overview'],
      });
      final layout = HomeLayout();
      await layout.restore();
      expect(layout.order.toSet(), HomeCardId.values.toSet());
      expect(layout.order.length, HomeCardId.values.length);
      // Kept in the saved relative order.
      expect(
        layout.order.indexOf(HomeCardId.recentTransactions),
        lessThan(layout.order.indexOf(HomeCardId.overview)),
      );
      // SMS history follows overview, including for existing saved layouts.
      expect(
        layout.order.indexOf(HomeCardId.smsHistory),
        layout.order.indexOf(HomeCardId.overview) + 1,
      );
      layout.dispose();
    });

    testWidgets('the arrangement screen hides a card', (tester) async {
      final layout = HomeLayout();
      await tester.pumpWidget(
        MaterialApp(home: HomeLayoutScreen(layout: layout)),
      );
      expect(find.text('Upcoming EMIs'), findsOneWidget);
      await tester.tap(find.byType(Switch).first);
      await tester.pump();
      expect(layout.isVisible(HomeCardId.values.first), isFalse);
      expect(
        find.text(
          '${HomeCardId.values.length - 1} of ${HomeCardId.values.length} shown',
        ),
        findsOneWidget,
      );
      // Reset lives behind the header's overflow menu, which only becomes
      // tappable once the layout differs from the default.
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reset to default'));
      await tester.pumpAndSettle();
      expect(layout.isDefault, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      layout.dispose();
    });
  });

  group('InsightsRepository', () {
    late AppDatabase db;
    late AccountStore accounts;
    late CategoryStore categories;
    late TransactionStore transactions;
    setUp(() async {
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
      await accounts.save(
        name: 'Bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
      );
    });
    tearDown(() async {
      accounts.dispose();
      categories.dispose();
      transactions.dispose();
      await db.close();
    });

    Future<void> add(
      TransactionType type,
      int amount,
      DateTime date,
      String category,
    ) => transactions.addExpenseOrIncome(
      type: type,
      amountMinor: amount,
      accountId: accounts.accounts.first.id,
      categoryId: categories.categories
          .firstWhere((c) => c.name == category)
          .id,
      date: date,
    );

    test('adds up months, category changes and month-end balances', () async {
      await add(TransactionType.expense, 1000, DateTime(2026, 1, 5), 'Cafe');
      await add(TransactionType.expense, 3000, DateTime(2026, 2, 5), 'Cafe');
      await add(TransactionType.expense, 400, DateTime(2026, 2, 25), 'Cafe');
      await add(TransactionType.income, 9000, DateTime(2026, 3, 1), 'Salary');
      await add(TransactionType.expense, 5000, DateTime(2026, 3, 10), 'Cafe');
      await transactions.addTransfer(
        amountMinor: 600,
        fromAccountId: accounts.accounts.first.id,
        toAccountId: accounts.accounts[1].id,
        date: DateTime(2026, 3, 2),
      );

      final result = await InsightsRepository(db)
          .load(DateTime(2026, 3), 'INR', 2, now: DateTime(2026, 3, 12));
      expect(result.previousDailyExpenses.length, 28);
      expect(result.previousDailyExpenses[4], 3000);
      expect(result.flows.length, InsightsRepository.months);
      expect(result.flows.last, (
        month: DateTime(2026, 3),
        income: 9000,
        spent: 5000,
      ));
      expect(result.flows[4].spent, 3400);

      // March is running, so February counts only to the 12th (3000, not
      // 3400) and January 1000: an average of 2000 over two months.
      expect(result.comparedMonths, 2);
      final food = result.categoryChanges.single;
      expect((food.current, food.average), (5000, 2000));

      // Transfers between the two INR accounts leave the total alone.
      expect(result.balances.last, 100000 - 1000 - 3400 + 9000 - 5000);
      expect(result.balances[4], 100000 - 1000 - 3400);
      expect(result.balances[3], 100000 - 1000);
      expect(result.balances[2], 100000);
    });
  });
}
