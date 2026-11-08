import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/repositories/statement_import_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/data/statements/statement_reconciliation.dart';
import 'package:simple_money/data/statements/upi_statement.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/transaction.dart';

void main() {
  late AppDatabase db;
  late StatementImportRepository repository;
  late int sbi, union, expenseCategory, incomeCategory;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory(), false);
    repository = StatementImportRepository(db);
    final accounts = AccountRepository(db);
    sbi = await accounts.save(
      name: 'SBI',
      currency: 'INR',
      digits: 2,
      openingBalance: 1000000,
      lastDigits: '2199',
      institution: 'State Bank of India',
    );
    union = await accounts.save(
      name: 'Union',
      currency: 'INR',
      digits: 2,
      openingBalance: 1000000,
      lastDigits: '3225',
      institution: 'Union Bank of India',
    );
    Future<int> category(String type) async =>
        (await db
                .customSelect(
                  'SELECT id FROM categories WHERE type = ? LIMIT 1',
                  variables: [Variable(type)],
                )
                .getSingle())
            .read<int>('id');
    expenseCategory = await category('expense');
    incomeCategory = await category('income');
  });
  tearDown(() => db.close());

  const sbiNamed = StatementAccount(
    bank: 'State Bank of India',
    digits: '2199',
  );
  const unionNamed = StatementAccount(
    bank: 'Union Bank of India',
    digits: '3225',
  );

  UpiStatementRow row(
    int rupees,
    DateTime date, {
    UpiStatementDirection direction = UpiStatementDirection.debit,
    String? reference,
    StatementAccount account = sbiNamed,
    StatementAccount? toAccount,
  }) => UpiStatementRow(
    date: date,
    direction: direction,
    amountMinor: rupees * 100,
    counterparty: 'Shop',
    reference: reference,
    account: account,
    toAccount: toAccount,
  );

  Future<List<StatementMatch?>> reconcile(List<UpiStatementRow> rows) async =>
      matchStatementRows(
        rows,
        await repository.candidates(rows),
        (r) => (
          account: r.account == unionNamed ? union : sbi,
          toAccount: r.toAccount == null
              ? null
              : r.toAccount == unionNamed
              ? union
              : sbi,
        ),
      );

  /// The ledger transaction each row already is; null for new rows and
  /// ones that complete a transfer.
  Future<List<int?>> match(List<UpiStatementRow> rows) async => [
    for (final m in await reconcile(rows))
      m == null || m.completesTransfer ? null : m.transactionId,
  ];

  Future<int> addExpense(
    int rupees,
    DateTime date, {
    String? note,
    int? account,
  }) => TransactionRepository(db).addExpenseOrIncome(
    type: TransactionType.expense,
    amountMinor: rupees * 100,
    accountId: account ?? sbi,
    categoryId: expenseCategory,
    note: note,
    date: date,
  );

  test('a row an SMS already recorded matches by its UPI reference', () async {
    final sms = await addExpense(
      90,
      DateTime(2026, 4, 2, 9),
      note: 'Sender: SBIUPI\n\nRs90 debited… UPI Ref No 609117907153',
    );
    final matches = await match([
      // A day off and a different amount still match a shared reference.
      row(91, DateTime(2026, 4, 1, 21, 32), reference: '609117907153'),
    ]);
    expect(matches, [sms]);
  });

  test('without a reference: same amount, account and day', () async {
    final existing = await addExpense(230, DateTime(2026, 4, 1, 21, 40));
    await addExpense(500, DateTime(2026, 4, 1, 12), account: union);
    final matches = await match([
      row(230, DateTime(2026, 4, 1, 21, 32)),
      // Same amount, but yesterday's payment is a different one.
      row(230, DateTime(2026, 4, 2, 21, 32)),
      // Right amount and day, wrong account.
      row(500, DateTime(2026, 4, 1, 12)),
    ]);
    expect(matches, [existing, null, null]);
  });

  test('each ledger transaction absorbs one row', () async {
    final tea = await addExpense(20, DateTime(2026, 4, 1, 10));
    final matches = await match([
      row(20, DateTime(2026, 4, 1, 10)),
      row(20, DateTime(2026, 4, 1, 16)),
    ]);
    expect(matches, [tea, null]);
  });

  test('added rows land in the ledger and a re-import finds them', () async {
    final rows = [
      row(1000, DateTime(2026, 4, 1, 14, 35), reference: '609170143345'),
      row(
        2000,
        DateTime(2026, 4, 1, 16, 3),
        direction: UpiStatementDirection.credit,
        reference: '692625007269',
        account: unionNamed,
      ),
      row(
        2500,
        DateTime(2026, 4, 1, 16, 12),
        direction: UpiStatementDirection.selfTransfer,
        reference: '609191990216',
        account: unionNamed,
        toAccount: sbiNamed,
      ),
    ];
    await repository.add(UpiStatementSource.googlePay, [
      StatementImport(
        row: rows[0],
        accountId: sbi,
        categoryId: expenseCategory,
      ),
      StatementImport(
        row: rows[1],
        accountId: union,
        categoryId: incomeCategory,
      ),
      StatementImport(row: rows[2], accountId: union, toAccountId: sbi),
    ]);

    final saved = await TransactionRepository(db).load();
    expect(saved, hasLength(3));
    final transfer = saved.singleWhere(
      (t) => t.type == TransactionType.transfer,
    );
    expect(transfer.accountId, union);
    expect(transfer.toAccountId, sbi);
    final payment = saved.singleWhere((t) => t.type == TransactionType.expense);
    expect(payment.title, 'Shop');
    expect(payment.note, contains('609170143345'));
    expect(payment.date, DateTime(2026, 4, 1, 14, 35));

    final balances = {
      for (final a in await AccountRepository(db).load()) a.id: a.balanceMinor,
    };
    expect(balances[sbi], 1000000 - 100000 + 250000);
    expect(balances[union], 1000000 + 200000 - 250000);

    expect((await match(rows)).nonNulls, hasLength(3));
  });

  test('an add that fails part-way adds nothing', () async {
    await expectLater(
      repository.add(UpiStatementSource.paytm, [
        StatementImport(
          row: row(10, DateTime(2026, 4, 1)),
          accountId: sbi,
          categoryId: expenseCategory,
        ),
        // A transfer to the account it came from is refused.
        StatementImport(
          row: row(
            20,
            DateTime(2026, 4, 1),
            direction: UpiStatementDirection.selfTransfer,
          ),
          accountId: sbi,
          toAccountId: sbi,
        ),
      ]),
      throwsArgumentError,
    );
    expect(await TransactionRepository(db).load(), isEmpty);
  });

  Future<int> addIncome(int rupees, DateTime date, {required int account}) =>
      TransactionRepository(db).addExpenseOrIncome(
        type: TransactionType.income,
        amountMinor: rupees * 100,
        accountId: account,
        categoryId: incomeCategory,
        date: date,
      );

  test('both legs of a transfer in one statement become one', () {
    final paired = pairTransferLegs([
      // Both banks quote the transfer's reference.
      row(500, DateTime(2026, 4, 1, 10), reference: '609100000001'),
      row(
        500,
        DateTime(2026, 4, 1, 10, 1),
        direction: UpiStatementDirection.credit,
        reference: '609100000001',
        account: unionNamed,
      ),
      // Paying GoDaddy and being paid the same amount minutes later by
      // someone else is no transfer.
      row(116, DateTime(2026, 4, 1, 14, 53), reference: '624898918474'),
      row(
        116,
        DateTime(2026, 4, 1, 14, 58),
        direction: UpiStatementDirection.credit,
        reference: '624835231853',
        account: unionNamed,
      ),
      // A self transfer takes the receipt into the account it names.
      row(
        70,
        DateTime(2026, 4, 2, 9),
        direction: UpiStatementDirection.selfTransfer,
        toAccount: unionNamed,
      ),
      row(
        70,
        DateTime(2026, 4, 2, 9, 5),
        direction: UpiStatementDirection.credit,
        account: unionNamed,
      ),
    ]);
    expect(paired.map((r) => (r.direction, r.amountMinor)), [
      (UpiStatementDirection.selfTransfer, 50000),
      (UpiStatementDirection.debit, 11600),
      (UpiStatementDirection.credit, 11600),
      (UpiStatementDirection.selfTransfer, 7000),
    ]);
    expect(paired.first.toAccount, unionNamed);
  });

  test(
    'a shared reference makes a receipt the other leg, not a copy',
    () async {
      final sent = await addExpense(
        800,
        DateTime(2026, 4, 3, 18),
        note: 'UPI ref: 661638589646',
      );
      UpiStatementRow receipt({String? reference}) => row(
        800,
        DateTime(2026, 4, 3, 18, 2),
        direction: UpiStatementDirection.credit,
        account: unionNamed,
        reference: reference,
      );
      final linked = (await reconcile([receipt(reference: '661638589646')]))
          .single!;
      expect(linked.transactionId, sent);
      expect((linked.fromAccountId, linked.toAccountId), (sbi, union));

      // The same amount and time alone isn't a transfer: it's new income.
      expect(await reconcile([receipt()]), [null]);

      // Told it isn't a transfer, the shared reference makes it a copy.
      final separate = matchStatementRows(
        [receipt(reference: '661638589646')],
        await repository.candidates([receipt()]),
        (_) => (account: union, toAccount: null),
        keepSeparate: {0},
      );
      expect(separate.single?.completesTransfer, isFalse);
    },
  );

  test('money to or from your own name is a self transfer', () {
    final owner = statementOwnerIn([
      'Mr. ASHIQUE  M',
      'ashique4786@gmail.com',
      'Transaction Statement for +917034321846',
    ]);
    expect(owner.names, {'ashique m'});
    expect(owner.handles, {'ashique4786', '7034321846'});

    const kotak = StatementAccount(bank: 'Kotak Mahindra Bank', digits: '4825');
    UpiStatementRow own(
      String name,
      UpiStatementDirection direction,
      String bank,
    ) => UpiStatementRow(
      date: DateTime(2026, 10, 26),
      direction: direction,
      amountMinor: 1000,
      counterparty: name,
      account: kotak,
      counterpartyBank: bank,
    );
    final rows = markOwnTransfers([
      own('ASHIQUE M', UpiStatementDirection.credit, 'Union Bank of India'),
      own('ashique4786-1@', UpiStatementDirection.debit, 'State Bank of India'),
      own('ASHIQUE MOHAN', UpiStatementDirection.debit, 'HDFC Bank'),
    ], owner);
    expect(rows[0].direction, UpiStatementDirection.selfTransfer);
    expect(rows[0].account?.label, 'Union Bank of India');
    expect(rows[0].toAccount, kotak);
    expect(rows[1].direction, UpiStatementDirection.selfTransfer);
    expect(rows[1].account, kotak);
    expect(rows[1].toAccount?.label, 'State Bank of India');
    // Someone else with a similar name is still someone else.
    expect(rows[2].direction, UpiStatementDirection.debit);
    // Two transfers in from the same bank minutes apart stay two.
    expect(pairTransferLegs([rows[0], rows[0]]), hasLength(2));
  });

  test('an account named only by its bank is found by the bank', () async {
    final all = await AccountRepository(db).load();
    expect(
      guessStatementAccount(
        const StatementAccount(bank: 'Union Bank of India', digits: ''),
        all,
      )?.id,
      union,
    );
    expect(guessStatementAccount(StatementAccount.other, all), isNull);
    // Cash is the one cash account, whatever it's called.
    final cash = await AccountRepository(db).save(
      name: 'Wallet',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      type: AccountType.cash,
    );
    expect(
      guessStatementAccount(
        StatementAccount.cash,
        await AccountRepository(db).load(),
      )?.id,
      cash,
    );
  });

  test('a self transfer whose two legs were recorded separately', () async {
    final sent = await addExpense(300, DateTime(2026, 4, 4, 9));
    final received = await addIncome(
      300,
      DateTime(2026, 4, 4, 9, 1),
      account: union,
    );
    final rows = [
      row(
        300,
        DateTime(2026, 4, 4, 9),
        direction: UpiStatementDirection.selfTransfer,
        toAccount: unionNamed,
      ),
    ];
    final match = (await reconcile(rows)).single!;
    expect(match.transactionId, sent);
    expect(match.otherLegId, received);

    await repository.add(
      UpiStatementSource.csv,
      const [],
      transfers: [StatementTransfer(row: rows.single, match: match)],
    );
    final saved = await TransactionRepository(db).load();
    final transfer = saved.single;
    expect(transfer.type, TransactionType.transfer);
    expect(transfer.accountId, sbi);
    expect(transfer.toAccountId, union);
    final balances = {
      for (final a in await AccountRepository(db).load()) a.id: a.balanceMinor,
    };
    expect(balances[sbi], 1000000 - 30000);
    expect(balances[union], 1000000 + 30000);
    // The transfer is now what a re-import finds.
    expect((await reconcile(rows)).single?.completesTransfer, isFalse);
  });

  test('statement accounts are recognised by digits, then bank', () {
    const accounts = [
      Account(
        id: 1,
        name: 'SBI',
        currency: 'INR',
        digits: 2,
        balanceMinor: 0,
        lastDigits: '2199',
        institution: 'SBI',
      ),
      Account(
        id: 2,
        name: 'Union',
        currency: 'INR',
        digits: 2,
        balanceMinor: 0,
        lastDigits: '3225',
      ),
      Account(
        id: 3,
        name: 'Federal',
        currency: 'INR',
        digits: 2,
        balanceMinor: 0,
        lastDigits: '1199',
        institution: 'Federal Bank',
      ),
    ];
    expect(guessStatementAccount(unionNamed, accounts)?.id, 2);
    // Paytm's two digits fit two accounts; the bank decides.
    expect(
      guessStatementAccount(
        const StatementAccount(bank: 'State Bank Of India', digits: '99'),
        accounts,
      )?.id,
      1,
    );
    expect(
      guessStatementAccount(const StatementAccount(digits: '99'), accounts),
      isNull,
    );
    expect(
      guessStatementAccount(const StatementAccount(digits: '4321'), accounts),
      isNull,
    );
  });

  test('two banks\' SMS of one transfer become that transfer', () async {
    final sms = SmsImportRepository(db);
    Future<void> receive(
      String id,
      String body, {
      required String direction,
      required String last4,
      required int minute,
    }) => db.customStatement(
      'INSERT INTO sms_imports(fingerprint,sender,body,received_at,candidate,rule_id,pack_version) VALUES (?,?,?,?,?,?,?)',
      [
        id,
        'BANK',
        body,
        DateTime(2026, 10, 26, 17, minute).millisecondsSinceEpoch,
        '{"amountMinor":1200,"currencyCode":"INR","direction":"$direction","accountLast4":"$last4"}',
        'test',
        1,
      ],
    );
    await receive(
      'sent',
      'Sent Rs.12.00 from A/c X2199 to SAMPLE PERSON. UPI Ref 666553422281.',
      direction: 'debit',
      last4: '2199',
      minute: 15,
    );
    await receive(
      'received',
      'A/c *3225 Credited for Rs:12.00 by Mob Bk ref no 666553422281',
      direction: 'credit',
      last4: '3225',
      minute: 16,
    );
    // The same amount into the same account under another reference is
    // someone else's payment.
    await receive(
      'other',
      'A/c *3225 Credited for Rs:12.00 by Mob Bk ref no 666500000000',
      direction: 'credit',
      last4: '3225',
      minute: 17,
    );
    for (final pending in (await sms.pending()).reversed) {
      await sms.save(
        pending,
        type: pending.credit ? TransactionType.income : TransactionType.expense,
        amountMinor: pending.amountMinor,
        accountId: pending.credit ? union : sbi,
        categoryId: pending.credit ? incomeCategory : expenseCategory,
        date: pending.receivedAt,
      );
    }

    final ledger = await TransactionRepository(db).load();
    final transfer = ledger.singleWhere(
      (t) => t.type == TransactionType.transfer,
    );
    expect((transfer.accountId, transfer.toAccountId), (sbi, union));
    // Both banks' messages stay on it, and both SMS point at it.
    expect(transfer.note, contains('UPI Ref 666553422281'));
    expect(transfer.note, contains('Credited for Rs:12.00'));
    final linked = await db
        .customSelect(
          'SELECT fingerprint FROM sms_imports WHERE transaction_id = ?',
          variables: [Variable(transfer.id)],
        )
        .get();
    expect(
      {for (final r in linked) r.read<String>('fingerprint')},
      {'sent', 'received'},
    );
    expect(
      ledger.where((t) => t.type == TransactionType.income).single.note,
      contains('666500000000'),
    );
    final balances = {
      for (final a in await AccountRepository(db).load()) a.id: a.balanceMinor,
    };
    expect(balances[sbi], 1000000 - 1200);
    expect(balances[union], 1000000 + 1200 + 1200);
  });

  test('legs pair by a shared reference, not by amount alone', () {
    LedgerCandidate leg(
      int id,
      TransactionType type,
      int account,
      String references,
    ) => LedgerCandidate(
      id: id,
      type: type,
      amountMinor: 1000,
      accountId: account,
      date: DateTime(2026, 10, 27, 14),
      references: references,
      transferable: true,
    );
    final pairs = recordedTransferLegs([
      leg(1, TransactionType.expense, 1, 'ref no 666659747707'),
      leg(2, TransactionType.income, 2, 'UPI Ref:666622731944'),
      leg(3, TransactionType.income, 2, 'UPI Ref:666659747707'),
      // The same account on both sides is a refund, not a transfer.
      leg(4, TransactionType.expense, 2, 'UPI Ref 666622731944'),
      leg(5, TransactionType.income, 3, 'no reference'),
    ]);
    expect(pairs.map((p) => (p.out.id, p.into.id)), [(1, 3)]);
  });
}
