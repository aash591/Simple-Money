import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/data/repositories/upi_repository.dart';
import 'package:simple_money/domain/upi_payment.dart';

void main() {
  group('UpiRecipient.hasMeaningfulName', () {
    bool named(String pn) =>
        UpiRecipient.parse('upi://pay?pa=shop@bank&pn=$pn').hasMeaningfulName;

    test('a person or shop name is meaningful', () {
      expect(named('Ashique%20M'), isTrue);
      expect(named('Dhanya%20Store'), isTrue);
    });

    test("a payment app's own generic stand-in is not", () {
      expect(named('PhonePe%20Merchant'), isFalse);
      expect(named('BharatPe%20Merchant'), isFalse);
      expect(named('Paytm'), isFalse);
      expect(named('UPI%20Merchant'), isFalse);
      expect(named('merchant'), isFalse);
    });

    test('no name at all (falls back to the address) is not meaningful', () {
      expect(
        UpiRecipient.parse('upi://pay?pa=shop@bank').hasMeaningfulName,
        isFalse,
      );
    });
  });

  test(
    'Late locality preserves edits and never recreates consumed drafts',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final repo = UpiRepository(db);
        final original = PendingUpiPayment(
          id: 'place-race',
          recipient: UpiRecipient.parse('upi://pay?pa=shop@bank'),
          amountText: '10',
          categoryId: null,
          accountId: null,
          date: DateTime(2026, 9, 22),
        );
        await repo.put(original);
        await repo.put(original.copyWith(amountText: '25'));
        await repo.attachPlace(original.id, 'Indiranagar, Bengaluru');
        expect((await repo.load()).single.amountText, '25');
        // An editor holding an older draft must not erase a finished lookup.
        await repo.put(original.copyWith(amountText: '30'));
        expect((await repo.load()).single.place, 'Indiranagar, Bengaluru');
        expect((await repo.load()).single.amountText, '30');
        await repo.delete(original.id);
        await repo.attachPlace(original.id, 'Late result');
        expect(await repo.load(), isEmpty);
      } finally {
        await db.close();
      }
    },
  );
  test('unchanged QR handoff keeps original bytes and provider metadata', () {
    const qr =
        'upi://pay?pa=shop%40bank&pn=Tea%20Shop&am=125.50&mode=02&orgid=000000&tr=ref%2f123&url=https%3a%2f%2fexample.com%2fpay';
    final recipient = UpiRecipient.parse(qr);
    expect(recipient.paymentUri('125.5'), qr);
    expect(
      recipient.paymentUri('150.25'),
      '${qr.replaceFirst('am=125.50', 'am=150.25')}&cu=INR',
    );
    final draft = PendingUpiPayment(
      id: 'raw',
      recipient: recipient,
      amountText: '125.50',
      categoryId: 1,
      accountId: 1,
      date: DateTime(2026),
    );
    expect(
      PendingUpiPayment.fromJson(draft.toJson()).recipient.paymentUri('125.50'),
      qr,
    );
  });

  test('amount entry adds only amount and currency to a static QR', () {
    const qr = 'upi://pay?pa=shop@bank&pn=Tea%20%26%20Co&tr=ref%2f123';
    final payment = UpiRecipient.parse(qr).paymentUri('25');
    expect(payment, '$qr&am=25&cu=INR');
    expect(Uri.parse(payment).queryParameters.keys, isNot(contains('mc')));
    expect(Uri.parse(payment).queryParameters.keys, isNot(contains('mode')));
  });

  test(
    'QR retains merchant reference, amount and encoded recipient details',
    () {
      final recipient = UpiRecipient.parse(
        'upi://pay?pa=shop@bank&pn=Tea%20%26%20Co&am=125.50&cu=INR&tr=order123&mc=5411',
      );
      expect(recipient.name, 'Tea & Co');
      expect(upiAmountMinor(recipient.amount), 12550);
      final payment = Uri.parse(recipient.paymentUri('150.25'));
      expect(payment.queryParameters, containsPair('tr', 'order123'));
      expect(payment.queryParameters, containsPair('pn', 'Tea & Co'));
      expect(payment.queryParameters, containsPair('am', '150.25'));
    },
  );

  test('untrusted and ambiguous QR data cannot become payment intents', () {
    for (final payload in [
      'https://example.com/pay',
      'upi://collect?pa=shop@bank',
      'upi://pay?pa=shop@bank&pa=other@bank',
      'upi://pay?pa=invalid',
      'upi://pay?pa=shop@bank&am=-1',
      'upi://pay?pa=shop@bank&am=1e4',
      'upi://pay?pa=shop@bank&am=10.001',
      'upi://pay?pa=shop@bank&cu=USD',
      'upi://pay?pa=shop@bank&sign=signed',
    ]) {
      expect(
        () => UpiRecipient.parse(payload),
        throwsFormatException,
        reason: payload,
      );
    }
  });

  test('signed QR is unchanged and amount cannot be changed', () {
    const payload =
        'upi://pay?pa=shop@bank&pn=Tea%20Shop&am=12.50&sign=abc%2Bxyz';
    final recipient = UpiRecipient.parse(payload);
    expect(recipient.amountLocked, isTrue);
    expect(recipient.paymentUri('12.5'), payload);
    expect(() => recipient.paymentUri('13'), throwsFormatException);
  });

  test('old phone drafts remain readable but cannot start a new payment', () {
    final recipient = PendingUpiPayment.fromJson({
      'id': 'legacy',
      'phone': '+91 (98765) 43210',
      'name': 'Alex',
      'amount': '10',
      'categoryId': 1,
      'accountId': 1,
      'date': '2026-09-12T12:00:00',
    }).recipient;
    expect(recipient.phone, '9876543210');
    expect(recipient.uri, isNull);
    expect(() => recipient.paymentUri('10'), throwsStateError);
    expect(upiAmountMinor('999999999.99'), 99999999999);
    expect(upiAmountMinor('0'), isNull);
  });

  test('pending survives restart; confirmation posts exactly one expense', () async {
    final directory = await Directory.systemTemp.createTemp('upi_test_');
    final file = File('${directory.path}/test.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    try {
      final accounts = AccountRepository(db);
      await accounts.save(
        name: 'Bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 100000,
      );
      final accountId = (await accounts.load()).single.id;
      final categoryId =
          (await db
                  .customSelect(
                    "SELECT id FROM categories WHERE type = 'expense' LIMIT 1",
                  )
                  .getSingle())
              .read<int>('id');
      final payment = PendingUpiPayment(
        id: 'payment-1',
        recipient: UpiRecipient.parse(
          'upi://pay?pa=shop@bank&pn=Shop&am=125.50',
        ),
        amountText: '125.50',
        categoryId: categoryId,
        accountId: accountId,
        date: DateTime(2026, 9, 12),
      );
      await UpiRepository(db).put(payment);
      expect((await accounts.load()).single.balanceMinor, 100000);
      expect(await TransactionRepository(db).load(), isEmpty);
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      final repo = UpiRepository(db);
      expect((await repo.load()).single.recipient.address, 'shop@bank');
      await repo.confirm('payment-1');
      await repo.confirm('payment-1');
      expect(await repo.load(), isEmpty);
      expect(
        (await TransactionRepository(db).load()).single.amountMinor,
        12550,
      );
      expect((await AccountRepository(db).load()).single.balanceMinor, 87450);
      await repo.put(
        PendingUpiPayment(
          id: 'payment-2',
          recipient: payment.recipient,
          amountText: payment.amountText,
          categoryId: categoryId,
          accountId: accountId,
          date: payment.date,
        ),
      );
      await repo.delete('payment-2');
      expect((await AccountRepository(db).load()).single.balanceMinor, 87450);
      expect(await repo.load(), isEmpty);
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });

  test('incomplete queue survives disk reopen and cannot be posted', () async {
    final directory = await Directory.systemTemp.createTemp('upi_queue_');
    final file = File('${directory.path}/test.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    try {
      final payment = PendingUpiPayment(
        id: 'incomplete',
        recipient: UpiRecipient.parse('upi://pay?pa=shop@bank'),
        amountText: '',
        categoryId: null,
        accountId: null,
        date: DateTime.now(),
      );
      await UpiRepository(db).put(payment);
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      final repo = UpiRepository(db);
      expect((await repo.load()).single.categoryId, isNull);
      await expectLater(repo.confirm('incomplete'), throwsStateError);
      expect((await repo.load()).length, 1);
      expect(await TransactionRepository(db).load(), isEmpty);
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });

  test('v10 database upgrades without changing the existing ledger', () async {
    final directory = await Directory.systemTemp.createTemp('upi_upgrade_');
    final file = File('${directory.path}/test.sqlite');
    var db = AppDatabase(NativeDatabase(file));
    try {
      await AccountRepository(db)
          .save(name: 'Bank', currency: 'INR', digits: 2, openingBalance: 2500);
      await db.customStatement('DROP TABLE pending_upi_payments');
      await db.customStatement('PRAGMA user_version = 10');
      await db.close();
      db = AppDatabase(NativeDatabase(file));
      expect(await UpiRepository(db).load(), isEmpty);
      expect((await AccountRepository(db).load()).single.balanceMinor, 2500);
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });

  test(
    'failed confirmation keeps draft and does not debit an unrelated account',
    () async {
      final db = AppDatabase(NativeDatabase.memory());
      try {
        final repo = UpiRepository(db);
        await repo.put(
          PendingUpiPayment(
            id: 'orphan',
            recipient: UpiRecipient.parse('upi://pay?pa=shop@bank'),
            amountText: '10',
            categoryId: 999999,
            accountId: 999999,
            date: DateTime.now(),
          ),
        );
        await expectLater(repo.confirm('orphan'), throwsStateError);
        expect((await repo.load()).single.id, 'orphan');
        expect(await TransactionRepository(db).load(), isEmpty);
      } finally {
        await db.close();
      }
    },
  );
}
