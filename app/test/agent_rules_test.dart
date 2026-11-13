import 'dart:convert';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/agent/agent_suggestion_repository.dart';
import 'package:simple_money/data/agent/agent_tools.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/reportable_sms.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/sms_inbox_platform.dart';
import 'package:simple_money/data/user_sms_rules.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

const _sms =
    'Paid Rs.1,250.00 to Blue Tokai Coffee from Zeta card XX4321. '
    'Ref 99887766. -Zeta';
const _other =
    'Paid Rs.89.00 to Metro Rail from Zeta card XX4321. Ref A1B2C3. -Zeta';

/// A format for Zeta, a card no bundled pack knows.
Map<String, Object?> _zetaFormat() => {
  'direction': 'debit',
  'channel': 'card',
  'tokens': [
    {'op': 'match_literal', 'value': 'Paid Rs.'},
    {'op': 'capture_money', 'name': 'amount', 'maxLength': 32},
    {'op': 'match_literal', 'value': ' to '},
    {'op': 'capture_text', 'name': 'party', 'maxLength': 80},
    {'op': 'match_literal', 'value': ' from Zeta card '},
    {'op': 'capture_account', 'name': 'account', 'maxLength': 16},
    {'op': 'match_literal', 'value': '. Ref '},
    {'op': 'capture_reference', 'name': 'ref', 'maxLength': 32},
    {'op': 'match_literal', 'value': '. -Zeta'},
    {'op': 'match_end'},
  ],
  'output': {
    'amount': {'capture': 'amount'},
    'accountLast4': {
      'capture': 'account',
      'operation': 'extract_account_suffix',
      'length': 4,
    },
    'counterparty': {'capture': 'party'},
    'reference': {'capture': 'ref'},
  },
};

class _Inbox extends SmsInboxPlatform {
  _Inbox(this.rows);
  final List<InboxSms> rows;
  @override
  bool get supported => true;
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<void> setRealtimeEnabled(bool enabled) async {}
  @override
  Future<List<InboxSms>> readPage({
    required int afterId,
    required int since,
  }) async => [
    for (final row in rows)
      if (row.id > afterId) row,
  ];
}

