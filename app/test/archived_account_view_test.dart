import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/transactions/transaction_pages.dart';

/// An archived account is absent from every list in the app, so a transaction
/// that names one has to say why, and be the way back to it.
void main() {
  final archived = Account(
    id: 1,
    name: 'Old wallet',
    currency: 'INR',
    digits: 2,
    balanceMinor: 25000,
    transactionCount: 4,
    archivedAt: DateTime(2026, 3, 18),
  );
  const active = Account(
    id: 2,
    name: 'Bank',
    currency: 'INR',
    digits: 2,
    balanceMinor: 500000,
    transactionCount: 4,
  );

  Future<List<Account>> show(
    WidgetTester tester, {
    required MoneyTransaction transaction,
    required Account account,
    Account? toAccount,
  }) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final opened = <Account>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: TransactionViewPage(
            transaction: transaction,
            account: account,
            toAccount: toAccount,
            category: null,
            onClose: () {},
            onEdit: null,
            onDelete: () {},
            onOpenAccount: opened.add,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return opened;
  }

  MoneyTransaction expense() => MoneyTransaction(
    id: 9,
    type: TransactionType.expense,
    amountMinor: 1500,
    accountId: 1,
    categoryId: 1,
    date: DateTime(2026, 9, 12, 14, 30),
  );

  testWidgets('An archived account is named, dated, and can be opened', (
    tester,
  ) async {
    final opened = await show(
      tester,
      transaction: expense(),
      account: archived,
    );
    // The name still reads as the name; the note qualifies it.
    expect(find.text('Old wallet'), findsOneWidget);
    expect(find.text('Archived on Mar 18, 2026'), findsOneWidget);
    await tester.tap(find.text('Old wallet'));
    await tester.pumpAndSettle();
    expect(opened.single.id, archived.id);
  });

  testWidgets('An account still in use says nothing and does not open', (
    tester,
  ) async {
    final opened = await show(tester, transaction: expense(), account: active);
    expect(find.text('Bank'), findsOneWidget);
    expect(find.textContaining('Archived on'), findsNothing);
    await tester.tap(find.text('Bank'));
    await tester.pumpAndSettle();
    expect(opened, isEmpty);
  });

  testWidgets('Either leg of a transfer can be the archived one', (
    tester,
  ) async {
    final opened = await show(
      tester,
      transaction: MoneyTransaction(
        id: 10,
        type: TransactionType.transfer,
        amountMinor: 20000,
        accountId: 2,
        toAccountId: 1,
        date: DateTime(2026, 9, 12),
      ),
      account: active,
      toAccount: archived,
    );
    expect(find.text('Archived on Mar 18, 2026'), findsOneWidget);
    await tester.tap(find.text('Old wallet'));
    await tester.pumpAndSettle();
    expect(opened.single.id, archived.id);
  });
}
