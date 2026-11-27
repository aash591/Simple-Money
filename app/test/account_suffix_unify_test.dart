import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/domain/account.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

void main() {
  ucoCardTests();
  final at = DateTime(2026, 5, 8, 10);

  PendingSmsImport sms(
    String? last4, {
    String bank = 'Federal Bank',
    String channel = 'upi',
    bool creditCard = false,
  }) => PendingSmsImport(
    id: 'm$last4',
    sender: 'VA-FEDBNK-S',
    body: '',
    receivedAt: at,
    data: {
      'amountMinor': 100,
      'bankName': bank,
      'countryCode': 'IN',
      'currencyCode': 'INR',
      'accountLast4': last4,
      'channel': channel,
      'isCreditCard': creditCard,
    },
  );

  test('a shortened number is the fuller one from the same bank', () {
    expect(fullerAccountSuffix('234', ['1234', '234']), '1234');
    expect(fullerAccountSuffix('234', ['0234']), '0234');
    expect(fullerAccountSuffix('1234', ['1234']), isNull);
  });

  test('it stays apart when it could be more than one account', () {
    expect(fullerAccountSuffix('234', ['1234', '5234']), isNull);
    // Two digits is too little to say anything about.
    expect(fullerAccountSuffix('34', ['1234']), isNull);
    expect(fullerAccountSuffix('XX4', ['1234']), isNull);
  });

  test('detected accounts count XX1234 and XX234 once', () async {
    final db = AppDatabase(NativeDatabase.memory());
    addTearDown(db.close);
    final imports = SmsImportRepository(db);
    for (final suffix in ['1234', '234']) {
      await imports.recordBalance({
        'bankName': 'Federal Bank',
        'countryCode': 'IN',
        'currencyCode': 'INR',
        'accountLast4': suffix,
        'isCreditCard': false,
      }, at);
    }
    final detected = await imports.detectedAccounts();
    expect(detected.map((d) => d.accountLast4), ['1234']);
    expect(resolveSmsAccount(sms('234'), detected).accountLast4, '1234');
  });

  test('another bank\'s number is never borrowed', () {
    final other = sms('1234', bank: 'HDFC Bank');
    expect(resolveSmsAccount(sms('234'), [other]).accountLast4, '234');
  });

  test("a debit card number is the bank's one account, not another", () {
    final account = sms('1234');
    final card = sms('6226', channel: 'card');
    expect(canonicalAccountLast4(card, [account, card]), '1234');
    expect(resolveSmsAccount(card, [account]).accountLast4, '1234');
    // The account itself is untouched.
    expect(canonicalAccountLast4(account, [account, card]), isNull);
  });

  test('a card stays its own when the bank has none or several accounts', () {
    final card = sms('6226', channel: 'card');
    expect(canonicalAccountLast4(card, [card]), isNull);
    expect(
      canonicalAccountLast4(card, [sms('1234'), sms('5678'), card]),
      isNull,
    );
  });

  test('a credit card is an account of its own', () {
    final credit = sms('6226', channel: 'card', creditCard: true);
    expect(canonicalAccountLast4(credit, [sms('1234'), credit]), isNull);
  });

  test(
    'detected accounts fold the card into the account, either order',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      addTearDown(db.close);
      final imports = SmsImportRepository(db);
      Future<void> seen(String suffix, String channel, DateTime when) =>
          imports.recordBalance({
            'bankName': 'Federal Bank',
            'countryCode': 'IN',
            'currencyCode': 'INR',
            'accountLast4': suffix,
            'channel': channel,
            'isCreditCard': false,
          }, when);
      await seen('1234', 'upi', at);
      await seen('6226', 'card', at.add(const Duration(days: 1)));
      final detected = await imports.detectedAccounts();
      expect(detected.map((d) => d.accountLast4), ['1234']);
      // The card message arriving later still finds the account.
      final card = sms('6226', channel: 'card');
      expect(resolveSmsAccount(card, detected).accountLast4, '1234');
    },
  );

  group('debit card icon', () {
    late AppDatabase db;
    late SmsImportRepository imports;
    setUp(() {
      db = AppDatabase(NativeDatabase.memory());
      imports = SmsImportRepository(db);
    });
    tearDown(() => db.close());

    Future<void> seen(String suffix, String channel, [int day = 0]) =>
        imports.recordBalance({
          'bankName': 'Federal Bank',
          'countryCode': 'IN',
          'currencyCode': 'INR',
          'accountLast4': suffix,
          'channel': channel,
          'isCreditCard': false,
        }, at.add(Duration(days: day)));

    Future<List<Account>> accounts() => AccountRepository(db).load();

    test('the account a card is used on gets the icon', () async {
      await seen('1234', 'upi');
      await seen('6226', 'card', 1);
      await imports.createDetectedAccounts(await imports.detectedAccounts());
      final list = await accounts();
      expect(list, hasLength(1));
      expect(list.single.lastDigits, '1234');
      expect(list.single.hasDebitCard, isTrue);
    });

    test('a card alone is an account with the icon', () async {
      await seen('6226', 'card');
      await imports.createDetectedAccounts(await imports.detectedAccounts());
      expect((await accounts()).single.hasDebitCard, isTrue);
    });

    test('an account without a card has none', () async {
      await seen('1234', 'upi');
      await imports.createDetectedAccounts(await imports.detectedAccounts());
      expect((await accounts()).single.hasDebitCard, isFalse);
    });

    test('a card seen after the account exists adds the icon', () async {
      await seen('1234', 'upi');
      await imports.createDetectedAccounts(await imports.detectedAccounts());
      expect((await accounts()).single.hasDebitCard, isFalse);
      await seen('6226', 'card', 2);
      expect((await accounts()).single.hasDebitCard, isTrue);
    });

    test('merging keeps the icon of either account', () async {
      final repo = AccountRepository(db);
      final bank = await repo.save(
        name: 'Bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
      );
      final card = await repo.save(
        name: 'Card',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
      );
      await repo.markDebitCard(card);
      await repo.merge(sourceId: card, targetId: bank);
      expect((await accounts()).single.hasDebitCard, isTrue);
    });
  });
}

