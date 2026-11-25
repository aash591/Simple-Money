import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/agent/agent_suggestion_repository.dart';
import 'package:simple_money/data/community/community_fixes.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/statement_import_repository.dart';
import 'package:simple_money/data/user_sms_rules.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:simple_money/ui/more/ai/share_fix_prompt.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

const _sms =
    'Paid Rs.1,250.00 to Blue Tokai Coffee from Zeta card XX4321. '
    'Ref 99887766. -Zeta';
const _other =
    'Paid Rs.89.00 to Metro Rail from Zeta card XX4321. Ref A1B2C3. -Zeta';

/// A format for Zeta, a card no bundled pack knows.
Map<String, Object?> _zeta({String to = ' to '}) => {
  // As an approved rule is saved (AgentRuleLab adds it).
  'classification': 'completed',
  'direction': 'debit',
  'channel': 'card',
  'tokens': [
    {'op': 'match_literal', 'value': 'Paid Rs.'},
    {'op': 'capture_money', 'name': 'amount', 'maxLength': 32},
    {'op': 'match_literal', 'value': to},
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

final _hashA = 'a' * 64, _hashB = 'b' * 64, _hashC = 'c' * 64;
const _signature = 'txn date|narration|withdrawal|deposit|balance';

Map<String, Object?> _pack({int version = 1}) => {
  'version': version,
  'sms': [
    {
      'hash': _hashA,
      'bankName': 'Zeta',
      'senders': ['ZETAPY'],
      'format': _zeta(),
    },
    // Doesn't compile: skipped, not trusted.
    {
      'hash': _hashB,
      'bankName': 'Broken',
      'senders': ['BRKBNK'],
      'format': {
        'tokens': [
          {'op': 'nonsense'},
        ],
      },
    },
  ],
  'statements': [
    {
      'hash': _hashC,
      'signature': _signature,
      'mapping': {
        'columns': {
          'date': 0,
          'description': 1,
          'debit': 2,
          'credit': 3,
          'balance': 4,
        },
        'dateOrder': 'dayFirst',
        'fallback': 'debit',
      },
    },
    // No amount column: incomplete.
    {
      'hash': 'd' * 64,
      'signature': 'a|b',
      'mapping': {
        'columns': {'date': 0},
      },
    },
  ],
};

/// A fake server: the pack, and what phones sent.
class _Server {
  Map<String, Object?> pack = _pack();
  String etag = '"v1"';
  bool offline = false;
  final requests = <http.Request>[];
  final submitted = <Map<String, Object?>>[];
  final reported = <Map<String, Object?>>[];

  late final client = MockClient((request) async {
    if (offline) throw http.ClientException('offline');
    requests.add(request);
    switch (request.url.path) {
      case '/v1/pack':
        if (request.headers['If-None-Match'] == etag) {
          return http.Response('', 304);
        }
        return http.Response(
          jsonEncode(pack),
          200,
          headers: {'etag': etag, 'content-type': 'application/json'},
        );
      case '/v1/submit':
        submitted.add(jsonDecode(request.body) as Map<String, Object?>);
        return http.Response('{"results":[]}', 200);
      case '/v1/report':
        reported.add(jsonDecode(request.body) as Map<String, Object?>);
        return http.Response('{"ok":true}', 200);
    }
    return http.Response('', 404);
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late _Server server;
  late DateTime now;

  CommunitySync sync() => CommunitySync(
    db,
    client: server.client,
    baseUrl: 'https://community.test',
    now: () => now,
  );

  Future<PortableParseResult> parse(String body) async =>
      (await loadSmsEngine(db)).parse(
        BankSms(sender: 'ZETAPY', body: body, receivedAt: DateTime(2026, 11)),
      );

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase(NativeDatabase.memory(), false);
    server = _Server();
    now = DateTime(2026, 11, 1, 9);
  });
  tearDown(() => db.close());

  test(
    'downloads usable fixes and reads SMS and statements with them',
    () async {
      expect((await parse(_sms)).candidate, isNull);
      expect(await sync().refresh(), isTrue);

      final fixes = await CommunityFixRepository(db).load();
      expect(fixes.map((f) => f.hash), unorderedEquals([_hashA, _hashC]));

      final parsed = await parse(_other);
      expect(parsed.candidate?.amountMinor, 8900);
      expect(parsed.ruleId, startsWith('community.zeta.r'));
      // The background path finds it for this sender alone.
      expect(
        await loadBundledSmsEngineFor(
          'ZETAPY',
          communityPack: await communitySmsPack(db),
        ),
        isNotNull,
      );

      final statements = StatementImportRepository(db);
      expect((await statements.knownMappings())[_signature], isNotNull);
      // Shared layouts are never copied into the device's own.
      expect(await statements.columnMappings(), isEmpty);
    },
  );

  test('checks about once a day, and a 304 changes nothing', () async {
    final community = sync();
    await community.refresh();
    expect(server.requests, hasLength(1));
    now = now.add(const Duration(hours: 2));
    expect(await community.refresh(), isFalse);
    expect(server.requests, hasLength(1));
    now = now.add(const Duration(hours: 20));
    expect(await community.refresh(), isFalse);
    expect(server.requests.last.headers['If-None-Match'], '"v1"');
    expect(await CommunityFixRepository(db).load(), hasLength(2));
  });

  test('offline is not an error', () async {
    server.offline = true;
    expect(await sync().refresh(force: true), isFalse);
    expect(await CommunityFixRepository(db).load(), isEmpty);
  });

  test('a format the user already has is used once, as theirs', () async {
    await UserSmsRuleRepository(db).add(
      bankName: 'Zeta',
      senders: ['ZETAPY'],
      format: _zeta(),
      samples: [_sms],
    );
    await sync().refresh();
    expect(await communitySmsPack(db), isNull);
    expect((await parse(_other)).ruleId, startsWith('user.zeta.r'));
  });

  test('turning a fix off reports it and keeps it off', () async {
    final community = sync();
    await community.refresh();
    await community.turnOff(_hashA);
    expect(server.reported.single['hash'], _hashA);
    expect(
      server.reported.single['install'],
      matches(RegExp(r'^[a-f0-9]{32}$')),
    );
    expect((await parse(_other)).candidate, isNull);

    // A new download doesn't bring it back.
    server
      ..etag = '"v2"'
      ..pack = _pack(version: 2);
    await community.refresh(force: true);
    final fixes = await CommunityFixRepository(db).load(includeOff: true);
    expect(fixes.firstWhere((f) => f.hash == _hashA).off, isTrue);
    expect((await parse(_other)).candidate, isNull);

    await community.turnOn(_hashA);
    expect((await parse(_other)).candidate, isNotNull);
  });

  test('shares an SMS format, never its messages', () async {
    final community = sync();
    await community.share([
      (
        CommunityKind.smsRule,
        {
          'bankName': 'Zeta',
          'senders': ['ZETAPY'],
          'format': _zeta(),
        },
      ),
    ]);
    final [sent] = server.submitted;
    final [item] = sent['items']! as List;
    expect((item as Map)['kind'], 'sms_rule');
    expect((item['payload'] as Map).containsKey('samples'), isFalse);
    expect(sent['install'], matches(RegExp(r'^[a-f0-9]{32}$')));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(CommunitySync.outboxKey), isEmpty);
  });

  group('a rule taught here', () {
    late int ruleId;
    var read = 0;

    Future<void> readsOne({bool dismissed = false, bool before = false}) {
      read++;
      final at = DateTime.now().add(Duration(hours: before ? -1 : 1));
      return db.customStatement(
        'INSERT INTO sms_imports (fingerprint, sender, body, received_at, '
        'candidate, rule_id, pack_version, status) '
        "VALUES (?, 'ZETAPY', ?, ?, '{}', ?, 1, ?)",
        [
          'f$read',
          _other,
          at.millisecondsSinceEpoch,
          'user.zeta.r$ruleId',
          dismissed ? 'dismissed' : 'pending',
        ],
      );
    }

    setUp(() async {
      ruleId = await UserSmsRuleRepository(db).add(
        bankName: 'Zeta',
        senders: ['ZETAPY'],
        format: _zeta(),
        samples: [_sms],
      );
    });

    test('is sent once it reads two new messages, then never again', () async {
      final community = sync();
      await readsOne(before: true);
      await readsOne(dismissed: true);
      await readsOne();
      await community.shareProvenRules();
      expect(server.submitted, isEmpty);

      await readsOne();
      await community.shareProvenRules();
      final [sent] = server.submitted;
      final [item] = sent['items']! as List;
      expect((item as Map)['kind'], 'sms_rule');
      expect(
        (item['payload'] as Map).keys,
        unorderedEquals(['bankName', 'senders', 'format']),
      );

      await readsOne();
      await community.shareProvenRules();
      expect(server.submitted, hasLength(1));
    });

    test('is not sent after the user said Not now', () async {
      await CommunitySync.noteRules([
        {
          'bankName': 'Zeta',
          'senders': ['ZETAPY'],
          'format': _zeta(),
        },
      ], sent: false);
      await readsOne();
      await readsOne();
      await sync().shareProvenRules();
      expect(server.submitted, isEmpty);
    });
  });

  test('offline sharing waits and goes on the next try', () async {
    final community = sync();
    server.offline = true;
    await community.share([
      (
        CommunityKind.statementLayout,
        {
          'signature': _signature,
          'mapping': (_pack()['statements']! as List).first['mapping'],
        },
      ),
    ]);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(CommunitySync.outboxKey), hasLength(1));

    server.offline = false;
    await community.flush();
    expect(
      ((server.submitted.single['items']! as List).single as Map)['kind'],
      'statement_layout',
    );
    expect(prefs.getStringList(CommunitySync.outboxKey), isEmpty);
  });

  AgentSuggestion rule() => AgentSuggestion(
    id: 1,
    batchId: 'b',
    kind: AgentSuggestionKind.parserRule,
    target: 't',
    payload: {
      'bankName': 'Zeta',
      'senders': ['ZETAPY'],
      'format': _zeta(),
      'samples': [_sms],
    },
    before: null,
    summary: 'New SMS rule · Zeta',
    detail: const [],
    reason: null,
    status: AgentSuggestionStatus.applied,
    error: null,
    createdAt: DateTime(2026),
    decidedAt: null,
  );

  Future<void> openPrompt(WidgetTester tester, CommunitySync community) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => offerToShareFixes(context, community, [rule()]),
            child: const Text('approve'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('approve'));
    await tester.pumpAndSettle();
  }

  testWidgets('after a fix: well done, and Share sends it', (tester) async {
    final community = sync();
    await openPrompt(tester, community);
    expect(find.text('Nice, it’s fixed!'), findsOneWidget);
    expect(
      find.textContaining('Your Zeta SMS will now be added'),
      findsOneWidget,
    );
    expect(find.textContaining('never your messages'), findsOneWidget);
    await tester.tap(find.text('Share'));
    await tester.runAsync(() async {
      for (var i = 0; i < 50 && server.submitted.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpAndSettle();
    expect(server.submitted, hasLength(1));
    expect(find.text('Thanks! You’re helping others.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('Not now shares nothing', (tester) async {
    final community = sync();
    await openPrompt(tester, community);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(server.submitted, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList(CommunitySync.outboxKey), isNull);
  });
}
