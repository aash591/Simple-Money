// A bank that says "credited to your loan a/c" when the user pays the loan:
// one approved correction turns that message, every waiting one like it and
// every one to come into the loan's payments. Saved ones can be fixed too.
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/agent/agent_suggestion_repository.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/loan_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/domain/loan.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

String _body(int day) =>
    'Rs.5,000.00 credited to your loan a/c XX9876 on 0$day-11-26. -Kotak';

PortableParseResult _read() => PortableParseResult(
  classification: RuleClassification.completed,
  decision: SmsDecision.review,
  reason: 'completedNeedsReview',
  packVersion: 1,
  ruleId: 'user.kotak.r1',
  candidate: SmsTransactionCandidate(
    amountMinor: 500000,
    currencyCode: 'INR',
    direction: SmsDirection.credit,
    channel: SmsPaymentChannel.bankTransfer,
    occurredAt: DateTime(2026, 11),
    bankName: 'Kotak',
    countryCode: 'IN',
    accountLast4: '9876',
  ),
);

void main() {
  late AppDatabase db;
  late AgentTools tools;
  late SmsImportRepository imports;
  late int sbi, loan;

  Future<Map<String, Object?>> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await tools.call(name, args);
    final text = ((result['content'] as List).single as Map)['text'] as String;
    if (result['isError'] == true) return {'error': text};
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  }

  Future<void> receive(int day) => imports.enqueue(
    BankSms(
      sender: 'VM-KOTAKB',
      body: _body(day),
      receivedAt: DateTime(2026, 11, day),
    ),
    _read(),
  );

  Future<Map<String, dynamic>> candidate(int day) async => jsonDecode(
    (await db
            .customSelect(
              'SELECT candidate FROM sms_imports WHERE body=?',
              variables: [Variable(_body(day))],
            )
            .getSingle())
        .read<String>('candidate'),
  ) as Map<String, dynamic>;

  Future<String> idOf(int day) async =>
      (await db
              .customSelect(
                'SELECT fingerprint FROM sms_imports WHERE body=?',
                variables: [Variable(_body(day))],
              )
              .getSingle())
          .read<String>('fingerprint');

  Future<void> approveAll() async {
    final repo = AgentSuggestionRepository(db);
    for (final s in await repo.load()) {
      expect(await repo.apply(s.id), isNull);
    }
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    tools = AgentTools(db);
    imports = SmsImportRepository(db);
    sbi = await AccountRepository(db).save(
      name: 'SBI',
      currency: 'INR',
      digits: 2,
      openingBalance: 10000000,
      type: AccountType.bank,
      lastDigits: '1234',
      institution: 'SBI',
    );
    loan = await LoanRepository(db).add(
      LoanTerms(
        lender: 'Kotak',
        kind: LoanKind.other,
        icon: 'bank',
        principal: 6000000,
        openingBalance: 6000000,
        startDate: DateTime(2026, 5),
        snapshotDate: DateTime(2026, 5),
        rate: 0,
        months: 12,
        emi: 500000,
        paidBefore: 0,
        firstDue: DateTime(2026, 6, 2),
        day: 2,
        currency: 'INR',
        digits: 2,
      ),
      sbi,
    );
  });
  tearDown(() => db.close());

  test(
    'Waiting messages of one layout, and later ones, pay the loan',
    () async {
      await receive(2);
      await receive(3);
      final first = await idOf(2);

      final suggested = await call('suggest_sms_corrections', {
        'items': [
          {'sms_id': first, 'loan_id': loan, 'same_layout': true},
        ],
      });
      expect(suggested['suggested'], 1, reason: '$suggested');
      final card = (await AgentSuggestionRepository(db).load()).single;
      expect(card.detail.join('\n'), contains('Also 1 more like it'));
      await approveAll();

      for (final day in [2, 3]) {
        final data = await candidate(day);
        final sms = PendingSmsImport(
          id: '$day',
          sender: 'VM-KOTAKB',
          body: '',
          data: data,
          receivedAt: DateTime(2026),
        );
        expect(sms.credit, isFalse);
        expect(sms.assignedLoanId, loan);
        expect(data['assignedAccountId'], sbi);
        // The loan account's number never becomes an account.
        expect(data['accountLast4'], isNull);
        expect(data['otherAccountLast4'], '9876');
      }

      // Next month's message is corrected as it arrives.
      await receive(4);
      final later = await candidate(4);
      expect(later['correctedDirection'], 'debit');
      expect(later['assignedLoanId'], loan);

      await imports.createDetectedAccounts([
        PendingSmsImport(
          id: '4',
          sender: 'VM-KOTAKB',
          body: '',
          data: later,
          receivedAt: DateTime(2026),
        ),
      ]);
      expect((await AccountRepository(db).load()).length, 1);
    },
  );

  test('A saved income becomes the loan’s payment', () async {
    final income = (await CategoryRepository(
      db,
    ).load()).firstWhere((c) => c.type == CategoryType.income);
    final id = await TransactionRepository(db).addExpenseOrIncome(
      type: TransactionType.income,
      amountMinor: 500000,
      accountId: sbi,
      categoryId: income.id,
      title: 'Kotak',
      date: DateTime(2026, 6, 2),
    );
    final suggested = await call('suggest_transaction_edits', {
      'items': [
        {'transaction_id': id, 'loan_id': loan},
      ],
    });
    expect(suggested['suggested'], 1, reason: '$suggested');
    await approveAll();

    final row = await db
        .customSelect(
          'SELECT type FROM transactions WHERE id=?',
          variables: [Variable(id)],
        )
        .getSingle();
    expect(row.read<String>('type'), 'expense');
    final paid = (await LoanRepository(db).load()).single;
    expect(paid.paid, 1);

    final repo = AgentSuggestionRepository(db);
    final applied = (await repo.load(statuses: {AgentSuggestionStatus.applied}))
        .single;
    expect(await repo.undo(applied.id), contains('loan’s screen'));
  });

  test('A loan in another currency, or a closed one, is refused', () async {
    await receive(2);
    final first = await idOf(2);
    final refused = await call('suggest_sms_corrections', {
      'items': [
        {'sms_id': first, 'loan_id': loan + 99},
      ],
    });
    expect(
      ((refused['rejected'] as List).single as Map)['error'],
      contains('list_loans'),
    );
  });
}
