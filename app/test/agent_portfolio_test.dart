import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/ui/more/ai/ai_suggestions_screen.dart';
import 'package:simple_money/ui/more/ai/portfolio_suggestion_card.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:flutter/material.dart';

void main() {
  late AppDatabase db;
  late AgentTools tools;
  late int bank;

  Future<Map<String, Object?>> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await tools.call(name, args);
    final text = ((result['content'] as List).single as Map)['text'] as String;
    if (result['isError'] == true) return {'error': text};
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  }

  Future<Map<String, Object?>> suggest(
    Map<String, Object?> item, {
    String tool = 'suggest_portfolio_changes',
  }) => call(tool, {
    'items': [item],
  });

  /// Suggests one change and approves it, returning the failure if any.
  Future<String?> approve(
    Map<String, Object?> item, {
    String tool = 'suggest_portfolio_changes',
  }) async {
    final reply = await suggest(item, tool: tool);
    if (reply['suggested'] != 1)
      return '${reply['error'] ?? reply['rejected']}';
    final id = (await tools.suggestions.load(limit: 1)).single.id;
    return tools.suggestions.apply(id);
  }

  Future<Map<String, Object?>> place(int id) async {
    final places = (await call('list_portfolio'))['places'] as List;
    return Map<String, Object?>.from(
      places.cast<Map>().firstWhere((p) => p['account_id'] == id),
    );
  }

  Future<Account> account(int id) async =>
      (await AccountRepository(db).load()).firstWhere((a) => a.id == id);

  late int broker;

  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    tools = AgentTools(db);
    bank = await AccountRepository(
      db,
    ).save(name: 'HDFC', currency: 'INR', digits: 2, openingBalance: 5000000);
    expect(
      await approve({
        'action': 'create',
        'name': 'Zerodha',
        'place': 'broker',
        'balance': '100000',
      }, tool: 'suggest_account_changes'),
      isNull,
    );
    broker = (await AccountRepository(
      db,
    ).load()).firstWhere((a) => a.name == 'Zerodha').id;
  });

  tearDown(() => db.close());

  test(
    'the tools are listed and a broker account is made as a broker',
    () async {
      expect(
        [for (final t in tools.tools) t.name],
        containsAll([
          'list_portfolio',
          'find_security',
          'suggest_portfolio_changes',
        ]),
      );
      final a = await account(broker);
      expect(a.isBroker, isTrue);
      expect(a.balanceMinor, 10000000);
      final listed = (await call('list_accounts'))['accounts'] as List;
      final row = listed.cast<Map>().firstWhere((x) => x['id'] == broker);
      expect(row['place'], 'broker');
      expect(row['investment_account'], isTrue);
    },
  );

  test('an in-hand place holds no cash', () async {
    final bad = await suggest({
      'action': 'create',
      'name': 'Home gold',
      'place': 'in_hand',
      'balance': '500',
    }, tool: 'suggest_account_changes');
    expect(bad['suggested'], 0);
    expect(
      await approve({
        'action': 'create',
        'name': 'Home gold',
        'place': 'in_hand',
      }, tool: 'suggest_account_changes'),
      isNull,
    );
    final home = (await AccountRepository(
      db,
    ).load()).firstWhere((a) => a.name == 'Home gold');
    expect(home.place?.holdsCash, isFalse);
  });

  test('add a holding with its first buy, then buy, sell and undo', () async {
    expect(
      await approve({
        'action': 'add_holding',
        'account_id': broker,
        'kind': 'stock',
        'name': 'Tata Consultancy Services',
        'symbol': 'TCS',
        'exchange': 'NSE',
        'units': '10',
        'price': '4000',
        'date': '2026-11-01',
      }),
      isNull,
    );
    var p = await place(broker);
    var h = (p['holdings'] as List).single as Map;
    expect(h['units'], '10');
    expect(h['price'], '4000');
    expect(h['price_source'], 'yahoo');
    expect(p['funds'], '60000.00');
    final holdingId = h['holding_id'] as int;

    // A buy paid from the bank leaves the bank, not the broker's funds.
    expect(
      await approve({
        'action': 'buy',
        'holding_id': holdingId,
        'units': '5',
        'price': '4100',
        'fees': '20',
        'pay_from_account_id': bank,
        'date': '2026-11-02',
      }),
      isNull,
    );
    expect((await account(bank)).balanceMinor, 5000000 - 2050000 - 2000);
    expect((await account(broker)).balanceMinor, 6000000);

    // Selling more than is held is turned down.
    final tooMany = await suggest({
      'action': 'sell',
      'holding_id': holdingId,
      'units': '99',
      'price': '4200',
    });
    expect(tooMany['suggested'], 0);

    expect(
      await approve({
        'action': 'sell',
        'holding_id': holdingId,
        'units': '3',
        'price': '4200',
        'date': '2026-11-03',
      }),
      isNull,
    );
    p = await place(broker);
    h = (p['holdings'] as List).single as Map;
    expect(h['units'], '12');
    expect((await account(broker)).balanceMinor, 6000000 + 1260000);

    // Undo the sale: units and cash go back.
    final sell = (await tools.suggestions.load(limit: 1)).single;
    expect(sell.canUndo, isTrue);
    expect(await tools.suggestions.undo(sell.id), isNull);
    p = await place(broker);
    expect(((p['holdings'] as List).single as Map)['units'], '15');
    expect((await account(broker)).balanceMinor, 6000000);

    final detail = await call('list_portfolio', {'holding_id': holdingId});
    final trades =
        (((detail['places'] as List).single as Map)['holdings'] as List)
                .cast<Map>()
                .single['trades']
            as List;
    expect(trades, hasLength(2));
  });

  test('a metal is added by metal and purity, in grams', () async {
    expect(
      await approve({
        'action': 'add_holding',
        'account_id': broker,
        'kind': 'metal',
        'name': 'Wedding necklace',
        'metal': 'gold',
        'purity': '22K',
        'units': '40',
        'price': '6500',
      }),
      isNull,
    );
    final h = ((await place(broker))['holdings'] as List).single as Map;
    expect(h['metal'], 'gold');
    expect(h['purity'], '22K');
    expect(h['units_are'], 'grams');
    expect(h['price_source'], 'metal_world');
  });

  test('set price can be undone; deleting a holding cannot', () async {
    await approve({
      'action': 'add_holding',
      'account_id': broker,
      'kind': 'crypto',
      'name': 'Bitcoin',
      'symbol': 'bitcoin',
      'units': '0.01',
      'price': '5000000',
    });
    final id =
        (((await place(broker))['holdings'] as List).single
                as Map)['holding_id']
            as int;
    expect(
      await approve({
        'action': 'set_price',
        'holding_id': id,
        'price': '5100000',
      }),
      isNull,
    );
    expect(
      (((await place(broker))['holdings'] as List).single as Map)['price'],
      '5100000',
    );
    final set = (await tools.suggestions.load(limit: 1)).single;
    expect(await tools.suggestions.undo(set.id), isNull);
    expect(
      (((await place(broker))['holdings'] as List).single as Map)['price'],
      '5000000',
    );

    expect(
      await approve({'action': 'delete_holding', 'holding_id': id}),
      isNull,
    );
    expect(((await place(broker))['holdings'] as List), isEmpty);
    // Its cash came back.
    expect((await account(broker)).balanceMinor, 10000000);
    final deleted = (await tools.suggestions.load(limit: 1)).single;
    expect(deleted.canUndo, isFalse);
  });

  test(
    'a suggestion for something that is not an investment account fails',
    () async {
      final reply = await suggest({
        'action': 'add_holding',
        'account_id': bank,
        'kind': 'stock',
        'name': 'X',
        'symbol': 'X',
      });
      expect(reply['suggested'], 0);
      expect('${reply['rejected']}', contains('not an investment account'));
    },
  );

  testWidgets('a suggestion is drawn like a portfolio row', (tester) async {
    await tester.runAsync(() async {
      await suggest({
        'action': 'add_holding',
        'account_id': broker,
        'kind': 'fund',
        'name': 'Parag Parikh Flexi Cap',
        'symbol': '122639',
        'units': '41.2',
        'price': '75.5',
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
    expect(find.byType(PortfolioSuggestionPreview), findsOneWidget);
    expect(find.text('Add holding'), findsOneWidget);
    expect(find.text('Parag Parikh Flexi Cap'), findsOneWidget);
    expect(find.text('41.2 units'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
