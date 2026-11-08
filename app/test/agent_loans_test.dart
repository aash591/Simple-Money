import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/ledger_match.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/debt_repository.dart';
import 'package:simple_money/data/repositories/loan_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/domain/debt.dart';
import 'package:simple_money/domain/loan.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/loan_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/ui/components/app_icon.dart';
import 'package:simple_money/ui/components/detail_page.dart';
import 'package:simple_money/ui/more/loans/loan_detail_screen.dart';
import 'package:simple_money/ui/more/ai/ai_suggestions_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/transactions/transaction_sheet.dart';

/// The Bajaj phone EMI statement from devtimefiles, as an AI app reads it. Six
/// instalments cleared, the first with ₹569 of fees inside it.
Map<String, Object?> bajaj({List<Map<String, Object?>>? payments}) => {
  'lender': 'Bajaj Finance',
  'asset': 'Phone',
  'amount': '25,801.00',
  'rate': 0,
  'months': 12,
  'emi': '2150.00',
  'start_date': '2026-05-12',
  'first_due': '2026-06-02',
  'end_date': '2027-05-02',
  'outstanding': '12,901.00',
  'as_of': '2026-11-03',
  'paid_from_last_digits': 'xxxxxxxxxxxxx2199',
  'payments':
      payments ??
      [
        {'date': '2026-06-02', 'amount': '2,719.00', 'fee': '569.00'},
        for (final month in ['07', '08', '09', '10', '11'])
          {'date': '2026-$month-02', 'amount': '2,150.00'},
      ],
};

