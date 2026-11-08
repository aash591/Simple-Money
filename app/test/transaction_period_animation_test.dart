import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/transactions/transactions_screen.dart';

void main() {
  for (final direction in [-1, 1]) {
    testWidgets('Period strip waits for halfway then animates ($direction)', (
      tester,
    ) async {
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
      });
      final now = DateTime.now();
      final month = DateTime(now.year, now.month);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TransactionsScreen(
              accountStore: accounts,
              categoryStore: categories,
              transactionStore: transactions,
              initialMonth: month,
              onAddTransaction: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final label = find.text(DateFormat('MMM yyyy').format(month));
      final bar = find.byKey(const ValueKey('transaction-period-indicator-0'));
      final nextBar = find.byKey(
        ValueKey('transaction-period-indicator-$direction'),
      );
      final initialLabel = tester.getRect(label);
      final initialBar = tester.getRect(bar);
      final strip = find.byKey(const Key('transaction-period'));
      final screen = find.byType(TransactionsScreen);
      expect(tester.getRect(strip).left, tester.getRect(screen).left);
      expect(tester.getRect(strip).right, tester.getRect(screen).right);
      final pages = find.byWidgetPredicate(
        (widget) =>
            widget is PageView && widget.controller?.initialPage == 20000,
      );
      final controller = tester.widget<PageView>(pages).controller!;
      final start = controller.position.pixels;
      final width = controller.position.viewportDimension;
      // Move the actual page viewport, keeping the drag below the threshold.
      controller.position.jumpTo(start + direction * width * .3);
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.getRect(label), initialLabel);
      expect(tester.getRect(bar), initialBar);
      controller.position.jumpTo(start);
      await tester.pumpAndSettle();
      expect(tester.getRect(bar), initialBar);

      controller.position.jumpTo(start + direction * width * .6);
      await tester.pump();
      expect(tester.getRect(label), initialLabel);
      await tester.pump(const Duration(milliseconds: 100));
      expect(tester.getRect(bar).width, lessThan(initialBar.width));
      expect(tester.getRect(label).left, isNot(initialLabel.left));
      expect(tester.getCenter(bar).dx, closeTo(tester.getCenter(label).dx, .1));
      await tester.pump(const Duration(milliseconds: 110));
      // Both bars coexist around the midpoint instead of one teleporting.
      expect(tester.getSize(bar).width, greaterThan(0));
      expect(tester.getSize(nextBar).width, greaterThan(0));
      expect(tester.getCenter(bar).dx, closeTo(tester.getCenter(label).dx, .1));
      await tester.pumpAndSettle();
      final nextLabel = find.text(
        DateFormat('MMM yyyy')
            .format(DateTime(month.year, month.month + direction)),
      );
      expect(
        tester.getCenter(nextLabel).dx,
        closeTo(initialLabel.center.dx, .1),
      );
      expect(
        tester.getRect(nextBar).width,
        closeTo(tester.getSize(nextLabel).width, .1),
      );
      // Reversing back across halfway returns the focus smoothly.
      controller.position.jumpTo(start);
      await tester.pumpAndSettle();
      expect(tester.getRect(label), initialLabel);
      expect(tester.getRect(bar), initialBar);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      transactions.dispose();
      categories.dispose();
      accounts.dispose();
      await tester.runAsync(db.close);
    });
  }
}
