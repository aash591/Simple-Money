import 'package:simple_money/ui/sms/sms_scan_card.dart';
import 'package:simple_money/ui/sms/sms_suggestions.dart';

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:simple_money/ui/sms/sms_amount_style.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/data/backup/data_transfer.dart';
import 'package:simple_money/data/backup/sync_engine.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/loan_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/repositories/sms_review_repository.dart';
import 'package:simple_money/data/sms_inbox_platform.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/loan.dart';
import 'package:simple_money/state/account_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/loan_store.dart';
import 'package:simple_money/state/transaction_store.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:simple_money/ui/components/adaptive_sheet.dart';
import 'package:simple_money/ui/sms/sms_pending_card.dart';
import 'package:simple_money/ui/sms/sms_review_card.dart';
import 'package:simple_money/ui/sms/sms_review_flow.dart';

class FakeInbox extends SmsInboxPlatform {
  @override
  Future<void> setRealtimeEnabled(bool enabled) async {}
  bool granted = true;
  int reads = 0, requests = 0, pageSize = 2;
  Future<void> Function()? onRead;
  bool fail = false;
  List<InboxSms> rows = [];
  @override
  bool get supported => true;
  @override
  Future<bool> hasPermission() async => granted;
  @override
  Future<bool> requestPermission() async {
    requests++;
    return granted;
  }

  @override
  Future<List<InboxSms>> readPage({
    required int afterId,
    required int since,
  }) async {
    reads++;
    await onRead?.call();
    if (fail && afterId > 0) throw StateError('Read interrupted');
    return rows
        .where(
          (r) =>
              r.id > afterId &&
              r.sms.receivedAt.millisecondsSinceEpoch >= since,
        )
        .take(pageSize)
        .toList();
  }
}

