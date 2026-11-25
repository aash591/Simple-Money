import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/agent/agent_suggestion_repository.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/budget_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/sms_review_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/ui/more/ai/ai_suggestions_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/transactions/transaction_sheet.dart';

void main() {
  late AppDatabase db;
  late AgentTools tools;
  late int hdfc, usd;
  late Map<String, int> category;
  late int changes;

  Future<Map<String, Object?>> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await tools.call(name, args);
    final text = ((result['content'] as List).single as Map)['text'] as String;
    if (result['isError'] == true) return {'error': text};
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  }

  Future<Map<String, Object?>> row(int id) async =>
      (await db
              .customSelect('SELECT * FROM transactions WHERE id = $id')
              .getSingle())
          .data;

  Future<int> expense(int minor, String categoryName, {String? title}) =>
      TransactionRepository(db).addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: minor,
        accountId: hdfc,
        categoryId: category[categoryName]!,
        title: title,
        date: DateTime(2026, 10, 12, 13),
      );

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    changes = 0;
    tools = AgentTools(db, onSuggestionsChanged: () => changes++);
    final accounts = AccountRepository(db);
    hdfc = await accounts.save(
      name: 'HDFC',
      currency: 'INR',
      digits: 2,
      openingBalance: 1000000,
      lastDigits: '1234',
    );
    usd = await accounts.save(
      name: 'Wise USD',
      currency: 'USD',
      digits: 2,
      openingBalance: 0,
    );
    category = {
      for (final c in await CategoryRepository(db).load()) c.name: c.id,
    };
  });

  tearDown(() => db.close());

  test('Without Pro only the teaching tools answer', () async {
    var pro = false;
    final gated = AgentTools(db, canUsePro: () => pro);
    String text(Map<String, Object?> r) =>
        ((r['content'] as List).single as Map)['text'] as String;
    final asked = await gated.call('spending_summary', {
      'from': '2026-10-01',
      'to': '2026-10-31',
    });
    expect(asked['isError'], isTrue);
    expect(text(asked), contains('SimpleMoney Pro'));
    // Teaching the app stays free, so an unreadable file never strands anyone.
    final teach = await gated.call('list_statements_to_map', {});
    expect(teach['isError'], isFalse);
    expect(
      AgentTools.freeTools,
      everyElement(isIn(gated.tools.map((t) => t.name))),
    );
    pro = true;
    final paid = await gated.call('spending_summary', {
      'from': '2026-10-01',
      'to': '2026-10-31',
    });
    expect(paid['isError'], isFalse);
  });

  test('Every tool has a unique name and an object input schema', () {
    final names = tools.definitions.map((d) => d['name']).toList();
    expect(names.toSet(), hasLength(names.length));
    for (final definition in tools.definitions) {
      expect((definition['inputSchema'] as Map)['type'], 'object');
      expect(definition['description'], isNotEmpty);
    }
  });

  test(
    'Reading tools return exact decimal amounts with their currency',
    () async {
      await expense(45050, 'Restaurants', title: 'Swiggy');
      await expense(120000, 'Groceries', title: 'More');

      final accounts = (await call('list_accounts'))['accounts'] as List;
      expect(accounts.first, containsPair('balance', '8349.50'));
      expect(accounts.first, containsPair('currency', 'INR'));

      final found = await call('search_transactions', {
        'from': '2026-10-01',
        'to': '2026-10-12',
        'query': 'swig',
      });
      expect(found['total'], 1);
      final transaction = (found['transactions'] as List).single as Map;
      expect(transaction['amount'], '450.50');
      expect(
        (transaction['category'] as Map)['name'],
        'Food & Beverage › Restaurants',
      );
      expect(transaction.containsKey('note'), isFalse);

      final summary = await call('spending_summary', {
        'from': '2026-10-01',
        'to': '2026-10-31',
      });
      expect(summary['groups'], [
        {
          'group': 'Food & Beverage',
          'total': '1650.50',
          'currency': 'INR',
          'count': 2,
        },
      ]);
    },
  );

  test('Totals come exact, by payee and for a search', () async {
    await expense(45050, 'Restaurants', title: 'Swiggy');
    await expense(19900, 'Restaurants', title: 'Swiggy');
    await expense(120000, 'Groceries', title: 'More');

    final byPayee = await call('spending_summary', {
      'from': '2026-10-01',
      'to': '2026-10-31',
      'group_by': 'payee',
      'limit': 1,
    });
    expect(byPayee['groups'], [
      {'group': 'More', 'total': '1200.00', 'currency': 'INR', 'count': 1},
    ]);
    expect(byPayee['groups_shown'], '1 of 2');
    expect(byPayee['all'], [
      {'total': '1849.50', 'currency': 'INR', 'count': 3},
    ]);

    final swiggy = await call('spending_summary', {
      'from': '2026-10-01',
      'to': '2026-10-31',
      'query': 'swig',
    });
    expect((swiggy['all'] as List).single, containsPair('total', '649.50'));

    final found = await call('search_transactions', {
      'from': '2026-10-01',
      'to': '2026-10-31',
      'query': 'swiggy',
      'limit': 1,
    });
    expect(found['totals'], [
      {'type': 'expense', 'total': '649.50', 'currency': 'INR', 'count': 2},
    ]);
    expect(found['transactions'], hasLength(1));
  });

  test('"Personal" payees are listed and sorted one payee at a time', () async {
    await expense(5000, 'Personal', title: 'INDIAN OIL');
    await expense(7000, 'Personal', title: 'Indian Oil ');
    await expense(2000, 'Personal', title: 'Rahul K');
    await expense(9000, 'Groceries', title: 'More');

    final listed = await call('list_payees_to_categorize');
    expect(listed['payees_left'], 2);
    final first = (listed['payees'] as List).first as Map;
    expect(first, containsPair('total', '120.00'));
    expect(first, containsPair('count', 2));

    final sorted = await call('categorize_payee', {
      'payee': 'indian oil',
      'category_name': 'Fuel',
    });
    expect(sorted['suggested'], 2, reason: '$sorted');
    final repo = AgentSuggestionRepository(db);
    final pending = await repo.load();
    expect(pending, hasLength(2));
    for (final s in pending) {
      expect(await repo.apply(s.id), isNull);
    }
    final fuel = await call('search_transactions', {
      'from': '2026-10-01',
      'to': '2026-10-31',
      'category_id': category['Fuel'],
    });
    expect(fuel['total'], 2);
    // Done this session: only the person is left.
    final left = await call('list_payees_to_categorize');
    expect(left['payees_left'], 1);
    expect(
      (await call('categorize_payee', {
        'payee': 'Nobody',
        'category_name': 'Fuel',
      }))['error'],
      contains('list_payees_to_categorize'),
    );
  });

  test('A purchase on a credit card isn’t a card bill', () async {
    final card = await AccountRepository(db).save(
      name: 'SBI Card',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      type: AccountType.creditCard,
    );
    await TransactionRepository(db).addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: 266000,
      accountId: card,
      categoryId: category['Personal']!,
      title: 'LE CHIQUE',
      date: DateTime(2026, 9, 27),
    );
    final refused = await call('categorize_payee', {
      'payee': 'LE CHIQUE',
      'category_name': 'Credit Card Repayment',
    });
    expect(refused['error'], contains('purchases made with a credit card'));
    final sorted = await call('categorize_payee', {
      'payee': 'LE CHIQUE',
      'category_name': 'Restaurants',
    });
    expect(sorted['suggested'], 1, reason: '$sorted');
  });

  test('A balance below zero is explained from what moved', () async {
    final cash = await AccountRepository(db).save(
      name: 'Cash',
      currency: 'INR',
      digits: 2,
      openingBalance: 0,
      type: AccountType.cash,
    );
    await TransactionRepository(db).addTransfer(
      amountMinor: 2500000,
      fromAccountId: cash,
      toAccountId: hdfc,
      date: DateTime(2026, 9, 3),
    );
    final activity = await call('account_activity', {'account_id': cash});
    expect(activity['money_in'], '0.00');
    expect(activity['money_out'], '25000.00');
    expect((activity['account'] as Map)['balance'], '-25000.00');
    expect(
      (activity['largest'] as List).single,
      containsPair('other_account', 'HDFC'),
    );
    expect((activity['notes'] as List).first, contains('Cash can’t be below'));
  });

  group('Fixing saved transactions', () {
    late int kotak;
    late AgentSuggestionRepository repository;

    Future<int> balance(int account) async =>
        (await db
                .customSelect(
                  'SELECT balance_minor FROM accounts WHERE id = $account',
                )
                .getSingle())
            .read<int>('balance_minor');

    /// Approves every pending suggestion.
    Future<void> approveAll() async {
      for (final s in await repository.load(
        statuses: {AgentSuggestionStatus.pending},
      )) {
        expect(await repository.apply(s.id), isNull, reason: s.summary);
      }
    }

    setUp(() async {
      kotak = await AccountRepository(db)
          .save(name: 'Kotak', currency: 'INR', digits: 2, openingBalance: 0);
      repository = AgentSuggestionRepository(db);
    });

    test(
      'An expense that was money moved becomes a transfer, and back',
      () async {
        final id = await expense(500000, 'Groceries', title: 'To Kotak');
        final result = await call('suggest_transaction_edits', {
          'items': [
            {'transaction_id': id, 'type': 'transfer', 'to_account_id': kotak},
          ],
        });
        expect(result['suggested'], 1, reason: '$result');
        final [suggestion] = await repository.load();
        expect(suggestion.detail, [
          'Type: expense → transfer',
          'To: — → Kotak',
        ]);
        await approveAll();
        final moved = await row(id);
        expect(moved['type'], 'transfer');
        expect(moved['to_account_id'], kotak);
        expect(moved['category_id'], isNull);
        expect(await balance(hdfc), 1000000 - 500000);
        expect(await balance(kotak), 500000);

        expect(await repository.undo(suggestion.id), isNull);
        final back = await row(id);
        expect(back['type'], 'expense');
        expect(back['category_id'], category['Groceries']);
        expect(back['title'], 'To Kotak');
        expect(await balance(kotak), 0);
        expect(await balance(hdfc), 1000000 - 500000);

        // A transfer back to an expense needs its category.
        await call('suggest_transaction_edits', {
          'items': [
            {'transaction_id': id, 'type': 'transfer', 'to_account_id': kotak},
          ],
        });
        await approveAll();
        final noCategory = await call('suggest_transaction_edits', {
          'items': [
            {'transaction_id': id, 'type': 'expense'},
          ],
        });
        expect(
          ((noCategory['rejected'] as List).single as Map)['error'],
          contains('needs a category'),
        );
      },
    );

    test('One change for many, and amount and date', () async {
      final ids = [
        for (final title in ['A', 'B', 'C'])
          await expense(10000, 'Groceries', title: title),
      ];
      final bulk = await call('suggest_transaction_edits', {
        'items': [
          {'transaction_ids': ids, 'category_id': category['Restaurants']},
          {
            'transaction_id': ids.first,
            'amount': '120.50',
            'date': '2026-10-10',
          },
        ],
      });
      // The first one's two changes are one edit.
      expect(bulk['suggested'], 3, reason: '$bulk');
      await approveAll();
      for (final id in ids) {
        expect((await row(id))['category_id'], category['Restaurants']);
      }
      final first = await row(ids.first);
      expect(first['amount_minor'], 12050);
      final day = DateTime.fromMillisecondsSinceEpoch(first['date'] as int);
      expect((day.year, day.month, day.day, day.hour), (2026, 10, 10, 13));
      expect(await balance(hdfc), 1000000 - 12050 - 20000);
    });

    test('A duplicate is deleted, and undo puts it back as it was', () async {
      final id = await expense(25000, 'Groceries', title: 'Twice');
      final deleted = await call('suggest_transaction_edits', {
        'items': [
          {'transaction_id': id, 'delete': true, 'reason': 'Saved twice'},
        ],
      });
      expect(deleted['suggested'], 1);
      final mixed = await call('suggest_transaction_edits', {
        'items': [
          {'transaction_id': id, 'delete': true, 'title': 'x'},
        ],
      });
      expect(
        ((mixed['rejected'] as List).single as Map)['error'],
        contains('give nothing else'),
      );
      final [suggestion] = await repository.load();
      await approveAll();
      expect(
        await db
            .customSelect('SELECT 1 FROM transactions WHERE id = $id')
            .get(),
        isEmpty,
      );
      expect(await balance(hdfc), 1000000);

      expect(await repository.undo(suggestion.id), isNull);
      final back = await row(id);
      expect(back['title'], 'Twice');
      expect(back['amount_minor'], 25000);
      expect(await balance(hdfc), 1000000 - 25000);
    });

    test('A transfer can be added', () async {
      final added = await call('suggest_transactions', {
        'items': [
          {
            'type': 'transfer',
            'amount': '300.00',
            'account_id': hdfc,
            'to_account_id': kotak,
            'date': '2026-10-12',
          },
          {
            'type': 'transfer',
            'amount': '10.00',
            'account_id': hdfc,
            'to_account_id': usd,
          },
          {
            'type': 'transfer',
            'amount': '10.00',
            'account_id': hdfc,
            'to_account_id': kotak,
            'category_id': category['Groceries'],
          },
        ],
      });
      expect(added['suggested'], 1, reason: '$added');
      expect((added['rejected'] as List).map((r) => (r as Map)['error']), [
        contains('received_amount'),
        'A transfer has no category or title.',
      ]);
      await approveAll();
      expect(await balance(kotak), 30000);
      expect(await balance(hdfc), 1000000 - 30000);
    });

    test('Duplicates are found by their UPI reference', () async {
      Future<int> saved(
        int account,
        TransactionType type,
        int minor,
        String note,
      ) => TransactionRepository(db).addExpenseOrIncome(
        type: type,
        amountMinor: minor,
        accountId: account,
        categoryId:
            category[type == TransactionType.income ? 'Salary' : 'Groceries']!,
        note: note,
        date: DateTime(2026, 10, 12, 13),
      );
      final now = DateTime.now();
      final today =
          '${now.year}-${'${now.month}'.padLeft(2, '0')}-'
          '${'${now.day}'.padLeft(2, '0')}';
      // The same payment twice.
      final a = await saved(
        hdfc,
        TransactionType.expense,
        9000,
        'UPI Ref 629920840430',
      );
      final b = await saved(
        hdfc,
        TransactionType.expense,
        9000,
        'UPI ref: 629920840430',
      );
      // Two teas of one price: each its own reference.
      await saved(hdfc, TransactionType.expense, 2000, 'UPI Ref 111111111111');
      await saved(hdfc, TransactionType.expense, 2000, 'UPI Ref 222222222222');
      // One transfer saved by each bank.
      final out = await saved(
        hdfc,
        TransactionType.expense,
        50000,
        'UPI Ref 333333333333',
      );
      final into = await saved(
        kotak,
        TransactionType.income,
        50000,
        'UPI Ref 333333333333',
      );
      final found = await call('find_duplicates', {
        'from': '2026-10-01',
        'to': today,
      });
      final [group] = found['duplicates'] as List;
      expect((group as Map)['evidence'], startsWith('same UPI reference'));
      expect(
        [for (final t in group['transactions'] as List) (t as Map)['id']],
        [a, b],
      );
      expect(found['left_out'], startsWith('1 sets'));
      final [pair] = found['transfers_saved_twice'] as List;
      expect(((pair as Map)['out'] as Map)['id'], out);
      expect((pair['in'] as Map)['id'], into);
    });

    test('Budgets show what is set, spent and left', () async {
      final now = DateTime.now();
      await BudgetRepository(db).saveTotal(
        currency: 'INR',
        digits: 2,
        fromMonth: DateTime(now.year, now.month),
        amountMinor: 500000,
      );
      await TransactionRepository(db).addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: 120000,
        accountId: hdfc,
        categoryId: category['Groceries']!,
        date: now,
      );
      final budgets = await call('list_budgets');
      final [inr] = budgets['by_currency'] as List;
      expect((inr as Map)['currency'], 'INR');
      expect(inr['total_budget'], {
        'limit': '5000.00',
        'spent': '1200.00',
        'left': '3800.00',
      });
    });

    test('The tool list fits what the relay accepts', () {
      final size = jsonEncode({
        'tools': tools.definitions,
        'instructions': AgentTools.instructions,
      }).length;
      expect(size, lessThan(256 * 1024));
    });
  });

  test('Bad input comes back as an error the AI app can read', () async {
    expect(
      (await call('search_transactions', {'to': '2026-10-01'}))['error'],
      'Give from as YYYY-MM-DD.',
    );
    expect((await call('no_such_tool'))['error'], contains('no tool'));
  });

  test(
    'A transaction edit waits for approval, applies, and can be undone',
    () async {
      final id = await expense(45050, 'Groceries', title: 'swgy order');

      final result = await call('suggest_transaction_edits', {
        'items': [
          {
            'transaction_id': id,
            'category_name': 'Food & Beverage › Restaurants',
            'title': 'Swiggy',
            'reason': 'Swiggy is food delivery',
          },
        ],
      });
      expect(result['suggested'], 1);
      expect(changes, 1);
      expect((await row(id))['category_id'], category['Groceries']);

      final repository = AgentSuggestionRepository(db);
      final [suggestion] = await repository.load();
      expect(suggestion.detail, [
        'Category: Food & Beverage › Groceries → Food & Beverage › Restaurants',
        'Title: swgy order → Swiggy',
      ]);
      expect(await repository.apply(suggestion.id), isNull);
      expect((await row(id))['category_id'], category['Restaurants']);
      expect((await row(id))['title'], 'Swiggy');

      expect(await repository.undo(suggestion.id), isNull);
      expect((await row(id))['category_id'], category['Groceries']);
      expect((await row(id))['title'], 'swgy order');
      expect(
        (await repository.load()).single.status,
        AgentSuggestionStatus.undone,
      );
    },
  );

  test(
    'Suggestions that could never apply are rejected item by item',
    () async {
      final id = await expense(1000, 'Groceries');
      final result = await call('suggest_transaction_edits', {
        'items': [
          {'transaction_id': id, 'account_id': usd},
          {'transaction_id': id, 'category_id': category['Salary']},
          {'transaction_id': 999},
          {'transaction_id': id, 'category_name': 'Groceries'},
        ],
      });
      expect(result['suggested'], 0);
      expect((result['rejected'] as List).map((r) => (r as Map)['error']), [
        'Wise USD uses a different currency from HDFC.',
        'Category ${category['Salary']} isn’t an expense category.',
        'No transaction has id 999.',
        'Nothing would change.',
      ]);
    },
  );

  test('A new category is approved before the edits that use it', () async {
    final id = await expense(64900, 'Shopping');
    await call('suggest_new_categories', {
      'items': [
        {'name': 'Streaming', 'type': 'expense', 'parent_name': 'Shopping'},
      ],
    });
    final edit = await call('suggest_transaction_edits', {
      'items': [
        {'transaction_id': id, 'category_name': 'Streaming'},
      ],
    });
    expect(edit['suggested'], 1);

    final repository = AgentSuggestionRepository(db);
    final pending = await repository.load();
    expect(pending.first.kind, AgentSuggestionKind.newCategory);
    expect(
      await repository.apply(pending.last.id),
      'Approve the new category “Streaming” first.',
    );

    expect(await repository.applyAll(), (2, 0));
    final streaming = (await CategoryRepository(
      db,
    ).load()).singleWhere((c) => c.name == 'Streaming');
    expect(streaming.parentId, category['Shopping']);
    expect((await row(id))['category_id'], streaming.id);
  });

  group('Pending SMS', () {
    const smsId = 'abc';

    setUp(() async {
      await db.customStatement(
        "INSERT INTO sms_imports (fingerprint, sender, body, received_at, candidate, rule_id, pack_version) VALUES (?, 'VM-HDFCBK', ?, ?, ?, 'test', 1)",
        [
          smsId,
          'Rs.450.00 debited from a/c **1234 to SWIGGY on 12-10-26',
          DateTime(2026, 10, 12, 13).millisecondsSinceEpoch,
          jsonEncode({
            'amountMinor': 45000,
            'currencyCode': 'INR',
            'direction': 'debit',
            'countryCode': 'IN',
            'bankName': 'HDFC Bank',
            'accountLast4': '1234',
            'counterparty': 'SWIGGY',
            'isCreditCard': false,
          }),
        ],
      );
    });

    Future<void> index() async {
      final sms = (await SmsImportRepository(db).pending()).single;
      await SmsReviewRepository(db).put(
        sms,
        await AccountRepository(db).load(),
        await CategoryRepository(db).load(),
        await SmsImportRepository(db).accountLinks(),
        null,
      );
    }

    test('An approved correction is what the review queue saves', () async {
      await index();
      final listed = await call('list_pending_sms');
      final message = (listed['messages'] as List).single as Map;
      expect(message['text'], contains('SWIGGY'));
      expect(message['ready'], isFalse);

      await call('suggest_sms_corrections', {
        'items': [
          {
            'sms_id': smsId,
            'account_id': hdfc,
            'category_id': category['Restaurants'],
          },
        ],
      });
      final repository = AgentSuggestionRepository(db);
      expect(await repository.applyAll(), (1, 0));

      await index();
      final [row] = await SmsReviewRepository(db).page();
      expect(row.ready, isTrue);
      expect(row.transaction.accountId, hdfc);
      expect(row.transaction.categoryId, category['Restaurants']);
    });

    test('Rejects an account in another currency or a cash account', () async {
      final cash = await AccountRepository(db).save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 0,
        type: AccountType.cash,
      );
      final result = await call('suggest_sms_corrections', {
        'items': [
          {'sms_id': smsId, 'account_id': usd},
          {'sms_id': smsId, 'account_id': cash},
          {'sms_id': smsId, 'category_id': category['Salary']},
        ],
      });
      expect(result['suggested'], 0);
      expect((result['rejected'] as List), hasLength(3));
    });

    test('A dismissal leaves the queue once approved', () async {
      await call('suggest_sms_corrections', {
        'items': [
          {'sms_id': smsId, 'dismiss': true},
        ],
      });
      expect(await AgentSuggestionRepository(db).applyAll(), (1, 0));
      expect(await SmsImportRepository(db).pending(), isEmpty);
    });

    test('A message the user reviewed first drops its suggestion', () async {
      await call('suggest_sms_corrections', {
        'items': [
          {'sms_id': smsId, 'category_id': category['Restaurants']},
        ],
      });
      await SmsImportRepository(db).dismiss(smsId);
      final repository = AgentSuggestionRepository(db);
      expect(await repository.pendingCount(), 0);
      expect(
        (await repository.load()).single.status,
        AgentSuggestionStatus.rejected,
      );
    });
  });

  testWidgets('The review screen approves a suggestion and can undo it', (
    tester,
  ) async {
    late int id;
    var reloads = 0;
    await tester.runAsync(() async {
      id = await expense(45050, 'Groceries', title: 'Swiggy');
      await call('suggest_transaction_edits', {
        'items': [
          {
            'transaction_id': id,
            'category_id': category['Restaurants'],
            'reason': 'Food delivery',
          },
        ],
      });
    });
    Future<void> settle() async {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
    }

    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: AiSuggestionsScreen(
          database: db,
          onLedgerChanged: () => reloads++,
        ),
      ),
    );
    await settle();
    expect(find.text('Pending 1'), findsOneWidget);
    expect(find.text('“Food delivery”'), findsOneWidget);

    // The transaction shows as it does everywhere, before and after.
    expect(find.text('Now'), findsOneWidget);
    expect(find.text('If approved'), findsOneWidget);
    expect(find.text('Swiggy'), findsNWidgets(2));
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text('Restaurants'), findsOneWidget);
    expect(find.textContaining('Category:'), findsNothing);

    // Tapping one opens it in the transaction sheet.
    await tester.tap(find.text('Groceries'));
    await settle();
    expect(find.byType(TransactionSheet), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await settle();
    expect(find.byType(TransactionSheet), findsNothing);

    await tester.tap(find.text('Approve'));
    await settle();
    // It moves out of Pending, into Applied.
    expect(find.textContaining('Nothing waiting'), findsOneWidget);
    expect(reloads, 1);
    await tester.runAsync(() async {
      expect((await row(id))['category_id'], category['Restaurants']);
    });
    await tester.tap(find.text('Applied'));
    await settle();
    expect(find.text('Approved'), findsOneWidget);
    expect(find.text('Before'), findsOneWidget);

    await tester.tap(find.text('Undo'));
    await settle();
    await tester.runAsync(() async {
      expect((await row(id))['category_id'], category['Groceries']);
    });

    // Undone, it waits under Rejected, where it can be applied again.
    await tester.tap(find.text('Rejected'));
    await settle();
    expect(find.text('Undone'), findsOneWidget);
    await tester.tap(find.text('Apply'));
    await settle();
    await tester.runAsync(() async {
      expect((await row(id))['category_id'], category['Restaurants']);
    });
    expect(find.textContaining('Nothing rejected'), findsOneWidget);
  });
}
