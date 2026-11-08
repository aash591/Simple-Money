// Run explicitly: flutter test tool/transactions_screenshot_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/app.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/transaction_store.dart';

void main() {
  testWidgets('Capture the populated Transactions screen', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fontPath = Platform.environment['QA_FONT'];
    if (fontPath != null) {
      await tester.runAsync(() async {
        for (final family in ['Roboto', 'Ahem']) {
          final font = FontLoader(family)
            ..addFont(
              File(
                fontPath,
              ).readAsBytes().then((bytes) => ByteData.sublistView(bytes)),
            );
          await font.load();
        }
      });
    }
    await tester.runAsync(() async {
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });

    final database = AppDatabase(NativeDatabase.memory());
    final accounts = AccountStore(AccountRepository(database));
    final categories = CategoryStore(CategoryRepository(database));
    final transactions = TransactionStore(
      TransactionRepository(database),
      accounts,
    );
    await tester.runAsync(() async {
      await accounts.load();
      await categories.load();
      await transactions.load();
      await accounts.save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 825000,
      );
      final cafe = categories.categories.firstWhere((c) => c.name == 'Cafe');
      final salary = categories.categories.firstWhere(
        (c) => c.name == 'Salary',
      );
      final now = DateTime.now();
      await transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 45000,
        accountId: accounts.accounts.single.id,
        categoryId: cafe.id,
        title: 'Coffee with friends',
        date: DateTime(now.year, now.month, now.day, 9, 41),
      );
      await transactions.addExpenseOrIncome(
        type: TransactionType.income,
        amountMinor: 5600000,
        accountId: accounts.accounts.single.id,
        categoryId: salary.id,
        date: DateTime(now.year, now.month, now.day - 2, 9),
      );
    });

    const captureKey = Key('transactions-capture');
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: SimpleMoneyApp(
          accountStore: accounts,
          categoryStore: categories,
          transactionStore: transactions,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 250)),
    );
    await tester.pumpAndSettle();
    final boundary = tester.renderObject<RenderRepaintBoundary>(
      find.byKey(captureKey),
    );
    await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      final file = File('build/qa/transactions-light.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data!.buffer.asUint8List());
      image.dispose();
    });

    await tester.pumpWidget(const SizedBox());
    transactions.dispose();
    categories.dispose();
    accounts.dispose();
    await tester.runAsync(database.close);
  });
}
