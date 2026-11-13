// A shop's or biller's SMS ("Refund of Rs.499 credited… -Meesho") says money
// moved, but the money is at a bank: it never becomes an account, it is
// matched to the bank's own SMS, and otherwise the user picks the account.
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/agent/agent_suggestion_repository.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/reportable_sms.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/user_sms_rules.dart';
import 'package:simple_money/domain/account.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

const _refund =
    'Refund of Rs.499.00 for your order 4471 has been credited to your '
    'source account. -Meesho';
const _refundAgain =
    'Refund of Rs.1,099.00 for your order 5120 has been credited to your '
    'source account. -Meesho';
const _initiated =
    'Refund of Rs.499.00 for your order 4471 has been initiated. It will be '
    'credited in 5-7 days. -Meesho';

const _refundCategory = SmsSuggestedCategory(
  id: 'refund',
  name: 'Refunds',
  type: 'income',
  ruleId: 'test',
);

PortableParseResult _parsed({
  required String bank,
  required int amount,
  bool credit = true,
  String? last4,
  String? party,
  SmsSuggestedCategory? category,
}) => PortableParseResult(
  classification: RuleClassification.completed,
  decision: SmsDecision.review,
  reason: 'completedNeedsReview',
  packVersion: 1,
  ruleId: 'user.test.r1',
  candidate: SmsTransactionCandidate(
    amountMinor: amount,
    currencyCode: 'INR',
    direction: credit ? SmsDirection.credit : SmsDirection.debit,
    channel: SmsPaymentChannel.bankTransfer,
    occurredAt: DateTime(2026, 11),
    bankName: bank,
    countryCode: 'IN',
    accountLast4: last4,
    counterparty: party,
    category: category,
  ),
);

