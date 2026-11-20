import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/reportable_sms.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart'
    show BankSms;
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/recurring_payment_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/ui/components/reminder_card.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/ui/more/ai/ai_suggestions_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  late AppDatabase db;
  late AgentTools tools;
  late int account;

  Future<Map<String, Object?>> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await tools.call(name, args);
    final text = ((result['content'] as List).single as Map)['text'] as String;
    if (result['isError'] == true) return {'error': text};
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  }

  Future<int> suggestionId() async =>
      (await tools.suggestions.load(limit: 1)).single.id;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tools = AgentTools(db);
    account = await AccountRepository(
      db,
    ).save(name: 'HDFC', currency: 'INR', digits: 2, openingBalance: 5000000);
  });

  tearDown(() => db.close());

  Map<String, Object?> rent({Map<String, Object?> extra = const {}}) => {
    'items': [
      {
        'name': 'House rent',
        'amount': '25,000',
        'account_id': account,
        'next_due': '2026-12-01',
        ...extra,
      },
    ],
  };

  test('the tools are listed, with the rules for choosing them', () {
    final names = [for (final t in tools.tools) t.name];
    expect(
      names,
      containsAll(['list_recurring_payments', 'suggest_recurring_payments']),
    );
    expect(AgentTools.instructions, contains('suggest_recurring_payments'));
  });

  test('nothing is set up until approved; then undo takes it back', () async {
    final reply = await call('suggest_recurring_payments', rent());
    expect(reply['error'], isNull);
    expect(reply['suggested'], 1);
    expect(await RecurringPaymentRepository(db).load(), isEmpty);

    final suggestion = await tools.suggestions.load(limit: 1);
    // The name picks the icon and category when none is given.
    expect(suggestion.single.payload['icon'], 'rent');
    expect(suggestion.single.summary, contains('House rent'));

    expect(await tools.suggestions.apply(suggestion.single.id), isNull);
    final saved = (await RecurringPaymentRepository(db).load()).single;
    expect(saved.name, 'House rent');
    expect(saved.incoming, isFalse);
    expect(saved.amountMinor, 2500000);
    expect(saved.nextDue, DateTime(2026, 12, 1));
    final categories = await CategoryRepository(db).load();
    expect(categories.firstWhere((c) => c.id == saved.categoryId).name, 'Rent');

    expect(await tools.suggestions.undo(suggestion.single.id), isNull);
    expect(await RecurringPaymentRepository(db).load(), isEmpty);
  });

  test('money coming in uses income categories', () async {
    await call('suggest_recurring_payments', rent(extra: {'incoming': true}));
    await tools.suggestions.apply(await suggestionId());
    final saved = (await RecurringPaymentRepository(db).load()).single;
    expect(saved.incoming, isTrue);
    final categories = await CategoryRepository(db).load();
    final category = categories.firstWhere((c) => c.id == saved.categoryId);
    expect(category.name, 'Rental Income');
    expect(category.type, CategoryType.income);
  });

  test('refuses what is already set up, and bad input', () async {
    await call('suggest_recurring_payments', rent());
    await tools.suggestions.apply(await suggestionId());
    final again = await call('suggest_recurring_payments', rent());
    expect(again['suggested'], 0);
    expect(jsonEncode(again), contains('already set up'));
    final bad = await call(
      'suggest_recurring_payments',
      rent(extra: {'name': 'Gym', 'cycle': 'daily'}),
    );
    expect(bad['error'] ?? jsonEncode(bad), contains('cycle'));
  });

  test('list_recurring_payments says which way the money goes', () async {
    await call('suggest_recurring_payments', rent());
    await tools.suggestions.apply(await suggestionId());
    await call(
      'suggest_recurring_payments',
      rent(extra: {'name': 'Tenant rent', 'incoming': true}),
    );
    await tools.suggestions.apply(await suggestionId());
    final reply = await call('list_recurring_payments');
    final list = (reply['recurring_payments'] as List).cast<Map>();
    expect(
      {for (final r in list) r['name']: r['direction']},
      {'House rent': 'out', 'Tenant rent': 'in'},
    );
    expect(list.first['account'], 'HDFC');
  });

  testWidgets('the suggestion card shows it as it would look', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await call('suggest_recurring_payments', rent(extra: {'incoming': true}));
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: AiSuggestionsScreen(database: db),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    // The Recurring payments card, with its details below.
    expect(find.byType(ReminderCard), findsOneWidget);
    expect(find.text('House rent'), findsOneWidget);
    expect(find.text('Suggested'), findsOneWidget);
    expect(find.text('Paid into'), findsOneWidget);
    expect(find.text('1 Dec 2026'), findsOneWidget);
    expect(find.textContaining('+'), findsWidgets);
    expect(find.text('Approve'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  group('finding them in the ledger', () {
    late int food;
    Future<int> paid(
      int minor,
      DateTime date,
      String title, {
      String? note,
      TransactionType type = TransactionType.expense,
    }) => TransactionRepository(db).addExpenseOrIncome(
      type: type,
      amountMinor: minor,
      accountId: account,
      categoryId: food,
      title: title,
      note: note,
      date: date,
    );
    DateTime monthsAgo(int n, [int day = 5]) {
      final now = DateTime.now();
      return DateTime(now.year, now.month - n, day, 10);
    }

    setUp(() async {
      food = (await CategoryRepository(
        db,
      ).load()).firstWhere((c) => c.type == CategoryType.expense).id;
    });

    test('monthly rent to a person, a subscription and income are found; '
        'one-offs and irregular spends are not', () async {
      // Rent by UPI to a phone-number ID, under varying titles.
      for (var m = 1; m <= 5; m++) {
        await paid(
          1500000,
          monthsAgo(m, 1),
          m.isEven ? 'RAMESH K' : 'Ramesh',
          note: 'Sender: VM-HDFCBK\n\nRs 15000 paid to 9876543210@ybl',
        );
      }
      // Two Netflix charges are enough for a known service.
      await paid(64900, monthsAgo(1, 12), 'Netflix');
      await paid(64900, monthsAgo(2, 12), 'Netflix');
      // Salary in.
      for (var m = 1; m <= 4; m++) {
        await paid(
          8000000,
          monthsAgo(m, 28),
          'ACME PAYROLL',
          type: TransactionType.income,
        );
      }
      // Groceries at one shop, different amounts and days: not a pattern.
      for (final (m, day, amount) in [
        (1, 3, 120000),
        (1, 19, 45000),
        (2, 7, 99000),
      ]) {
        await paid(amount, monthsAgo(m, day), 'Big Bazaar');
      }

      final reply = await call('find_recurring_payments');
      final found = (reply['candidates'] as List).cast<Map>();
      final byName = {for (final c in found) c['name']: c};
      expect(byName.keys, containsAll(['Netflix', 'ACME PAYROLL']));
      final rent = found.firstWhere((c) => c['amount'] == '15000.00');
      expect(rent['kind'], 'person');
      expect(rent['cycle'], 'monthly');
      expect(rent['times'], 5);
      expect((rent['transaction_ids'] as List), hasLength(5));
      expect(byName['Netflix']!['known_service'], isTrue);
      expect(byName['ACME PAYROLL']!['incoming'], isTrue);
      expect(byName.containsKey('Big Bazaar'), isFalse);
      expect(reply['next'], contains('Ask which to track'));
    });

    test('approving links the past payments as its history, '
        'and it is then left out', () async {
      final ids = [
        for (var m = 1; m <= 3; m++)
          await paid(64900, monthsAgo(m, 12), 'Netflix'),
      ];
      final found =
          ((await call('find_recurring_payments'))['candidates'] as List)
              .cast<Map>()
              .single;
      final reply = await call('suggest_recurring_payments', {
        'items': [
          {
            'name': found['name'],
            'amount': found['amount'],
            'account_id': found['account_id'],
            'cycle': found['cycle'],
            'next_due': found['next_due'],
            'transaction_ids': found['transaction_ids'],
          },
        ],
      });
      expect(reply['suggested'], 1);
      final id = await suggestionId();
      expect(await tools.suggestions.apply(id), isNull);
      final saved = (await RecurringPaymentRepository(db).load()).single;
      final history = await RecurringPaymentRepository(db).payments(saved.id);
      expect([for (final p in history) p.transactionId]..sort(), ids..sort());

      final again = await call('find_recurring_payments');
      expect(again['found'], 0);

      // Undo drops the history with it; the transactions stay.
      expect(await tools.suggestions.undo(id), isNull);
      expect(await TransactionRepository(db).load(), hasLength(3));
    });

    test('a past payment of the wrong kind is refused', () async {
      final income = await paid(
        100,
        monthsAgo(1),
        'Refund',
        type: TransactionType.income,
      );
      final reply = await call(
        'suggest_recurring_payments',
        rent(
          extra: {
            'transaction_ids': [income],
          },
        ),
      );
      expect(jsonEncode(reply), contains('isn’t an expense'));
    });

    test('SMS in review and unparsed SMS count, and approving saves them '
        'so none is left behind', () async {
      // Rent to one UPI ID: two saved, one waiting in review, one unread.
      final saved = [
        for (final m in [4, 3])
          await paid(
            1500000,
            monthsAgo(m, 1),
            'Ramesh',
            note: 'Sender: VM-HDFCBK\n\nRs 15000 paid to 9876543210@ybl',
          ),
      ];
      await db.customStatement(
        "INSERT INTO sms_imports (fingerprint, sender, body, received_at, candidate, rule_id, pack_version) VALUES ('rev', 'VM-HDFCBK', 'Rs.15000.00 debited to 9876543210@ybl', ?, ?, 't', 1)",
        [
          monthsAgo(2, 1).millisecondsSinceEpoch,
          jsonEncode({
            'amountMinor': 1500000,
            'currencyCode': 'INR',
            'direction': 'debit',
            'counterparty': 'RAMESH',
            'bankName': 'HDFC',
          }),
        ],
      );
      tools = AgentTools(
        db,
        missedSms: (_) async => [
          ReportableSms(
            'unread-fp',
            BankSms(
              sender: 'VM-HDFCBK',
              body: 'Rs 15,000.00 debited from a/c XX2199 to 9876543210@ybl',
              receivedAt: monthsAgo(1, 1),
            ),
            ReportableKind.missed,
            'noRule',
            null,
          ),
        ],
      );
      final before = (await AccountRepository(db).load()).single.balanceMinor;

      final reply = await call('find_recurring_payments');
      final rent = (reply['candidates'] as List).cast<Map>().single;
      expect(rent['times'], 4);
      expect(rent['seen_in'], {'saved': 2, 'needs_review': 1, 'unparsed': 1});
      expect(rent['sms_ids'], hasLength(2));
      expect(reply['next'], contains('none is left in SMS review'));

      final suggested = await call('suggest_recurring_payments', {
        'items': [
          {
            'name': 'House rent',
            'amount': rent['amount'],
            'account_id': rent['account_id'],
            'next_due': rent['next_due'],
            'transaction_ids': rent['transaction_ids'],
            'sms_ids': rent['sms_ids'],
          },
        ],
      });
      expect(suggested['suggested'], 1);
      expect(await tools.suggestions.apply(await suggestionId()), isNull);

      final recurring = (await RecurringPaymentRepository(db).load()).single;
      final history = await RecurringPaymentRepository(db)
          .payments(recurring.id);
      expect(history, hasLength(4));
      expect(history.map((h) => h.transactionId), containsAll(saved));
      // Nothing waits in review, and the unread one is now imported.
      final statuses = {
        for (final r
            in await db
                .customSelect('SELECT fingerprint, status FROM sms_imports')
                .get())
          r.read<String>('fingerprint'): r.read<String>('status'),
      };
      expect(statuses, {'rev': 'imported', 'unread-fp': 'imported'});
      // The two payments only SMS knew of leave the account now.
      expect(
        (await AccountRepository(db).load()).single.balanceMinor,
        before - 2 * 1500000,
      );
      expect((await call('find_recurring_payments'))['found'], 0);
    });
  });
}
