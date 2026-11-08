import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

// Only Variable: drift's Column and Table collide with Flutter's.
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/data/backup/data_transfer.dart';
import 'package:simple_money/data/backup/sync_engine.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/home_repository.dart';
import 'package:simple_money/data/repositories/loan_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/loan.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/loan_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/more/loans/loan_detail_screen.dart';
import 'package:simple_money/ui/more/loans/loan_action_sheet.dart';
import 'package:simple_money/ui/more/loans/loan_flow_screen.dart';
import 'package:simple_money/ui/more/loans/loans_screen.dart';
import 'package:simple_money/ui/components/number_keypad.dart';
import 'package:simple_money/ui/components/adaptive_sheet.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

LoanTerms terms({
  int paid = 0,
  int balance = 120000,
  double rate = 12,
  int? emi,
  LoanRepaymentMode mode = LoanRepaymentMode.emi,
  int charges = 0,
  bool chargesDeducted = false,
}) => LoanTerms(
  lender: 'Test Bank',
  kind: LoanKind.personal,
  icon: 'bank',
  principal: 120000,
  openingBalance: balance,
  rate: rate,
  months: 12,
  emi: mode.amortises ? (emi ?? loanEmi(120000, rate, 12)) : 0,
  paidBefore: paid,
  firstDue: DateTime(2026, 1, 31),
  day: 31,
  currency: 'INR',
  digits: 2,
  mode: mode,
  chargesMinor: charges,
  chargesDeducted: chargesDeducted,
);