// "UCO Bank Card XX1523" and "UCO Debit Card XX1523" are the one UCO account
// the phone already knows from other messages.
void ucoCardTests() {
  final at = DateTime(2026, 11, 30, 12);
  final parser = BankSmsParser(
    const RuleCompiler().loadRuntime(
      jsonDecode(
            File(
              'packages/universal_bank_sms_parser/distribution/packs/india/uco.json',
            ).readAsStringSync(),
          )
          as Map<String, dynamic>,
    ),
  );
  for (final wording in ['Bank Card', 'Debit Card']) {
    test('UCO $wording joins the bank\'s one account', () {
      final body =
          'Rs.3,000.00 withdrawn on UCO $wording XX1523 on 30-11-2025,11:43:17 at ATM. Avl Bal Rs.5562.34.';
      final snapshot = parser.balanceSnapshot(
        BankSms(sender: 'JD-UCOBNK-S', body: body, receivedAt: at),
      );
      expect(snapshot?['channel'], 'card');
      final card = PendingSmsImport(
        id: 'c',
        sender: 'JD-UCOBNK-S',
        body: body,
        receivedAt: at,
        data: {...?snapshot, 'amountMinor': 300000},
      );
      final account = PendingSmsImport(
        id: 'a',
        sender: 'JD-UCOBNK-S',
        body: '',
        receivedAt: at,
        data: {
          'bankName': 'UCO Bank',
          'countryCode': 'IN',
          'currencyCode': 'INR',
          'accountLast4': '1234',
          'channel': 'upi',
          'isCreditCard': false,
        },
      );
      expect(canonicalAccountLast4(card, [account, card]), '1234');
    });
  }
}