void main() {
  late AppDatabase db;
  late AgentTools tools;
  late int sbi, hdfc;
  late int personal;

  Future<Map<String, Object?>> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await tools.call(name, args);
    final text = ((result['content'] as List).single as Map)['text'] as String;
    if (result['isError'] == true) return {'error': text};
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  }

  Future<int> saved(
    int minor,
    DateTime date, {
    String title = 'BAJAJ FINANCE LTD',
    int? account,
    TransactionType type = TransactionType.expense,
    int? category,
  }) => TransactionRepository(db).addExpenseOrIncome(
    type: type,
    amountMinor: minor,
    accountId: account ?? sbi,
    categoryId: category ?? personal,
    title: title,
    date: date,
  );

  Future<int> balance(int account) async => (await AccountRepository(
    db,
  ).load()).firstWhere((a) => a.id == account).balanceMinor;

  Future<int> suggestionId() async => (await tools.suggestions.load(
    limit: 1,
  )).single.id;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tools = AgentTools(db);
    final accounts = AccountRepository(db);
    sbi = await accounts.save(
      name: 'SBI',
      currency: 'INR',
      digits: 2,
      openingBalance: 5000000,
      lastDigits: '2199',
    );
    hdfc = await accounts.save(
      name: 'HDFC',
      currency: 'INR',
      digits: 2,
      openingBalance: 5000000,
      lastDigits: '1234',
    );
    final categories = await CategoryRepository(db).load();
    personal = categories
        .firstWhere((c) => c.type == CategoryType.expense)
        .id;
  });

  tearDown(() => db.close());

  group('A loan from a statement', () {
    test('finds what the ledger has and counts the rest as paid', () async {
      final first = await saved(271900, DateTime(2026, 6, 2, 9));
      for (final month in [7, 8, 9, 10]) {
        // A debit can land a day from the lender's date.
        await saved(215000, DateTime(2026, month, 3, 9));
      }
      final before = await balance(sbi);

      final reply = await call('suggest_loan', bajaj());
      expect(reply['error'], isNull);
      expect(reply['loan'], 'Phone · Bajaj Finance');
      expect(reply['paid_from'], 'SBI');
      expect(reply['repaid'], '12900.00');
      expect(reply['left'], '12901.00');
      expect(reply['next_due'], '2026-12-02');
      expect(reply['payments_found_in_ledger'], 5);
      expect(reply['payments_not_found'], 1);
      // Nothing moves until it's approved.
      expect(await LoanRepository(db).load(), isEmpty);

      final suggestion = (await tools.suggestions.load()).single;
      expect(suggestion.detail, contains('Paid from SBI'));
      expect(
        suggestion.detail,
        contains('5 of 6 payments found in your accounts'),
      );

      expect(await tools.suggestions.apply(suggestion.id), isNull);
      final loan = (await LoanRepository(db).load()).single;
      expect(loan.title, 'Phone · Bajaj Finance');
      expect(loan.icon, 'phone');
      expect(loan.terms.rate, 0);
      expect(loan.outstanding, 1290100);
      expect(loan.paid, 6);
      expect(loan.charges, 56900);
      expect(loan.events.first.fee, 56900);
      expect(loan.events.first.principal, 215000);
      expect(loan.nextDue, DateTime(2026, 12, 2));
      expect(loan.closed, isFalse);

      // The ledger's own payments now belong to the loan, untouched in amount.
      expect(loan.events.first.transactionId, first);
      expect(await balance(sbi), before);
      expect(loan.events.last.offLedger, isTrue);
      expect(loan.events.last.transactionId, isNull);
      final row = await db
          .customSelect('SELECT * FROM transactions WHERE id = $first')
          .getSingle();
      expect(row.read<String>('title'), 'Phone · Bajaj Finance');
      expect(row.read<int>('category_id'), isNot(personal));
      expect(row.read<int>('amount_minor'), 271900);
    });

    test('the schedule ends where the statement does', () async {
      await call('suggest_loan', bajaj());
      await tools.suggestions.apply(await suggestionId());
      final loan = (await LoanRepository(db).load()).single;
      expect(loan.schedule.length, 6);
      expect(loan.schedule.last.due, DateTime(2027, 5, 2));
      // The ₹1 left by rounding the EMI goes on the last instalment.
      expect(loan.schedule.last.amount, 215100);
    });

    test('undo gives every transaction back', () async {
      final id = await saved(271900, DateTime(2026, 6, 2, 9));
      final before = await balance(sbi);
      await call('suggest_loan', bajaj());
      final suggestion = await suggestionId();
      await tools.suggestions.apply(suggestion);

      expect(await tools.suggestions.undo(suggestion), isNull);
      expect(await LoanRepository(db).load(), isEmpty);
      expect(await db.customSelect('SELECT * FROM loan_events').get(), isEmpty);
      final row = await db
          .customSelect('SELECT * FROM transactions WHERE id = $id')
          .getSingle();
      expect(row.read<String>('title'), 'BAJAJ FINANCE LTD');
      expect(row.read<int>('category_id'), personal);
      expect(await balance(sbi), before);
    });

    test('the loan screen’s undo keeps a taken-over payment', () async {
      final id = await saved(215000, DateTime(2026, 11, 2, 9));
      await call('suggest_loan', bajaj());
      await tools.suggestions.apply(await suggestionId());
      final repository = LoanRepository(db);
      await repository.undo((await repository.load()).single);
      final row = await db
          .customSelect('SELECT * FROM transactions WHERE id = $id')
          .getSingleOrNull();
      expect(row, isNotNull);
      expect(row!.read<int>('category_id'), personal);
      // A statement-only payment can be undone too.
      await repository.undo((await repository.load()).single);
      expect((await repository.load()).single.events.length, 4);
    });

    test('adds missing payments to the account only when asked', () async {
      final before = await balance(sbi);
      await call('suggest_loan', {...bajaj(), 'add_missing_to_account': true});
      final suggestion = await suggestionId();
      await tools.suggestions.apply(suggestion);
      expect(await balance(sbi), before - 271900 - 215000 * 5);
      await tools.suggestions.undo(suggestion);
      expect(await balance(sbi), before);
    });

    test('a match never takes money coming in', () async {
      await saved(
        215000,
        DateTime(2026, 7, 2),
        type: TransactionType.income,
        category: (await CategoryRepository(
          db,
        ).load()).firstWhere((c) => c.type == CategoryType.income).id,
      );
      final reply = await call('suggest_loan', bajaj());
      expect(reply['payments_found_in_ledger'], 0);
    });

    test('prefers the payment that names the lender', () async {
      await saved(215000, DateTime(2026, 7, 2, 12), title: 'Rent', account: hdfc);
      final bajajPayment = await saved(215000, DateTime(2026, 7, 4));
      final reply = await call('suggest_loan', {
        ...bajaj(),
        'paid_from_last_digits': null,
        'paid_from_account_id': sbi,
      });
      final rows = (reply['payments'] as List).cast<Map>();
      expect(rows[1]['transaction_id'], bajajPayment);
    });

    test('a wrong match can be corrected', () async {
      final wrong = await saved(215000, DateTime(2026, 7, 2));
      final right = await saved(
        215000,
        DateTime(2026, 6, 20),
        title: 'NACH',
        account: hdfc,
      );
      final payments = [
        {'date': '2026-06-02', 'amount': '2719', 'fee': '569'},
        {'date': '2026-07-02', 'amount': '2150', 'transaction_id': right},
        for (final month in ['08', '09', '10', '11'])
          {'date': '2026-$month-02', 'amount': '2150', 'not_in_ledger': true},
      ];
      final reply = await call('suggest_loan', bajaj(payments: payments));
      expect(reply['error'], isNull);
      final rows = (reply['payments'] as List).cast<Map>();
      expect(rows[1]['transaction_id'], right);
      expect(rows.any((r) => r['transaction_id'] == wrong), isFalse);
    });

    test('matches by day, wherever in the day the debit landed', () async {
      final late = await saved(215000, DateTime(2026, 7, 5, 22));
      await saved(215000, DateTime(2026, 8, 6, 9));
      final rows =
          ((await call('suggest_loan', bajaj()))['payments'] as List)
              .cast<Map>();
      expect(rows[1]['transaction_id'], late);
      // Four days out is another payment.
      expect(rows[2]['transaction_id'], isNull);
    });

    test('a failed approval leaves nothing behind', () async {
      final first = await saved(271900, DateTime(2026, 6, 2));
      final second = await saved(215000, DateTime(2026, 7, 2));
      final before = await balance(sbi);
      await call('suggest_loan', bajaj());
      await TransactionRepository(db).delete(second);

      final id = await suggestionId();
      expect(await tools.suggestions.apply(id), contains('no longer exists'));
      expect(await LoanRepository(db).load(), isEmpty);
      expect(await db.customSelect('SELECT * FROM loan_events').get(), isEmpty);
      final row = await db
          .customSelect('SELECT * FROM transactions WHERE id = $first')
          .getSingle();
      expect(row.read<String>('title'), 'BAJAJ FINANCE LTD');
      expect(await balance(sbi), before + 215000);
      final waiting = (await tools.suggestions.load()).single;
      expect(waiting.error, contains('no longer exists'));
    });

    test('a loan with new payments can’t be undone from here', () async {
      await call('suggest_loan', bajaj());
      final suggestion = await suggestionId();
      await tools.suggestions.apply(suggestion);
      final repository = LoanRepository(db);
      await repository.record(
        (await repository.load()).single,
        kind: LoanEventKind.emi,
        date: DateTime.now(),
        accountId: sbi,
        amount: 215000,
      );
      expect(
        await tools.suggestions.undo(suggestion),
        contains('More › Loans'),
      );
      expect((await repository.load()).single.events.length, 7);
    });

    test('rejects payments outside the loan', () async {
      final reply = await call(
        'suggest_loan',
        bajaj(
          payments: [
            {'date': '2026-05-01', 'amount': '2150'},
          ],
        ),
      );
      expect(reply['error'], contains('2026-05-01'));
    });

    test('says when the payments don’t add up', () async {
      final reply = await call(
        'suggest_loan',
        bajaj(
          payments: [
            // The fee left out of the first instalment.
            {'date': '2026-06-02', 'amount': '2719'},
            for (final month in ['07', '08', '09', '10', '11'])
              {'date': '2026-$month-02', 'amount': '2150'},
          ],
        ),
      );
      expect(reply['error'], contains('12332.00'));
      expect(reply['error'], contains('12901.00'));
      expect(await tools.suggestions.pendingCount(), 0);
    });

    test('with only a balance, picks the loan up from there', () async {
      final reply = await call('suggest_loan', {...bajaj(), 'payments': null});
      expect(reply['next_due'], '2026-12-02');
      await tools.suggestions.apply(await suggestionId());
      final loan = (await LoanRepository(db).load()).single;
      expect(loan.terms.existing, isTrue);
      expect(loan.outstanding, 1290100);
      expect(loan.events, isEmpty);
      expect(loan.nextDue, DateTime(2026, 12, 2));
    });

    test('spreads interest a statement doesn’t split', () async {
      final reply = await call('suggest_loan', {
        'lender': 'HDFC Bank',
        'amount': '100000',
        'rate': 12,
        'months': 12,
        'emi': '8885',
        'start_date': '2026-01-05',
        'first_due': '2026-02-05',
        'outstanding': '84000',
        'paid_from_account_id': hdfc,
        'payments': [
          {'date': '2026-02-05', 'amount': '8885'},
          {'date': '2026-03-05', 'amount': '8885'},
        ],
      });
      expect(reply['error'], isNull);
      await tools.suggestions.apply(await suggestionId());
      final loan = (await LoanRepository(db).load()).single;
      expect(loan.outstanding, 8400000);
      expect(loan.interestPaid, 8885 * 2 * 100 - 1600000);
      expect(
        loan.events.first.interest,
        greaterThan(loan.events.last.interest),
      );
    });

    test('adopts the money received and charges paid', () async {
      final landed = await saved(
        4900000,
        DateTime(2026, 8, 1),
        title: 'NEFT',
        type: TransactionType.income,
        category: (await CategoryRepository(
          db,
        ).load()).firstWhere((c) => c.type == CategoryType.income).id,
      );
      final before = await balance(sbi);
      final reply = await call('suggest_loan', {
        'lender': 'KreditBee',
        'kind': 'personal',
        'amount': '50000',
        'rate': 18,
        'months': 12,
        'emi': '4584',
        'start_date': '2026-08-01',
        'first_due': '2026-09-01',
        'charges': '1000',
        'charges_deducted': true,
        'received_in_account_id': sbi,
        'paid_from_account_id': sbi,
      });
      expect(reply['error'], isNull);
      final suggestion = await suggestionId();
      await tools.suggestions.apply(suggestion);
      final loan = (await LoanRepository(db).load()).single;
      expect(loan.disbursalId, landed);
      expect(await balance(sbi), before);
      await tools.suggestions.undo(suggestion);
      final row = await db
          .customSelect('SELECT * FROM transactions WHERE id = $landed')
          .getSingle();
      expect(row.read<String>('title'), 'NEFT');
      expect(await balance(sbi), before);
    });

    test('won’t suggest a loan twice', () async {
      await call('suggest_loan', bajaj());
      await tools.suggestions.apply(await suggestionId());
      final reply = await call('suggest_loan', bajaj());
      expect(reply['error'], contains('already tracked'));
    });

    test('asks which account when nothing shows it', () async {
      final reply = await call('suggest_loan', {
        ...bajaj(),
        'paid_from_last_digits': '9999',
      });
      expect(reply['error'], contains('paid_from_account_id'));
    });

    test('lists a loan once it is tracked', () async {
      await call('suggest_loan', bajaj());
      await tools.suggestions.apply(await suggestionId());
      final loans = (await call('list_loans'))['loans'] as List;
      expect((loans.single as Map)['left'], '12901.00');
      expect((loans.single as Map)['next_due'], '2026-12-02');
    });

    test('list_icons finds a key suggest_loan takes', () async {
      final icons = (await call('list_icons', {'query': 'phone'}))['icons'];
      expect(icons, contains('phone'));
      final reply = await call('suggest_loan', {
        ...bajaj(),
        'asset_icon': 'not_an_icon',
      });
      expect(reply['error'], contains('list_icons'));
    });
  });

  group('A debt entry', () {
    Map<String, Object?> lent(Map<String, Object?> extra) => {
      'items': [
        {
          'person': 'Rahul Nair',
          'kind': 'lend',
          'amount': '5,000',
          'date': '2026-10-05',
          ...extra,
        },
      ],
    };

    test('with no account is only a record', () async {
      final before = await balance(sbi);
      final reply = await call('suggest_debt_entries', lent({}));
      expect(reply['suggested'], 1);
      await tools.suggestions.apply(await suggestionId());
      final person = (await DebtRepository(db).load()).single;
      expect(person.person.name, 'Rahul Nair');
      expect(person.entries.single.amountMinor, 500000);
      expect(person.entries.single.transactionId, isNull);
      expect(person.owesYou, isTrue);
      expect(await balance(sbi), before);
    });

    test('with an account moves the money, and undo takes it back', () async {
      final before = await balance(hdfc);
      await call(
        'suggest_debt_entries',
        lent({'account_id': hdfc, 'due_date': '2026-12-01'}),
      );
      final suggestion = await suggestionId();
      await tools.suggestions.apply(suggestion);
      expect(await balance(hdfc), before - 500000);
      final entry = (await DebtRepository(db).load()).single.entries.single;
      expect(entry.dueDate, DateTime(2026, 12, 1));

      expect(await tools.suggestions.undo(suggestion), isNull);
      expect(await balance(hdfc), before);
      expect(await DebtRepository(db).load(), isEmpty);
    });

    test('uses the payment already saved when it names the person', () async {
      final id = await saved(
        500000,
        DateTime(2026, 10, 5, 11),
        title: 'UPI RAHUL NAIR',
      );
      final before = await balance(sbi);
      await call('suggest_debt_entries', lent({'account_id': sbi}));
      final suggestion = await suggestionId();
      await tools.suggestions.apply(suggestion);
      final entry = (await DebtRepository(db).load()).single.entries.single;
      expect(entry.transactionId, id);
      expect(entry.accountId, sbi);
      expect(await balance(sbi), before);

      expect(await tools.suggestions.undo(suggestion), isNull);
      expect(await DebtRepository(db).load(), isEmpty);
      final row = await db
          .customSelect('SELECT * FROM transactions WHERE id = $id')
          .getSingle();
      expect(row.read<String>('title'), 'UPI RAHUL NAIR');
      expect(row.read<int>('category_id'), personal);
      expect(await balance(sbi), before);
    });

    test('asks rather than guesses when a payment might be it', () async {
      final id = await saved(500000, DateTime(2026, 10, 6), title: 'UPI 8842');
      final reply = await call('suggest_debt_entries', lent({}));
      expect(reply['suggested'], 0);
      final why = ((reply['rejected'] as List).single as Map)['error'];
      expect(why, contains('id $id'));

      expect(
        (await call(
          'suggest_debt_entries',
          lent({'transaction_id': id}),
        ))['suggested'],
        1,
      );
      expect(
        (await call(
          'suggest_debt_entries',
          lent({'ignore_matches': true}),
        ))['suggested'],
        1,
      );
    });

    test('adds to a person already listed, once for a new one', () async {
      await DebtRepository(db).addEntry(
        newPersonName: 'Rahul Nair',
        kind: DebtKind.lend,
        amountMinor: 100000,
        currency: 'INR',
        digits: 2,
        date: DateTime(2026, 9),
      );
      await call('suggest_debt_entries', {
        'items': [
          {
            'person': 'rahul nair',
            'kind': 'collect',
            'amount': '1000',
            'date': '2026-10-01',
          },
          {'person': 'Meera', 'kind': 'borrow', 'amount': '200', 'date': '2026-10-01'},
          {'person': 'Meera', 'kind': 'repay', 'amount': '50', 'date': '2026-10-02'},
        ],
      });
      await tools.suggestions.applyAll();
      final people = await DebtRepository(db).load();
      expect(people.map((p) => p.person.name), ['Meera', 'Rahul Nair']);
      expect(people.last.settled, isTrue);
      expect(people.first.balances.single.amountMinor, -15000);
      final listed = (await call('list_debts'))['people'] as List;
      expect(((listed.single as Map)['outstanding'] as List).single, {
        'you_owe': '150.00',
        'currency': 'INR',
      });
    });
  });

  group('The shared ledger match', () {
    test('marks what is owned, and picks the nearest free one', () async {
      final free = await saved(100000, DateTime(2026, 3, 2));
      final owned = await saved(100000, DateTime(2026, 3, 3));
      await db.customStatement(
        'INSERT INTO debt_people (id, name, created_at) VALUES (1, \'A\', 0)',
      );
      await db.customStatement(
        '''INSERT INTO debt_entries (person_id, kind, amount_minor, currency,
          digits, transaction_id, date, created_at)
          VALUES (1, 'lend', 100000, 'INR', 2, $owned, 0, 0)''',
      );
      final ledger = await ledgerBetween(
        db,
        DateTime(2026, 3),
        DateTime(2026, 3, 9),
      );
      expect(ledger.firstWhere((t) => t.id == owned).free, isFalse);
      expect(ledger.firstWhere((t) => t.id == owned).transferable, isFalse);
      final match = closestInLedger(
        ledger,
        amountMinor: 100000,
        date: DateTime(2026, 3, 3),
        claimed: {},
        near: withinDays(3),
        fits: (t) => t.free,
      );
      expect(match?.id, free);
      expect(
        closestInLedger(
          ledger,
          amountMinor: 100000,
          date: DateTime(2026, 3, 3),
          claimed: {free},
          near: withinDays(3),
          fits: (t) => t.free,
        ),
        isNull,
      );
    });
  });

  testWidgets('Loan history numbers payments from the first', (tester) async {
    tester.view.physicalSize = const Size(400, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    late LoanStore loans;
    late int id;
    await tester.runAsync(() async {
      await call('suggest_loan', bajaj());
      await tools.suggestions.apply(await suggestionId());
      final accounts = AccountStore(AccountRepository(db));
      final transactions = TransactionStore(
        TransactionRepository(db),
        accounts,
      );
      loans = LoanStore(
        LoanRepository(db),
        accountStore: accounts,
        categoryStore: CategoryStore(CategoryRepository(db)),
        transactionStore: transactions,
      );
      await Future.wait([accounts.load(), transactions.load()]);
      await loans.load();
      id = loans.loans.single.id;
    });
    addTearDown(loans.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: LoanDetailScreen(store: loans, id: id),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    List<int?> numbers() => [
      for (final t in tester.widgetList<DetailIconTile>(
        find.byType(DetailIconTile),
      ))
        t.number,
    ];
    // Newest at the top, so the numbers run down towards 1, not ticks.
    expect(numbers().take(2), [6, 5]);
    expect(find.byIcon(Icons.check_rounded), findsNothing);
    expect(find.text('October 2026'), findsOneWidget);
    // Each month says what is left at its end, in the month's heading:
    // ₹25,801 less the principal of every payment so far.
    expect(find.text('₹12,901 left'), findsOneWidget);
    expect(find.text('₹15,051 left'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('June 2026'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(numbers().last, 1);
    expect(find.text('₹23,651 left'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.textContaining('principal still owed'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('principal still owed'), findsOneWidget);
  });

  group('The suggested loan card', () {
    Future<void> show(WidgetTester tester) async {
      tester.view.physicalSize = const Size(400, 2000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      await tester.runAsync(() async {
        await saved(271900, DateTime(2026, 6, 2, 9));
        for (final month in [7, 8, 9, 10]) {
          await saved(215000, DateTime(2026, month, 2, 9));
        }
        await call('suggest_loan', bajaj());
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: AiSuggestionsScreen(database: db),
        ),
      );
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('shows the loan, its bank and its payments', (tester) async {
      await show(tester);
      expect(find.text('Phone · Bajaj Finance'), findsOneWidget);
      expect(find.text('New loan · Monthly EMI'), findsOneWidget);
      expect(find.text('Left to repay'), findsOneWidget);
      expect(find.text('No interest'), findsOneWidget);
      expect(find.text('2 Dec 2026'), findsOneWidget);
      expect(find.text('5 of 6 found'), findsOneWidget);
      // The lines written for the AI aren't shown as well.
      expect(find.textContaining('payments found'), findsNothing);

      // The bank that pays, with its own icon.
      final paidFrom = find
          .ancestor(of: find.text('Paid from'), matching: find.byType(Row))
          .first;
      expect(
        find.descendant(of: paidFrom, matching: find.byType(AppIcon)),
        findsOneWidget,
      );
      expect(
        find.descendant(of: paidFrom, matching: find.text('SBI')),
        findsOneWidget,
      );

      // Newest first, trimmed until asked for, then real rows.
      expect(find.text('EMI 6'), findsOneWidget);
      expect(find.text('Counted as paid'), findsOneWidget);
      expect(find.text('BAJAJ FINANCE LTD'), findsNWidgets(2));
      await tester.tap(find.text('Show all 6'));
      await settle(tester);
      expect(find.text('BAJAJ FINANCE LTD'), findsNWidgets(5));
      expect(find.text('Show less'), findsOneWidget);

      await tester.tap(find.text('BAJAJ FINANCE LTD').first);
      await settle(tester);
      expect(find.byType(TransactionSheet), findsOneWidget);
    });

    testWidgets('says what happens to the balance, and lets you choose', (
      tester,
    ) async {
      await show(tester);
      late int before;
      await tester.runAsync(() async => before = await balance(sbi));
      expect(find.text('SBI balance'), findsOneWidget);
      expect(find.text('Stays the same'), findsOneWidget);
      expect(find.textContaining('Only tracked here'), findsOneWidget);

      await tester.tap(find.byType(Switch));
      await settle(tester);
      expect(find.text('Stays the same'), findsNothing);
      expect(find.textContaining('→'), findsOneWidget);
      expect(find.text('Adds to SBI'), findsOneWidget);
      expect(
        find.text('Takes the missing payment out of SBI'),
        findsOneWidget,
      );

      await tester.tap(find.text('Approve'));
      await settle(tester);
      late int after;
      await tester.runAsync(() async => after = await balance(sbi));
      expect(after, before - 215000);
    });

    testWidgets('turning it off again leaves the balance alone', (
      tester,
    ) async {
      await show(tester);
      await tester.tap(find.byType(Switch));
      await settle(tester);
      await tester.tap(find.byType(Switch));
      await settle(tester);
      late int before;
      await tester.runAsync(() async {
        before = await balance(sbi);
        await tools.suggestions.applyAll();
      });
      late int after;
      await tester.runAsync(() async => after = await balance(sbi));
      expect(after, before);
    });
  });

  test('Suggestions from before loans survive the upgrade', () async {
    final old = AppDatabase(
      NativeDatabase.memory(
        setup: (raw) {
          // Version 38's table, which allowed five kinds.
          raw.execute('''CREATE TABLE agent_suggestions (
            id INTEGER PRIMARY KEY AUTOINCREMENT, batch_id TEXT NOT NULL,
            kind TEXT NOT NULL CHECK(kind IN ('new_category', 'sms_correction',
              'transaction_edit', 'parser_rule', 'statement_layout')),
            target TEXT NOT NULL, payload TEXT NOT NULL, before TEXT,
            summary TEXT NOT NULL, detail TEXT NOT NULL, reason TEXT,
            status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending',
              'applied', 'rejected', 'undone')),
            error TEXT, created_at INTEGER NOT NULL, decided_at INTEGER)''');
          raw.execute("""INSERT INTO agent_suggestions
            (batch_id, kind, target, payload, summary, detail, created_at)
            VALUES ('b', 'statement_layout', 'x', '{}', 'Layout', '', 1)""");
          raw.userVersion = 38;
        },
      ),
    );
    addTearDown(old.close);
    final kinds = await old
        .customSelect('SELECT kind FROM agent_suggestions')
        .map((r) => r.read<String>('kind'))
        .get();
    expect(kinds, ['statement_layout']);
    for (final kind in ['new_loan', 'debt_entry']) {
      await old.customStatement("""INSERT INTO agent_suggestions
        (batch_id, kind, target, payload, summary, detail, created_at)
        VALUES ('b', '$kind', 'x', '{}', 'Loan', '', 2)""");
    }
  });

  test('a rounding remainder stays on the last instalment only', () {
    Loan loan(int emi, int months) => Loan(
      id: 1,
      accountId: 1,
      terms: LoanTerms(
        lender: 'A',
        kind: LoanKind.other,
        icon: 'bank',
        principal: 1000000,
        openingBalance: 1000000,
        startDate: DateTime(2026),
        snapshotDate: DateTime(2026),
        rate: 0,
        months: months,
        emi: emi,
        paidBefore: 0,
        firstDue: DateTime(2026, 2),
        day: 1,
        currency: 'INR',
        digits: 2,
      ),
    );
    // 300 × 3 leaves ₹100, far too much to hide in the last instalment.
    expect(loan(300000, 3).projectedSchedule(DateTime(2026)).length, 4);
    expect(loan(333333, 3).projectedSchedule(DateTime(2026)).length, 3);
    expect(
      loan(333333, 3).projectedSchedule(DateTime(2026)).last.amount,
      333334,
    );
  });
}
