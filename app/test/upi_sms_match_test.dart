import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/realtime_sms_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/data/repositories/upi_repository.dart';
import 'package:simple_money/data/repositories/upi_sms_match.dart';
import 'package:simple_money/domain/upi_payment.dart';

void main() {
  late AppDatabase db;
  late RealtimeSmsRepository live;
  late UpiRepository upi;
  late PortableSmsEngine engine;
  late int bank, groceries;
  final paidAt = DateTime(2026, 10, 25, 12);

  BankSms sms({
    Duration after = const Duration(minutes: 1),
    String amount = '500',
    String reference = '123456789012',
  }) => BankSms(
    sender: 'AX-SBIUPI-S',
    receivedAt: paidAt.add(after),
    body:
        'Dear SBI User, your A/c X1234-debited by Rs.$amount on 25Oct26 transfer to SAMPLE RECEIVER Ref No $reference -SBI',
  );

  Future<bool> pay(String id, {String amount = '500'}) async {
    await upi.put(
      PendingUpiPayment(
        id: id,
        recipient: UpiRecipient.parse('upi://pay?pa=shop@bank&pn=Shop'),
        amountText: amount,
        categoryId: groceries,
        accountId: bank,
        date: paidAt,
      ),
    );
    return upi.confirm(id);
  }

  Future<List<String>> importStatuses() async => [
    for (final row
        in await db
            .customSelect('SELECT status FROM sms_imports ORDER BY received_at')
            .get())
      row.read<String>('status'),
  ];

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    live = RealtimeSmsRepository(db);
    upi = UpiRepository(db);
    engine = BankSmsParser(
      const RuleCompiler().loadRuntime(
        jsonDecode(
          File(
            'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
          ).readAsStringSync(),
        ) as Map<String, dynamic>,
      ),
    );
    bank = await AccountRepository(db).save(
      name: 'Bank',
      currency: 'INR',
      digits: 2,
      openingBalance: 100000,
      lastDigits: '1234',
      institution: engine.parse(sms()).candidate!.bankName,
    );
    groceries =
        (await db
                .customSelect(
                  "SELECT id FROM categories WHERE type='expense' ORDER BY id DESC LIMIT 1",
                )
                .getSingle())
            .read<int>('id');
    await SmsImportRepository(db).enable(true);
  });
  tearDown(() => db.close());

  Future<int> balance() async => (await AccountRepository(
    db,
  ).load()).singleWhere((a) => a.id == bank).balanceMinor;

  test('SMS after the UPI payment joins it instead of adding one', () async {
    expect(await pay('p1'), isFalse);
    expect(await live.receive(sms(), engine), isNull);
    final ledger = await TransactionRepository(db).load();
    expect(ledger, hasLength(1));
    expect(ledger.single.categoryId, groceries);
    expect(await importStatuses(), ['imported']);
    expect(await balance(), 50000);
  });

  test('UPI confirmed after its SMS updates the SMS expense', () async {
    final received = (await live.receive(sms(), engine))!;
    expect(await TransactionRepository(db).load(), hasLength(1));
    expect(await pay('p1'), isTrue);
    final ledger = await TransactionRepository(db).load();
    expect(ledger, hasLength(1));
    expect(ledger.single.categoryId, groceries);
    expect(
      ledger.single.note,
      startsWith('UPI • shop@bank • Payment confirmed by you'),
    );
    expect(ledger.single.note, contains('SAMPLE RECEIVER'));
    expect(await balance(), 50000);
    // The notification still shows the transaction, with the new category.
    expect((await live.load(received.sms.id))!.categoryId, groceries);
    expect(
      (await upi.remembered(UpiRecipient.parse('upi://pay?pa=shop@bank')))
          .categoryId,
      groceries,
    );
  });

  test(
    'SMS waiting for review joins the UPI expense confirmed later',
    () async {
      final message = sms();
      await SmsImportRepository(db).enqueue(message, engine.parse(message));
      expect(await importStatuses(), ['pending']);
      expect(await pay('p1'), isTrue);
      expect(await TransactionRepository(db).load(), hasLength(1));
      expect(await importStatuses(), ['imported']);
      expect(await balance(), 50000);
    },
  );

  PendingUpiPayment draft({String amount = '500'}) => PendingUpiPayment(
    id: 'd1',
    recipient: UpiRecipient.parse('upi://pay?pa=shop@bank&pn=Shop'),
    amountText: amount,
    categoryId: null,
    accountId: null,
    date: paidAt,
  );

  test('bankSms finds the expense an SMS saved for the payment', () async {
    expect(await upi.bankSms(draft()), isNull);
    await live.receive(sms(), engine);
    final found = (await upi.bankSms(draft()))!;
    expect(found.saved, isTrue);
    expect(found.accountId, bank);
    expect(await upi.bankSms(draft(amount: '501')), isNull);
  });

  test('bankSms finds an SMS still waiting for review', () async {
    final message = sms();
    await SmsImportRepository(db).enqueue(message, engine.parse(message));
    final found = (await upi.bankSms(draft()))!;
    expect(found.saved, isFalse);
    // Not linked to an account yet: the payment keeps the account it has.
    expect(found.accountId, isNull);
  });

  Future<int> wallet() =>
      AccountRepository(db)
          .save(name: 'Wallet', currency: 'INR', digits: 2, openingBalance: 0);

  Future<bool> payTransfer(int to) async {
    await upi.put(
      draft().copyWith(isTransfer: true, accountId: bank, toAccountId: to),
    );
    return upi.confirm('d1');
  }

  test('a transfer saved after its SMS takes over the SMS expense', () async {
    final to = await wallet();
    await live.receive(sms(), engine);
    expect(await payTransfer(to), isTrue);
    final ledger = await TransactionRepository(db).load();
    expect(ledger, hasLength(1));
    expect(ledger.single.type.name, 'transfer');
    expect(ledger.single.toAccountId, to);
    expect(await balance(), 50000);
  });

  test('a transfer joins the SMS waiting for review', () async {
    final to = await wallet();
    final message = sms();
    await SmsImportRepository(db).enqueue(message, engine.parse(message));
    expect(await payTransfer(to), isTrue);
    expect(await TransactionRepository(db).load(), hasLength(1));
    expect(await importStatuses(), ['imported']);
  });

  test('an SMS arriving after a UPI transfer joins it', () async {
    final to = await wallet();
    expect(await payTransfer(to), isFalse);
    await live.receive(sms(), engine);
    expect(await TransactionRepository(db).load(), hasLength(1));
    expect(await importStatuses(), ['imported']);
  });

  test('moving the payment to another account still saves one', () async {
    final other = await wallet();
    await live.receive(sms(), engine);
    await upi.put(draft().copyWith(categoryId: groceries, accountId: other));
    expect(await upi.confirm('d1'), isTrue);
    final ledger = await TransactionRepository(db).load();
    expect(ledger, hasLength(1));
    expect(ledger.single.accountId, other);
  });

  test('a different amount or a much later SMS stays separate', () async {
    await pay('p1');
    await live.receive(sms(amount: '501'), engine);
    await live.receive(
      sms(after: const Duration(hours: 3), reference: '123456789013'),
      engine,
    );
    expect(await TransactionRepository(db).load(), hasLength(3));
  });

  test('two equal payments each take one SMS', () async {
    await pay('p1');
    await pay('p2');
    await live.receive(sms(), engine);
    await live.receive(
      sms(after: const Duration(minutes: 2), reference: '123456789013'),
      engine,
    );
    await live.receive(
      sms(after: const Duration(minutes: 3), reference: '123456789014'),
      engine,
    );
    // The third SMS has no UPI payment left, so it is its own expense.
    expect(await TransactionRepository(db).load(), hasLength(3));
    expect(await importStatuses(), ['imported', 'imported', 'imported']);
    expect(await balance(), 100000 - 3 * 50000);
  });

  test(
    'a UPI transfer note starts with the same bullet as an expense',
    () async {
      final other = await AccountRepository(db)
          .save(name: 'Wallet', currency: 'INR', digits: 2, openingBalance: 0);
      await upi.put(
        PendingUpiPayment(
          id: 'move',
          recipient: UpiRecipient.parse('upi://pay?pa=me@bank&pn=Me'),
          amountText: '700',
          categoryId: null,
          accountId: bank,
          toAccountId: other,
          isTransfer: true,
          date: paidAt,
        ),
      );
      expect(await upi.confirm('move'), isFalse);
      final note = (await TransactionRepository(db).load()).single.note;
      expect(note, startsWith('UPI • me@bank • Payment confirmed by you'));
    },
  );

  group('a live SMS for a UPI scan', () {
    test('still pending takes the scan’s category, and picking one '
        'settles the scan into the same expense', () async {
      await upi.put(draft().copyWith(categoryId: groceries, accountId: bank));
      final got = (await live.receive(sms(), engine))!;
      expect(got.categoryId, groceries);
      expect((await pendingUpiForSms(db, got.sms))?.id, 'd1');

      await live.selectCategory(
        got.sms.id,
        groceries,
        accountId: got.accountId,
      );
      expect(await upi.load(), isEmpty);
      final ledger = await TransactionRepository(db).load();
      expect(ledger, hasLength(1));
      expect(ledger.single.note, startsWith('UPI • shop@bank'));
      expect(await balance(), 50000);
    });

    test('already saved is reported as confirmed by the bank', () async {
      expect(await pay('p1'), isFalse);
      final message = sms();
      expect(await live.receive(message, engine), isNull);
      final id =
          (await db
                  .customSelect('SELECT fingerprint FROM sms_imports')
                  .getSingle())
              .read<String>('fingerprint');
      final joined = (await upiExpenseJoinedBy(db, id))!;
      expect(joined.payee, 'Shop');
      expect(joined.amountMinor, 50000);
      expect(joined.category, isNotNull);
    });

    test('a credit or another amount matches no scan', () async {
      await upi.put(draft(amount: '499'));
      final got = (await live.receive(sms(), engine))!;
      expect(await pendingUpiForSms(db, got.sms), isNull);
    });
  });
}
