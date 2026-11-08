import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/domain/transaction_preview.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/repositories/sms_review_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

void main() {
  late AppDatabase db;
  late SmsImportRepository imports;
  late SmsReviewRepository review;
  final at = DateTime(2026, 10, 12);

  BankSms message(int i) =>
      BankSms(sender: 'BANK', body: 'Payment $i', receivedAt: at);
  PortableParseResult parsed(int i) => PortableParseResult(
    classification: RuleClassification.completed,
    decision: SmsDecision.review,
    reason: 'completedNeedsReview',
    packVersion: 1,
    ruleId: 'test',
    candidate: SmsTransactionCandidate(
      amountMinor: 10000 + i,
      direction: SmsDirection.debit,
      occurredAt: at,
      currencyCode: 'INR',
      bankName: 'Bank',
      accountLast4: '1234',
      countryCode: 'IN',
      counterparty: i == 120 ? 'Unique recipient' : 'Person $i',
    ),
  );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    imports = SmsImportRepository(db);
    review = SmsReviewRepository(db);
    await AccountRepository(
      db,
    ).save(name: 'Bank', currency: 'INR', digits: 2, openingBalance: 10000000);
    final accounts = await AccountRepository(db).load();
    final categories = await CategoryRepository(db).load();
    final category = categories.firstWhere((c) => c.type.name == 'expense');
    await db.transaction(() async {
      for (var i = 0; i < 121; i++) {
        await imports.enqueue(message(i), parsed(i));
      }
      for (final sms in await imports.pending()) {
        await review.put(sms, accounts, categories, {
          sms.bankKey: accounts.single.id,
        }, category.id);
      }
    });
  });
  tearDown(() => db.close());

  test(
    'SQL pages cover tied dates without gaps and filter beyond the first page',
    () async {
      expect(await review.count(), 121);
      final ids = <String>{};
      for (var offset = 0; offset < 121; offset += 50) {
        final page = await review.page(offset: offset);
        expect(page.length, lessThanOrEqualTo(50));
        for (final row in page) {
          expect(ids.add(row.sms.id), isTrue);
        }
      }
      expect(ids, hasLength(121));
      final rows = await review.page(
        filter: const SmsReviewFilter(search: 'UNIQUE RECIPIENT'),
      );
      expect(rows.single.sms.title, 'Unique recipient');
      expect(await review.count(const SmsReviewFilter(search: '%')), 0);
      expect(await review.count(const SmsReviewFilter(type: 'income')), 0);
      expect(await review.count(const SmsReviewFilter(ready: false)), 0);
      expect(
        await review.count(
          SmsReviewFilter(start: at, end: at.add(const Duration(days: 1))),
        ),
        121,
      );
      expect(await review.count(SmsReviewFilter(end: at)), 0);
      expect(
        await review.count(
          SmsReviewFilter(accountId: rows.single.transaction.accountId),
        ),
        121,
      );
      expect(
        await review.count(
          SmsReviewFilter(categoryId: rows.single.transaction.categoryId),
        ),
        121,
      );
      expect(await TransactionRepository(db).load(), isEmpty);
    },
  );

  TransactionPreviewQuery query({
    bool byCategory = true,
    String search = '',
    Set<int> expanded = const {},
    bool? ready = true,
    int limit = 50,
    DateTime? start,
    DateTime? end,
    int? accountId,
    int? categoryId,
  }) => TransactionPreviewQuery(
    start: start ?? at,
    end: end ?? at.add(const Duration(days: 1)),
    ready: ready,
    byCategory: byCategory,
    search: search,
    expandedGroups: expanded,
    limit: limit,
    accountId: accountId,
    categoryId: categoryId,
  );

  test('original category browser receives ten rows with complete counts and totals', () async {
    final data = await review.browse(query());
    expect(data.count, 121);
    expect(data.transactions, hasLength(10));
    expect(data.groups.single.count, 121);
    expect(data.groups.single.totals[('INR', 2)], (0, 1217260));
    expect(data.summary[('INR', 2)], (0, 1217260));
    expect(data.currencies, {('INR', 2): 121});
    final expanded = await review.browse(
      query(expanded: {data.groups.single.categoryId!}),
    );
    expect(expanded.transactions, hasLength(121));
    expect(expanded.count, 121);
    final sms = await review.byPreviewId(data.transactions.first.id);
    expect(sms!.sms.body, startsWith('Payment'));
    expect(await TransactionRepository(db).load(), isEmpty);
  });

  test('original browser searches the entire database and preserves summary totals', () async {
    final data = await review.browse(query(search: 'UNIQUE RECIPIENT'));
    expect(data.count, 1);
    expect(data.transactions.single.title, 'Unique recipient');
    expect(data.summary[('INR', 2)], (0, 1217260));
    expect(data.filteredSummary[('INR', 2)], (0, 10120));
    expect((await review.browse(query(ready: false))).transactions, isEmpty);
    expect((await review.browse(query(accountId: -1))).transactions, isEmpty);
    expect((await review.browse(query(categoryId: -1))).transactions, isEmpty);
    expect((await review.browse(query(end: at))).count, 0);
    expect((await review.browse(query(search: '%'))).count, 0);
  });

  test(
    'transactions needing a category appear in the default review view',
    () async {
      final account = (await AccountRepository(db).load()).single;
      final categories = await CategoryRepository(db).load();
      final sms = BankSms(
        sender: 'SBI',
        body: 'NACH debit awaiting category confirmation',
        receivedAt: at.add(const Duration(hours: 1)),
      );
      final result = PortableParseResult(
        classification: RuleClassification.completed,
        decision: SmsDecision.review,
        reason: 'completedNeedsReview',
        packVersion: 1,
        ruleId: 'test',
        candidate: SmsTransactionCandidate(
          amountMinor: 50000,
          direction: SmsDirection.debit,
          occurredAt: sms.receivedAt,
          currencyCode: 'INR',
          bankName: 'State Bank of India',
          accountLast4: '1234',
          countryCode: 'IN',
          counterparty: 'SBI NACH debit',
          category: const SmsSuggestedCategory(
            id: 'nach_debit',
            name: 'NACH debit',
            type: 'expense',
            ruleId: 'test',
          ),
        ),
      );
      await imports.enqueue(sms, result);
      final pending = (await imports.pending()).firstWhere(
        (r) => r.sender == 'SBI',
      );
      await review.put(
        pending,
        [account],
        categories,
        {pending.bankKey: account.id},
        null,
      );
      expect(
        (await review.page(filter: const SmsReviewFilter(ready: false)))
            .single
            .sms
            .id,
        pending.id,
      );
      final all = await review.browse(query(ready: null));
      expect(all.count, 122);
      expect(
        all.groups.any(
          (group) =>
              group.transactions.any((row) => row.title == 'SBI NACH debit'),
        ),
        isTrue,
      );
      expect((await review.browse(query())).count, 121);
      expect(
        (await review.browse(query(ready: false))).transactions.single.title,
        'SBI NACH debit',
      );
    },
  );

  test(
    'original date browser loads rows in batches and totals the full day',
    () async {
      final first = await review.browse(query(byCategory: false));
      expect(first.transactions, hasLength(50));
      expect(first.groups.single.count, 121);
      expect(first.groups.single.totals[('INR', 2)], (0, 1217260));
      expect(first.groups.single.date, DateTime(at.year, at.month, at.day));
      final second = await review.browse(query(byCategory: false, limit: 100));
      expect(second.transactions, hasLength(100));
      expect(
        second.transactions.take(50).map((t) => t.id),
        first.transactions.map((t) => t.id),
      );
    },
  );

  test(
    'bulk save consumes all pages, deletes scratch data and prevents reimport',
    () async {
      expect(await review.saveReady(), 121);
      expect(await review.count(), 0);
      expect(await db.customSelect('SELECT * FROM sms_review').get(), isEmpty);
      expect(await imports.pending(), isEmpty);
      expect(await TransactionRepository(db).load(), hasLength(121));
      final retained = await db
          .customSelect('SELECT body,candidate FROM sms_imports')
          .get();
      expect(
        retained.every((r) => r.readNullable<String>('body') == null),
        isTrue,
      );
      expect(
        retained.every(
          (r) => !(jsonDecode(r.read<String>('candidate')) as Map).containsKey(
            'amountMinor',
          ),
        ),
        isTrue,
      );
      await imports.enqueue(message(120), parsed(120));
      expect(await imports.pending(), isEmpty);
      expect(await review.saveReady(), 0);
    },
  );

  test(
    'a failed batch rolls back ledger writes and retains review data',
    () async {
      final last = (await review.page(offset: 120)).single;
      await db.customStatement(
        'UPDATE sms_review SET account_id=-1 WHERE fingerprint=?',
        [last.sms.id],
      );
      await expectLater(review.saveReady(), throwsStateError);
      expect(await TransactionRepository(db).load(), isEmpty);
      expect(await review.count(), 121);
      expect(await imports.pending(), hasLength(121));
    },
  );

  test(
    'dismissal cleans only consumed rows and keeps unfinished work',
    () async {
      final row = (await review.page()).first;
      await imports.dismiss(row.sms.id);
      await review.cleanReviewed();
      expect(await review.count(), 120);
      expect(
        await db.customSelect('SELECT * FROM sms_review').get(),
        hasLength(120),
      );
      expect(await TransactionRepository(db).load(), isEmpty);
    },
  );

  test(
    'v30 migration creates local review storage without losing pending SMS',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sms-review-migration',
      );
      final file = File('${directory.path}/database.sqlite');
      final old = AppDatabase(NativeDatabase(file));
      try {
        await SmsImportRepository(old).enqueue(message(0), parsed(0));
        await old.customStatement('DROP TABLE sms_review');
        await old.customStatement('PRAGMA user_version=30');
      } finally {
        await old.close();
      }
      final upgraded = AppDatabase(NativeDatabase(file));
      try {
        expect(await SmsImportRepository(upgraded).pending(), hasLength(1));
        expect(await SmsReviewRepository(upgraded).count(), 0);
        expect(
          (await upgraded.customSelect('PRAGMA user_version').getSingle())
              .read<int>('user_version'),
          upgraded.schemaVersion,
        );
      } finally {
        await upgraded.close();
        await directory.delete(recursive: true);
      }
    },
  );
}
