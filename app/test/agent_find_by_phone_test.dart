import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/reportable_sms.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart'
    show BankSms;

void main() {
  late AppDatabase db;
  late AgentTools tools;
  late int bank, food;

  Future<Map<String, Object?>> call(Map<String, Object?> args) async {
    final result = await tools.call('find_by_phone', args);
    final text = ((result['content'] as List).single as Map)['text'] as String;
    if (result['isError'] == true) return {'error': text};
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  }

  Future<int> add(
    int minor,
    String? note, {
    String? title,
    TransactionType type = TransactionType.expense,
  }) => TransactionRepository(db).addExpenseOrIncome(
    type: type,
    amountMinor: minor,
    accountId: bank,
    categoryId: food,
    title: title,
    note: note,
    date: DateTime(2026, 10, 5),
  );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tools = AgentTools(
      db,
      missedSms: (_) async => [
        ReportableSms(
          'fp1',
          BankSms(
            sender: 'VM-HDFCBK',
            body: 'Rs 300 sent to 98765 43210 via UPI',
            receivedAt: DateTime.now().subtract(const Duration(days: 2)),
          ),
          ReportableKind.missed,
          'noRule',
          null,
        ),
      ],
    );
    bank = await AccountRepository(db)
        .save(name: 'HDFC', currency: 'INR', digits: 2, openingBalance: 100000);
    food = (await CategoryRepository(
      db,
    ).load()).firstWhere((c) => c.type == CategoryType.expense).id;
  });
  tearDown(() => db.close());

  test('finds a number in UPI IDs and SMS, not inside other numbers', () async {
    final upi = await add(
      25000,
      'Sender: VM-HDFCBK\n\nRs 250 debited to VPA 9876543210@ybl',
      title: 'Ravi',
    );
    final spaced = await add(
      10000,
      'Paid +91 98765-43210',
      title: 'Ravi K',
      type: TransactionType.income,
    );
    // Same digits inside a longer reference number: not this phone.
    await add(5000, 'UPI Ref 1239876543210456');
    await add(7000, 'Paid someone@okhdfcbank', title: 'Ravi');
    await db.customStatement(
      "INSERT INTO sms_imports (fingerprint, sender, body, received_at, candidate, rule_id, pack_version) VALUES ('w1', 'VM-SBI', 'Rs.40.00 debited to 9876543210@paytm', ?, ?, 't', 1)",
      [
        DateTime(2026, 10, 6).millisecondsSinceEpoch,
        jsonEncode({
          'amountMinor': 4000,
          'currencyCode': 'INR',
          'direction': 'debit',
        }),
      ],
    );

    final reply = await call({'phone': '+91 98765 43210'});
    expect(reply['phone'], '9876543210');
    final saved = reply['saved'] as Map;
    expect(saved['count'], 2);
    expect([
      for (final t in saved['transactions'] as List) t['id'],
    ], [spaced, upi]..sort((a, b) => b.compareTo(a)));
    expect(
      saved['totals'],
      containsAll([
        {'type': 'expense', 'total': '250.00', 'currency': 'INR', 'count': 1},
        {'type': 'income', 'total': '100.00', 'currency': 'INR', 'count': 1},
      ]),
    );
    expect(
      (saved['transactions'] as List).firstWhere((t) => t['id'] == upi)['from'],
      'bank_sms',
    );
    expect(reply['upi_ids_seen'], ['9876543210@paytm', '9876543210@ybl']);
    expect((reply['sms_waiting_for_review'] as List).single['sms_id'], 'w1');
    expect((reply['unparsed_sms'] as List), hasLength(1));
    expect(reply['accuracy'], contains('email'));
    expect(reply['names_seen'], containsAll(['Ravi', 'Ravi K']));
    expect(reply['next'], contains('accuracy'));
  });

  test('says when nothing mentions the number', () async {
    await add(5000, 'Paid someone@okhdfcbank');
    final reply = await call({
      'phone': '9000000001',
      'include_unparsed': false,
    });
    expect((reply['saved'] as Map)['count'], 0);
    expect(reply['next'], startsWith('Nothing mentions this number.'));
    expect(reply['accuracy'], isNotEmpty);
  });

  test('rejects something that isn’t a phone number', () async {
    expect((await call({'phone': '12ab'}))['error'], contains('phone number'));
  });
}