void main() {
  late AppDatabase db;
  late SmsImportRepository repo;
  late PortableSmsEngine engine;
  late FakeInbox inbox;
  late SmsImportStore store;
  late int bank;
  late int savings;
  Future<void> tapAndReload(WidgetTester tester, Finder finder) async {
    await tester.runAsync(() async {
      final reloaded = Completer<void>();
      void listener() {
        if (!reloaded.isCompleted) reloaded.complete();
      }

      store.addListener(listener);
      try {
        await tester.tap(finder);
        await reloaded.future.timeout(const Duration(seconds: 15));
      } finally {
        store.removeListener(listener);
      }
    });
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    // SQLite workers use real time while animations use the test clock. Give
    // both clocks a turn until the action's final refresh has completed.
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 20)),
      );
      if (find.byType(LinearProgressIndicator).evaluate().isEmpty &&
          !tester.binding.hasScheduledFrame) {
        break;
      }
    }
    await tester.pumpAndSettle();
  }

  BankSms sms([int index = 0]) => BankSms(
    sender: 'ATMSBI',
    body: 'Rs.500 debited from A/c X1234 on 13Sep25. Avl Bal Rs.999999999',
    receivedAt: DateTime(2026, 10, 7, 12, index),
  );
  Future<void> enqueue([int index = 0]) =>
      repo.enqueue(sms(index), engine.parse(sms(index)));
  setUpAll(() {
    const c = RuleCompiler();
    engine = BankSmsParser(
      c.loadRuntime(
        jsonDecode(
          File(
            'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
          ).readAsStringSync(),
        ) as Map<String, dynamic>,
      ),
    );
  });
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    repo = SmsImportRepository(db);
    inbox = FakeInbox();
    // Scan mechanics are checked on the review queue; auto-import has its own
    // test.
    store = SmsImportStore(
      repo,
      platform: inbox,
      engineLoader: () async => engine,
      autoImport: false,
    );
    bank = await AccountRepository(db)
        .save(name: 'Bank', currency: 'INR', digits: 2, openingBalance: 100000);
    savings = await AccountRepository(db)
        .save(name: 'Savings', currency: 'INR', digits: 2, openingBalance: 0);
  });
  test('bank mappings persist and separate account suffixes', () async {
    await enqueue();
    final row = (await repo.pending()).single;
    await store.linkAccount(row, bank);
    expect((await SmsImportRepository(db).accountLinks())[row.bankKey], bank);
    final other = PendingSmsImport(
      id: 'other',
      sender: row.sender,
      body: row.body,
      receivedAt: row.receivedAt,
      data: {...row.data, 'accountLast4': '9999'},
    );
    expect(store.accountLinks[other.bankKey], isNull);
  });
  test(
    'current rules repair a pending candidate scanned by an older pack',
    () async {
      final message = BankSms(
        sender: 'AX-SBIUPI-S',
        body: 'Dear SBI User, your A/c X1234-credited by Rs.550 on 10Oct26 transfer from SAMPLE SENDER Ref No 123456789012 -SBI',
        receivedAt: DateTime(2026, 10, 10),
      );
      await repo.enqueue(
        message,
        PortableParseResult(
          classification: RuleClassification.completed,
          decision: SmsDecision.review,
          reason: 'completedNeedsReview',
          packVersion: 1,
          ruleId: 'old_fallback',
          candidate: SmsTransactionCandidate(
            amountMinor: 55000,
            currencyCode: 'INR',
            direction: SmsDirection.credit,
            occurredAt: message.receivedAt,
            bankName: 'State Bank of India',
            countryCode: 'IN',
            accountLast4: '1234',
          ),
        ),
      );

      await store.reload();

      expect(store.pending.single.title, 'SAMPLE SENDER');
      expect(store.pending.single.suggestedCategory?.name, 'Other Income');
    },
  );
  test('legacy pending retries show once and are consumed together', () async {
    await enqueue();
    final original = (await repo.pending()).single;
    await db.customStatement(
      'INSERT INTO sms_imports(fingerprint,sender,body,received_at,candidate,rule_id,pack_version) VALUES (?,?,?,?,?,?,?)',
      [
        'restored-retry',
        original.sender,
        original.body,
        original.receivedAt
            .add(const Duration(seconds: 24))
            .millisecondsSinceEpoch,
        jsonEncode(original.data),
        'test.retry',
        1,
      ],
    );
    expect(await repo.pending(), hasLength(2));
    await store.reload();
    expect(store.pending, hasLength(1));
    final row = store.pending.single;
    final category = (await CategoryRepository(
      db,
    ).load()).firstWhere((c) => c.type.name == 'expense');
    await repo.save(
      row,
      type: TransactionType.expense,
      amountMinor: row.amountMinor,
      accountId: bank,
      categoryId: category.id,
      date: row.receivedAt,
    );
    expect(await repo.pending(), isEmpty);
    expect(await TransactionRepository(db).load(), hasLength(1));
  });
  test(
    'identical SMS retries within 24 seconds stay deduplicated after save',
    () async {
      final first = sms();
      final retry = BankSms(
        sender: first.sender,
        body: first.body,
        receivedAt: first.receivedAt.add(const Duration(seconds: 24)),
      );
      await repo.enqueue(first, engine.parse(first));
      await repo.enqueue(retry, engine.parse(retry));
      expect(await repo.pending(), hasLength(1));
      final row = (await repo.pending()).single;
      final category = (await CategoryRepository(
        db,
      ).load()).firstWhere((c) => c.type.name == 'expense');
      await repo.save(
        row,
        type: TransactionType.expense,
        amountMinor: row.amountMinor,
        accountId: bank,
        categoryId: category.id,
        date: row.receivedAt,
      );
      await repo.enqueue(retry, engine.parse(retry));
      expect(await repo.pending(), isEmpty);
      expect(await TransactionRepository(db).load(), hasLength(1));
      final later = BankSms(
        sender: first.sender,
        body: first.body,
        receivedAt: first.receivedAt.add(const Duration(minutes: 1)),
      );
      await repo.enqueue(later, engine.parse(later));
      expect(await repo.pending(), hasLength(1));
      await repo.dismiss((await repo.pending()).single.id);
      final laterRetry = BankSms(
        sender: later.sender,
        body: later.body,
        receivedAt: later.receivedAt.add(const Duration(seconds: 24)),
      );
      await repo.enqueue(laterRetry, engine.parse(laterRetry));
      expect(await repo.pending(), isEmpty);
    },
  );

  test(
    'repayment cannot save as income and waits for both transfer accounts',
    () async {
      final cardId = await AccountRepository(db).save(
        name: 'Credit card',
        type: AccountType.creditCard,
        currency: 'INR',
        digits: 2,
        openingBalance: -200000,
      );
      final message = BankSms(
        sender: 'SBICRD',
        body: 'Your payment of Rs.1,644.55 has been credited to your SBI Credit Card ending with 5667. Your available limit is Rs.48,355.45.',
        receivedAt: DateTime(2026, 10, 12),
      );
      final parser = BankSmsParser(
        const RuleCompiler().loadRuntime(
          jsonDecode(
            File(
              'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
            ).readAsStringSync(),
          ) as Map<String, dynamic>,
        ),
      );
      await repo.enqueue(message, parser.parse(message));
      final pending = (await repo.pending()).single;
      expect(pending.isCreditCardRepayment, isTrue);
      final categories = await CategoryRepository(db).load();
      expect(smsCategory(pending, categories), isNull);
      await expectLater(
        repo.save(
          pending,
          type: TransactionType.income,
          amountMinor: pending.amountMinor,
          accountId: bank,
          date: message.receivedAt,
        ),
        throwsStateError,
      );
      expect((await repo.pending()), hasLength(1));
      expect(await TransactionRepository(db).load(), isEmpty);
      await repo.save(
        pending,
        type: TransactionType.transfer,
        amountMinor: pending.amountMinor,
        accountId: bank,
        toAccountId: cardId,
        date: message.receivedAt,
      );
      expect(
        (await TransactionRepository(db).load()).single.type,
        TransactionType.transfer,
      );
      expect(await repo.pending(), isEmpty);
      final balances = await AccountRepository(db).load();
      expect(balances.singleWhere((a) => a.id == cardId).balanceMinor, -35545);
      expect(balances.singleWhere((a) => a.id == bank).balanceMinor, -64455);
    },
  );
  test(
    'SMS balances keep the latest report after review and out-of-order scans',
    () async {
      await enqueue();
      final row = (await repo.pending()).single;
      await repo.recordBalance({
        ...row.data,
        'balanceMinor': 332837,
      }, row.receivedAt.add(const Duration(days: 1)));
      await repo.recordBalance({
        ...row.data,
        'balanceMinor': 55000,
      }, row.receivedAt.subtract(const Duration(days: 1)));
      await repo.dismiss(row.id);
      await store.reload();
      expect(store.smsBalances[row.bankKey], 332837);
      expect(store.pending, isEmpty);
      expect(
        (await SmsImportRepository(db).latestBalances())[row.bankKey],
        332837,
      );
    },
  );
  test('large backlog uses package categorization and excludes old reminders without deleting raw queue records', () async {
    await db.transaction(() async {
      for (var i = 0; i < 210; i++) {
        await enqueue(i);
      }
      final reminder = BankSms(
        sender: 'ONECRD',
        body: 'Your bill has been generated. Pay your bill of Rs.500 at the earliest. Please ignore if already paid. - OneCard',
        receivedAt: DateTime(2026, 10, 12),
      );
      await repo.enqueue(
        reminder,
        PortableParseResult(
          classification: RuleClassification.completed,
          decision: SmsDecision.review,
          reason: 'completedNeedsReview',
          packVersion: 1,
          ruleId: 'old_format',
          candidate: SmsTransactionCandidate(
            amountMinor: 50000,
            direction: SmsDirection.debit,
            occurredAt: reminder.receivedAt,
            currencyCode: 'INR',
            bankName: 'OneCard',
            countryCode: 'IN',
          ),
        ),
      );
    });
    final full = BankSmsParser(
      const RuleCompiler().mergeRuntimePacks([
        for (final bank in ['sbi', 'onecard'])
          const RuleCompiler().loadRuntime(
            jsonDecode(
              File(
                'packages/universal_bank_sms_parser/distribution/packs/india/$bank.json',
              ).readAsStringSync(),
            ) as Map<String, dynamic>,
          ),
      ]),
    );
    final queue = SmsImportStore(
      repo,
      platform: inbox,
      engineLoader: () async => full,
    );
    try {
      await queue.reload();
      expect(queue.pendingCount, 210);
      expect(queue.pending, hasLength(50));
      expect(
        queue.pending.every((row) => row.suggestedCategory?.id == 'personal'),
        isTrue,
      );
      expect(await repo.pending(), hasLength(211));
      final revision = queue.reviewRevision;
      await db.customStatement('''CREATE TRIGGER keep_review_index
        BEFORE INSERT ON sms_review
        BEGIN SELECT RAISE(ABORT, 'Unexpected review rebuild'); END''');
      await queue.reload();
      expect(queue.reviewRevision, revision);
      expect(queue.pendingCount, 210);
      await db.customStatement('DROP TRIGGER keep_review_index');
    } finally {
      queue.dispose();
    }
  });
  test(
    'review index survives reopening and invalidates matching changes only',
    () async {
      await enqueue();
      await store.reload();
      final sms = store.pending.single;
      await repo.linkAccount(sms, bank);
      await store.reload();
      expect(store.readyCount, 1);
      final revision = store.reviewRevision;
      await db.customStatement(
        'UPDATE accounts SET balance_minor=balance_minor+1',
      );
      await store.reload();
      expect(store.reviewRevision, revision);
      final reopened = SmsImportStore(
        repo,
        platform: inbox,
        engineLoader: () async => engine,
        autoImport: false,
      );
      addTearDown(reopened.dispose);
      await db.customStatement('''CREATE TRIGGER keep_reopened_index
      BEFORE INSERT ON sms_review
      BEGIN SELECT RAISE(ABORT, 'Unexpected review rebuild'); END''');
      await reopened.reload();
      await db.customStatement('DROP TRIGGER keep_reopened_index');
      expect(reopened.pendingCount, 1);
      expect(reopened.readyCount, 1);
      await db.customStatement(
        "UPDATE accounts SET name='Renamed bank' WHERE id=$bank",
      );
      await store.reload();
      expect(store.reviewRevision, greaterThan(revision));
      expect(
        await store.review.count(const SmsReviewFilter(search: 'Renamed bank')),
        1,
      );
      await db.customStatement(
        'UPDATE accounts SET archived_at=1 WHERE id=$bank',
      );
      await store.reload();
      expect(store.readyCount, 0);
    },
  );

  test('merchant suggestions use existing expense categories', () async {
    await enqueue();
    final row = (await repo.pending()).single;
    final categories = await CategoryRepository(db).load();
    for (final item in [
      ('NETFLIX', 'Subscriptions'),
      ('Corner STORE', 'Groceries'),
      ('PETROL PUMP STORE', 'Fuel'),
    ]) {
      final candidate = PendingSmsImport(
        id: row.id,
        sender: row.sender,
        body: row.body,
        receivedAt: row.receivedAt,
        data: {
          ...row.data,
          ...PortableParseResult(
                classification: RuleClassification.completed,
                decision: SmsDecision.review,
                reason: 'completedNeedsReview',
                packVersion: 1,
                candidate: engine.enrichCandidate(
                  BankSms(
                    sender: row.sender,
                    body: row.body,
                    receivedAt: row.receivedAt,
                  ),
                  SmsTransactionCandidate.fromJson({
                    ...row.data,
                    'counterparty': item.$1,
                  }),
                ),
              ).toJson()['candidate']
              as Map,
        },
      );
      expect(smsCategory(candidate, categories)?.name, item.$2);
    }
  });
  test(
    'latest available credit limit survives review and out-of-order scans',
    () async {
      final card = BankSms(
        sender: 'SBICRD',
        body: 'SBI Credit Card XX1234 used for INR 500 at SHOP. Available limit INR 9500.',
        receivedAt: sms().receivedAt,
      );
      await repo.enqueue(card, engine.parse(card));
      final row = (await repo.pending()).single;
      expect(row.availableCreditLimitMinor, 950000);
      await repo.recordBalance({
        ...row.data,
        'availableCreditLimitMinor': 0,
      }, card.receivedAt.add(const Duration(days: 1)));
      await repo.recordBalance({
        ...row.data,
        'availableCreditLimitMinor': 990000,
      }, card.receivedAt.subtract(const Duration(days: 1)));
      await repo.dismiss(row.id);
      await store.reload();
      expect(store.smsCreditLimits[row.bankKey], 0);
      expect(store.smsBalances[row.bankKey], isNull);
      expect(
        (await SmsImportRepository(db).latestCreditLimits())[row.bankKey],
        0,
      );
    },
  );
  test(
    'scan records limit-only messages without creating transactions',
    () async {
      final date = sms().receivedAt;
      inbox.rows = [
        InboxSms(
          1,
          BankSms(
            sender: 'SBICRD',
            body: 'SBI Credit Card XX1234 used for INR 500 at SHOP. Available limit INR 9500.',
            receivedAt: date,
          ),
        ),
        InboxSms(
          2,
          BankSms(
            sender: 'SBICRD',
            body: 'SBI Credit Card XX1234 available limit Rs.9000.',
            receivedAt: date.add(const Duration(days: 1)),
          ),
        ),
      ];
      await store.enable();
      expect(store.pending, hasLength(1));
      expect(store.smsCreditLimits[store.pending.single.bankKey], 900000);
    },
  );
  test(
    'card spending stays orange after import and card credits are green',
    () async {
      final cardSms = BankSms(
        sender: 'SBICRD',
        body: 'SBI Credit Card XX1234 used for INR 123.45 at SHOP on 11/10/26.',
        receivedAt: DateTime(2026, 10, 11),
      );
      await repo.enqueue(cardSms, engine.parse(cardSms));
      final row = (await repo.pending()).single;
      expect(row.creditCard, isTrue);
      expect(smsAmountColor(row), Colors.orange);
      final category = (await CategoryRepository(
        db,
      ).load()).firstWhere((c) => c.name == 'Groceries');
      await repo.save(
        row,
        type: TransactionType.expense,
        amountMinor: row.amountMinor,
        accountId: bank,
        categoryId: category.id,
        date: row.receivedAt,
      );
      expect(
        (await TransactionRepository(db).load()).single.isCreditCard,
        isTrue,
      );
      final repayment = BankSms(
        sender: 'SBICRD',
        body: 'Your payment of Rs.1,644.55 has been credited to your SBI Credit Card ending with 5667. Your available limit is Rs.48,355.45.',
        receivedAt: DateTime(2026, 10, 12),
      );
      await repo.enqueue(repayment, engine.parse(repayment));
      final credit = (await repo.pending()).single;
      expect(credit.credit, isTrue);
      expect(smsAmountColor(credit), green);
      await enqueue();
      final debit = (await repo.pending()).firstWhere((r) => !r.creditCard);
      expect(smsAmountColor(debit), Colors.red);
      expect(row.bankKey, isNot(debit.bankKey));
    },
  );
  test('scan includes latest balance-only SMS without importing it as a transaction', () async {
    inbox.rows = [
      InboxSms(1, sms()),
      InboxSms(
        2,
        BankSms(
          sender: 'ATMSBI',
          body: 'Your A/c XX1234 current balance: INR 3,328.37.',
          receivedAt: sms().receivedAt.add(const Duration(days: 1)),
        ),
      ),
    ];
    await store.enable();
    expect(store.pending, hasLength(1));
    expect(store.smsBalances[store.pending.single.bankKey], 332837);
  });
  test('link a bank, choose a category, then save all', () async {
    await enqueue();
    await store.reload();
    final sms = store.pending.single;
    await store.linkAccount(sms, savings);
    expect(store.accountLinks[sms.bankKey], savings);
    final groceries = (await CategoryRepository(
      db,
    ).load()).firstWhere((c) => c.name == 'Groceries');
    await store.selectCategory(store.pending.single, groceries.id);
    expect(await TransactionRepository(db).load(), isEmpty);
    expect(await store.saveReady(), 1);
    await store.reload();
    expect(store.pending, isEmpty);
    final saved = (await TransactionRepository(db).load()).single;
    expect(saved.accountId, savings);
    expect(saved.categoryId, groceries.id);
  });
  testWidgets('with SMS off and nothing to review, Home shows no card', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SmsPendingCard(store: store, onReview: (_) {}),
          ),
        ),
      ),
    );
    expect(find.byType(SmsScanCard), findsNothing);
    expect(inbox.requests, 0);
    // A refused permission leaves it off, so the card stays away.
    inbox.granted = false;
    await tester.runAsync(store.enable);
    await tester.pumpAndSettle();
    expect(inbox.requests, 1);
    expect(inbox.reads, 0);
    expect(find.byType(SmsScanCard), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('successful scan stays home until review is tapped', (
    tester,
  ) async {
    inbox.rows = [InboxSms(1, sms())];
    final card = SmsPendingCard(store: store, onReview: (_) {});
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: card)));
    final context = tester.element(find.byType(SmsPendingCard));
    await tester.runAsync(() => card.open(context, scan: true));
    await tester.pumpAndSettle();
    expect(inbox.requests, 1);
    expect(inbox.reads, greaterThan(0));
    expect(find.byType(SmsPendingPage), findsNothing);
    expect(find.text("Review 1"), findsOneWidget);
    await tester.tap(find.text("Review 1"));
    await tester.pumpAndSettle();
    expect(find.byType(SmsPendingPage), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('scan illustration displays real counters without a spinner', (
    tester,
  ) async {
    store.scanning = true;
    store.busy = true;
    store.scannedMessages = 230;
    store.foundTransactions = 200;
    store.foundAccounts.addAll(['a', 'b', 'c']);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SmsScanCard(store: store, onScan: () {}),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('200'), findsOneWidget);
    expect(find.text('3'), findsOneWidget);
    expect(find.text('230 messages checked'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('SMS card keeps one height through every state', (tester) async {
    Future<double> height({VoidCallback? onReview, int unlinked = 0}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                child: SmsScanCard(
                  store: store,
                  onScan: () {},
                  onReview: onReview,
                  unlinked: unlinked,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester.getSize(find.byType(SmsScanCard)).height;
    }

    final intro = await height();
    store.scanning = true;
    store.scannedMessages = 1200;
    final reading = await height();
    store.importing = true;
    final saving = await height();
    store
      ..scanning = false
      ..importing = false
      ..pendingCount = 8
      ..lastScan = const SmsScanSummary(accountsAdded: 1, saved: 5);
    final attention = await height(onReview: () {}, unlinked: 2);
    store.pendingCount = 0;
    final done = await height(onReview: () {});
    store.error = 'SMS access was not granted. Tap Scan messages to try again.';
    final failed = await height(onReview: () {});
    expect(find.text(SmsScanCard.title), findsOneWidget);
    expect([reading, saving, attention, done, failed], everyElement(intro));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  tearDown(() async {
    store.dispose();
    await db.close();
  });
  test(
    'v20 migration preserves ledger and starts SMS access disabled',
    () async {
      final dir = await Directory.systemTemp.createTemp('sms_migration_');
      final file = File('${dir.path}/ledger.sqlite');
      var disk = AppDatabase(NativeDatabase(file), false);
      try {
        await AccountRepository(disk).save(
          name: 'Existing',
          currency: 'INR',
          digits: 2,
          openingBalance: 12345,
        );
        await disk.customStatement('DROP TABLE sms_imports');
        await disk.customStatement('DROP TABLE sms_import_state');
        await disk.customStatement('PRAGMA user_version=20');
        await disk.close();
        disk = AppDatabase(NativeDatabase(file), false);
        expect(
          (await AccountRepository(disk).load()).single.balanceMinor,
          12345,
        );
        final migrated = SmsImportRepository(disk);
        expect(await migrated.state(), (false, 0));
        expect(await migrated.pending(), isEmpty);
      } finally {
        await disk.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'SMS stays out of exports and device erase clears queue and consent',
    () async {
      await enqueue();
      await repo.enable(true);
      await repo.checkpoint(123);
      await repo.recordBalance({
        'bankName': 'SBI',
        'countryCode': 'IN',
        'currencyCode': 'INR',
        'accountLast4': '1234',
        'isCreditCard': true,
        'availableCreditLimitMinor': 500000,
      }, sms().receivedAt);
      await repo.stagePage([InboxSms(1, sms())]);
      final exported = utf8.decode(await exportLedger(db));
      expect(exported, isNot(contains('sms_scan_queue')));
      expect(exported, isNot(contains('sms_imports')));
      expect(exported, isNot(contains(sms().body)));
      await SyncEngine(
        SyncRepository(db),
        openTransport: (_) => throw StateError('No network'),
      ).eraseDevice();
      await store.reload();
      expect(store.pending, isEmpty);
      expect(store.enabled, isFalse);
      expect(store.smsCreditLimits, isEmpty);
      expect(await repo.stagedPage(), isEmpty);
      expect(await repo.state(), (false, 0));
    },
  );
  test(
    'v23 migration adds credit limits without losing pending messages',
    () async {
      final dir = await Directory.systemTemp.createTemp('sms_limit_migration_');
      final file = File('${dir.path}/ledger.sqlite');
      var disk = AppDatabase(NativeDatabase(file), false);
      try {
        final oldRepo = SmsImportRepository(disk);
        await oldRepo.enqueue(sms(), engine.parse(sms()));
        await oldRepo.enable(true);
        await oldRepo.checkpoint(123);
        await disk.customStatement('DROP TABLE sms_credit_limits');
        await disk.customStatement('PRAGMA user_version=23');
        await disk.close();
        disk = AppDatabase(NativeDatabase(file), false);
        final migrated = SmsImportRepository(disk);
        expect(await migrated.state(), (true, 123));
        expect(await migrated.pending(), hasLength(1));
        expect(await migrated.latestCreditLimits(), isEmpty);
      } finally {
        await disk.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test('bundled Indian packs load and match offline', () async {
    final bundled = await loadBundledSmsEngine();
    expect(bundled.parse(sms()).candidate!.amountMinor, 50000);
  });
  test(
    'deduplicates rescans and remembers dismissed messages after restart',
    () async {
      await enqueue();
      await enqueue();
      expect(await repo.pending(), hasLength(1));
      await repo.dismiss((await repo.pending()).single.id);
      await enqueue();
      expect(await SmsImportRepository(db).pending(), isEmpty);
      final row = await db
          .customSelect('SELECT body,status FROM sms_imports')
          .getSingle();
      expect(row.readNullable<String>('body'), isNull);
      expect(row.read<String>('status'), 'dismissed');
    },
  );
  test(
    'save updates the ledger and consumes message atomically exactly once',
    () async {
      await enqueue();
      final pending = (await repo.pending()).single;
      final category = (await CategoryRepository(
        db,
      ).load()).firstWhere((c) => c.type.name == 'expense');
      Future<void> save() => repo.save(
        pending,
        type: TransactionType.expense,
        amountMinor: 50000,
        accountId: bank,
        categoryId: category.id,
        title: 'Reviewed title',
        date: pending.receivedAt,
      );
      await save();
      await expectLater(save(), throwsStateError);
      await enqueue();
      expect(await repo.pending(), isEmpty);
      final ledger = await TransactionRepository(db).load();
      expect(ledger, hasLength(1));
      expect(ledger.single.title, 'Reviewed title');
      expect(
        ledger.single.note,
        'Sender: ${pending.sender}\n\n${pending.body}',
      );
      expect((await AccountRepository(db).load()).first.balanceMinor, 50000);
    },
  );
  test(
    'invalid account currency leaves queue and balances untouched',
    () async {
      await AccountRepository(
        db,
      ).save(name: 'USD', currency: 'USD', digits: 2, openingBalance: 100000);
      await enqueue();
      final item = (await repo.pending()).single;
      final category = (await CategoryRepository(
        db,
      ).load()).firstWhere((c) => c.type.name == 'expense');
      await expectLater(
        repo.save(
          item,
          type: TransactionType.expense,
          amountMinor: 50000,
          accountId: 3,
          categoryId: category.id,
          date: item.receivedAt,
        ),
        throwsStateError,
      );
      expect(await repo.pending(), hasLength(1));
      expect(await TransactionRepository(db).load(), isEmpty);
    },
  );
  test('transfer changes both balances without creating expense', () async {
    await enqueue();
    final item = (await repo.pending()).single;
    await repo.save(
      item,
      type: TransactionType.transfer,
      amountMinor: item.amountMinor,
      accountId: bank,
      toAccountId: savings,
      date: item.receivedAt,
    );
    expect(await repo.pending(), isEmpty);
    final accounts = await AccountRepository(db).load();
    expect(accounts[0].balanceMinor, 50000);
    expect(accounts[1].balanceMinor, 50000);
    expect(
      (await TransactionRepository(db).load()).single.note,
      'Sender: ${item.sender}\n\n${item.body}',
    );
    expect(
      (await TransactionRepository(db).load()).single.type,
      TransactionType.transfer,
    );
  });
  test('permission denied never reads or enables inbox', () async {
    inbox.granted = false;
    await store.initialize();
    expect(inbox.requests, 0);
    await store.enable();
    expect(inbox.reads, 0);
    expect(store.enabled, isFalse);
    expect((await repo.state()).$1, isFalse);
  });
  test(
    'pages all messages, ignores OTP, and deduplicates full rescan',
    () async {
      inbox.rows = [
        InboxSms(1, sms()),
        InboxSms(2, sms(1)),
        InboxSms(
          3,
          BankSms(
            sender: 'ATMSBI',
            body: 'OTP 123456. Do not share.',
            receivedAt: sms().receivedAt,
          ),
        ),
      ];
      await store.enable();
      expect(store.pending, hasLength(2));
      expect(inbox.reads, 3);
      await store.scan(full: true);
      expect(store.pending, hasLength(2));
      expect((await repo.state()).$2, greaterThan(0));
    },
  );
  test(
    'scan account count matches resolved review groups across pages',
    () async {
      final withoutSuffix = BankSms(
        sender: 'ATMSBI',
        body: 'Rs.500 debited from your account on 13Sep25. Avl Bal Rs.1000',
        receivedAt: sms().receivedAt,
      );
      expect(engine.parse(withoutSuffix).candidate, isNotNull);
      inbox.pageSize = 1;
      inbox.rows = [InboxSms(1, withoutSuffix), InboxSms(2, sms(1))];
      final counts = <int>[];
      inbox.onRead = () async {
        if (store.scannedMessages > 0) {
          final resolved = await repo.detectedAccounts();
          expect(
            store.foundAccounts,
            resolved.map((sms) => sms.bankKey).toSet(),
          );
          counts.add(store.foundAccounts.length);
        }
      };
      await store.enable();
      expect(store.error, isNull);
      expect(store.pending, hasLength(2));
      // The unnumbered message is SBI's account by name, then the same
      // account once its number is seen: one account on both pages.
      expect(counts, [1, 1]);
      expect(store.pending.map((sms) => sms.accountLast4), ['1234', '1234']);
      expect(store.detectedAccounts.single.accountLast4, '1234');
      expect(store.foundAccounts.length, store.detectedAccounts.length);
    },
  );
  test('large scan stages bounded pages and only publishes review rows at completion', () async {
    inbox.pageSize = 200;
    inbox.rows = [for (var i = 0; i < 2201; i++) InboxSms(i + 1, sms(i))];
    await db.customStatement("""
      CREATE TRIGGER bounded_sms_stage AFTER INSERT ON sms_scan_queue
      WHEN (SELECT COUNT(*) FROM sms_scan_queue) > 200
      BEGIN SELECT RAISE(ABORT, 'Unbounded scan queue'); END
    """);
    inbox.onRead = () async {
      expect(await repo.stagedPage(), isEmpty);
      expect(store.pending, isEmpty);
    };
    await store.enable();
    expect(store.error, isNull);
    expect(store.scannedMessages, 2201);
    expect(store.foundTransactions, 2201);
    expect(store.pendingCount, 2201);
    expect(store.pending, hasLength(50));
    expect(inbox.reads, 13);
    expect(await repo.stagedPage(), isEmpty);
    inbox.onRead = null;
    await store.scan(full: true);
    expect(store.error, isNull);
    expect(store.pendingCount, 2201);
    expect(store.pending, hasLength(50));
  });
  test(
    'failed page rolls back parsed rows, clears scratch SMS, and can retry',
    () async {
      inbox.rows = [InboxSms(1, sms()), InboxSms(2, sms(1))];
      await db.customStatement("""
      CREATE TRIGGER fail_sms_page BEFORE INSERT ON sms_imports
      WHEN NEW.received_at = ${sms(1).receivedAt.millisecondsSinceEpoch}
      BEGIN SELECT RAISE(ABORT, 'Injected failure'); END
    """);
      await store.enable();
      expect(store.error, isNotNull);
      expect(store.pending, isEmpty);
      expect(store.scannedMessages, 0);
      expect((await repo.state()).$2, 0);
      expect(await repo.stagedPage(), isEmpty);
      await db.customStatement('DROP TRIGGER fail_sms_page');
      await store.scan();
      expect(store.error, isNull);
      expect(store.pending, hasLength(2));
    },
  );
  test(
    'v29 upgrade adds scratch storage without losing pending reviews',
    () async {
      final dir = await Directory.systemTemp.createTemp('sms_stage_migration_');
      final file = File('${dir.path}/ledger.sqlite');
      var disk = AppDatabase(NativeDatabase(file), false);
      try {
        await SmsImportRepository(disk).enqueue(sms(), engine.parse(sms()));
        await disk.customStatement('DROP TABLE sms_scan_queue');
        await disk.customStatement('PRAGMA user_version=29');
        await disk.close();
        disk = AppDatabase(NativeDatabase(file), false);
        final migrated = SmsImportRepository(disk);
        expect(await migrated.pending(), hasLength(1));
        await migrated.stagePage([InboxSms(1, sms())]);
        expect(await migrated.stagedPage(), hasLength(1));
      } finally {
        await disk.close();
        await dir.delete(recursive: true);
      }
    },
  );
  test(
    'completed scans skip automatic resume but manual scans still run',
    () async {
      await store.enable();
      final reads = inbox.reads;
      await store.scan(automatic: true);
      expect(inbox.reads, reads);
      await store.scan(full: true);
      expect(inbox.reads, greaterThan(reads));
    },
  );
  test('reopening restores pending review without scanning again', () async {
    inbox.rows = [InboxSms(1, sms())];
    await store.enable();
    // An old checkpoint must still suppress scanning, not just throttle it.
    await repo.checkpoint(DateTime(2025).millisecondsSinceEpoch);
    final reads = inbox.reads;
    final reopened = SmsImportStore(
      repo,
      platform: inbox,
      engineLoader: () async => engine,
      autoImport: false,
    );
    addTearDown(reopened.dispose);
    final scanningStates = <bool>[];
    reopened.addListener(() => scanningStates.add(reopened.scanning));
    await reopened.initialize();
    await reopened.scan(automatic: true);
    expect(inbox.reads, reads);
    expect(reopened.pendingCount, 1);
    expect(scanningStates, isNot(contains(true)));
    await reopened.scan(full: true);
    expect(inbox.reads, greaterThan(reads));
    expect(reopened.pendingCount, 1);
  });

  test('completed empty scans do not restart when reopening', () async {
    await store.enable();
    final reads = inbox.reads;
    final reopened = SmsImportStore(
      repo,
      platform: inbox,
      engineLoader: () async => engine,
      autoImport: false,
    );
    addTearDown(reopened.dispose);
    await reopened.initialize();
    await reopened.scan(automatic: true);
    expect(inbox.reads, reads);
    expect(reopened.pendingCount, 0);
  });

  test('reopening can recover an interrupted first scan', () async {
    inbox.rows = [InboxSms(1, sms()), InboxSms(2, sms(1)), InboxSms(3, sms(2))];
    inbox.fail = true;
    await store.enable();
    expect((await repo.state()).$2, 0);
    inbox.fail = false;
    final reopened = SmsImportStore(
      repo,
      platform: inbox,
      engineLoader: () async => engine,
      autoImport: false,
    );
    addTearDown(reopened.dispose);
    await reopened.initialize();
    expect(reopened.pendingCount, 3);
    expect((await repo.state()).$2, greaterThan(0));
    expect(reopened.error, isNull);
  });

  test(
    'interrupted scans keep checkpoint and can recover without duplicates',
    () async {
      inbox.rows = [
        InboxSms(1, sms()),
        InboxSms(2, sms(1)),
        InboxSms(3, sms(2)),
      ];
      inbox.fail = true;
      await store.enable();
      expect((await repo.state()).$2, 0);
      expect(store.pending, hasLength(2));
      expect(store.error, isNotNull);
      inbox.fail = false;
      await store.scan();
      expect(store.pending, hasLength(3));
      expect(store.error, isNull);
      await store.disable();
      final reads = inbox.reads;
      await store.scan();
      expect(inbox.reads, reads);
    },
  );
  test(
    'a scan adds numbered accounts and saves, leaving unnumbered banks',
    () async {
      final auto = SmsImportStore(
        repo,
        platform: inbox,
        engineLoader: () async => engine,
      );
      addTearDown(auto.dispose);
      var ledgerChanged = 0;
      auto.onLedgerChanged = () => ledgerChanged++;
      inbox.rows = [InboxSms(1, sms(0)), InboxSms(2, sms(1))];
      await auto.enable();
      expect(auto.error, isNull);
      expect(auto.lastScan!.accountsAdded, 1);
      expect(auto.lastScan!.saved, 2);
      expect(auto.pendingCount, 0);
      expect(ledgerChanged, 1);
      final account = (await AccountRepository(
        db,
      ).load()).singleWhere((a) => a.lastDigits == '1234');
      // Named after the bank; the number is kept apart.
      expect(account.name, account.institution);
      expect(await TransactionRepository(db).load(), hasLength(2));
    },
  );
  test('a bank seen only without a number waits to be linked', () async {
    final auto = SmsImportStore(
      repo,
      platform: inbox,
      engineLoader: () async => engine,
    );
    addTearDown(auto.dispose);
    inbox.rows = [
      InboxSms(
        1,
        BankSms(
          sender: 'ATMSBI',
          body: 'Rs.500 debited from your account on 13Sep25. Avl Bal Rs.1000',
          receivedAt: sms().receivedAt,
        ),
      ),
    ];
    await auto.enable();
    expect(auto.lastScan!.accountsAdded, 0);
    expect(auto.lastScan!.saved, 0);
    expect(auto.pendingCount, 1);
    expect(auto.detectedAccounts.single.accountLast4, isNull);
    expect(await TransactionRepository(db).load(), isEmpty);
  });
  testWidgets('Home card shows only what needs attention', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (var i = 0; i < 8; i++) {
      await enqueue(i);
    }
    await tester.runAsync(store.reload);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: SmsPendingCard(store: store, onReview: (_) {}),
          ),
        ),
      ),
    );
    // A few of the waiting messages are listed, under what they need.
    expect(
      find.byType(SmsCompactTile),
      findsNWidgets(SmsReviewCard.previewRows),
    );
    expect(find.text('8 bank messages need a category'), findsOneWidget);
    await tester.tap(find.text('Review 8'));
    await tester.pumpAndSettle();
    expect(find.text('Bank SMS to categorize'), findsOneWidget);
    expect(find.byType(SmsPendingTile), findsNWidgets(8));
    await tester.pumpWidget(const SizedBox());
  });
  Future<(AccountStore, CategoryStore, TransactionStore)> stores() async {
    final a = AccountStore(AccountRepository(db));
    final c = CategoryStore(CategoryRepository(db));
    final t = TransactionStore(TransactionRepository(db), a);
    await a.load();
    await c.load();
    await t.load();
    return (a, c, t);
  }

  group('A bank SMS paid to a loan', () {
    /// Picks [loanName] for the waiting message, then saves it.
    Future<void> saveAsLoan(
      WidgetTester tester,
      int principal,
      String loanName,
    ) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> settle() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 60)),
        );
        await tester.pumpAndSettle();
      }

      late final PendingSmsImport row;
      late final (AccountStore, CategoryStore, TransactionStore) all;
      late final LoanStore loans;
      await tester.runAsync(() async {
        await enqueue();
        row = (await repo.pending()).single;
        await store.linkAccount(row, bank);
        await LoanRepository(db).add(
          LoanTerms(
            lender: loanName,
            kind: LoanKind.other,
            icon: 'bank',
            principal: principal,
            openingBalance: principal,
            startDate: DateTime(2020),
            snapshotDate: DateTime(2020),
            rate: 0,
            months: 12,
            emi: 5000,
            paidBefore: 0,
            firstDue: DateTime(2020, 2),
            day: 1,
            currency: 'INR',
            digits: 2,
          ),
          bank,
        );
        all = await stores();
        loans = LoanStore(
          LoanRepository(db),
          accountStore: all.$1,
          categoryStore: all.$2,
          transactionStore: all.$3,
        );
        await loans.load();
      });
      addTearDown(loans.dispose);
      addTearDown(all.$3.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: LoanStoreScope(
            store: loans,
            child: Scaffold(
              body: SmsReviewFlow(
                sms: row,
                store: store,
                accounts: all.$1,
                categories: all.$2,
                transactions: all.$3,
              ),
            ),
          ),
        ),
      );
      await settle();
      await tester.tap(find.text('Category'));
      await settle();
      await tester.tap(find.text('Loan repayment'));
      await settle();
      expect(find.text('Which loan?'), findsOneWidget);
      await tester.tap(find.text(loanName));
      await settle();
      // The category row now names the loan.
      expect(find.text(loanName), findsOneWidget);
      await tester.tap(find.text('Save'));
      await settle();
    }

    testWidgets('becomes its next payment, recorded once', (tester) async {
      late int before;
      await tester.runAsync(
        () async =>
            before = (await AccountRepository(db).load()).first.balanceMinor,
      );
      await saveAsLoan(tester, 500000, 'Bajaj Finance');
      await tester.runAsync(() async {
        final loan = (await LoanRepository(db).load()).single;
        expect(loan.paid, 1);
        expect(loan.outstanding, 450000);
        expect(
          (await db.customSelect('SELECT * FROM transactions').get()).length,
          1,
        );
        expect(
          (await AccountRepository(db).load()).first.balanceMinor,
          before - 50000,
        );
        expect(await repo.pending(), isEmpty);
      });
    });

    testWidgets('a payment the loan refuses saves nothing', (tester) async {
      await saveAsLoan(tester, 10000, 'Small loan');
      expect(find.textContaining('cannot exceed'), findsOneWidget);
      await tester.runAsync(() async {
        expect((await LoanRepository(db).load()).single.events, isEmpty);
        expect(
          await db.customSelect('SELECT * FROM transactions').get(),
          isEmpty,
        );
        expect((await repo.pending()).length, 1);
      });
    });
  });

  testWidgets('ATM withdrawal suggests cash and records a transfer', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final cashId = await AccountRepository(db).save(
      name: 'Cash wallet',
      type: AccountType.cash,
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
    );
    final message = BankSms(
      sender: 'AD-ATMSBI-S',
      body: 'Dear SBI Customer, Rs.500.00 withdrawn at SAMPLE ATM from A/cXX1234 on 08Oct26 Transaction number 123456. Available balance Rs.5000.00.',
      receivedAt: DateTime(2026, 10, 8),
    );
    await repo.enqueue(message, engine.parse(message));
    final row = (await repo.pending()).single;
    expect(row.isAtmWithdrawal, isTrue);
    await tester.runAsync(() => store.linkAccount(row, bank));
    final (a, c, t) = await stores();
    addTearDown(a.dispose);
    addTearDown(c.dispose);
    addTearDown(t.dispose);
    expect(smsCashAccount(row, a.accounts)?.id, cashId);
    expect(smsCategory(row, c.categories), isNull);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SmsReviewFlow(
            sms: row,
            store: store,
            accounts: a,
            categories: c,
            transactions: t,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Cash wallet'), findsOneWidget);
    expect(
      find.text(
        'ATM withdrawal. Transfer from the withdrawal account to your cash account.',
      ),
      findsOneWidget,
    );
    expect(find.text('Save'), findsOneWidget);
    await expectLater(
      repo.save(
        row,
        type: TransactionType.expense,
        amountMinor: 50000,
        accountId: bank,
        date: message.receivedAt,
      ),
      throwsStateError,
    );
    await expectLater(
      repo.save(
        row,
        type: TransactionType.transfer,
        amountMinor: 50000,
        accountId: bank,
        toAccountId: savings,
        date: message.receivedAt,
      ),
      throwsStateError,
    );
    await repo.save(
      row,
      type: TransactionType.transfer,
      amountMinor: 50000,
      accountId: bank,
      toAccountId: cashId,
      date: message.receivedAt,
    );
    final saved = (await TransactionRepository(db).load()).single;
    expect(saved.type, TransactionType.transfer);
    expect(saved.toAccountId, cashId);
    final accounts = await AccountRepository(db).load();
    expect(accounts.singleWhere((a) => a.id == bank).balanceMinor, 50000);
    expect(accounts.singleWhere((a) => a.id == cashId).balanceMinor, 50000);
    expect(
      smsCashAccount(row, [
        ...accounts,
        Account(
          id: 999,
          name: 'Second cash',
          type: AccountType.cash,
          currency: 'INR',
          digits: 2,
          balanceMinor: 0,
        ),
      ]),
      isNull,
    );
    await tester.pumpWidget(const SizedBox());
  });

  for (final transfer in [false, true]) {
    testWidgets(
      'SMS selects ${transfer ? 'transfer' : 'category'} and saves directly',
      (tester) async {
        tester.view.physicalSize = const Size(1080, 2400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await enqueue();
        await tester.runAsync(store.reload);
        final (a, c, t) = await stores();
        addTearDown(a.dispose);
        addTearDown(c.dispose);
        addTearDown(t.dispose);
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showAdaptiveSheet<void>(
                    context,
                    builder: (_) => SmsReviewFlow(
                      sms: store.pending.single,
                      store: store,
                      accounts: a,
                      categories: c,
                      transactions: t,
                    ),
                  ),
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('Is the payment completed?'), findsNothing);
        expect(find.text('SMS preview'), findsOneWidget);
        if (transfer) {
          await tester.tap(find.text('Transfer'));
          await tester.pumpAndSettle();
        } else {
          await tester.tap(find.text('Personal'));
          await tester.pumpAndSettle();
          final category = c.categories.firstWhere(
            (c) => c.type.name == 'expense',
          );
          await tester.tap(find.text(category.name).last);
          await tester.pumpAndSettle();
          // Like Add transaction, a top-level category opens its subcategories.
          final only = find.text('Use ${category.name} only');
          if (only.evaluate().isNotEmpty) {
            await tester.tap(only);
            await tester.pumpAndSettle();
          }
        }
        await tester.tap(find.text('Choose INR account').first);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Bank').last);
        await tester.pumpAndSettle();
        if (transfer) {
          await tester.tap(find.text('Choose INR account'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('Savings').last);
          await tester.pumpAndSettle();
        }
        await tapAndReload(tester, find.text('Save'));
        await tester.pumpAndSettle();
        expect(store.pending, isEmpty);
        expect(
          await tester.runAsync(TransactionRepository(db).load),
          hasLength(1),
        );
        expect(
          (await tester.runAsync(TransactionRepository(db).load))!.single.note,
          'Sender: ${sms().sender}\n\n${sms().body}',
        );
        if (!transfer) {
          final saved = (await tester.runAsync(TransactionRepository(db).load))!
              .single;
          expect(saved.title, isNotEmpty);
          expect(saved.accountId, bank);
          expect(saved.categoryId, isNotNull);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
