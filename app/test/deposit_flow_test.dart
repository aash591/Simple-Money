import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/ui/components/number_keypad.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/transactions/transfer_sheet.dart';

/// Paying money into a broker: where from, how much, when, then a preview and
/// save. It never asks where the money goes, and reads "Deposit" throughout.
void main() {
  late AppDatabase db;
  late AccountStore accounts;
  late TransactionStore transactions;
  late int bank, broker;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    accounts = AccountStore(AccountRepository(db));
    transactions = TransactionStore(TransactionRepository(db), accounts);
    await accounts.load();
    await transactions.load();
    await accounts.save(
      name: 'Bank',
      currency: 'INR',
      digits: 2,
      openingBalance: 100000,
    );
    await accounts.save(
      name: 'Zerodha',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      broker: true,
    );
    bank = accounts.accounts.firstWhere((a) => a.name == 'Bank').id;
    broker = accounts.accounts.firstWhere((a) => a.name == 'Zerodha').id;
  });

  tearDown(() async {
    transactions.dispose();
    accounts.dispose();
    await db.close();
  });

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: TransferSheet(
            accountStore: accounts,
            transactionStore: transactions,
            depositToAccountId: broker,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> continueOn(WidgetTester tester) async {
    await tester.tap(find.widgetWithText(GlassButton, 'Continue'));
    await tester.pumpAndSettle();
  }

  int balanceOf(int id) =>
      accounts.accounts.firstWhere((a) => a.id == id).balanceMinor;

  testWidgets('deposit: from, amount, date, then preview and save', (
    tester,
  ) async {
    await mount(tester);

    // 1. Where the money comes from. The broker itself isn't offered.
    expect(find.text('Deposited from'), findsOneWidget);
    expect(find.text('Transferred from'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Zerodha'), findsNothing);
    await tester.tap(find.widgetWithText(ListTile, 'Bank'));
    await tester.pumpAndSettle();

    // 2. How much. (No "Transfer to" step in between.)
    expect(find.text('How much did you deposit?'), findsOneWidget);
    expect(find.text('Transferred to'), findsNothing);
    for (final digit in '500'.split('')) {
      await tester.tap(
        find.descendant(
          of: find.byType(NumberKeypad),
          matching: find.text(digit),
        ),
      );
    }
    await tester.pumpAndSettle();
    await continueOn(tester);

    // 3. When.
    expect(find.text('When did you deposit it?'), findsOneWidget);
    await continueOn(tester);

    // 4. Preview and save.
    expect(find.text('Confirm deposit'), findsOneWidget);
    expect(find.text('Zerodha'), findsWidgets);
    expect(find.text('Save transfer'), findsNothing);
    await tester.tap(find.widgetWithText(GlassButton, 'Save deposit'));
    await tester.pumpAndSettle();

    expect(balanceOf(bank), 100000 - 50000);
    expect(balanceOf(broker), 50000);
    final saved = transactions.transactions.single;
    expect(saved.amountMinor, 50000);
  });

  testWidgets('withdraw: reads as a withdrawal from amount to save', (
    tester,
  ) async {
    // Something in the broker to take out.
    await transactions.addTransfer(
      amountMinor: 80000,
      fromAccountId: bank,
      toAccountId: broker,
      date: DateTime(2026, 3, 1),
    );
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: TransferSheet(
            accountStore: accounts,
            transactionStore: transactions,
            initialFromAccountId: broker,
            withdrawal: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The source is the broker, so it goes straight to the amount.
    expect(find.text('How much did you withdraw?'), findsOneWidget);
    expect(find.text('How much did you transfer?'), findsNothing);
    for (final digit in '300'.split('')) {
      await tester.tap(
        find.descendant(
          of: find.byType(NumberKeypad),
          matching: find.text(digit),
        ),
      );
    }
    await tester.pumpAndSettle();
    await continueOn(tester);

    expect(find.text('Withdrawn to'), findsOneWidget);
    await tester.tap(find.widgetWithText(ListTile, 'Bank'));
    await tester.pumpAndSettle();

    expect(find.text('When did you withdraw it?'), findsOneWidget);
    await continueOn(tester);

    expect(find.text('Confirm withdrawal'), findsOneWidget);
    expect(find.text('Save transfer'), findsNothing);
    await tester.tap(find.widgetWithText(GlassButton, 'Save withdrawal'));
    await tester.pumpAndSettle();

    // ₹800 went in, ₹300 came back out.
    expect(balanceOf(broker), 80000 - 30000);
    expect(balanceOf(bank), 100000 - 80000 + 30000);
  });

  testWidgets('a plain transfer still asks where the money goes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          body: TransferSheet(
            accountStore: accounts,
            transactionStore: transactions,
            initialFromAccountId: bank,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final digit in '5'.split('')) {
      await tester.tap(
        find.descendant(
          of: find.byType(NumberKeypad),
          matching: find.text(digit),
        ),
      );
    }
    await tester.pumpAndSettle();
    await continueOn(tester);
    expect(find.text('Transferred to'), findsOneWidget);
    expect(find.text('Deposited from'), findsNothing);
  });
}
