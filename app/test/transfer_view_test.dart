import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/transactions/transaction_pages.dart';

void main() {
  const sar = Account(
    id: 1,
    name: 'SAR account',
    currency: 'SAR',
    digits: 2,
    balanceMinor: 50000,
    transactionCount: 1,
  );
  const inr = Account(
    id: 2,
    name: 'INR account',
    currency: 'INR',
    digits: 2,
    balanceMinor: 1213586,
    transactionCount: 1,
  );
  const secondInr = Account(
    id: 3,
    name: 'Second INR',
    currency: 'INR',
    digits: 2,
    balanceMinor: 99500,
    transactionCount: 1,
  );

  Future<void> show(
    WidgetTester tester, {
    required MoneyTransaction transaction,
    required Account from,
    required Account to,
  }) async {
    tester.view.physicalSize = const Size(420, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: TransactionViewPage(
            transaction: transaction,
            account: from,
            toAccount: to,
            category: null,
            onClose: () {},
            onEdit: null,
            onDelete: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  MoneyTransaction transfer({required int amount, int? received}) =>
      MoneyTransaction(
        id: 9,
        type: TransactionType.transfer,
        amountMinor: amount,
        accountId: 1,
        toAccountId: 2,
        toAmountMinor: received,
        date: DateTime(2026, 9, 12, 14, 30),
      );

  testWidgets(
    'A cross-currency transfer shows both legs and the rate applied',
    (tester) async {
      await show(
        tester,
        transaction: transfer(amount: 50000, received: 1113586),
        from: sar,
        to: inr,
      );

      // The hero carries the pair: one figure cannot stand for both sides.
      expect(find.text('SAR 500  →  ₹11,135.86'), findsOneWidget);
      // Each account row says what it actually moved.
      expect(find.text('- SAR 500'), findsOneWidget);
      expect(find.text('+ ₹11,135.86'), findsOneWidget);
      // The rate is derived from the two stored amounts, so it never drifts.
      expect(find.text('Rate applied'), findsOneWidget);
      expect(find.text('1 SAR = 22.2717 INR'), findsOneWidget);
      // Across currencies the charge lives inside the rate and is not shown.
      expect(find.text('Charge'), findsNothing);
    },
  );

  testWidgets('A same-currency transfer with a charge names the charge', (
    tester,
  ) async {
    await show(
      tester,
      transaction: MoneyTransaction(
        id: 9,
        type: TransactionType.transfer,
        amountMinor: 100000,
        accountId: 1,
        toAccountId: 3,
        toAmountMinor: 99500,
        date: DateTime(2026, 9, 12, 14, 30),
      ),
      from: secondInr,
      to: secondInr,
    );

    expect(find.text('₹1,000  →  ₹995'), findsOneWidget);
    expect(find.text('Charge'), findsOneWidget);
    expect(find.text('₹5'), findsOneWidget);
    // Both sides are in one currency, so there is no rate to report.
    expect(find.text('Rate applied'), findsNothing);
  });

  testWidgets('An ordinary transfer is unchanged: one amount, no extra rows', (
    tester,
  ) async {
    await show(
      tester,
      transaction: transfer(amount: 50000),
      from: sar,
      to: sar,
    );

    expect(find.text('SAR 500'), findsOneWidget);
    expect(find.textContaining('→'), findsNothing);
    expect(find.text('Rate applied'), findsNothing);
    expect(find.text('Charge'), findsNothing);
  });
}
