import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dart:convert';

import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/ui/sms/sms_suggestions.dart';

void main() {
  late AppDatabase db;
  late List<Category> categories;
  final categorizer = PortableCategorizer(
    const RuleCompiler().loadRuntime(
      jsonDecode(
        File(
          'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
        ).readAsStringSync(),
      ) as Map<String, dynamic>,
    ),
  );
  PendingSmsImport sms(
    String body, {
    bool credit = true,
    bool card = false,
    String? merchant,
  }) {
    final candidate = categorizer.enrich(
      body,
      SmsTransactionCandidate(
        amountMinor: 125050,
        direction: credit ? SmsDirection.credit : SmsDirection.debit,
        occurredAt: DateTime(2026, 10, 12),
        currencyCode: 'INR',
        countryCode: 'IN',
        bankName: 'Bank',
        channel: card ? SmsPaymentChannel.card : SmsPaymentChannel.bankTransfer,
        counterparty: merchant,
      ),
    );
    final data =
        PortableParseResult(
              classification: RuleClassification.completed,
              decision: SmsDecision.review,
              reason: 'completedNeedsReview',
              packVersion: 1,
              candidate: candidate,
            ).toJson()['candidate']
            as Map;
    return PendingSmsImport(
      id: 'example',
      sender: 'BANK',
      body: body,
      receivedAt: DateTime(2026, 10, 12),
      data: {...Map<String, dynamic>.from(data), 'isCreditCard': card},
    );
  }

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    categories = await CategoryRepository(db).load();
  });
  tearDown(() => db.close());

  test(
    'new artwork categories are seeded and upgrades preserve custom icons',
    () async {
      final fuel = categories.singleWhere((c) => c.name == 'Fuel');
      expect(fuel.icon, 'fuel');
      for (final pair in [
        ('Travel Trip', 'Travel'),
        ('Wellness', 'Health & Fitness'),
      ]) {
        final child = categories.singleWhere((c) => c.name == pair.$1);
        expect(
          child.parentId,
          categories.singleWhere((c) => c.name == pair.$2).id,
        );
      }
      expect(
        categories.singleWhere((c) => c.name == 'Emergency Fund').icon,
        'emergency_fund',
      );
      final dir = await Directory.systemTemp.createTemp('lifestyle_upgrade_');
      final file = File('${dir.path}/ledger.sqlite');
      var disk = AppDatabase(NativeDatabase(file));
      try {
        await disk.customStatement(
          "DELETE FROM categories WHERE name IN ('Travel Trip','Wellness','Emergency Fund')",
        );
        await disk.customStatement(
          "UPDATE categories SET icon='car_battery' WHERE name='Fuel'",
        );
        await disk.customStatement('PRAGMA user_version=28');
        await disk.close();
        disk = AppDatabase(NativeDatabase(file));
        final after = await CategoryRepository(disk).load();
        expect(after.singleWhere((c) => c.name == 'Fuel').icon, 'fuel');
        for (final name in ['Travel Trip', 'Wellness', 'Emergency Fund']) {
          expect(after.where((c) => c.name == name), hasLength(1));
        }
        await disk.customStatement(
          "UPDATE categories SET icon='car' WHERE name='Fuel'",
        );
        await disk.seedLifestyleCategories();
        expect(
          (await CategoryRepository(
            disk,
          ).load()).singleWhere((c) => c.name == 'Fuel').icon,
          'car',
        );
        expect((await CategoryRepository(disk).load()).length, after.length);
      } finally {
        await disk.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test('generic NACH auto debits wait for category confirmation', () {
    final debit = sms(
      'Your A/C XX1234 has a debit by NACH of Rs 5848.00.',
      credit: false,
    );
    expect(debit.needsCategoryConfirmation, isTrue);
    expect(smsCategory(debit, categories), isNull);
  });

  test('package transport suggestions resolve to the default children', () {
    final parent = categories.singleWhere((c) => c.name == 'Public Transport');
    expect(parent.parentId, isNull);
    for (final item in [
      (merchant: 'Kerala State', category: 'Bus'),
      (merchant: 'KSRTC', category: 'Bus'),
      (merchant: 'Indian Railw', category: 'Train'),
      (merchant: 'IRCTC UTS', category: 'Train'),
      (merchant: 'Uber', category: 'Cab'),
    ]) {
      final result = smsCategory(
        sms('Paid at ${item.merchant}', credit: false, merchant: item.merchant),
        categories,
      );
      expect(result?.name, item.category);
      expect(result?.parentId, parent.id);
    }
  });

  test(
    'v27 upgrade preserves the transport ID and creates children once',
    () async {
      final dir = await Directory.systemTemp.createTemp('transport_upgrade_');
      final file = File('${dir.path}/ledger.sqlite');
      var disk = AppDatabase(NativeDatabase(file));
      try {
        final before = await CategoryRepository(disk).load();
        final parent = before.singleWhere((c) => c.name == 'Public Transport');
        final transportation = before.singleWhere(
          (c) => c.name == 'Transportation',
        );
        await disk.customStatement('DELETE FROM categories WHERE parent_id=?', [
          parent.id,
        ]);
        await disk.customStatement(
          'UPDATE categories SET parent_id=?,icon=? WHERE id=?',
          [transportation.id, 'train', parent.id],
        );
        await disk.customStatement('PRAGMA user_version=27');
        await disk.close();
        disk = AppDatabase(NativeDatabase(file));
        final after = await CategoryRepository(disk).load();
        final preserved = after.singleWhere((c) => c.id == parent.id);
        expect(preserved.parentId, isNull);
        expect(preserved.icon, 'train');
        expect(
          after.where((c) => c.parentId == parent.id).map((c) => c.name),
          unorderedEquals(['Bus', 'Train', 'Cab']),
        );
        await disk.seedPublicTransportCategories();
        expect((await CategoryRepository(disk).load()).length, after.length);
      } finally {
        await disk.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test('SBI and Federal machine deposits are ATM transfers, not merchant categories', () {
    for (final body in [
      'Your A/C XXXXX1234 Credited INR 1,250.50 on 12/10/26 -Deposit of Cash at S1NL000001 CDM. Avl Bal INR 9,876.54-SBI',
      'Hi,Rs.1250.50credited in your A/c XX1234 on 12OCT2026 10:30:00 using cash deposit machine at FBL-TEST STORE. Current Bal: Rs.9876.54 - Federal Bank',
    ]) {
      final deposit = sms(body, merchant: 'TEST STORE');
      // Cash moves between the bank and a Cash account, so no category.
      expect(deposit.suggestedCategory?.name, 'ATM Deposit');
      expect(deposit.isAtmDeposit, isTrue);
      expect(deposit.requiresTransfer, isTrue);
      expect(smsCategory(deposit, categories), isNull);
    }
    expect(
      smsCategory(
        sms(
          'INR 1250.50 has been CREDITED to your A/c XXX123 by CASH.Total bal is INR 9876.54.',
        ),
        categories,
      )?.name,
      'Cash Deposit',
    );
    expect(
      smsCategory(
        sms(
          'Your AC XXXXX1234 Debited INR 25.00 -CDM CHARGE DR. Avl Bal INR 9,876.54.-SBI',
          credit: false,
        ),
        categories,
      )?.name,
      'Bank Charges',
    );
    expect(
      smsCategory(
        sms(
          'Refund credited for reversed cash using cash deposit machine at TEST.',
        ),
        categories,
      )?.name,
      'Refunds',
    );
  });

  test('card repayment receipts and bank debits require transfers, not categories', () {
    for (final body in [
      'Your payment of Rs.1250.50 has been credited to your SBI Credit Card ending with 1234.',
      'PAYMENT OF Rs.1250.50 RECEIVED TOWARDS YOUR CREDIT CARD ENDING WITH 1234.',
      'Hi, we have received a payment of INR 1250.50 towards your RBL Bank SuperCard (1234).',
      'Your payment of Rs.1250.50 has been processed for OneCard ending XX1234.',
    ]) {
      final category = smsCategory(
        sms(body, card: true, merchant: 'STORE'),
        categories,
      );
      expect(category, isNull);
      expect(sms(body, card: true).isCreditCardRepayment, isTrue);
    }
    final category = smsCategory(
      sms(
        'Rs.1250.50 debited from A/c XX1234 towards your credit card payment.',
        credit: false,
      ),
      categories,
    );
    expect(category, isNull);
  });

  test(
    'refunds, cashback, purchases, and ordinary credits are not repayments',
    () {
      for (final body in [
        'Refund payment of Rs.1250.50 credited to your credit card XX1234.',
        'Cashback payment credited to SBI credit card XX1234.',
        'Rs.1250.50 credited to SBI credit card XX1234 for a reversal.',
        'Rs.1250.50 credited from a friend to your account XX1234.',
      ]) {
        expect(
          smsCategory(sms(body), categories)?.name,
          body.contains('from a friend') ? 'Personal' : 'Refunds',
        );
      }
      final purchase = sms(
        'Your payment of Rs.1250.50 at CORNER STORE has been processed for OneCard.',
        credit: false,
        card: true,
        merchant: 'CORNER STORE',
      );
      expect(smsCategory(purchase, categories)?.name, 'Groceries');
      expect(
        smsCategory(
          sms(
            'SBI credit card XX1234 spent Rs.1250.50 at STORE.',
            credit: false,
            card: true,
            merchant: 'STORE',
          ),
          categories,
        )?.name,
        'Groceries',
      );
    },
  );

  test('missing or deleted categories do not select the wrong direction', () {
    final repayment = sms(
      'Payment received towards your credit card XX1234.',
      card: true,
    );
    final expenseOnly = categories
        .where((c) => c.type == CategoryType.expense)
        .toList();
    expect(smsCategory(repayment, expenseOnly), isNull);
    // A machine deposit is a transfer however the category list looks.
    final withoutAtm = categories
        .where((c) => c.name != 'ATM Deposit')
        .toList();
    expect(
      smsCategory(
        sms('Cash credited using cash deposit machine at TEST.'),
        withoutAtm,
      ),
      isNull,
    );
  });

  test('v25 upgrade adds suggestions once and preserves existing categories and balances', () async {
    final dir = await Directory.systemTemp.createTemp('sms_category_upgrade_');
    final file = File('${dir.path}/database.sqlite');
    final old = _V25Database(NativeDatabase(file));
    try {
      await old.customStatement(
        "DELETE FROM categories WHERE name IN ('Credit Card Repayment','ATM Deposit','Cash Deposit')",
      );
      await CategoryRepository(old).save(
        name: 'credit card repayment',
        type: CategoryType.expense,
        icon: 'wallet_one',
      );
      await AccountRepository(old).save(
        name: 'Savings',
        currency: 'INR',
        digits: 2,
        openingBalance: 123450,
      );
      final before = await CategoryRepository(old).load();
      final custom = before.firstWhere(
        (c) => c.name == 'credit card repayment',
      );
      await old.close();
      final upgraded = AppDatabase(NativeDatabase(file));
      final repo = CategoryRepository(upgraded);
      try {
        final after = await repo.load();
        expect(after.length, before.length + 3);
        final preserved = after.singleWhere((c) => c.id == custom.id);
        expect(preserved.name, custom.name);
        expect(preserved.icon, 'wallet_one');
        expect(
          (await AccountRepository(upgraded).load()).single.balanceMinor,
          123450,
        );
        await repo.delete(after.singleWhere((c) => c.name == 'ATM Deposit').id);
      } finally {
        await upgraded.close();
      }
      final reopened = AppDatabase(NativeDatabase(file));
      try {
        expect(
          (await CategoryRepository(
            reopened,
          ).load()).where((c) => c.name == 'ATM Deposit'),
          isEmpty,
        );
      } finally {
        await reopened.close();
      }
    } finally {
      await old.close();
      await dir.delete(recursive: true);
    }
  });
}

class _V25Database extends AppDatabase {
  _V25Database(super.executor);
  @override
  int get schemaVersion => 25;
}