void main() {
  late AppDatabase db;
  late LoanRepository repository;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory(), false);
    repository = LoanRepository(db);
    await AccountRepository(
      db,
    ).save(name: 'Cash', currency: 'INR', digits: 2, openingBalance: 1000000);
  });
  tearDown(() => db.close());
  Future<Loan> current() async => (await repository.load()).single;
  Future<int> balance() async =>
      (await AccountRepository(db).load()).first.balanceMinor;

  test('Schedule conserves principal, reduces interest and clears the last minor unit', () {
    final emi = loanEmi(10000000, 8.5, 240);
    expect(emi, 86782);
    final rows = loanSchedule(
      principal: 10000000,
      rate: 8.5,
      emi: emi,
      first: DateTime(2026, 1, 31),
      day: 31,
    );
    expect(rows.fold(0, (n, r) => n + r.principal), 10000000);
    expect(rows.last.balance, 0);
    expect(rows.last.amount, lessThanOrEqualTo(emi));
    expect(rows.first.interest, greaterThan(rows.last.interest));
    expect(rows[1].due, DateTime(2026, 2, 28));
    expect(rows[2].due, DateTime(2026, 3, 31));
    expect(loanMonth(DateTime(2028, 1, 31), 1, 31), DateTime(2028, 2, 29));
  });
  test('Zero interest and impossible repayment terms', () {
    final rows = loanSchedule(
      principal: 101,
      rate: 0,
      emi: loanEmi(101, 0, 12),
      first: DateTime(2026),
      day: 1,
    );
    expect(rows.length, 12);
    expect(rows.last.amount, 2);
    expect(rows.every((r) => r.interest == 0), isTrue);
    expect(
      () => loanSchedule(
        principal: 120000,
        rate: 12,
        emi: 1200,
        first: DateTime(2026),
        day: 1,
      ),
      throwsArgumentError,
    );
    expect(() => loanEmi(1000, double.nan, 12), throwsArgumentError);
    expect(loanEmi(1, 1, 600), 1);
  });
  test('Opening charges are either an expense of their own or come off the '
      'money disbursed', () async {
    await repository.add(terms(charges: 2400), 1, receivedIn: 1);
    // Disbursal in full, charges paid separately out of the same account.
    expect(await balance(), 1000000 + 120000 - 2400);
    final logged = await TransactionRepository(db).load();
    expect(
      logged.map((t) => t.title),
      containsAll(['Test Bank loan disbursal', 'Test Bank loan charges']),
    );
    final separate = await current();
    expect(separate.charges, 2400);
    expect(separate.totalCost, separate.futureInterest + 2400);
    // Its charges transaction belongs to the loan, not the ledger.
    final chargeRow = logged.firstWhere((t) => t.title!.endsWith('charges'));
    expect(
      () => TransactionRepository(db).delete(chargeRow.id),
      throwsStateError,
    );

    await repository.delete(separate);
    final before = await balance();
    await repository.add(
      terms(charges: 2400, chargesDeducted: true),
      1,
      receivedIn: 1,
    );
    // Netted off instead: less money arrives and nothing is logged for the
    // charges, but the principal to repay is unchanged.
    expect(await balance(), before + 120000 - 2400);
    final deducted = await current();
    expect(deducted.chargesId, isNull);
    expect(deducted.outstanding, 120000);
    expect(deducted.charges, 2400);
  });

  test('An interest-only loan repays nothing until its last payment, and a '
      'bullet loan is settled in one', () async {
    await repository.add(terms(mode: LoanRepaymentMode.interestOnly), 1);
    final monthly = (await current()).schedule.first;
    expect(monthly.principal, 0);
    expect(monthly.interest, 1200); // 120000 at 12% for one month.
    await repository.record(
      await current(),
      kind: LoanEventKind.emi,
      date: DateTime.now(),
      accountId: 1,
      amount: 1200,
    );
    final after = await current();
    expect(after.outstanding, 120000, reason: 'interest repays no principal');
    expect(after.paid, 1);
    expect(after.closed, isFalse);
    expect(after.schedule.length, 11);
    expect(after.schedule.last.principal, 120000);
    expect(await balance(), 1000000 - 1200);

    await repository.delete(after);
    await repository.add(terms(mode: LoanRepaymentMode.bullet), 1);
    final bullet = await current();
    expect(bullet.schedule, hasLength(1));
    expect(bullet.schedule.single.principal, 120000);
    expect(bullet.schedule.single.interest, 14400); // 12% over 12 months.
    expect(bullet.nextAmount, 134400);
  });

  test('A late payment takes the interest actually charged, and a penal '
      'charge is never added to the principal', () async {
    await repository.add(terms(), 1);
    final loan = await current();
    final scheduled = loan.schedule.first;
    await repository.record(
      loan,
      kind: LoanEventKind.emi,
      date: DateTime.now(),
      accountId: 1,
      amount: scheduled.amount,
      interestCharged: scheduled.interest + 500,
      fee: 600,
    );
    final after = await current();
    final event = after.events.single;
    expect(event.interest, scheduled.interest + 500);
    expect(event.principal, scheduled.amount - scheduled.interest - 500);
    expect(event.fee, 600);
    // The fee leaves the account but never joins what is owed.
    expect(after.outstanding, 120000 - event.principal);
    expect(after.charges, 600);
    expect(await balance(), 1000000 - scheduled.amount - 600);
  });

  test('A loan the lender paid the seller for moves no money, and its EMIs '
      'can come from any account', () async {
    await AccountRepository(
      db,
    ).save(name: 'Salary', currency: 'INR', digits: 2, openingBalance: 500000);
    // A car loan: nothing is disbursed to the borrower.
    await repository.add(terms(), 1);
    expect(await balance(), 1000000);
    expect(await TransactionRepository(db).load(), isEmpty);

    // One EMI from the usual account, the next from another.
    await repository.record(
      await current(),
      kind: LoanEventKind.emi,
      date: DateTime.now(),
      accountId: 1,
    );
    final first = (await current()).events.single;
    await repository.record(
      await current(),
      kind: LoanEventKind.emi,
      date: DateTime.now(),
      accountId: 2,
    );
    final loan = await current();
    expect(loan.paid, 2);
    expect(loan.events.map((e) => e.accountName), ['Cash', 'Salary']);
    final accounts = await AccountRepository(db).load();
    expect(accounts[0].balanceMinor, 1000000 - first.amount);
    expect(accounts[1].balanceMinor, 500000 - loan.events.last.amount);
    expect(loan.outstanding, isPositive);
  });
  test('Upgrading a v12 ledger adds loan tables and sync triggers without changing accounts', () async {
    final directory = await Directory.systemTemp.createTemp('loan_migration_');
    final file = File('${directory.path}/ledger.sqlite');
    final old = AppDatabase(NativeDatabase(file), false);
    await AccountRepository(
      old,
    ).save(name: 'Existing', currency: 'INR', digits: 2, openingBalance: 12345);
    await old.customStatement('DROP TABLE loan_events');
    await old.customStatement('DROP TABLE loans');
    await old.customStatement('PRAGMA user_version = 12');
    await old.close();
    final upgraded = AppDatabase(NativeDatabase(file), false);
    try {
      expect(
        (await AccountRepository(upgraded).load()).single.balanceMinor,
        12345,
      );
      await LoanRepository(upgraded).add(terms(), 1);
      final queued = await upgraded
          .customSelect("SELECT * FROM sync_outbox WHERE table_name = 'loans'")
          .get();
      expect(queued.length, 1);
    } finally {
      await upgraded.close();
      await directory.delete(recursive: true);
    }
  });
  test(
    'Upgrading a v13 ledger keeps its loans and syncs the charges column',
    () async {
      final directory = await Directory.systemTemp.createTemp('loan_charges_');
      final file = File('${directory.path}/ledger.sqlite');
      final old = AppDatabase(NativeDatabase(file), false);
      await AccountRepository(old).save(
        name: 'Existing',
        currency: 'INR',
        digits: 2,
        openingBalance: 12345,
      );
      // A v13 install: loans without the charges column.
      await old.customStatement('DROP TABLE loans');
      await old.customStatement('''CREATE TABLE loans (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      payload TEXT NOT NULL CHECK(json_valid(payload)),
      account_id INTEGER, disbursal_id INTEGER
    )''');
      await old.customInsert(
        'INSERT INTO loans (payload, account_id) VALUES (?, 1)',
        variables: [Variable(jsonEncode(terms().toJson()))],
      );
      await old.customStatement('PRAGMA user_version = 13');
      await old.close();
      final upgraded = AppDatabase(NativeDatabase(file), false);
      try {
        final loan = (await LoanRepository(upgraded).load()).single;
        expect(loan.chargesId, isNull);
        expect(loan.outstanding, 120000);
        // The rebuilt trigger has to carry the new column, or a synced loan
        // would arrive on another device without it.
        await LoanRepository(upgraded).edit(
          loan,
          lender: 'Renamed Bank',
          icon: 'bank',
          accountId: 1,
          remind: true,
        );
        final queued = await upgraded
            .customSelect(
              "SELECT row_json FROM sync_outbox WHERE table_name = 'loans'",
            )
            .get();
        expect(
          jsonDecode(queued.single.read<String>('row_json')),
          containsPair('charges_id', null),
        );
      } finally {
        await upgraded.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test('Imported balance never adds historical expenses', () async {
    await repository.add(terms(paid: 4, balance: 80000), 1);
    expect((await current()).outstanding, 80000);
    expect((await current()).paid, 4);
    expect(await balance(), 1000000);
    expect(await TransactionRepository(db).load(), isEmpty);
  });
  test('EMI with fee atomically logs expense, advances once, and undo reverses both', () async {
    await repository.add(terms(), 1);
    final loan = await current();
    final next = loan.schedule.first;
    await repository.record(
      loan,
      kind: LoanEventKind.emi,
      date: DateTime(2026, 2, 1),
      accountId: 1,
      fee: 500,
    );
    expect(await balance(), 1000000 - next.amount - 500);
    final paid = await current();
    expect(paid.outstanding, 120000 - next.principal);
    expect(paid.nextDue, DateTime(2026, 2, 28));
    final tx = (await TransactionRepository(db).load()).single;
    expect(tx.amountMinor, next.amount + 500);
    expect(
      (await HomeRepository(db).load(DateTime(2026, 2), 'INR', 2)).spent,
      next.amount + 500,
    );
    await expectLater(
      repository.record(
        loan,
        kind: LoanEventKind.emi,
        date: DateTime(2026, 2, 1),
        accountId: 1,
      ),
      throwsStateError,
    );
    expect((await TransactionRepository(db).load()).length, 1);
    await repository.undo(paid);
    expect(await balance(), 1000000);
    expect((await current()).outstanding, 120000);
    expect((await current()).nextDue, DateTime(2026, 1, 31));
    expect(await TransactionRepository(db).load(), isEmpty);
  });
  test(
    'Wrong currency rolls back without category or transaction changes',
    () async {
      await AccountRepository(db).save(
        name: 'Dollars',
        currency: 'USD',
        digits: 2,
        openingBalance: 1000000,
      );
      await repository.add(terms(), 1);
      await expectLater(
        repository.record(
          await current(),
          kind: LoanEventKind.emi,
          date: DateTime(2026, 2, 1),
          accountId: 2,
        ),
        throwsArgumentError,
      );
      expect((await current()).events, isEmpty);
      expect(await TransactionRepository(db).load(), isEmpty);
      expect(await balance(), 1000000);
    },
  );
  test(
    'Prepayment and rate changes preserve history and can be undone in order',
    () async {
      await repository.add(terms(), 1);
      final initial = await current();
      await repository.record(
        initial,
        kind: LoanEventKind.partPayment,
        amount: 40000,
        accountId: 1,
        date: DateTime(2026, 2, 1),
      );
      final part = await current();
      expect(part.schedule.length, lessThan(initial.schedule.length));
      expect(part.futureInterest, lessThan(initial.futureInterest));
      expect(part.nextDue, initial.nextDue);
      await repository.record(
        part,
        kind: LoanEventKind.rateChange,
        newRate: 6,
        reduceEmi: true,
        date: DateTime(2026, 2, 1),
      );
      final changed = await current();
      expect(changed.rate, 6);
      expect(changed.emi, lessThan(part.emi));
      expect(changed.events.first.principal, 40000);
      expect((await TransactionRepository(db).load()).length, 1);
      await repository.undo(changed);
      expect((await current()).rate, 12);
      await repository.undo(await current());
      expect(await balance(), 1000000);
    },
  );
  test('Early closure and deletion retain real ledger history', () async {
    await repository.add(terms(), 1);
    await repository.record(
      await current(),
      kind: LoanEventKind.closure,
      amount: 121000,
      fee: 200,
      accountId: 1,
      date: DateTime(2026, 2, 1),
    );
    final closed = await current();
    expect(closed.closed, isTrue);
    expect(closed.schedule, isEmpty);
    expect(await balance(), 878800);
    await repository.delete(closed);
    expect(await repository.load(), isEmpty);
    expect((await TransactionRepository(db).load()).single.amountMinor, 121200);
  });
  test('Linked transactions require loan undo; deleting an account preserves loan history', () async {
    await repository.add(terms(), 1);
    await repository.record(
      await current(),
      kind: LoanEventKind.emi,
      date: DateTime(2026, 2, 1),
      accountId: 1,
    );
    final loan = await current();
    final tx = (await TransactionRepository(db).load()).single;
    await expectLater(
      TransactionRepository(db).delete(tx.id),
      throwsStateError,
    );
    await expectLater(
      TransactionRepository(db).updateExpenseOrIncome(
        id: tx.id,
        type: TransactionType.expense,
        amountMinor: 100,
        accountId: 1,
        categoryId: tx.categoryId!,
        date: DateTime(2026, 2, 1),
      ),
      throwsStateError,
    );
    await expectLater(
      AccountRepository(db).save(
        existing: (await AccountRepository(db).load()).single,
        name: 'Cash',
        currency: 'USD',
        digits: 2,
        openingBalance: 0,
      ),
      throwsArgumentError,
    );
    await AccountRepository(db).delete(1);
    final after = await current();
    expect(after.outstanding, loan.outstanding);
    expect(after.accountId, isNull);
    expect(after.events.single.transactionId, isNull);
    await expectLater(repository.undo(after), throwsStateError);
  });
  test('Disbursal changes cash but not earned income; loans round-trip through backup', () async {
    await repository.add(terms(), 1, receivedIn: 1);
    expect(await balance(), 1120000);
    expect((await HomeRepository(db).load(DateTime.now(), 'INR', 2)).income, 0);
    await repository.record(
      await current(),
      kind: LoanEventKind.emi,
      date: DateTime(2026, 2, 1),
      accountId: 1,
    );
    final backup = parseLedgerExport(await exportLedger(db));
    expect(backup.count('loans'), 1);
    expect(backup.count('loan_events'), 1);
    final other = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(other.close);
    await SyncEngine(
      SyncRepository(other),
      openTransport: (_) => throw StateError('unused'),
    ).restore(backup);
    final restored = (await LoanRepository(other).load()).single;
    expect(restored.outstanding, (await current()).outstanding);
    expect(
      restored.events.single.toJson(),
      (await current()).events.single.toJson(),
    );
    expect(restored.nextDue, (await current()).nextDue);
  });

  Future<LoanStore> store() async {
    final accounts = AccountStore(AccountRepository(db));
    final categories = CategoryStore(CategoryRepository(db));
    final transactions = TransactionStore(TransactionRepository(db), accounts);
    final loans = LoanStore(
      repository,
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
    addTearDown(() {
      loans.dispose();
      transactions.dispose();
      categories.dispose();
      accounts.dispose();
    });
    return loans;
  }

  testWidgets(
    'Add loan flow saves typed lender and repayment account on a narrow screen',
    (tester) async {
      final loans = await store();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showAddLoanFlow(context, loans),
                child: const Text('Open loan'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open loan'));
      await tester.pumpAndSettle();
      Future<void> next() async {
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(GlassButton, 'Continue'));
        await tester.pumpAndSettle();
      }

      expect(find.text('Name your loan'), findsOneWidget);
      await tester.enterText(
        find.widgetWithText(TextField, 'Type a name'),
        'Local lender',
      );
      await tester.pumpAndSettle();
      await next();

      // The amount is typed on the keypad, as everywhere else in the app.
      for (final digit in '1200'.split('')) {
        await tester.tap(
          find.descendant(
            of: find.byType(NumberKeypad),
            matching: find.text(digit),
          ),
        );
      }
      await tester.pumpAndSettle();
      await next();

      Future<void> choose(String label) async {
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
      }

      expect(find.text('Does it charge interest?'), findsOneWidget);
      await choose('Yes');
      await tester.enterText(find.widgetWithText(TextField, 'e.g. 12'), '12');
      await choose('The amount still unpaid');
      await next();
      expect(find.text('When did it start, and for how long?'), findsOneWidget);
      await tester.enterText(find.widgetWithText(TextField, 'e.g. 12'), '12');
      await next();
      await choose('No payments yet');
      await next();
      await choose('Fixed monthly EMI');
      expect(find.text('Estimated monthly EMI'), findsOneWidget);
      expect(find.text('First instalment date'), findsOneWidget);
      await next();
      expect(find.text('Usually repaid from'), findsOneWidget);
      expect(find.text('Do not add money to an account'), findsOneWidget);
      await next();
      expect(find.text('Review your loan'), findsOneWidget);
      await tester.tap(find.widgetWithText(GlassButton, 'Add loan'));
      await tester.pumpAndSettle();
      expect((await current()).terms.lender, 'Local lender');
      expect((await current()).accountId, 1);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'List, detail and schedule fit at 360px with large text in dark mode',
    (tester) async {
      await repository.add(terms(), 1);
      final loans = await store();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.3)),
            child: child!,
          ),
          home: LoansScreen(store: loans),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Test Bank Personal loan'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Test Bank Personal loan'));
      await tester.pumpAndSettle();
      expect(find.byType(LoanDetailScreen), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Schedule'),
        250,
        scrollable: find
            .descendant(
              of: find.byType(LoanDetailScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Schedule'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Schedule'));
      await tester.pumpAndSettle();
      expect(find.text('EMI 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Part-payment previews and rate-change sheet save revised terms',
    (tester) async {
      await repository.add(terms(), 1);
      final loans = await store();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: Column(
                children: [
                  TextButton(
                    onPressed: () => showLoanAction(
                      context,
                      loans,
                      loans.loans.single,
                      LoanEventKind.partPayment,
                    ),
                    child: const Text('Part'),
                  ),
                  TextButton(
                    onPressed: () => showLoanAction(
                      context,
                      loans,
                      loans.loans.single,
                      LoanEventKind.rateChange,
                    ),
                    child: const Text('Rate'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Part'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '400');
      await tester.pumpAndSettle();
      expect(find.textContaining('Saves'), findsNWidgets(2));
      await tester.tap(find.widgetWithText(GlassButton, 'Part-payment'));
      await tester.pumpAndSettle();
      expect((await current()).outstanding, 80000);
      await tester.tap(find.text('Rate'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '6');
      await tester.ensureVisible(find.text('Keep tenure'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep tenure'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(GlassButton, 'Rate changed'));
      await tester.pumpAndSettle();
      expect((await current()).rate, 6);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'Loan detail uses the shared menu and shows rate changes without a payment split',
    (tester) async {
      await repository.add(terms(), 1);
      await repository.record(
        await current(),
        kind: LoanEventKind.rateChange,
        newRate: 6,
        date: DateTime(2026, 2, 1),
        reduceEmi: true,
      );
      final loans = await store();
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: LoanDetailScreen(store: loans, id: loans.loans.single.id),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      expect(find.text('Change rate'), findsOneWidget);
      await tester.tap(find.text('Edit loan'));
      await tester.pumpAndSettle();
      // Existing loans open directly on review, with recorded terms locked.
      expect(find.text('Review your changes'), findsOneWidget);
      expect(find.byTooltip('Change loan amount'), findsNothing);
      expect(find.byTooltip('Change interest'), findsNothing);
      await tester.tap(find.byTooltip('Edit loan name'));
      await tester.pumpAndSettle();
      expect(find.text('Name your loan'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, 'Local bank');
      await tester.tap(find.widgetWithText(GlassButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.text('Review your changes'), findsOneWidget);
      expect(find.text('View more details'), findsNothing);
      expect(find.byTooltip('Change repay from'), findsOneWidget);
      await tester.tap(find.widgetWithText(GlassButton, 'Save changes'));
      await tester.pumpAndSettle();
      expect(find.byType(LoanDetailScreen), findsOneWidget);
      expect((await current()).terms.lender, 'Local bank');
      await tester.scrollUntilVisible(
        find.text('Interest rate changed'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Interest rate changed'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Interest rate changed'));
      await tester.pumpAndSettle();
      expect(find.text('Rate change'), findsOneWidget);
      expect(find.text('Revised EMI'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SheetPage).last,
          matching: find.text('Principal'),
        ),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Every loan action sheet scrolls at 320px with large text and keyboard',
    (tester) async {
      await repository.add(terms(), 1);
      final loans = await store();
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final brightness in Brightness.values) {
        for (final kind in LoanEventKind.values) {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pumpWidget(
            MaterialApp(
              theme: appTheme(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: const TextScaler.linear(1.5),
                  viewInsets: const EdgeInsets.only(bottom: 260),
                ),
                child: child!,
              ),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => showLoanAction(
                      context,
                      loans,
                      loans.loans.single,
                      kind,
                    ),
                    child: const Text('Open action'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Open action'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          await tester.drag(
            find.byType(SingleChildScrollView).last,
            const Offset(0, -1800),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(find.text('Cancel').hitTestable(), findsOneWidget);
          await tester.tap(find.text('Cancel'));
          await tester.pumpAndSettle();
          expect(find.text('Open action'), findsOneWidget);
        }
      }
    },
  );
  testWidgets('Visual review of loan detail and sheets', (tester) async {
    await tester.runAsync(() async {
      final bytes = await File(
        "${Platform.environment['FLUTTER_ROOT'] ?? 'C:/tools/flutter'}/bin/cache/artifacts/material_fonts/roboto-regular.ttf",
      ).readAsBytes();
      await (FontLoader(
        'Roboto',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      final icons = await File(
        'build/unit_test_assets/fonts/MaterialIcons-Regular.otf',
      ).readAsBytes();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(Future.value(ByteData.sublistView(icons)))).load();
    });
    await repository.add(
      LoanTerms(
        lender: 'Bajaj Finserv',
        kind: LoanKind.personal,
        icon: 'bank',
        principal: 30000000,
        openingBalance: 26543642,
        rate: 14,
        months: 36,
        emi: 1025330,
        paidBefore: 5,
        firstDue: DateTime(2026, 9, 1),
        day: 1,
        currency: 'INR',
        digits: 2,
      ),
      1,
    );
    final loans = await store();
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final captureKey = GlobalKey();
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      final boundary =
          captureKey.currentContext!.findRenderObject()
              as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.5);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        await Directory('build/loan-review').create(recursive: true);
        await File('build/loan-review/$name.png')
            .writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appTheme(Brightness.light),
          home: LoanDetailScreen(store: loans, id: loans.loans.single.id),
        ),
      ),
    );
    await capture('detail');
    await tester.tap(find.byTooltip('More options'));
    await capture('menu');
    await tester.tap(find.text('Change rate'));
    await capture('rate-sheet');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Schedule'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Schedule'));
    await capture('schedule');
    expect(tester.takeException(), isNull);
  });
}
