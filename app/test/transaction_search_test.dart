import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/transactions/transactions_screen.dart';
import 'package:simple_money/ui/components/common.dart';

void main() {
  testWidgets(
    'Search expands in place, hides options and keeps the current period',
    (tester) async {
      tester.view.physicalSize = const Size(390, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final db = AppDatabase(NativeDatabase.memory());
      final accounts = AccountStore(AccountRepository(db));
      final categories = CategoryStore(CategoryRepository(db));
      final transactions = TransactionStore(
        TransactionRepository(db),
        accounts,
      );
      await tester.runAsync(() async {
        await accounts.load();
        await categories.load();
        await transactions.load();
        await accounts.save(
          name: 'Wallet',
          currency: 'INR',
          digits: 2,
          openingBalance: 100000,
        );
        for (final row in [
          (TransactionType.expense, 12500, 'Lunch', DateTime(2025, 3, 5)),
          (TransactionType.income, 2500, 'Refund', DateTime(2025, 3, 6)),
          (TransactionType.expense, 5000, 'Old coffee', DateTime(2025, 2, 5)),
        ]) {
          await transactions.addExpenseOrIncome(
            type: row.$1,
            amountMinor: row.$2,
            accountId: accounts.accounts.single.id,
            categoryId: categories.categories
                .firstWhere((c) => c.name == 'Cafe')
                .id,
            title: row.$3,
            date: row.$4,
          );
        }
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransactionsScreen(
              accountStore: accounts,
              categoryStore: categories,
              transactionStore: transactions,
              initialMonth: DateTime(2025, 3),
              onAddTransaction: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Total balance'), findsOneWidget);
      expect(find.text('Opening balance'), findsOneWidget);
      final searchIconY = tester
          .getCenter(find.byTooltip('Search transactions'))
          .dy;
      await tester.tap(find.byTooltip('Search transactions'));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(TransactionsScreen), findsOneWidget);
      expect(find.byType(AnimatedSize), findsWidgets);
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.byKey(const Key('transaction-search'))).dy,
        lessThanOrEqualTo(searchIconY),
      );
      expect(find.text('Total balance'), findsNothing);
      expect(find.text('Opening balance'), findsNothing);
      expect(find.text('Money in'), findsOneWidget);
      expect(find.text('Money out'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('transaction-search')),
        'cafe',
      );
      await tester.pumpAndSettle();
      expect(find.text('Lunch'), findsOneWidget);
      expect(find.text('Refund'), findsOneWidget);
      expect(find.text('Old coffee'), findsNothing);
      final cafe = categories.categories.firstWhere((c) => c.name == 'Cafe');
      final parent = categories.categories.firstWhere(
        (c) => c.id == cafe.parentId,
      );
      await tester.enterText(
        find.byKey(const Key('transaction-search')),
        parent.name.toUpperCase(),
      );
      await tester.pumpAndSettle();
      expect(find.text('Lunch'), findsOneWidget);
      expect(find.text('Refund'), findsOneWidget);
      expect(find.text('Old coffee'), findsNothing);
      final summary = find.ancestor(
        of: find.text('Money in'),
        matching: find.byType(MoneyCard),
      );
      String summaryText() => tester
          .widgetList<Text>(
            find.descendant(of: summary, matching: find.byType(Text)),
          )
          .map((text) => text.data ?? '')
          .join(' ');
      expect(summaryText(), contains('125'));
      expect(summaryText(), contains('25'));
      expect(find.byTooltip('Search options'), findsNothing);
      expect(find.byTooltip('Transaction options'), findsNothing);
      expect(find.text('Old coffee'), findsNothing);
      await tester.enterText(
        find.byKey(const Key('transaction-search')),
        'no match',
      );
      await tester.pumpAndSettle();
      expect(find.text('No matching transactions'), findsOneWidget);
      expect(summaryText(), isNot(contains('125')));
      await tester.tap(find.byTooltip('Clear search'));
      await tester.pumpAndSettle();
      expect(find.text('Lunch'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('transaction-search')), findsNothing);
      expect(find.byTooltip('Transaction options'), findsOneWidget);
      expect(find.text('Total balance'), findsOneWidget);
      expect(find.text('Opening balance'), findsOneWidget);
      expect(find.text('Lunch'), findsOneWidget);
      expect(find.text('Old coffee'), findsNothing);
      await tester.tap(find.byTooltip('Transaction options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('View by category'));
      await tester.pumpAndSettle();
      final parentOption = find.text(parent.name);
      await tester.ensureVisible(parentOption);
      await tester.tap(parentOption);
      await tester.pumpAndSettle();
      expect(find.text('Lunch'), findsOneWidget);
      expect(find.text('Refund'), findsOneWidget);
      expect(find.byTooltip('Clear category filter'), findsOneWidget);
      await tester.tap(find.byTooltip('Transaction options'));
      await tester.pumpAndSettle();
      // Already in the category view, so it reads as the filter it is.
      await tester.tap(find.text('Filter by category'));
      await tester.pumpAndSettle();
      final unrelated = categories.categories.firstWhere(
        (c) => c.id != cafe.id && c.id != parent.id && c.parentId == null,
      );
      final unrelatedOption = find.text(unrelated.name);
      await tester.ensureVisible(unrelatedOption);
      await tester.tap(unrelatedOption);
      await tester.pumpAndSettle();
      expect(find.text('Lunch'), findsNothing);
      expect(find.text('Refund'), findsNothing);
      expect(find.text('No matching transactions'), findsOneWidget);
      await tester.tap(find.byTooltip('Clear category filter'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Clear category filter'), findsNothing);
      expect(find.text('Lunch'), findsOneWidget);
      expect(
        (await SharedPreferences.getInstance()).getString(
          'transactions_range_kind',
        ),
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      transactions.dispose();
      categories.dispose();
      accounts.dispose();
      await tester.runAsync(db.close);
    },
  );
}
