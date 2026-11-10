import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/transactions/transactions_screen.dart';

Future<Finder> mount(
  WidgetTester tester,
  int count, {
  int balance = 1000000,
  double width = 390,
}) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final db = AppDatabase(NativeDatabase.memory());
  final accounts = AccountStore(AccountRepository(db));
  final categories = CategoryStore(CategoryRepository(db));
  final transactions = TransactionStore(TransactionRepository(db), accounts);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    transactions.dispose();
    categories.dispose();
    accounts.dispose();
    await tester.runAsync(db.close);
  });
  await tester.runAsync(() async {
    await accounts.load();
    await categories.load();
    await transactions.load();
    await accounts.save(
      name: 'Main',
      currency: 'INR',
      digits: 2,
      openingBalance: balance,
    );
    final cafe = categories.categories.firstWhere((c) => c.name == 'Cafe');
    for (var i = 0; i < count; i++) {
      await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 1000 + i,
        accountId: accounts.accounts.first.id,
        categoryId: cafe.id,
        title: 'Purchase $i',
        date: DateTime(2026, 9, 1 + i % 28),
      );
    }
  });
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: TransactionsScreen(
          accountStore: accounts,
          categoryStore: categories,
          transactionStore: transactions,
          initialMonth: DateTime(2026, 9),
          onAddTransaction: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return find.byKey(const Key('transaction-account-filter'));
}

void main() {
  testWidgets('the balance card folds in step with a long list scrolling', (
    tester,
  ) async {
    final card = await mount(tester, 40);
    final open = tester.getSize(card).height;
    final ribbon = find.byType(PageView);
    final ribbonTop = tester.getTopLeft(ribbon).dy;
    // Half way down the fold distance, the card is half way folded.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -28));
    await tester.pump();
    final half = tester.getSize(card).height;
    expect(half, lessThan(open));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final folded = tester.getSize(card).height;
    expect(folded, lessThan(half));
    // Everything under the card, the ribbon included, moves up with it.
    expect(tester.getTopLeft(ribbon).dy, lessThan(ribbonTop - 20));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 800));
    await tester.pumpAndSettle();
    expect(tester.getSize(card).height, open);
  });

  testWidgets('swiping to a page with less content leaves the card as it '
      'was; pulling down opens it', (tester) async {
    final card = await mount(tester, 40);
    final open = tester.getSize(card).height;
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -400));
    await tester.pumpAndSettle();
    final folded = tester.getSize(card).height;
    expect(folded, lessThan(open));
    // October is empty: the new page cannot scroll. Nothing unfolds by itself.
    await tester.drag(find.byType(PageView), const Offset(-390, 0));
    await tester.pumpAndSettle();
    expect(tester.getSize(card).height, folded);
    // Pulling down opens it, with the finger.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 50));
    await tester.pump();
    final part = tester.getSize(card).height;
    expect(part, greaterThan(folded));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(tester.getSize(card).height, open);
  });

  testWidgets('a list with little in it still folds and unfolds the card', (
    tester,
  ) async {
    final card = await mount(tester, 2);
    final open = tester.getSize(card).height;
    // Nothing to scroll, yet dragging up folds the card with the finger.
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final folded = tester.getSize(card).height;
    expect(folded, lessThan(open));
    await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
    await tester.pumpAndSettle();
    expect(tester.getSize(card).height, open);
  });

  testWidgets(
    'let go half way, the card settles open or folded, never between',
    (tester) async {
      final card = await mount(tester, 2);
      final open = tester.getSize(card).height;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -300));
      await tester.pumpAndSettle();
      final folded = tester.getSize(card).height;
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
      await tester.pumpAndSettle();
      // Small drags of different lengths, each let go mid-fold.
      for (final distance in [30.0, 40.0, 50.0, 60.0, 70.0]) {
        await tester.drag(find.byType(CustomScrollView), Offset(0, -distance));
        await tester.pumpAndSettle();
        final h = tester.getSize(card).height;
        expect(
          (h - open).abs() < .5 || (h - folded).abs() < .5,
          isTrue,
          reason:
              'after $distance px it rested at $h ($open open, $folded folded)',
        );
        await tester.drag(find.byType(CustomScrollView), const Offset(0, 300));
        await tester.pumpAndSettle();
        expect(tester.getSize(card).height, open);
      }
    },
  );
}
