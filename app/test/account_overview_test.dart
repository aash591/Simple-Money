import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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
import 'package:simple_money/ui/components/app_back_button.dart';
import 'package:simple_money/ui/more/accounts/account_overview_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  testWidgets('account page shows the period ribbon, totals and a way to the '
      'account\'s transactions', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase(NativeDatabase.memory());
    final accounts = AccountStore(AccountRepository(db));
    final categories = CategoryStore(CategoryRepository(db));
    final transactions = TransactionStore(TransactionRepository(db), accounts);
    addTearDown(() async {
      accounts.dispose();
      categories.dispose();
      transactions.dispose();
      await db.close();
    });
    await tester.runAsync(() async {
      await accounts.load();
      await categories.load();
      await transactions.load();
      await accounts.save(
        name: 'SBI',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
      final cafe = categories.categories.firstWhere((c) => c.name == 'Cafe');
      final now = DateTime.now();
      for (final (amount, date) in [
        (10000, DateTime(now.year, now.month, 1)),
        (5000, DateTime(now.year - 1, 3, 4)),
      ]) {
        await transactions.addExpenseOrIncome(
          type: TransactionType.expense,
          amountMinor: amount,
          accountId: accounts.accounts.first.id,
          categoryId: cafe.id,
          date: date,
        );
      }
    });
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: AccountOverviewScreen(
          accountId: accounts.accounts.first.id,
          accountStore: accounts,
          categoryStore: categories,
          transactionStore: transactions,
        ),
      ),
    );
    await tester.pumpAndSettle();
    // Opens on the current month: only this month's expense counts, and
    // the older one is left out.
    expect(find.text('Account summary'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Spent ₹100')), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Received ₹0')), findsOneWidget);
    expect(
      find.text(DateFormat('MMM yyyy').format(DateTime.now())),
      findsOneWidget,
    );
    // The old chips are gone; the Transactions screen's ribbon replaces them.
    expect(find.text('This year'), findsNothing);
    expect(find.text('SBI'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Scrolling carries the account card away, while the ribbon stops just
    // under the header and stays there.
    final ribbon = find.text(DateFormat('MMM yyyy').format(DateTime.now()));
    final cardTop = tester.getTopLeft(find.text('SBI')).dy;
    final ribbonTop = tester.getTopLeft(ribbon).dy;
    await tester.drag(find.text('Spent'), const Offset(0, -400));
    await tester.pumpAndSettle();
    final pinned = tester.getTopLeft(ribbon).dy;
    expect(find.text('SBI'), findsNothing);
    expect(pinned, lessThan(ribbonTop));
    await tester.drag(find.text('Spent'), const Offset(0, -300));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(ribbon).dy, pinned);
    // And back up again: the card returns.
    await tester.drag(find.text('Spent'), const Offset(0, 1200));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('SBI')).dy, cardTop);

    await tester.scrollUntilVisible(
      find.text('See all transactions'),
      200,
      scrollable: find
          .byWidgetPredicate((w) => w is Scrollable && w.axis == Axis.vertical)
          .first,
    );
    await tester.ensureVisible(find.text('See all transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('See all transactions'));
    await tester.pumpAndSettle();
    // The Transactions screen slides in over this page, on this account.
    expect(find.text('Transactions'), findsOneWidget);
    expect(find.text('Spent'), findsNothing);
    // Back returns to the account page.
    await tester.tap(find.byType(AppBackButton).first);
    await tester.pumpAndSettle();
    expect(find.text('Transactions'), findsNothing);
    expect(find.text('See all transactions'), findsOneWidget);
    semantics.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