void main() {
  late AppDatabase db;
  late AgentTools tools;

  Future<Map<String, Object?>> call(
    String name, [
    Map<String, Object?> args = const {},
  ]) async {
    final result = await tools.call(name, args);
    final text = ((result['content'] as List).single as Map)['text'] as String;
    if (result['isError'] == true) return {'error': text};
    return Map<String, Object?>.from(jsonDecode(text) as Map);
  }

  Map<String, Object?> zeta({
    Map<String, Object?>? format,
    List<String> samples = const [_sms, _other],
    String? bankName = 'Zeta',
  }) => {
    'bank_name': ?bankName,
    'senders': ['VM-ZETAPY'],
    'format': format ?? _zetaFormat(),
    'samples': [
      for (final text in samples) {'text': text},
    ],
  };

  Future<PortableParseResult> parse(String body) async =>
      (await loadSmsEngine(db)).parse(
        BankSms(sender: 'AD-ZETAPY', body: body, receivedAt: DateTime(2026)),
      );

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    tools = AgentTools(
      db,
      missedSms: (window) async => [
        for (final (i, body) in [_sms, _other].indexed)
          ReportableSms(
            '$i',
            BankSms(
              sender: 'VM-ZETAPY',
              body: body,
              receivedAt: DateTime(2026, 10, 20 + i),
            ),
            ReportableKind.missed,
            'unregisteredSender',
            null,
          ),
      ],
    );
  });

  tearDown(() => db.close());

  test('Missed messages are listed newest first, counted by sender', () async {
    final missed = await call('list_missed_sms');
    expect(missed['total'], 2);
    expect(missed['by_sender'], {'ZETAPY': 2});
    expect(((missed['messages'] as List).first as Map)['text'], _other);
  });

  test(
    'A rule is tested in the app’s parser and reports what it read',
    () async {
      final trial = await call('test_parser_rule', zeta());
      expect(trial['bank_name'], 'Zeta');
      expect(trial['senders'], ['ZETAPY']);
      expect(trial['all_samples_read_by_new_rule'], isTrue);
      final first = ((trial['samples'] as List).first as Map)['read'] as Map;
      expect(first['amount'], '1250.00');
      expect(first['counterparty'], 'Blue Tokai Coffee');
      expect(first['account_last4'], '4321');
      expect(first['reference'], '99887766');
      // Testing saves nothing.
      expect(await UserSmsRuleRepository(db).load(), isEmpty);
    },
  );

  test('Mistakes come back as messages the AI app can act on', () async {
    final noEnd = _zetaFormat();
    (noEnd['tokens'] as List).removeRange(8, 10);
    expect(
      (await call('test_parser_rule', zeta(format: noEnd)))['error'],
      'The rule isn’t valid: Captures must be followed by a literal or '
      'message end.',
    );
    expect(
      (await call('test_parser_rule', zeta(bankName: null)))['error'],
      startsWith('Give bank_name'),
    );
    final partly = await call(
      'suggest_parser_rule',
      zeta(samples: [_sms, 'Paid Rs.10 to X via UPI. -Zeta']),
    );
    expect(partly['error'], startsWith('The rule didn’t read sample 1'));
  });

  test('A sender a bundled bank uses keeps that bank’s name', () async {
    final rules = await call('get_parser_rules', {'sender': 'FEDBNK'});
    expect(rules['bank'], 'Federal Bank');
    expect(rules['bundled_formats'], isNotEmpty);

    final format = _zetaFormat()
      ..['tokens'] = [
        {'op': 'match_literal', 'value': 'Fed spend of Rs '},
        {'op': 'capture_money', 'name': 'amount', 'maxLength': 32},
        {'op': 'match_literal', 'value': ' at '},
        {'op': 'capture_text', 'name': 'party', 'maxLength': 80},
        {'op': 'match_literal', 'value': ' on card '},
        {'op': 'capture_account', 'name': 'account', 'maxLength': 16},
        {'op': 'match_literal', 'value': ' ref '},
        {'op': 'capture_reference', 'name': 'ref', 'maxLength': 32},
        {'op': 'match_end'},
      ];
    final trial = await call('test_parser_rule', {
      'bank_name': 'My Fed',
      'senders': ['FEDBNK'],
      'format': format,
      'samples': [
        {'text': 'Fed spend of Rs 300.00 at Cafe X on card XX1111 ref R9'},
      ],
    });
    expect(trial['bank_name'], 'Federal Bank');
    expect(trial['all_samples_read_by_new_rule'], isTrue);
  });

  test('An approved rule joins the parser, and undo takes it out', () async {
    expect((await parse(_sms)).candidate, isNull);

    expect((await call('suggest_parser_rule', zeta()))['suggested'], 1);
    final repository = AgentSuggestionRepository(db);
    final [suggestion] = await repository.load();
    expect(suggestion.kind, AgentSuggestionKind.parserRule);
    expect(suggestion.summary, 'New SMS rule · Zeta');
    expect(suggestion.detail[1], 'Reads: amount, account, payee, reference');
    // Suggesting changes nothing.
    expect(await UserSmsRuleRepository(db).load(), isEmpty);

    expect(await repository.apply(suggestion.id), isNull);
    final parsed = await parse(_other);
    expect(parsed.candidate?.amountMinor, 8900);
    expect(parsed.candidate?.bankName, 'Zeta');
    expect(parsed.ruleId, startsWith('user.zeta.r'));

    // The real-time path finds it for this sender alone.
    final realtime = await loadBundledSmsEngineFor(
      'ZETAPY',
      userPack: await userSmsPack(db),
    );
    expect(realtime, isNotNull);

    final [applied] = await repository.load();
    expect(applied.canUndo, isTrue);
    expect(await repository.undo(applied.id), isNull);
    expect(await UserSmsRuleRepository(db).load(), isEmpty);
    expect((await parse(_sms)).candidate, isNull);
  });

  test('A rule the bundled packs already have can’t be saved twice', () async {
    final rules = await call('get_parser_rules', {'sender': 'FEDBNK'});
    final bundled = (rules['bundled_formats'] as List).first as Map;
    final trial = await call('test_parser_rule', {
      'senders': ['FEDBNK'],
      'format': {
        'direction': bundled['direction'],
        'channel': bundled['channel'],
        'tokens': bundled['tokens'],
        'output': bundled['output'],
        if (bundled['requires'] case [_, final Map format]) 'requires': format,
      },
      'samples': [
        {'text': 'anything'},
      ],
    });
    expect(trial['error'], startsWith('The rule clashes with an existing one'));
  });

  test(
    'Approving a rule reads the inbox again and queues what it reads',
    () async {
      final store = SmsImportStore(
        SmsImportRepository(db),
        platform: _Inbox([
          InboxSms(
            1,
            BankSms(
              sender: 'VM-ZETAPY',
              body: _sms,
              receivedAt: DateTime(2026, 10, 20),
            ),
          ),
        ]),
        autoImport: false,
      );
      addTearDown(store.dispose);
      await SmsImportRepository(db).enable(true);
      await store.initialize();
      expect(store.pendingCount, 0);

      await call('suggest_parser_rule', zeta());
      expect(await AgentSuggestionRepository(db).applyAll(), (1, 0));
      await store.rulesChanged();
      expect(store.pendingCount, 1);
      expect(store.pending.single.title, 'Blue Tokai Coffee');
    },
  );

  test(
    'A sample saved from the rule card isn’t queued again by the rule',
    () async {
      final store = SmsImportStore(
        SmsImportRepository(db),
        platform: _Inbox([
          InboxSms(
            1,
            BankSms(
              sender: 'VM-ZETAPY',
              body: _sms,
              receivedAt: DateTime(2026, 10, 20),
            ),
          ),
        ]),
        autoImport: false,
      );
      addTearDown(store.dispose);
      await SmsImportRepository(db).enable(true);
      await store.initialize();

      await call('suggest_parser_rule', zeta());
      final repository = AgentSuggestionRepository(db);
      final rule = (await repository.load()).single;
      await AccountRepository(db)
          .save(name: 'Bank', currency: 'INR', digits: 2, openingBalance: 0);
      final account = (await AccountRepository(db).load()).single;
      final category = (await CategoryRepository(
        db,
      ).load()).firstWhere((c) => c.type == CategoryType.expense);
      final id = await repository.saveRuleSample(
        rule.id,
        type: TransactionType.expense,
        amountMinor: 45000,
        accountId: account.id,
        categoryId: category.id,
        title: 'Blue Tokai Coffee',
        date: DateTime(2026, 10, 20),
      );
      await expectLater(
        repository.saveRuleSample(
          rule.id,
          type: TransactionType.expense,
          amountMinor: 45000,
          accountId: account.id,
          categoryId: category.id,
          date: DateTime(2026, 10, 20),
        ),
        throwsStateError,
      );

      expect(await repository.applyAll(), (1, 0));
      await store.rulesChanged();
      expect(store.pendingCount, 0);
      final linked = await db
          .customSelect(
            "SELECT count(*) AS n FROM sms_imports WHERE transaction_id = ? AND fingerprint NOT LIKE 'sample:%'",
            variables: [Variable(id)],
          )
          .getSingle();
      expect(linked.read<int>('n'), 1);
    },
  );
}
