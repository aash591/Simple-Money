// A real model on a real inbox: the user's own exported SMS (gitignored,
// never copied into the repo) imported the way a first scan does, then the
// questions people ask. The answers are checked against the database.
// Skipped unless the export exists; the model tests also need LLM_URL (see
// llm_chat.dart). REAL_SMS picks another export.
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/agent/agent_suggestion_repository.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/sms_inbox_platform.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import 'llm_chat.dart';

const _defaultExport = '../sms/artifacts/decrypted/realme_15x_5G/all_sms.jsonl';

/// The export as an inbox, oldest first.
class _ExportInbox extends SmsInboxPlatform {
  _ExportInbox(this.rows);
  final List<InboxSms> rows;
  @override
  bool get supported => true;
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<void> setRealtimeEnabled(bool enabled) async {}
  @override
  Future<List<InboxSms>> readPage({
    required int afterId,
    required int since,
  }) async => rows
      .where(
        (r) =>
            r.id > afterId && r.sms.receivedAt.millisecondsSinceEpoch >= since,
      )
      .take(200)
      .toList();
}

List<InboxSms> _readExport(File file) => [
  for (final line in file.readAsLinesSync())
    if (line.trim().isNotEmpty)
      if (jsonDecode(line) case {
        'smsId': final int id,
        'address': final String sender,
        'dateMs': final int at,
        'type': 1,
        'body': final String body,
      })
        InboxSms(
          id,
          BankSms(
            sender: sender,
            body: body,
            receivedAt: DateTime.fromMillisecondsSinceEpoch(at),
          ),
        ),
]..sort((a, b) => a.id.compareTo(b.id));

void main() {
  final export = File(Platform.environment['REAL_SMS'] ?? _defaultExport);
  final noExport = export.existsSync() ? false : 'No SMS export at $export';
  final skip = noExport == false ? llmSkip : noExport;

  late AppDatabase db;
  late AgentTools tools;

  Future<Map<String, Object?>> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await tools.call(name, args);
    return Map<String, Object?>.from(
      jsonDecode(((result['content'] as List).single as Map)['text'] as String)
          as Map,
    );
  }

  setUpAll(() async {
    HttpOverrides.global = null;
    if (!export.existsSync()) return;
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory());
    await SmsImportStore(
      SmsImportRepository(db),
      platform: _ExportInbox(_readExport(export)),
    ).enable();
    tools = AgentTools(db);
  });

  test(
    'Spending last month, and on what',
    () async {
      final truth = await call('spending_summary', {
        'from': '2026-09-01',
        'to': '2026-09-30',
      });
      final total = ((truth['all'] as List).single as Map)['total'] as String;
      final top = ((truth['groups'] as List).first as Map)['group'] as String;
      // ignore: avoid_print
      print('Truth: $total, top $top');
      final run = await converse(
        tools,
        'How much did I spend in September 2026, and on what mostly?',
      );
      expect(statesAmount(run.answer, total), isTrue, reason: 'Total $total');
      // "On what": the top category, or who was paid most.
      final payees = await call('spending_summary', {
        'from': '2026-09-01',
        'to': '2026-09-30',
        'group_by': 'payee',
        'limit': 1,
      });
      final payee =
          ((payees['groups'] as List).first as Map)['group'] as String;
      expect(
        run.answer.toLowerCase(),
        anyOf(contains(top.toLowerCase()), contains(payee.toLowerCase())),
      );
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'Who was paid the most',
    () async {
      final truth = await call('spending_summary', {
        'from': '2026-07-01',
        'to': '2026-09-30',
        'group_by': 'payee',
        'limit': 3,
      });
      final top = (truth['groups'] as List).cast<Map>().first;
      // ignore: avoid_print
      print('Truth: $top');
      final run = await converse(
        tools,
        'Who did I pay the most money to from July to September 2026, and '
        'how much?',
      );
      expect(
        run.answer.toLowerCase(),
        contains((top['group'] as String).toLowerCase()),
      );
      expect(statesAmount(run.answer, top['total'] as String), isTrue);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'How much went to one place, all told',
    () async {
      // The payee paid most often this year.
      final often = await db.customSelect('''SELECT title, COUNT(*) AS n
          FROM transactions WHERE type = 'expense' AND title IS NOT NULL
            AND date >= ${DateTime(2026).millisecondsSinceEpoch}
          GROUP BY lower(title) ORDER BY n DESC LIMIT 1''').getSingle();
      final payee = often.read<String>('title');
      final truth = await call('search_transactions', {
        'from': '2026-01-01',
        'to': '2026-10-31',
        'query': payee,
        'type': 'expense',
        'limit': 1,
      });
      final total = ((truth['totals'] as List).single as Map)['total'];
      // ignore: avoid_print
      print('Truth: $payee $total');
      final run = await converse(
        tools,
        'How much have I spent on $payee this year?',
      );
      expect(statesAmount(run.answer, total as String), isTrue);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'Why an account’s balance makes no sense',
    () async {
      final cash = (await AccountRepository(
        db,
      ).load()).firstWhere((a) => a.type == AccountType.cash);
      // ignore: avoid_print
      print('Cash: ${cash.balanceMinor / 100}');
      final run = await converse(
        tools,
        'My Cash balance shows ${(cash.balanceMinor / 100).toStringAsFixed(0)}. '
        'That makes no sense. Why?',
      );
      // It looked at what moved the cash, not guessed.
      expect(
        run.called('account_activity', (a) => a['account_id'] == cash.id) ||
            run.called(
              'search_transactions',
              (a) => a['account_id'] == cash.id,
            ),
        isTrue,
      );
      // And says what to do about it.
      expect(run.answer.toLowerCase(), contains('balance'));
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 5)),
  );

  test(
    'Personal fallbacks get real categories',
    () async {
      final run = await converse(
        tools,
        'Many of my September 2026 transactions are just "Personal". Put '
        'them in better categories.',
      );
      final edits = (await AgentSuggestionRepository(db).load())
          .where((s) => s.kind == AgentSuggestionKind.transactionEdit)
          .toList();
      for (final e in edits) {
        // ignore: avoid_print
        print('  ${e.summary} · ${e.detail.join(' · ')}');
      }
      expect(edits.length, greaterThanOrEqualTo(3), reason: run.answer);
    },
    skip: skip,
    timeout: const Timeout(Duration(minutes: 8)),
  );
}
