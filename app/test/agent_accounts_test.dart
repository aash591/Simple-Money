import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/ui/more/accounts/account_card.dart';
import 'package:simple_money/ui/more/ai/ai_suggestions_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  late AppDatabase db;
  late AgentTools tools;
  late int bank, card;

  Future<Map<String, Object?>> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await tools.call(name, args);
    final text = ((result['content'] as List).single as Map)['text'] as String;
    if (result['isError'] == true) return {'error': text};
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  }

  Future<Map<String, Object?>> suggest(Map<String, Object?> item) =>
      call('suggest_account_changes', {
        'items': [item],
      });

  Future<int> latest() async =>
      (await tools.suggestions.load(limit: 1)).single.id;

  Future<Account?> account(int id) async =>
      (await AccountRepository(db).load()).where((a) => a.id == id).firstOrNull;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tools = AgentTools(db);
    final accounts = AccountRepository(db);
    bank = await accounts.save(
      name: 'HDFC',
      currency: 'INR',
      digits: 2,
      lastDigits: '1234',
      openingBalance: 500000,
    );
    card = await accounts.save(
      name: 'HDFC Debit',
      currency: 'INR',
      digits: 2,
      lastDigits: '9876',
      openingBalance: 100000,
    );
    await TransactionRepository(db).addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: 2000,
      accountId: card,
      categoryId: 1,
      date: DateTime(2026, 11),
    );
  });

  tearDown(() => db.close());

  test('the tool is listed and list_accounts shows the details', () async {
    expect([
      for (final t in tools.tools) t.name,
    ], contains('suggest_account_changes'));
    final list = (await call('list_accounts'))['accounts'] as List;
    final debit = list.cast<Map>().firstWhere((a) => a['id'] == card);
    expect(debit['transactions'], 1);
    expect(debit['last_digits'], '9876');
  });

  test('create waits for approval; undo removes the empty account', () async {
    final reply = await suggest({
      'action': 'create',
      'name': 'SBI Card',
      'type': 'creditCard',
      'last_digits': '4455',
      'balance': '-1500',
      'credit_limit': '50000',
    });
    expect(reply['suggested'], 1);
    expect(await AccountRepository(db).load(), hasLength(2));
    final id = await latest();
    expect(await tools.suggestions.apply(id), isNull);
    final created = (await AccountRepository(db).load()).last;
    expect(created.name, 'SBI Card');
    expect(created.type, AccountType.creditCard);
    expect(created.balanceMinor, -150000);
    expect(created.creditLimitMinor, 5000000);
    expect(await tools.suggestions.undo(id), isNull);
    expect(await AccountRepository(db).load(), hasLength(2));
  });

  test('update and adjust_balance apply, and undo puts them back', () async {
    await suggest({
      'action': 'update',
      'account_id': bank,
      'name': 'HDFC Savings',
    });
    final rename = await latest();
    await tools.suggestions.apply(rename);
    expect((await account(bank))!.name, 'HDFC Savings');
    expect((await account(bank))!.lastDigits, '1234');

    await suggest({
      'action': 'adjust_balance',
      'account_id': bank,
      'balance': '7,250.50',
    });
    final balance = await latest();
    await tools.suggestions.apply(balance);
    expect((await account(bank))!.balanceMinor, 725050);

    expect(await tools.suggestions.undo(balance), isNull);
    expect((await account(bank))!.balanceMinor, 500000);
    expect(await tools.suggestions.undo(rename), isNull);
    expect((await account(bank))!.name, 'HDFC');
  });

  test('archive and restore are each other\'s undo', () async {
    await suggest({'action': 'archive', 'account_id': card});
    final id = await latest();
    await tools.suggestions.apply(id);
    expect((await account(card))!.isArchived, isTrue);
    await tools.suggestions.undo(id);
    expect((await account(card))!.isArchived, isFalse);
  });

  test('merge folds one account into another and cannot be undone', () async {
    await suggest({
      'action': 'merge',
      'account_id': card,
      'merge_into_id': bank,
    });
    final id = await latest();
    final s = (await tools.suggestions.load(limit: 1)).single;
    expect(s.canUndo, isFalse);
    expect(await tools.suggestions.apply(id), isNull);
    expect(await account(card), isNull);
    final kept = (await account(bank))!;
    expect(kept.balanceMinor, 500000 + 100000 - 2000);
    expect(kept.transactionCount, 1);
  });

  test('bad suggestions are refused with a reason', () async {
    final self = await suggest({
      'action': 'merge',
      'account_id': bank,
      'merge_into_id': bank,
    });
    expect(jsonEncode(self), contains('itself'));
    final missing = await suggest({
      'action': 'update',
      'account_id': 999,
      'name': 'X',
    });
    expect(jsonEncode(missing), contains('no account 999'));
    final nothing = await suggest({
      'action': 'update',
      'account_id': bank,
      'name': 'HDFC',
    });
    expect(jsonEncode(nothing), contains('Nothing to change'));
    final digits = await suggest({
      'action': 'create',
      'name': 'A',
      'last_digits': '12345',
    });
    expect(jsonEncode(digits), contains('last_digits'));
  });

  testWidgets('a merge shows both accounts as account cards', (tester) async {
    tester.view.physicalSize = const Size(390, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(() async {
      await suggest({
        'action': 'merge',
        'account_id': card,
        'merge_into_id': bank,
      });
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
    expect(find.byType(AccountCard), findsNWidgets(2));
    expect(find.text('Merge accounts'), findsOneWidget);
    expect(find.text('Keeps everything'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
