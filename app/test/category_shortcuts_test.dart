import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/loan_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/domain/loan.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/loan_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/app_back_button.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/ui/components/transactions/review_pickers.dart';
import 'package:simple_money/ui/components/transactions/transaction_review_sheet.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/transactions/transaction_sheet.dart';
import 'package:simple_money/ui/transactions/transfer_sheet.dart';

LoanTerms _terms(String lender) => LoanTerms(
  lender: lender,
  kind: LoanKind.other,
  icon: 'bank',
  principal: 2580100,
  openingBalance: 2580100,
  startDate: DateTime(2026, 5, 12),
  snapshotDate: DateTime(2026, 5, 12),
  rate: 0,
  months: 12,
  emi: 215000,
  paidBefore: 0,
  firstDue: DateTime(2026, 6, 2),
  day: 2,
  currency: 'INR',
  digits: 2,
);

void main() {
  late AppDatabase db;
  late int sbi, expense;
  late AccountStore accounts;
  late CategoryStore categories;
  late TransactionStore transactions;
  late LoanStore loans;

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    final repository = AccountRepository(db);
    sbi = await repository.save(
      name: 'SBI',
      currency: 'INR',
      digits: 2,
      openingBalance: 5000000,
    );
    await repository.save(
      name: 'HDFC Card',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      type: AccountType.creditCard,
    );
    expense = (await CategoryRepository(
      db,
    ).load()).firstWhere((c) => c.type == CategoryType.expense).id;
    await LoanRepository(db).add(_terms('Bajaj Finance'), sbi);
    await LoanRepository(db).add(_terms('Kotak'), sbi);
    accounts = AccountStore(repository);
    categories = CategoryStore(CategoryRepository(db));
    transactions = TransactionStore(TransactionRepository(db), accounts);
    loans = LoanStore(
      LoanRepository(db),
      accountStore: accounts,
      categoryStore: categories,
      transactionStore: transactions,
    );
    await Future.wait([
      accounts.load(),
      categories.load(),
      transactions.load(),
    ]);
    await loans.load();
  });

  tearDown(() async {
    loans.dispose();
    transactions.dispose();
    await db.close();
  });

  Future<void> pump(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(420, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    // Above the app, as in the real one, so sheets can see it too.
    await tester.pumpWidget(
      LoanStoreScope(
        store: loans,
        child: MaterialApp(
          theme: appTheme(Brightness.light),
          home: Scaffold(body: child),
        ),
      ),
    );
    await settle(tester);
  }

  group('The shortcut rows', () {
    final top = [
      const Category(id: 1, name: 'Credit Card Repayment', type: CategoryType.expense),
      const Category(id: 2, name: 'Food', type: CategoryType.expense),
    ];

    test('come first, in order', () {
      final items = CategoryShortcuts(
        transfer: true,
        cardRepayment: true,
        loans: [Loan(id: 1, terms: _terms('A'), accountId: 1)],
      ).items;
      expect(items.map((i) => i.label), [
        'Transfer',
        'Loan repayment',
        'Credit card repayment',
      ]);
    });

    test('hide a loan row with no loans to pay', () {
      expect(
        const CategoryShortcuts(transfer: true).items.map((i) => i.label),
        ['Transfer'],
      );
    });

    test('replace the card category, which otherwise leads', () {
      expect(
        const CategoryShortcuts(cardRepayment: true).topLevel(top).map((c) => c.name),
        ['Food'],
      );
      expect(
        const CategoryShortcuts().topLevel(top.reversed).map((c) => c.name),
        ['Credit Card Repayment', 'Food'],
      );
    });
  });

  group('The transfer flow', () {
    testWidgets('keeps an amount already typed', (tester) async {
      await pump(
        tester,
        TransferSheet(
          accountStore: accounts,
          transactionStore: transactions,
          initialAmountText: '500',
          onClose: () {},
        ),
      );
      await tester.tap(find.text('SBI'));
      await settle(tester);
      expect(find.text('Transfer to'), findsOneWidget);
      expect(find.textContaining('₹500'), findsWidgets);
    });

    testWidgets('a card repayment asks only where it came from', (
      tester,
    ) async {
      await pump(
        tester,
        TransferSheet(
          accountStore: accounts,
          transactionStore: transactions,
          initialAmountText: '500',
          cardRepayment: true,
          onClose: () {},
        ),
      );
      expect(find.text('Credit card repayment'), findsOneWidget);
      // A card doesn't pay a card.
      expect(find.text('HDFC Card'), findsNothing);
      await tester.tap(find.text('SBI'));
      await settle(tester);
      // Straight to the date: the only card is the destination.
      expect(find.text('Which card?'), findsNothing);
      expect(find.text('When did you transfer it?'), findsOneWidget);
    });

    testWidgets('with two cards it asks which, and lists only cards', (
      tester,
    ) async {
      await tester.runAsync(() async {
        await AccountRepository(db).save(
          name: 'Axis Card',
          currency: 'INR',
          digits: 2,
          openingBalance: 0,
          type: AccountType.creditCard,
        );
        await accounts.load();
      });
      await pump(
        tester,
        TransferSheet(
          accountStore: accounts,
          transactionStore: transactions,
          initialAmountText: '500',
          cardRepayment: true,
          onClose: () {},
        ),
      );
      await tester.tap(find.text('SBI'));
      await settle(tester);
      expect(find.text('Which card?'), findsOneWidget);
      expect(find.text('Axis Card'), findsOneWidget);
      expect(find.text('HDFC Card'), findsOneWidget);
    });
  });

  group('Linking a saved expense to a loan', () {
    test('uses it as the next EMI without moving the balance', () async {
      final id = await TransactionRepository(db).addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 215000,
        accountId: sbi,
        categoryId: expense,
        title: 'BAJAJ',
        date: DateTime(2026, 6, 2),
      );
      final repository = LoanRepository(db);
      final before = (await AccountRepository(
        db,
      ).load()).firstWhere((a) => a.id == sbi).balanceMinor;
      final loan = (await repository.load()).first;
      await repository.payWith(loan.id, id);

      final paid = (await repository.load()).first;
      expect(paid.paid, 1);
      expect(paid.outstanding, 2365100);
      expect(paid.events.single.transactionId, id);
      expect(
        (await AccountRepository(
          db,
        ).load()).firstWhere((a) => a.id == sbi).balanceMinor,
        before,
      );
      final row = await db
          .customSelect('SELECT * FROM transactions WHERE id = $id')
          .getSingle();
      expect(row.read<String>('title'), loan.title);
    });

    test('a refused payment leaves nothing half saved', () async {
      final repository = LoanRepository(db);
      final loan = (await repository.load()).first;
      final tx = TransactionRepository(db);
      Future<int> paid(int minor) => tx.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: minor,
        accountId: sbi,
        categoryId: expense,
        date: DateTime(2026, 6, 2),
      );
      // More than the whole loan.
      final tooMuch = await paid(99999999);
      await expectLater(
        repository.payWith(loan.id, tooMuch),
        throwsA(isA<ArgumentError>()),
      );
      expect((await repository.load()).first.events, isEmpty);
      final row = await db
          .customSelect('SELECT * FROM transactions WHERE id = $tooMuch')
          .getSingle();
      expect(row.read<int>('category_id'), expense);
    });
  });

  group('Add transaction', () {
    /// As far as Choose category, with ₹50 typed.
    Future<void> toCategories(WidgetTester tester) async {
      await pump(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () => showAddTransactionSheet(
              context,
              accountStore: accounts,
              categoryStore: categories,
              transactionStore: transactions,
              initialType: TransactionType.expense,
            ),
            child: const Text('Open'),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await settle(tester);
      for (final digit in ['5', '0']) {
        await tester.tap(find.text(digit).last);
        await tester.pump();
      }
      await tester.tap(find.widgetWithText(GlassButton, 'Continue'));
      await settle(tester);
      expect(find.text('Choose category'), findsOneWidget);
    }

    Future<void> choose(WidgetTester tester, String label) async {
      await tester.tap(find.widgetWithText(ListTile, label).hitTestable());
      await settle(tester);
    }

    testWidgets('leads with the three shortcuts, then categories', (
      tester,
    ) async {
      await toCategories(tester);
      double top(String label) =>
          tester.getTopLeft(find.widgetWithText(ListTile, label)).dy;
      final first = categories.categories
          .where((c) => c.type == CategoryType.expense && c.parentId == null)
          .firstWhere((c) => c.name != 'Credit Card Repayment');
      expect(top('Transfer'), lessThan(top('Loan repayment')));
      expect(top('Loan repayment'), lessThan(top('Credit card repayment')));
      expect(top('Credit card repayment'), lessThan(top(first.name)));
      // The row stands in for the category of that name.
      expect(find.text('Credit Card Repayment'), findsNothing);
    });

    testWidgets('Transfer carries on with the amount typed', (tester) async {
      await toCategories(tester);
      await choose(tester, 'Transfer');
      expect(find.byType(TransferSheet), findsOneWidget);
      expect(find.text('Transfer from'), findsOneWidget);
      await choose(tester, 'SBI');
      expect(find.text('Transfer to'), findsOneWidget);
    });

    testWidgets('backing out of Transfer returns to the categories', (
      tester,
    ) async {
      await toCategories(tester);
      await choose(tester, 'Transfer');
      await tester.tap(find.byType(AppBackButton).last);
      await settle(tester);
      expect(find.text('Choose category'), findsOneWidget);
    });

    testWidgets('Credit card repayment saves a transfer to the card', (
      tester,
    ) async {
      await toCategories(tester);
      await choose(tester, 'Credit card repayment');
      await choose(tester, 'SBI');
      expect(find.text('When did you transfer it?'), findsOneWidget);
      await tester.tap(find.widgetWithText(GlassButton, 'Continue'));
      await settle(tester);
      await tester.tap(find.widgetWithText(GlassButton, 'Save transfer'));
      await settle(tester);
      late List<Map<String, Object?>> rows;
      await tester.runAsync(() async {
        rows = [
          for (final r
              in await db
                  .customSelect(
                    'SELECT t.type, t.amount_minor, a.type AS to_type '
                    'FROM transactions t JOIN accounts a ON a.id = t.to_account_id',
                  )
                  .get())
            r.data,
        ];
      });
      expect(rows.single['type'], 'transfer');
      expect(rows.single['amount_minor'], 5000);
      expect(rows.single['to_type'], 'creditCard');
    });

    testWidgets('Loan repayment lists the loans, even just one', (
      tester,
    ) async {
      await tester.runAsync(() async {
        final repository = LoanRepository(db);
        await repository.delete((await repository.load()).last);
        await loans.load();
      });
      await toCategories(tester);
      await choose(tester, 'Loan repayment');
      expect(find.text('Which loan?'), findsOneWidget);
      expect(find.text('Bajaj Finance'), findsOneWidget);
      await tester.tap(find.byType(AppBackButton).last);
      await settle(tester);
      expect(find.text('Choose category'), findsOneWidget);
    });
  });

  group('The review sheet', () {
    Future<void> open(
      WidgetTester tester, {
      List<Loan>? offered,
      List<TransactionType> types = TransactionType.values,
    }) async {
      await pump(
        tester,
        TransactionReviewSheet(
          heading: 'Edit transaction',
          draft: ReviewDraft(
            type: TransactionType.expense,
            amountMinor: 215000,
            currency: 'INR',
            digits: 2,
            date: DateTime(2026, 6, 2),
            title: 'BAJAJ',
            categoryId: expense,
            accountId: sbi,
          ),
          accounts: accounts,
          categories: categories,
          loans: offered ?? loans.loans,
          types: types,
          onSave: (_) async {},
        ),
      );
    }

    Future<void> openPicker(WidgetTester tester) async {
      await tester.tap(find.text(categories.categories
          .firstWhere((c) => c.id == expense)
          .name).first);
      await settle(tester);
    }

    testWidgets('Transfer turns it into a transfer', (tester) async {
      await open(tester);
      await openPicker(tester);
      expect(find.text('Choose category'), findsOneWidget);
      // The sheet's own Record as switch says Transfer too, underneath.
      await tester.tap(find.widgetWithText(ListTile, 'Transfer'));
      await settle(tester);
      expect(find.text('Transfer to'), findsOneWidget);
      expect(find.text('Between your accounts'), findsOneWidget);
    });

    testWidgets('Credit card repayment fills in the only card', (
      tester,
    ) async {
      await open(tester);
      await openPicker(tester);
      await tester.tap(find.text('Credit card repayment'));
      await settle(tester);
      expect(find.text('Transfer to'), findsOneWidget);
      expect(find.text('HDFC Card'), findsOneWidget);
    });

    testWidgets('Loan repayment shows only the loans', (tester) async {
      await open(tester);
      await openPicker(tester);
      await tester.tap(find.text('Loan repayment'));
      await settle(tester);
      expect(find.text('Which loan?'), findsOneWidget);
      expect(find.text('Bajaj Finance'), findsOneWidget);
      expect(find.text('Kotak'), findsOneWidget);
      expect(find.text('₹25,801 left'), findsNWidgets(2));
      expect(find.text('Credit card repayment'), findsNothing);
      expect(find.widgetWithText(ListTile, 'Transfer'), findsNothing);

      await tester.tap(find.text('Kotak'));
      await settle(tester);
      // The category row now names the loan.
      expect(find.text('Kotak'), findsOneWidget);
    });

    testWidgets('back from the loans returns to the categories', (
      tester,
    ) async {
      await open(tester);
      await openPicker(tester);
      await tester.tap(find.text('Loan repayment'));
      await settle(tester);
      await tester.tap(find.byType(AppBackButton).last);
      await settle(tester);
      expect(find.text('Choose category'), findsOneWidget);
    });

    testWidgets('a caller with no loans offers no loan row', (tester) async {
      await open(tester, offered: const []);
      await openPicker(tester);
      expect(find.text('Loan repayment'), findsNothing);
    });

    testWidgets('a kind that can\'t transfer offers no transfer', (
      tester,
    ) async {
      await open(tester, types: const [TransactionType.expense]);
      await openPicker(tester);
      expect(find.widgetWithText(ListTile, 'Transfer'), findsNothing);
      expect(find.text('Credit card repayment'), findsNothing);
    });
  });
}
