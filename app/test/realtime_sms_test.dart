import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/realtime_sms_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/domain/realtime_sms_category.dart';
import 'package:simple_money/domain/transaction.dart';

void main() {
  late AppDatabase db;
  late RealtimeSmsRepository live;
  late PortableSmsEngine engine;
  late int bank, savings;
  final date = DateTime(2026, 10, 25, 12);
  BankSms message({
    bool credit = false,
    String digits = '1234',
    String reference = '123456789012',
  }) => BankSms(
    sender: 'AX-SBIUPI-S',
    receivedAt: date,
    body: credit
        ? 'Dear SBI User, your A/c X$digits-credited by Rs.500 on 25Oct26 transfer from SAMPLE SENDER Ref No $reference -SBI'
        : 'Dear SBI User, your A/c X$digits-debited by Rs.500 on 25Oct26 transfer to SAMPLE RECEIVER Ref No $reference -SBI',
  );
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    live = RealtimeSmsRepository(db);
    engine = BankSmsParser(
      const RuleCompiler().loadRuntime(
        jsonDecode(
          File(
            'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
          ).readAsStringSync(),
        ) as Map<String, dynamic>,
      ),
    );
    final name = engine.parse(message()).candidate!.bankName;
    bank = await AccountRepository(db).save(
      name: 'Bank',
      currency: 'INR',
      digits: 2,
      openingBalance: 100000,
      lastDigits: '1234',
      institution: name,
    );
    savings = await AccountRepository(db).save(
      name: 'Savings',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      lastDigits: '5678',
      institution: name,
    );
    await SmsImportRepository(db).enable(true);
  });
  tearDown(() => db.close());

  test('Undo category correction restores a paired transfer', () async {
    final debit = (await live.receive(message(), engine))!;
    await live.receive(message(credit: true, digits: '5678'), engine);
    await live.edit(debit.sms.id, accountId: bank, otherAccountId: savings);
    final category = (await CategoryRepository(
      db,
    ).load()).firstWhere((c) => c.type == CategoryType.expense);
    await live.selectCategory(debit.sms.id, category.id);
    expect(await TransactionRepository(db).load(), hasLength(2));
    final state = (await live.categoryConfirmation(debit.sms.id))!;
    await live.undoCategory(debit.sms.id, state['token'] as String);
    final transactions = await TransactionRepository(db).load();
    expect(transactions, hasLength(1));
    expect(transactions.single.type, TransactionType.transfer);
  });

  test('category correction learns merchant and undo restores rule and ledger', () async {
    BankSms purchase(String ref) => BankSms(
      sender: 'ATMSBI',
      receivedAt: date,
      body:
          'Dear Customer, transaction number $ref for Rs.383.00 by SBI Debit Card 1234 done at SAMPLE SHOP on 13Sep25 at 21:38:26. Your updated available balance is Rs.999999999. If not done by you, forward this SMS to 7400165218/ call 1800111109/9449112211 to block card. GOI helpline for cyber fraud 1930.',
    );
    final first = (await live.receive(purchase('1234'), engine))!;
    final original = first.categoryId;
    final category = (await CategoryRepository(db).load()).firstWhere(
      (c) => c.type == CategoryType.expense && c.id != original,
    );
    await live.selectCategory(first.sms.id, category.id);
    final confirmation = (await live.categoryConfirmation(first.sms.id))!;
    expect(confirmation['merchant'], isNotNull);
    expect((await live.load(first.sms.id))!.categoryId, category.id);
    // Persisted state survives a new repository instance / notification activity.
    final repo = RealtimeSmsRepository(db);
    final second = (await repo.receive(purchase('5678'), engine))!;
    expect(second.categoryId, category.id);
    await repo.undoCategory(first.sms.id, confirmation['token'] as String);
    expect((await repo.load(first.sms.id))!.categoryId, original);
    expect(await repo.categoryConfirmation(first.sms.id), isNull);
    final third = (await repo.receive(purchase('9012'), engine))!;
    expect(third.categoryId, original);
    // Undo does not retroactively alter a separately saved payment.
    expect((await repo.load(second.sms.id))!.categoryId, category.id);
  });

  test('stale undo cannot replace a newer category selection', () async {
    final first = (await live.receive(message(), engine))!;
    final categories = (await CategoryRepository(db).load())
        .where(
          (c) => c.type == CategoryType.expense && c.id != first.categoryId,
        )
        .take(2)
        .toList();
    await live.selectCategory(first.sms.id, categories[0].id);
    final old = (await live.categoryConfirmation(first.sms.id))!;
    await live.selectCategory(first.sms.id, categories[1].id);
    await live.undoCategory(first.sms.id, old['token'] as String);
    expect((await live.load(first.sms.id))!.categoryId, categories[1].id);
  });

  test('different references combine only after explicit selection', () async {
    final debit = (await live.receive(message(), engine))!;
    final credit = (await live.receive(
      message(credit: true, digits: '5678', reference: '999999999999'),
      engine,
    ))!;
    final matches = await live.possibleTransferMatches(
      debit.sms.id,
      accountId: bank,
      otherAccountId: savings,
    );
    expect(matches.map((m) => m.sms.id), [credit.sms.id]);
    expect(await TransactionRepository(db).load(), hasLength(2));
    await live.edit(
      debit.sms.id,
      accountId: bank,
      otherAccountId: savings,
      confirmedMatchId: credit.sms.id,
    );
    final transactions = await TransactionRepository(db).load();
    expect(transactions, hasLength(1));
    expect(transactions.single.type, TransactionType.transfer);
    expect(
      (await live.load(credit.sms.id))!.transactionId,
      transactions.single.id,
    );
    final accounts = await AccountRepository(db).load();
    expect(accounts.firstWhere((a) => a.id == bank).balanceMinor, 50000);
    expect(accounts.firstWhere((a) => a.id == savings).balanceMinor, 50000);
    await expectLater(
      live.edit(
        debit.sms.id,
        accountId: bank,
        otherAccountId: savings,
        confirmedMatchId: credit.sms.id,
      ),
      throwsStateError,
    );
    expect(await TransactionRepository(db).load(), hasLength(1));
  });

  test(
    'missing references offer candidates but never merge on receipt',
    () async {
      final debit = (await live.receive(message(reference: ''), engine))!;
      final credit = (await live.receive(
        message(credit: true, digits: '5678', reference: ''),
        engine,
      ))!;
      expect(debit.sms.reference, isNull);
      expect(credit.sms.reference, isNull);
      expect(
        await live.hasExactTransferMatch(
          debit.sms.id,
          accountId: bank,
          otherAccountId: savings,
        ),
        isFalse,
      );
      expect(await TransactionRepository(db).load(), hasLength(2));
      await live.edit(
        credit.sms.id,
        accountId: savings,
        otherAccountId: bank,
        confirmedMatchId: debit.sms.id,
      );
      expect(await TransactionRepository(db).load(), hasLength(1));
    },
  );

  test(
    'late SMS can attach to a confirmed transfer with a different reference',
    () async {
      final debit = (await live.receive(message(), engine))!;
      await live.edit(debit.sms.id, accountId: bank, otherAccountId: savings);
      final credit = (await live.receive(
        message(credit: true, digits: '5678', reference: '999999999999'),
        engine,
      ))!;
      final transferId = (await live.load(debit.sms.id))!.transactionId;
      await live.edit(
        credit.sms.id,
        accountId: savings,
        otherAccountId: bank,
        confirmedMatchId: debit.sms.id,
      );
      expect((await TransactionRepository(db).load()).single.id, transferId);
      expect(
        (await AccountRepository(
          db,
        ).load()).firstWhere((a) => a.id == savings).balanceMinor,
        50000,
      );
    },
  );

  test(
    'stale and unrelated selections fail without changing either entry',
    () async {
      final debit = (await live.receive(message(), engine))!;
      final credit = (await live.receive(
        message(credit: true, digits: '5678', reference: '999999999999'),
        engine,
      ))!;
      await expectLater(
        live.edit(
          debit.sms.id,
          accountId: bank,
          otherAccountId: savings,
          confirmedMatchId: debit.sms.id,
        ),
        throwsStateError,
      );
      expect(await TransactionRepository(db).load(), hasLength(2));
      await TransactionRepository(db).delete(credit.transactionId!);
      await expectLater(
        live.edit(
          debit.sms.id,
          accountId: bank,
          otherAccountId: savings,
          confirmedMatchId: credit.sms.id,
        ),
        throwsStateError,
      );
      expect(
        (await TransactionRepository(db).load()).single.id,
        debit.transactionId,
      );
    },
  );

  test(
    'unknown categories use Other Expense/Other Income by direction',
    () async {
      final categories = await CategoryRepository(db).load();
      for (final credit in [false, true]) {
        final sms = PendingSmsImport(
          id: 'test',
          sender: 'BANK',
          body: '',
          receivedAt: date,
          data: {'direction': credit ? 'credit' : 'debit'},
        );
        final category = realtimeSmsCategory(sms, categories);
        expect(category?.name, credit ? 'Other Income' : 'Other Expense');
        expect(
          category?.type,
          credit ? CategoryType.income : CategoryType.expense,
        );
        expect(
          realtimeSmsCategory(
            sms,
            categories.where((c) => c.type != category!.type).toList(),
          ),
          isNull,
        );
      }
    },
  );

  test('new SMS saves once, fallback is Other Expense, and editing does not duplicate', () async {
    final received = (await live.receive(message(), engine))!;
    expect(received.accountId, bank);
    expect(received.transactionId, isNotNull);
    final categories = await CategoryRepository(db).load();
    expect(
      categories.firstWhere((c) => c.id == received.categoryId).name,
      'Other Expense',
    );
    await live.receive(message(), engine);
    expect((await TransactionRepository(db).load()), hasLength(1));
    expect(
      (await AccountRepository(
        db,
      ).load()).firstWhere((a) => a.id == bank).balanceMinor,
      50000,
    );
    final food = categories.firstWhere((c) => c.name == 'Food & Beverage');
    await live.edit(received.sms.id, accountId: savings, categoryId: food.id);
    final transactions = await TransactionRepository(db).load();
    expect(transactions, hasLength(1));
    expect(transactions.single.categoryId, food.id);
    final accounts = await AccountRepository(db).load();
    expect(accounts.firstWhere((a) => a.id == bank).balanceMinor, 100000);
    expect(accounts.firstWhere((a) => a.id == savings).balanceMinor, -50000);
  });

  test('an unknown account is created, and undo returns the SMS to pending', () async {
    final received = (await live.receive(message(digits: '9999'), engine))!;
    final created = await live.createdAccount(received.sms.id);
    expect(created, isNotNull);
    expect(received.accountId, created);
    expect(received.transactionId, isNotNull);
    final account = (await AccountRepository(
      db,
    ).load()).firstWhere((a) => a.id == created);
    // Named after the bank; the number is kept apart from the name.
    expect(account.name, received.sms.bankName);
    expect(account.lastDigits, '9999');
    expect(await TransactionRepository(db).load(), hasLength(1));
    // A second message from that account reuses it, without a new-account mark.
    final again = (await live.receive(
      message(digits: '9999', reference: '223456789012'),
      engine,
    ))!;
    expect(again.accountId, created);
    expect(await live.createdAccount(again.sms.id), isNull);
    await expectLater(
      live.undoCreatedAccount(received.sms.id),
      throwsStateError,
    );
    await TransactionRepository(db).delete(again.transactionId!);

    await live.undoCreatedAccount(received.sms.id);
    final undone = (await live.load(received.sms.id))!;
    expect(undone.accountId, isNull);
    expect(undone.transactionId, isNull);
    expect(
      (await AccountRepository(db).load()).where((a) => a.id == created),
      isEmpty,
    );
    expect(await TransactionRepository(db).load(), isEmpty);
    // The undone bank is not created again unasked.
    final later = (await live.receive(
      message(digits: '9999', reference: '323456789012'),
      engine,
    ))!;
    expect(later.accountId, isNull);
    // Tapping Add account creates it and saves the transaction.
    await live.createAccountFor(later.sms.id);
    final saved = (await live.load(later.sms.id))!;
    expect(saved.accountId, isNotNull);
    expect(saved.transactionId, isNotNull);
    expect(await live.createdAccount(later.sms.id), saved.accountId);
  });

  test('bank name identifies an account when SMS carry no number', () async {
    PendingSmsImport row(String? digits, {String id = 'x'}) => PendingSmsImport(
      id: id,
      sender: 'FEDBNK',
      body: '',
      receivedAt: date,
      data: {
        'amountMinor': 500,
        'currencyCode': 'INR',
        'direction': 'debit',
        'bankName': 'Federal Bank',
        'countryCode': 'IN',
        'accountLast4': ?digits,
      },
    );
    final unnumbered = row(null);
    // None known: the bank name is the identity.
    expect(resolveSmsAccount(unnumbered, []).ambiguousAccount, isFalse);
    expect(resolveSmsAccount(unnumbered, []).accountLast4, isNull);
    // One known: the message belongs to it.
    expect(resolveSmsAccount(unnumbered, [row('1234')]).accountLast4, '1234');
    // Several known: a choice is needed.
    final both = [row('1234'), row('5678')];
    expect(resolveSmsAccount(unnumbered, both).ambiguousAccount, isTrue);

    final imports = SmsImportRepository(db);
    await imports.recordBalance({
      ...unnumbered.data,
      'balanceMinor': 900000,
    }, date);
    expect((await imports.detectedAccounts()).single.accountLast4, isNull);
    await imports.createDetectedAccounts([unnumbered]);
    final federal = (await AccountRepository(
      db,
    ).load()).singleWhere((a) => a.name == 'Federal Bank');
    expect(federal.lastDigits, isNull);
    expect(federal.balanceMinor, 900000);
    // A numbered message later adopts that account instead of adding one.
    final numbered = row('4321');
    await imports.recordBalance(numbered.data, date);
    expect(
      (await imports.detectedAccounts())
          .where((r) => r.bankName == 'Federal Bank')
          .map((r) => r.accountLast4),
      ['4321'],
    );
    await imports.createDetectedAccounts([numbered]);
    final adopted = (await AccountRepository(
      db,
    ).load()).where((a) => a.institution == 'Federal Bank').toList();
    expect(adopted.single.id, federal.id);
    expect(adopted.single.lastDigits, '4321');
  });

  test('a created account can be swapped for an existing one', () async {
    final received = (await live.receive(message(digits: '9999'), engine))!;
    final chosen = (await CategoryRepository(
      db,
    ).load()).firstWhere((c) => c.name == 'Food & Beverage');
    await live.edit(received.sms.id, accountId: bank, categoryId: chosen.id);
    expect((await live.load(received.sms.id))!.accountId, bank);
    expect(await TransactionRepository(db).load(), hasLength(1));
  });

  test(
    'wrong-direction category is rejected without changing the ledger',
    () async {
      final received = (await live.receive(message(), engine))!;
      final income = (await CategoryRepository(
        db,
      ).load()).firstWhere((c) => c.type == CategoryType.income);
      await expectLater(
        live.edit(received.sms.id, accountId: bank, categoryId: income.id),
        throwsStateError,
      );
      expect(
        (await TransactionRepository(db).load()).single.id,
        received.transactionId,
      );
      expect(
        (await AccountRepository(
          db,
        ).load()).firstWhere((a) => a.id == bank).balanceMinor,
        50000,
      );
    },
  );

  test(
    'deleted fallback is recreated once in the matching direction',
    () async {
      await db.customStatement(
        "DELETE FROM categories WHERE name='Other Expense' AND type='expense'",
      );
      final received = (await live.receive(message(), engine))!;
      final personal = (await CategoryRepository(db).load()).where(
        (c) => c.name == 'Other Expense' && c.type == CategoryType.expense,
      );
      expect(personal, hasLength(1));
      expect(received.categoryId, personal.single.id);
    },
  );

  test('full-editor amount changes supersede notification edits', () async {
    final received = (await live.receive(message(), engine))!;
    await TransactionRepository(db).updateExpenseOrIncome(
      id: received.transactionId!,
      type: TransactionType.expense,
      amountMinor: 60000,
      accountId: bank,
      categoryId: received.categoryId!,
      date: date,
    );
    expect(await live.load(received.sms.id), isNull);
    await expectLater(
      live.edit(
        received.sms.id,
        accountId: savings,
        categoryId: received.categoryId,
      ),
      throwsStateError,
    );
    expect((await TransactionRepository(db).load()).single.amountMinor, 60000);
  });

  test('credit and debit can each become a transfer and switch back', () async {
    for (final credit in [false, true]) {
      final received = (await live.receive(
        message(
          credit: credit,
          reference: credit ? '222222222222' : '111111111111',
        ),
        engine,
      ))!;
      await live.edit(
        received.sms.id,
        accountId: bank,
        otherAccountId: savings,
      );
      final updated = (await live.load(received.sms.id))!;
      final transfer = (await TransactionRepository(
        db,
      ).load()).firstWhere((t) => t.id == updated.transactionId);
      expect(transfer.type, TransactionType.transfer);
      expect(transfer.accountId, credit ? savings : bank);
      expect(transfer.toAccountId, credit ? bank : savings);
      await live.edit(
        received.sms.id,
        accountId: bank,
        categoryId: received.categoryId,
      );
      expect((await live.load(received.sms.id))!.otherAccountId, isNull);
    }
    final accounts = await AccountRepository(db).load();
    expect(accounts.firstWhere((a) => a.id == bank).balanceMinor, 100000);
    expect(accounts.firstWhere((a) => a.id == savings).balanceMinor, 0);
  });

  test(
    'matching two bank messages produces one transfer and correct balances',
    () async {
      final debit = (await live.receive(message(), engine))!;
      final credit = (await live.receive(
        message(credit: true, digits: '5678'),
        engine,
      ))!;
      expect(
        debit.sms.reference,
        '123456789012',
        reason: 'Debit reference parsed',
      );
      expect(
        credit.sms.reference,
        '123456789012',
        reason: 'Credit reference parsed',
      );
      expect(await TransactionRepository(db).load(), hasLength(2));
      await live.edit(debit.sms.id, accountId: bank, otherAccountId: savings);
      final transactions = await TransactionRepository(db).load();
      expect(transactions, hasLength(1));
      expect(transactions.single.type, TransactionType.transfer);
      expect(
        (await live.load(credit.sms.id))!.transactionId,
        transactions.single.id,
      );
      final accounts = await AccountRepository(db).load();
      expect(accounts.firstWhere((a) => a.id == bank).balanceMinor, 50000);
      expect(accounts.firstWhere((a) => a.id == savings).balanceMinor, 50000);
      await live.edit(
        credit.sms.id,
        accountId: savings,
        categoryId: credit.categoryId,
      );
      expect(await TransactionRepository(db).load(), hasLength(2));
      expect(
        (await AccountRepository(
          db,
        ).load()).firstWhere((a) => a.id == savings).balanceMinor,
        50000,
      );
    },
  );

  test(
    'a later counterpart attaches to an already confirmed transfer',
    () async {
      final debit = (await live.receive(message(), engine))!;
      await live.edit(debit.sms.id, accountId: bank, otherAccountId: savings);
      final credit = (await live.receive(
        message(credit: true, digits: '5678'),
        engine,
      ))!;
      expect(credit.otherAccountId, bank);
      expect(await TransactionRepository(db).load(), hasLength(1));
    },
  );

  test('different references do not merge equal amounts', () async {
    final debit = (await live.receive(message(), engine))!;
    await live.receive(
      message(credit: true, digits: '5678', reference: '999999999999'),
      engine,
    );
    await live.edit(debit.sms.id, accountId: bank, otherAccountId: savings);
    expect(await TransactionRepository(db).load(), hasLength(2));
  });

  test(
    'disabled processing and deleted transactions cannot be resurrected',
    () async {
      await SmsImportRepository(db).enable(false);
      expect(await live.receive(message(), engine), isNull);
      await SmsImportRepository(db).enable(true);
      final received = (await live.receive(message(), engine))!;
      await TransactionRepository(db).delete(received.transactionId!);
      expect(await live.load(received.sms.id), isNull);
      expect(await live.receive(message(), engine), isNull);
      expect(await TransactionRepository(db).load(), isEmpty);
    },
  );
}