void main() {
  late AppDatabase db;
  late SmsImportRepository imports;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    imports = SmsImportRepository(db);
  });
  tearDown(() => db.close());

  Future<Map<String, dynamic>> candidate(String sender) async {
    final row = await db
        .customSelect(
          'SELECT candidate,status FROM sms_imports WHERE sender=?',
          variables: [Variable(sender)],
        )
        .getSingle();
    return {
      ...jsonDecode(row.read<String>('candidate')) as Map<String, dynamic>,
      'status': row.read<String>('status'),
    };
  }

  group('Role of a rule', () {
    test('An explicit role wins; an old rule holds money only with an '
        'account number', () {
      expect(
        ruleSenderRole({'senderRole': 'merchant'}),
        SmsSenderRole.merchant,
      );
      expect(
        ruleSenderRole({
          'output': {'accountLast4': {}},
        }),
        SmsSenderRole.bank,
      );
      expect(
        ruleSenderRole({
          'output': {'amount': {}},
        }),
        SmsSenderRole.other,
      );
      expect(compilableFormat({'senderRole': 'biller', 'tokens': []}), {
        'tokens': [],
      });
    });

    test('A sender any rule says holds money is never a non-holder', () {
      UserSmsRule rule(String role, String sender) => UserSmsRule(
        id: 1,
        bankName: 'X',
        senders: [sender],
        format: {'senderRole': role},
        samples: const [],
        createdAt: DateTime(2026),
      );
      expect(
        nonHolderSenders([
          rule('merchant', 'MEESHO'),
          rule('biller', 'KSEBLT'),
          rule('wallet', 'KSEBLT'),
        ]),
        {'MEESHO': SmsSenderRole.merchant},
      );
    });
  });

  group('A shop’s SMS', () {
    test('never becomes an account, and waits for one', () async {
      await imports.enqueue(
        BankSms(
          sender: 'VM-MEESHO',
          body: _refund,
          receivedAt: DateTime(2026, 11, 3),
        ),
        _parsed(bank: 'Meesho', amount: 49900, category: _refundCategory),
        role: SmsSenderRole.merchant,
      );
      final data = await candidate('VM-MEESHO');
      expect(data['senderRole'], 'merchant');
      expect(data['ambiguousAccount'], isTrue);
      // The shop is the payee, not an account.
      expect(data['counterparty'], 'Meesho');
      expect(data['status'], 'pending');

      final pending = PendingSmsImport(
        id: 'x',
        sender: 'VM-MEESHO',
        body: _refund,
        data: data,
        receivedAt: DateTime(2026, 11, 3),
      );
      expect(pending.holdsMoney, isFalse);
      // Not resolved by its name, not offered as a detected account.
      expect(resolveSmsAccount(pending, const []).ambiguousAccount, isTrue);
      expect(await imports.detectedAccounts(queued: [pending]), isEmpty);
      await imports.createDetectedAccounts([pending]);
      expect(await AccountRepository(db).load(), isEmpty);
    });

    test(
      'quoting the bank account’s number is matched to that account',
      () async {
        final hdfc = await AccountRepository(db).save(
          name: 'HDFC Bank',
          currency: 'INR',
          digits: 2,
          openingBalance: 0,
          type: AccountType.bank,
          lastDigits: '1234',
          institution: 'HDFC Bank',
        );
        await imports.enqueue(
          BankSms(
            sender: 'VM-MEESHO',
            body: 'Refund of Rs.499.00 credited to a/c XX1234. -Meesho',
            receivedAt: DateTime(2026, 11, 3),
          ),
          _parsed(bank: 'Meesho', amount: 49900, last4: '1234'),
          role: SmsSenderRole.merchant,
        );
        final data = await candidate('VM-MEESHO');
        expect(data['accountLast4'], isNull);
        expect(data['otherAccountLast4'], '1234');
        expect(data['assignedAccountId'], hdfc);
      },
    );
  });

  group('One refund, two messages', () {
    test('the shop’s first: the bank’s days later takes its name and '
        'category', () async {
      await imports.enqueue(
        BankSms(
          sender: 'VM-MEESHO',
          body: _refund,
          receivedAt: DateTime(2026, 11, 3),
        ),
        _parsed(
          bank: 'Meesho',
          amount: 49900,
          party: 'Meesho',
          category: _refundCategory,
        ),
        role: SmsSenderRole.merchant,
      );
      await imports.enqueue(
        BankSms(
          sender: 'VM-HDFCBK',
          body: 'Rs.499.00 credited to A/c XX1234 on 07-11-26. -HDFC Bank',
          receivedAt: DateTime(2026, 11, 7),
        ),
        _parsed(bank: 'HDFC Bank', amount: 49900, last4: '1234'),
      );
      final shop = await candidate('VM-MEESHO');
      final bank = await candidate('VM-HDFCBK');
      expect(shop['status'], 'dismissed');
      expect(bank['status'], 'pending');
      expect(bank['counterparty'], 'Meesho');
      expect((bank['category'] as Map)['id'], 'refund');
    });

    test(
      'the bank’s first: the shop’s is dropped and lends its category',
      () async {
        await imports.enqueue(
          BankSms(
            sender: 'VM-HDFCBK',
            body: 'Rs.499.00 credited to A/c XX1234. -HDFC Bank',
            receivedAt: DateTime(2026, 11, 3, 9),
          ),
          _parsed(bank: 'HDFC Bank', amount: 49900, last4: '1234'),
        );
        await imports.enqueue(
          BankSms(
            sender: 'VM-MEESHO',
            body: _refund,
            receivedAt: DateTime(2026, 11, 3, 10),
          ),
          _parsed(bank: 'Meesho', amount: 49900, category: _refundCategory),
          role: SmsSenderRole.merchant,
        );
        expect((await candidate('VM-MEESHO'))['status'], 'dismissed');
        final bank = await candidate('VM-HDFCBK');
        expect(bank['status'], 'pending');
        expect((bank['category'] as Map)['id'], 'refund');
      },
    );

    test('two banks crediting the same amount are never merged', () async {
      await imports.enqueue(
        BankSms(
          sender: 'VM-HDFCBK',
          body: 'a',
          receivedAt: DateTime(2026, 11, 3),
        ),
        _parsed(bank: 'HDFC Bank', amount: 49900, last4: '1234'),
      );
      await imports.enqueue(
        BankSms(
          sender: 'VM-SBIINB',
          body: 'b',
          receivedAt: DateTime(2026, 11, 3),
        ),
        _parsed(bank: 'SBI', amount: 49900),
      );
      expect((await candidate('VM-HDFCBK'))['status'], 'pending');
      expect((await candidate('VM-SBIINB'))['status'], 'pending');
    });

    test(
      'a shop’s refund weeks before the bank’s credit stays apart',
      () async {
        await imports.enqueue(
          BankSms(
            sender: 'VM-MEESHO',
            body: _refund,
            receivedAt: DateTime(2026, 10, 1),
          ),
          _parsed(bank: 'Meesho', amount: 49900, category: _refundCategory),
          role: SmsSenderRole.merchant,
        );
        await imports.enqueue(
          BankSms(
            sender: 'VM-HDFCBK',
            body: 'c',
            receivedAt: DateTime(2026, 11, 3),
          ),
          _parsed(bank: 'HDFC Bank', amount: 49900, last4: '1234'),
        );
        expect((await candidate('VM-MEESHO'))['status'], 'pending');
      },
    );
  });

  group('Teaching a shop’s SMS', () {
    late AgentTools tools;
    var inbox = <String>[];

    Future<Map<String, Object?>> call(
      String name, [
      Map<String, Object?> args = const {},
    ]) async {
      final result = await tools.call(name, args);
      final text =
          ((result['content'] as List).single as Map)['text'] as String;
      if (result['isError'] == true) return {'error': text};
      return Map<String, Object?>.from(jsonDecode(text) as Map);
    }

    Future<String> idOf(String body) async {
      final listed = await call('list_missed_sms');
      return ((listed['messages'] as List).cast<Map>().firstWhere(
            (m) => m['text'] == body,
          ))['id']
          as String;
    }

    setUp(() {
      tools = AgentTools(
        db,
        missedSms: (window) async => [
          for (final (i, body) in inbox.indexed)
            ReportableSms(
              '$i',
              BankSms(
                sender: 'VM-MEESHO',
                body: body,
                receivedAt: DateTime(2026, 10, 20 + i),
              ),
              ReportableKind.missed,
              'unregisteredSender',
              null,
            ),
        ],
      );
    });

    test('needs a sender type', () async {
      inbox = [_refund];
      final taught = await call('label_sms', {
        'sms_id': await idOf(_refund),
        'amount': '499.00',
        'direction': 'credit',
        'channel': 'other',
        'country': 'IN',
        'currency': 'INR',
      });
      expect(taught['error'], contains('sender_type'));
    });

    test('a refund not yet sent isn’t taught', () async {
      inbox = [_initiated];
      final taught = await call('label_sms', {
        'sms_id': await idOf(_initiated),
        'amount': '499.00',
        'direction': 'credit',
        'channel': 'other',
        'country': 'IN',
        'currency': 'INR',
        'sender_type': 'merchant',
        'stage': 'pending',
      });
      expect(taught['suggested'], isFalse);
      expect(await AgentSuggestionRepository(db).load(), isEmpty);
    });

    test('makes a rule that keeps the role and leaves the account to the '
        'user', () async {
      inbox = [_refund, _refundAgain];
      final taught = await call('label_sms', {
        'sms_id': await idOf(_refund),
        'amount': '499.00',
        'direction': 'credit',
        'channel': 'other',
        'country': 'IN',
        'currency': 'INR',
        'sender_type': 'merchant',
      });
      expect(taught['suggested'], isTrue, reason: '$taught');
      expect(taught['user_picks_in_review'], contains('account'));
      expect(
        taught['read_from_this_sms'],
        containsPair('counterparty', 'Meesho'),
      );
      final rule = (await AgentSuggestionRepository(db).load()).single;
      expect(rule.summary, 'New SMS rule · Meesho');
      expect(rule.detail.join('\n'), contains('Sender: merchant'));
      expect((rule.payload['format'] as Map)['senderRole'], 'merchant');
    });
  });
}
