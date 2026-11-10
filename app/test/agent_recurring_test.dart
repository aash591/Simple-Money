import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/recurring_payment_repository.dart';
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
    expect(find.text('House rent'), findsOneWidget);
    expect(find.text('Money coming in'), findsOneWidget);
    expect(find.text('Next 1 Dec 2026'), findsOneWidget);
    expect(find.textContaining('+'), findsWidgets);
    expect(find.text('Approve'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
