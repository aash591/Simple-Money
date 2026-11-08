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

void main() {
  testWidgets('View by category groups the period into parents, totals them, '
      'previews ten and expands', (tester) async {
    // Tall enough that a whole expanded group fits without scrolling.
    tester.view.physicalSize = const Size(400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final accounts = AccountStore(AccountRepository(db));
    final categories = CategoryStore(CategoryRepository(db));
    final transactions = TransactionStore(TransactionRepository(db), accounts);
    await tester.runAsync(() async {
      await accounts.load();
      await categories.load();
      await transactions.load();
      await accounts.save(
        name: 'Wallet',
        currency: 'INR',
        digits: 2,
        openingBalance: 1000000,
      );
      int categoryId(String name) =>
          categories.categories.firstWhere((c) => c.name == name).id;
      final accountId = accounts.accounts.single.id;
      // 12 cafe + 1 groceries roll up into Food & Beverage (₹1,700);
      // one fuel run into Transportation (₹300).
      for (var index = 0; index < 12; index++) {
        await transactions.addExpenseOrIncome(
          type: TransactionType.expense,
          amountMinor: 10000,
          accountId: accountId,
          categoryId: categoryId('Cafe'),
          title: 'Coffee $index',
          date: DateTime(2025, 3, index + 1),
        );
      }
      await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 50000,
        accountId: accountId,
        categoryId: categoryId('Groceries'),
        title: 'Weekly shop',
        date: DateTime(2025, 3, 14),
      );
      await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 30000,
        accountId: accountId,
        categoryId: categoryId('Fuel'),
        title: 'Petrol',
        date: DateTime(2025, 3, 15),
      );
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

    // The date view is what the screen opens on.
    expect(find.text('Food & Beverage'), findsNothing);

    await tester.tap(find.byTooltip('Transaction options'));
    await tester.pumpAndSettle();
    expect(find.text('View by transaction'), findsNothing);
    await tester.tap(find.text('View by category'));
    await tester.pumpAndSettle();
    expect(find.text('Expense'), findsOneWidget);
    expect(find.text('Income'), findsOneWidget);
    expect(find.text('Food & Beverage'), findsOneWidget);
    expect(find.text('Salary'), findsNothing);
    await tester.tap(find.text('Income'));
    await tester.pumpAndSettle();
    expect(find.text('Salary'), findsOneWidget);
    expect(find.text('Food & Beverage'), findsNothing);
    await tester.tap(find.text('Expense'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All categories'));
    await tester.pumpAndSettle();

    // Parents, biggest first, each headed by its own total and count.
    expect(find.text('Food & Beverage'), findsOneWidget);
    expect(find.text('Transportation'), findsOneWidget);
    expect(find.text('- ₹1,700'), findsOneWidget);
    // A one-transaction group's header repeats that transaction's amount.
    expect(find.text('- ₹300'), findsNWidgets(2));
    expect(find.text('13 transactions'), findsOneWidget);
    expect(find.text('1 transaction'), findsOneWidget);
    expect(
      tester.getCenter(find.text('Food & Beverage')).dy,
      lessThan(tester.getCenter(find.text('Transportation')).dy),
    );

    // Rows are stamped with their date, since the group spans the period.
    expect(find.text('14 Mar 2025'), findsOneWidget);

    // The group's total ends in the same column as the amounts it sums.
    expect(
      tester.getBottomRight(find.text('- ₹1,700')).dx,
      moreOrLessEquals(tester.getBottomRight(find.text('- ₹500')).dx),
    );

    // Only the ten most recent show until the group is expanded.
    expect(find.text('Weekly shop'), findsOneWidget);
    expect(find.text('Coffee 11'), findsOneWidget);
    expect(find.text('Coffee 0'), findsNothing);
    await tester.tap(find.text('Show all 13'));
    await tester.pumpAndSettle();
    expect(find.text('Coffee 0'), findsOneWidget);
    expect(find.text('Show less'), findsOneWidget);
    await tester.tap(find.text('Show less'));
    await tester.pumpAndSettle();
    expect(find.text('Coffee 0'), findsNothing);

    // Picking a parent breaks it down into its own children instead. The
    // category view offers it as a filter, not as a view to switch to.
    await tester.tap(find.byTooltip('Transaction options'));
    await tester.pumpAndSettle();
    expect(find.text('View by category'), findsNothing);
    await tester.tap(find.text('Filter by category'));
    await tester.pumpAndSettle();
    // The group header behind the sheet carries the same name; the
    // sheet's own option is the later of the two in the tree.
    final parent = find.text('Food & Beverage').last;
    await tester.ensureVisible(parent);
    await tester.tap(parent);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Clear category filter'), findsOneWidget);
    expect(find.text('Cafe'), findsWidgets);
    expect(find.text('Groceries'), findsWidgets);
    expect(find.text('Transportation'), findsNothing);
    expect(find.text('Petrol'), findsNothing);
    expect(find.text('- ₹1,200'), findsOneWidget);
    expect(find.text('- ₹500'), findsNWidgets(2));
    // The category it is narrowed to heads its own breakdown, totalled,
    // in the same column as the child totals under it.
    expect(find.text('Food & Beverage'), findsOneWidget);
    expect(find.text('- ₹1,700'), findsOneWidget);
    expect(
      tester.getBottomRight(find.text('- ₹1,700')).dx,
      moreOrLessEquals(tester.getBottomRight(find.text('- ₹1,200')).dx),
    );

    // Clearing widens back out instead of leaving the category view.
    await tester.tap(find.byTooltip('Clear category filter'));
    await tester.pumpAndSettle();
    expect(find.text('Transportation'), findsOneWidget);

    // A selected leaf already has its summary: don't repeat its heading,
    // count, or total above the transaction card.
    await tester.tap(find.byTooltip('Transaction options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Filter by category'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Cafe').last);
    await tester.tap(find.text('Cafe').last);
    await tester.pumpAndSettle();
    expect(find.text('Viewing category'), findsOneWidget);
    expect(find.text('12 transactions'), findsOneWidget);
    expect(find.text('- ₹1,200'), findsOneWidget);
    expect(find.text('Transportation'), findsNothing);
    // Reading the summary must not accidentally clear the selection.
    await tester.tap(find.text('Viewing category'));
    await tester.pumpAndSettle();
    expect(find.text('Viewing category'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear category filter'));
    await tester.pumpAndSettle();
    expect(find.text('Transportation'), findsOneWidget);

    // The transaction view is reachable again from the same menu.
    await tester.tap(find.byTooltip('Transaction options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View by transaction'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('All transactions'));
    await tester.pumpAndSettle();
    expect(find.text('Food & Beverage'), findsNothing);
    expect(find.text('Petrol'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    transactions.dispose();
    categories.dispose();
    accounts.dispose();
    await tester.runAsync(db.close);
  });
}
