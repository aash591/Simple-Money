import 'package:simple_money/domain/category.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/domain/sms_matching.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

void main() {
  test('late-added food children appear under Food, not the last parent', () {
    const rows = [
      Category(id: 1, name: 'Food & Beverage', type: CategoryType.expense),
      Category(
        id: 2,
        name: 'Restaurants',
        type: CategoryType.expense,
        parentId: 1,
      ),
      Category(id: 67, name: 'Personal', type: CategoryType.expense),
      Category(
        id: -1001,
        name: 'Swiggy',
        type: CategoryType.expense,
        parentId: 1,
      ),
      Category(
        id: -1002,
        name: 'Zomato',
        type: CategoryType.expense,
        parentId: 1,
      ),
    ];
    expect(categoriesInDisplayOrder(rows).map((c) => c.name), [
      'Food & Beverage',
      'Restaurants',
      'Swiggy',
      'Zomato',
      'Personal',
    ]);
  });
  test('handles and conflicting names', () {
    expect(foodDeliveryMerchant('to VPA swiggyupi@axisbank'), 'Swiggy');
    expect(foodDeliveryMerchant('ZOMATO'), 'Zomato');
    expect(foodDeliveryMerchant('Swiggy Zomato'), isNull);
  });
  for (final name in ['Swiggy', 'Zomato']) {
    test(
      '$name drafts persist only on save and reuse existing category',
      () async {
        final db = AppDatabase(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = SmsImportRepository(db);
        final cats = CategoryRepository(db);
        final accounts = AccountRepository(db);
        await accounts.save(
          name: 'Bank',
          currency: 'INR',
          digits: 2,
          openingBalance: 100000,
        );
        final account = (await accounts.load()).single;
        final at = DateTime(2026, 10, 1);
        for (var i = 0; i < 2; i++) {
          final sms = BankSms(
            sender: 'FEDBNK',
            body: 'Rs 323 debited to ${name.toLowerCase()}upi@axisbank ref $i',
            receivedAt: at.add(Duration(days: i)),
          );
          await repo.enqueue(
            sms,
            PortableParseResult(
              classification: RuleClassification.completed,
              decision: SmsDecision.review,
              reason: 'completedNeedsReview',
              packVersion: 1,
              ruleId: 'test',
              candidate: SmsTransactionCandidate(
                amountMinor: 32300,
                currencyCode: 'INR',
                direction: SmsDirection.debit,
                occurredAt: sms.receivedAt,
                bankName: 'Federal Bank',
                countryCode: 'IN',
                accountLast4: '0544',
              ),
            ),
          );
        }
        final pending = await repo.pending();
        final draft = smsCategory(
          pending.first,
          await cats.load(includeDrafts: true),
        )!;
        expect(draft.name, name);
        expect(draft.icon, 'brand:${name.toLowerCase()}');
        expect(
          smsCategory(pending.first, await cats.load())?.parentId,
          draft.parentId,
        );
        expect(draft.id, lessThan(0));
        expect((await cats.load()).where((c) => c.name == name), isEmpty);
        Future<void> save(PendingSmsImport sms, int amount) => repo.save(
          sms,
          type: TransactionType.expense,
          amountMinor: amount,
          accountId: account.id,
          categoryId: draft.id,
          date: at,
        );
        await expectLater(
          save(pending.first, -1),
          throwsA(isA<ArgumentError>()),
        );
        expect((await cats.load()).where((c) => c.name == name), isEmpty);
        await save(pending.first, 32300);
        await save(pending.last, 32300);
        final saved = (await cats.load()).where((c) => c.name == name).single;
        expect(saved.id, greaterThan(0));
        expect(saved.parentId, draft.parentId);
        expect(
          (await cats.load(includeDrafts: true)).where((c) => c.id < 0),
          isEmpty,
        );
      },
    );
  }
}
