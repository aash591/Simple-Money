import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/repositories/sms_review_repository.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

void main() {
  final at = DateTime(2026, 5, 8, 10, 49, 44);
  final message = BankSms(
    sender: 'VA-FEDBNK-S',
    body:
        'Rs 379.00 sent via UPI on 08-05-2026 at 10:49:44 to '
        'VODAFONE IDEA L.Ref:612816686088.Not you? Call '
        '18004251199/SMS BLOCKUPI to 98950 88888 -Federal Bank',
    receivedAt: at,
  );
  final parser = PortableSmsEngine(
    const RuleCompiler().loadRuntime(
      jsonDecode(
        File(
          'packages/universal_bank_sms_parser/distribution/packs/india/federal.json',
        ).readAsStringSync(),
      ) as Map<String, dynamic>,
    ),
  );
  late AppDatabase db;
  late SmsImportRepository imports;
  late SmsReviewRepository review;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    imports = SmsImportRepository(db);
    review = SmsReviewRepository(db);
    await imports.enqueue(message, parser.parse(message));
  });
  tearDown(() => db.close());

  Future<void> detect(String suffix, {bool card = false}) =>
      imports.recordBalance({
        'bankName': 'Federal Bank',
        'countryCode': 'IN',
        'currencyCode': 'INR',
        'accountLast4': suffix,
        'isCreditCard': card,
      }, at);

  Future<SmsReviewRow> project() async {
    final sms = (await imports.pending()).single;
    final categories = await CategoryRepository(db).load();
    await review.put(
      sms,
      await AccountRepository(db).load(),
      categories,
      await imports.accountLinks(),
      categories.firstWhere((c) => c.type.name == 'expense').id,
    );
    return (await review.page()).single;
  }

  test(
    'explicit assignment persists without inventing an account suffix',
    () async {
      await AccountRepository(db)
          .save(name: 'Chosen', currency: 'INR', digits: 2, openingBalance: 0);
      final account = (await AccountRepository(db).load()).single;
      final sms = (await imports.pending()).single;
      await imports.assignAccounts({sms.id}, account.id);
      final row = await project();
      expect(row.transaction.accountId, account.id);
      expect(row.ready, isTrue);
      expect(row.sms.accountLast4, isNull);
      expect(
        (await imports.pending()).single.data['assignedAccountId'],
        account.id,
      );
    },
  );
  test(
    'batch assignment rolls back when a message is no longer pending',
    () async {
      await AccountRepository(db)
          .save(name: 'Chosen', currency: 'INR', digits: 2, openingBalance: 0);
      final account = (await AccountRepository(db).load()).single;
      final sms = (await imports.pending()).single;
      await expectLater(
        imports.assignAccounts({sms.id, 'missing'}, account.id),
        throwsStateError,
      );
      expect(
        (await imports.pending()).single.data['assignedAccountId'],
        isNull,
      );
    },
  );
  test(
    'portable parser identifies Federal without inventing account digits',
    () {
      final candidate = parser.parse(message).candidate!;
      expect(candidate.bankName, 'Federal Bank');
      expect(candidate.accountLast4, isNull);
      expect(candidate.amountMinor, 37900);
      expect(candidate.direction, SmsDirection.debit);
    },
  );

  test(
    'no history needs attention; sole detected bank account resolves',
    () async {
      expect((await project()).ready, isFalse);
      await detect('0544');
      await detect('9999', card: true);
      final detected = await imports.detectedAccounts();
      await imports.createDetectedAccounts(detected);
      final row = await project();
      expect(row.ready, isTrue);
      expect(row.sms.accountLast4, '0544');
      expect((await imports.pending()).single.accountLast4, isNull);
      expect(
        (await imports.detectedAccountMessageCounts())[row.sms.bankKey],
        1,
      );
    },
  );

  test(
    'second historical account invalidates suggestion even if only one linked',
    () async {
      await detect('0544');
      await imports.createDetectedAccounts(await imports.detectedAccounts());
      expect((await project()).ready, isTrue);
      await review.recordContext(await review.contextSignature('rules'));
      await detect('1234');
      expect(
        await review.contextChanged(await review.contextSignature('rules')),
        isTrue,
      );
      final row = await project();
      expect(row.sms.accountLast4, isNull);
      expect(row.transaction.accountId, 0);
      expect(row.ready, isFalse);
    },
  );

  test(
    'explicit suffix is retained and other banks are not inferred',
    () async {
      await detect('0544');
      final sms = (await imports.pending()).single;
      PendingSmsImport withData(Map<String, dynamic> data) => PendingSmsImport(
        id: sms.id,
        sender: sms.sender,
        body: sms.body,
        receivedAt: at,
        data: data,
      );
      final groups = await imports.detectedAccounts();
      expect(
        resolveSmsAccount(
          withData({...sms.data, 'accountLast4': '1234'}),
          groups,
        ).accountLast4,
        '1234',
      );
      expect(
        resolveSmsAccount(
          withData({...sms.data, 'bankName': 'Other'}),
          groups,
        ).accountLast4,
        isNull,
      );
      expect(
        resolveSmsAccount(
          withData({...sms.data, 'currencyCode': 'USD'}),
          groups,
        ).accountLast4,
        isNull,
      );
      expect(
        resolveSmsAccount(
          withData({...sms.data, 'countryCode': 'US'}),
          groups,
        ).accountLast4,
        isNull,
      );
    },
  );
}
