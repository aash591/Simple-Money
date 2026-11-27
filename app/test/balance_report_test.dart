import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/balance_report_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/transaction.dart';

void main() {
  late AppDatabase db;
  late BalanceReportRepository reports;
  late SmsImportRepository imports;
  late int bank;
  final at = DateTime(2026, 10, 25, 12);
  final data = <String, dynamic>{
    'bankName': 'SBI',
    'countryCode': 'IN',
    'currencyCode': 'INR',
    'accountLast4': '1234',
    'isCreditCard': false,
  };

  Future<void> report(int balance, DateTime when) =>
      imports.recordBalance({...data, 'balanceMinor': balance}, when);
  Future<Account> account() async => (await AccountRepository(
    db,
  ).load()).singleWhere((a) => a.id == bank);

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    reports = BalanceReportRepository(db);
    imports = SmsImportRepository(db);
    bank = await AccountRepository(db).save(
      name: 'Bank',
      currency: 'INR',
      digits: 2,
      openingBalance: 100000,
      lastDigits: '1234',
      institution: 'SBI',
    );
    await db.customStatement(
      'INSERT INTO sms_account_links(bank_key,account_id) VALUES (?,?)',
      [smsBankKey(data), bank],
    );
  });
  tearDown(() => db.close());

  test('a reported balance is offered, never applied by itself', () async {
    await report(90000, at);
    expect((await account()).balanceMinor, 100000);
    final mismatch = (await reports.mismatches()).single;
    expect(mismatch.appMinor, 100000);
    expect(mismatch.differenceMinor, -10000);
  });

  test('accepting adds an entry that deleting undoes', () async {
    await report(90000, at);
    final id = await reports.adjust((await reports.mismatches()).single);
    expect((await account()).balanceMinor, 90000);
    final entry = (await TransactionRepository(db).load(id: id)).single;
    expect(entry.title, balanceAdjustmentCategory);
    expect(entry.amountMinor, 10000);
    expect(entry.date, at);
    expect(await reports.mismatches(), isEmpty);
    await TransactionRepository(db).delete(id);
    expect((await account()).balanceMinor, 100000);
    expect(await reports.mismatches(), isEmpty);
  });

  test('keeping asks again only for a newer report', () async {
    await report(90000, at);
    await reports.keep((await reports.mismatches()).single);
    expect(await reports.mismatches(), isEmpty);
    await report(80000, at.add(const Duration(days: 1)));
    expect((await reports.mismatches()).single.reportedMinor, 80000);
  });

  test('later transactions are left out of the comparison', () async {
    await report(100000, at);
    await db.customStatement(
      '''INSERT INTO transactions
      (id,type,amount_minor,account_id,date,created_at)
      VALUES (1,'expense',500,?,?,0)''',
      [bank, at.add(const Duration(hours: 1)).millisecondsSinceEpoch],
    );
    await db.customStatement(
      'UPDATE accounts SET balance_minor=balance_minor-500 WHERE id=?',
      [bank],
    );
    expect(await reports.mismatches(), isEmpty);
  });

  test('a report that once matched does not come back', () async {
    await report(100000, at);
    expect(await reports.mismatches(), isEmpty);
    await db.customStatement(
      'UPDATE accounts SET balance_minor=1 WHERE id=?',
      [bank],
    );
    expect(await reports.mismatches(), isEmpty);
  });

  test('setting the balance by hand answers the report', () async {
    await report(90000, at);
    await TransactionRepository(db).adjustBalance(
      accountId: bank,
      mode: BalanceAdjustmentMode.setTo,
      amountMinor: 70000,
    );
    expect(await reports.mismatches(), isEmpty);
  });
}
