import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../db/app_database.dart';
import '../statements/statement_table.dart';
import '../user_sms_rules.dart';

/// Where shared fixes live (community/README.md). `FIXES_URL` in `.env`
/// points a build elsewhere. Not COMMUNITY_URL: that's the Telegram group.
const communityUrl = String.fromEnvironment(
  'FIXES_URL',
  defaultValue: 'https://simplemoney-community.aashglobal591.workers.dev',
);

enum CommunityKind {
  smsRule('sms_rule'),
  statementLayout('statement_layout');

  const CommunityKind(this.id);
  final String id;

  static CommunityKind? byId(Object? id) =>
      values.where((k) => k.id == id).firstOrNull;
}

/// One fix another user taught the app, as downloaded.
class CommunityFix {
  const CommunityFix({
    required this.hash,
    required this.kind,
    required this.payload,
    this.off = false,
  });
  final String hash;
  final CommunityKind kind;

  /// SMS: `{bankName, senders, format}`. Statement: `{signature, mapping}`.
  final Map<String, dynamic> payload;

  /// The user turned it off on this phone.
  final bool off;

  /// The bank, or the statement's first columns.
  String get title => switch (kind) {
    CommunityKind.smsRule => payload['bankName'] as String? ?? 'Bank SMS',
    CommunityKind.statementLayout => () {
      final cells = (payload['signature'] as String? ?? '')
          .split('|')
          .where((c) => c.isNotEmpty);
      return cells.take(3).join(' · ') + (cells.length > 3 ? ' …' : '');
    }(),
  };
}

/// JSON with object keys sorted at every level, so equal formats compare
/// equal however they were written.
String _canonical(Object? value) => switch (value) {
  final Map<Object?, Object?> map =>
    '{${(map.keys.map((k) => '$k').toList()..sort()).map((k) => '${jsonEncode(k)}:${_canonical(map[k])}').join(',')}}',
  final List<Object?> list => '[${list.map(_canonical).join(',')}]',
  _ => jsonEncode(value),
};

/// How often a shared fix was used here, and the rule IDs it read under.
class FixUse {
  const FixUse(this.count, this.ruleIds);
  final int count;
  final List<String> ruleIds;
}

/// A message a shared SMS fix read on this phone. Once saved, its text comes
/// from the transaction's note, where the app keeps the original SMS;
/// [body] is null only when that note was edited away.
class FixSample {
  const FixSample({
    required this.id,
    required this.sender,
    required this.body,
    required this.candidate,
    required this.receivedAt,
    this.transactionId,
  });

  /// The message's fingerprint in the SMS queue.
  final String id;
  final String sender;
  final String? body;

  /// What the fix read. After saving, only a few keys are left: the
  /// transaction ([transactionId]) then says what it became.
  final Map<String, dynamic> candidate;
  final DateTime receivedAt;
  final int? transactionId;
}

/// The downloaded fixes, kept in the database so the background SMS handler
/// can use them too.
class CommunityFixRepository {
  CommunityFixRepository(this.database);
  final AppDatabase database;

  Future<List<CommunityFix>> load({
    CommunityKind? kind,
    bool includeOff = false,
  }) async => [
    for (final r
        in await database
            .customSelect(
              'SELECT * FROM community_fixes WHERE (?1 IS NULL OR kind = ?1) '
              'AND (?2 OR off = 0) ORDER BY kind, payload',
              variables: [Variable(kind?.id), Variable(includeOff)],
            )
            .get())
      if (CommunityKind.byId(r.read<String>('kind')) case final kind?)
        CommunityFix(
          hash: r.read<String>('hash'),
          kind: kind,
          payload:
              jsonDecode(r.read<String>('payload')) as Map<String, dynamic>,
          off: r.read<int>('off') == 1,
        ),
  ];

  /// Replaces the downloaded set. Fixes the user turned off stay, still off,
  /// so a later download can't bring them back. Returns whether the SMS rules
  /// in use changed.
  Future<bool> replace(List<CommunityFix> fixes) async {
    final before = await signature();
    await database.transaction(() async {
      await database.customStatement(
        'DELETE FROM community_fixes WHERE off = 0',
      );
      for (final fix in fixes) {
        await database.customStatement(
          'INSERT OR IGNORE INTO community_fixes (hash, kind, payload) '
          'VALUES (?, ?, ?)',
          [fix.hash, fix.kind.id, jsonEncode(fix.payload)],
        );
      }
    });
    return await signature() != before;
  }

  Future<void> setOff(String hash, bool off) => database.customStatement(
    'UPDATE community_fixes SET off = ? WHERE hash = ?',
    [off ? 1 : 0, hash],
  );

  /// Changes whenever the shared SMS rules in use change, so the SMS review
  /// knows to read pending messages again.
  Future<String> signature() async =>
      (await database
              .customSelect(
                "SELECT coalesce(group_concat(hash), '') AS hashes FROM "
                "(SELECT hash FROM community_fixes WHERE kind = 'sms_rule' "
                'AND off = 0 ORDER BY hash)',
              )
              .getSingle())
          .read<String>('hashes');

  static const _usedLayoutsKey = 'community.used_layouts';

  /// A shared statement layout read a file here.
  Future<void> noteLayoutUsed(String signature) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final used = {...?prefs.getStringList(_usedLayoutsKey)};
      if (used.add(signature)) {
        await prefs.setStringList(_usedLayoutsKey, used.toList());
      }
    } catch (_) {}
  }

  /// How each shared fix was used on this phone, by hash: the messages an SMS
  /// format read (and the rule IDs it read them under), or 1 for a statement
  /// layout that read a file. Unused ones are left out.
  Future<Map<String, FixUse>> uses(List<CommunityFix> fixes) async {
    final counts = {
      for (final r
          in await database
              .customSelect(
                "SELECT rule_id, count(*) AS n FROM sms_imports WHERE rule_id LIKE 'community.%' GROUP BY rule_id",
              )
              .get())
        r.read<String>('rule_id'): r.read<int>('n'),
    };
    var layouts = const <String>{};
    try {
      final prefs = await SharedPreferences.getInstance();
      layouts = {...?prefs.getStringList(_usedLayoutsKey)};
    } catch (_) {}
    // Messages read before rule IDs came from the hash carry an index
    // instead: they count for their bank's fix when it has only one.
    final current = {
      for (final fix in fixes)
        if (fix.kind == CommunityKind.smsRule) ruleId(fix),
    };
    final bankOf = <String, List<CommunityFix>>{};
    for (final fix in fixes) {
      if (fix.kind != CommunityKind.smsRule) continue;
      final id = ruleId(fix);
      bankOf
          .putIfAbsent(id.substring(0, id.lastIndexOf('.')), () => [])
          .add(fix);
    }
    final legacy = <String, List<String>>{};
    for (final id in counts.keys) {
      if (current.contains(id) || !id.contains('.')) continue;
      if (bankOf[id.substring(0, id.lastIndexOf('.'))] case [final only]) {
        legacy.putIfAbsent(only.hash, () => []).add(id);
      }
    }
    final uses = <String, FixUse>{};
    for (final fix in fixes) {
      switch (fix.kind) {
        case CommunityKind.smsRule:
          final ids = [ruleId(fix), ...?legacy[fix.hash]];
          final n = ids.fold(0, (sum, id) => sum + (counts[id] ?? 0));
          if (n > 0) uses[fix.hash] = FixUse(n, ids);
        case CommunityKind.statementLayout:
          if (layouts.contains(fix.payload['signature'])) {
            uses[fix.hash] = const FixUse(1, []);
          }
      }
    }
    return uses;
  }

  /// The latest message [use] read here, preferring one whose text is still
  /// kept: what it said, and what the rule made of it.
  Future<FixSample?> sample(FixUse use) async {
    if (use.ruleIds.isEmpty) return null;
    // A saved one first: what it became is the entry the user kept.
    final row = await database
        .customSelect(
          'SELECT i.fingerprint, i.sender, i.body, i.candidate, i.received_at, '
          't.id AS transaction_id, t.note FROM sms_imports i '
          'LEFT JOIN transactions t ON t.id = i.transaction_id '
          'WHERE i.rule_id IN (${List.filled(use.ruleIds.length, '?').join(',')}) '
          'ORDER BY t.id IS NULL, i.received_at DESC LIMIT 1',
          variables: [for (final id in use.ruleIds) Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) return null;
    return FixSample(
      id: row.read<String>('fingerprint'),
      transactionId: row.readNullable<int>('transaction_id'),
      sender: row.read<String>('sender'),
      body:
          row.readNullable<String>('body') ??
          _smsInNote(row.readNullable<String>('note')),
      candidate: Map<String, dynamic>.from(
        jsonDecode(row.read<String>('candidate')) as Map,
      ),
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('received_at'),
      ),
    );
  }

  /// The SMS a saved transaction's note keeps: "Sender: X", a blank line,
  /// then the text.
  static String? _smsInNote(String? note) {
    if (note == null || !note.startsWith('Sender: ')) return null;
    final at = note.indexOf('\n\n');
    final text = at < 0 ? '' : note.substring(at + 2).trim();
    return text.isEmpty ? null : text;
  }

  /// The rule ID an SMS fix reads messages under, from its hash so it stays
  /// the same across downloads.
  static String ruleId(CommunityFix fix) => userSmsRuleId(
    fix.payload['bankName'] as String? ?? 'bank',
    _label(fix.hash),
    prefix: 'community',
    country: switch (fix.payload['format']) {
      final Map format => ruleCountry(Map<String, dynamic>.from(format)),
      _ => 'IN',
    },
  );

  static int _label(String hash) => int.parse(hash.substring(0, 12), radix: 16);

  /// Shared layouts by header signature, as saved mappings are stored.
  Future<Map<String, Object?>> statementLayouts() async => {
    for (final fix in await load(kind: CommunityKind.statementLayout))
      fix.payload['signature'] as String: fix.payload['mapping'],
  };

  /// The shared SMS rules, for what they say about their senders.
  Future<List<UserSmsRule>> smsRules() async => [
    for (final fix in await load(kind: CommunityKind.smsRule))
      _asRule(_label(fix.hash), fix.payload),
  ];

  /// The shared SMS rules in use as one runtime pack, or null. Formats the
  /// user already has are left out (the same pattern twice won't compile);
  /// a set that still doesn't compile is left out whole.
  Future<String?> runtimePack() async {
    final fixes = await load(kind: CommunityKind.smsRule);
    if (fixes.isEmpty) return null;
    final own = {
      for (final rule in await UserSmsRuleRepository(database).load())
        _canonical(rule.format),
    };
    final rules = [
      for (final fix in fixes)
        if (!own.contains(_canonical(fix.payload['format'])))
          _asRule(_label(fix.hash), fix.payload),
    ];
    if (rules.isEmpty) return null;
    try {
      return jsonEncode(
        (await compileUserSmsRules(rules, prefix: 'community')).toJson(),
      );
    } catch (_) {
      return null;
    }
  }
}

UserSmsRule _asRule(int id, Map<String, dynamic> payload) => UserSmsRule(
  id: id,
  bankName: payload['bankName'] as String,
  senders: (payload['senders'] as List).cast(),
  format: Map<String, dynamic>.from(payload['format'] as Map),
  samples: const [],
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
);

/// Talks to the community server: downloads the shared fixes for everyone,
/// and sends a fix of the user's own when they chose to share it. Never
/// sends messages, amounts or names; see `community/README.md`.
class CommunitySync {
  CommunitySync(
    this.database, {
    this.client,
    this.baseUrl = communityUrl,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;
  final AppDatabase database;

  /// For tests; each call opens its own otherwise.
  final http.Client? client;
  final String baseUrl;
  final DateTime Function() _now;

  late final repository = CommunityFixRepository(database);

  static const etagKey = 'community.etag';
  static const checkedKey = 'community.checked_at';
  static const installKey = 'community.install';
  static const outboxKey = 'community.outbox';

  /// About once a day: the pack changes when a fix is approved.
  static const refreshEvery = Duration(hours: 20);
  static const _timeout = Duration(seconds: 20);
  static const _maxOutbox = 50;

  /// One send at a time, across every instance.
  static Future<void>? _flushing;

  Future<T> _withClient<T>(Future<T> Function(http.Client) run) async {
    final client = this.client ?? http.Client();
    try {
      return await run(client);
    } finally {
      if (this.client == null) client.close();
    }
  }

  /// Downloads the shared fixes when the last check is old enough. True when
  /// the SMS rules in use changed, so messages should be read again. Never
  /// throws: being offline just means trying again later.
  Future<bool> refresh({bool force = false}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = _now().millisecondsSinceEpoch;
      final checked = prefs.getInt(checkedKey);
      if (!force &&
          checked != null &&
          now - checked < refreshEvery.inMilliseconds) {
        return false;
      }
      final etag = prefs.getString(etagKey);
      final response = await _withClient(
        (client) => client
            .get(
              Uri.parse('$baseUrl/v1/pack'),
              headers: {'If-None-Match': ?etag},
            )
            .timeout(_timeout),
      );
      if (response.statusCode == 304) {
        await prefs.setInt(checkedKey, now);
        return false;
      }
      if (response.statusCode != 200) return false;
      final fixes = await _read(jsonDecode(utf8.decode(response.bodyBytes)));
      if (fixes == null) return false;
      final changed = await repository.replace(fixes);
      if (response.headers['etag'] case final tag?) {
        await prefs.setString(etagKey, tag);
      }
      await prefs.setInt(checkedKey, now);
      return changed;
    } catch (_) {
      return false;
    }
  }

  /// The pack's fixes that this app can use. Anything malformed, or an SMS
  /// format this version can't compile, is skipped rather than trusted.
  Future<List<CommunityFix>?> _read(Object? pack) async {
    if (pack is! Map) return null;
    final hash = RegExp(r'^[a-f0-9]{64}$');
    final fixes = <CommunityFix>[];
    for (final (i, item) in ((pack['sms'] as List?) ?? const []).indexed) {
      if (item is! Map ||
          item['hash'] is! String ||
          !hash.hasMatch(item['hash'] as String) ||
          item['bankName'] is! String ||
          item['senders'] is! List ||
          item['format'] is! Map) {
        continue;
      }
      final payload = {
        'bankName': item['bankName'],
        'senders': [
          for (final s in item['senders'] as List)
            if (s is String) s,
        ],
        'format': item['format'],
      };
      try {
        await compileUserSmsRules([_asRule(i, payload)], prefix: 'community');
      } catch (_) {
        continue;
      }
      fixes.add(
        CommunityFix(
          hash: item['hash'] as String,
          kind: CommunityKind.smsRule,
          payload: payload,
        ),
      );
    }
    for (final item in (pack['statements'] as List?) ?? const []) {
      if (item is! Map ||
          item['hash'] is! String ||
          !hash.hasMatch(item['hash'] as String) ||
          item['signature'] is! String ||
          (item['signature'] as String).isEmpty ||
          TableMapping.fromJson(item['mapping'], 0)?.isComplete != true) {
        continue;
      }
      fixes.add(
        CommunityFix(
          hash: item['hash'] as String,
          kind: CommunityKind.statementLayout,
          payload: {'signature': item['signature'], 'mapping': item['mapping']},
        ),
      );
    }
    return fixes;
  }

  static const sentRulesKey = 'community.sent_rules';
  static const keptRulesKey = 'community.kept_rules';

  /// New messages a rule taught on this phone must read before it's sent.
  static const provenAfter = 2;

  /// The same SMS rule, however it was written, gets the same key.
  static String ruleKey(Map<String, Object?> fix) => sha256
      .convert(
        utf8.encode(
          _canonical({
            'bankName': fix['bankName'],
            'senders': fix['senders'],
            'format': fix['format'],
          }),
        ),
      )
      .toString();

  /// Remembers SMS rules already sent ([sent]) or that the user chose not to
  /// share ([kept]), so [shareProvenRules] leaves them alone.
  static Future<void> noteRules(
    Iterable<Map<String, Object?>> fixes, {
    required bool sent,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = sent ? sentRulesKey : keptRulesKey;
      await prefs.setStringList(
        key,
        {
          ...?prefs.getStringList(key),
          for (final fix in fixes) ruleKey(fix),
        }.toList(),
      );
    } catch (_) {}
  }

  /// Sends the user's own SMS rules that have read at least [provenAfter]
  /// new messages since they were taught, to wait on the dashboard until
  /// checked. Only the format goes (fixed bank text and sender IDs), never
  /// the messages, amounts, names or account digits it reads. Rules the user
  /// chose not to share, and ones already sent, are skipped. Never throws.
  Future<void> shareProvenRules() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final skip = {
        ...?prefs.getStringList(sentRulesKey),
        ...?prefs.getStringList(keptRulesKey),
      };
      final proven = <Map<String, Object?>>[];
      for (final rule in await UserSmsRuleRepository(database).load()) {
        final fix = <String, Object?>{
          'bankName': rule.bankName,
          'senders': rule.senders,
          'format': rule.format,
        };
        if (skip.contains(ruleKey(fix))) continue;
        final read = await database
            .customSelect(
              'SELECT count(*) AS n FROM sms_imports WHERE rule_id = ? '
              "AND received_at > ? AND status != 'dismissed'",
              variables: [
                Variable(
                  userSmsRuleId(
                    rule.bankName,
                    rule.id,
                    country: ruleCountry(rule.format),
                  ),
                ),
                Variable(rule.createdAt.millisecondsSinceEpoch),
              ],
            )
            .getSingle();
        if (read.read<int>('n') >= provenAfter) proven.add(fix);
      }
      if (proven.isEmpty) return;
      await noteRules(proven, sent: true);
      await share([for (final fix in proven) (CommunityKind.smsRule, fix)]);
    } catch (_) {}
  }

  /// Shares fixes the user chose to share. They wait in a queue until the
  /// phone is online.
  Future<void> share(List<(CommunityKind, Map<String, Object?>)> fixes) async {
    if (fixes.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final outbox = [
        ...?prefs.getStringList(outboxKey),
        for (final (kind, payload) in fixes)
          jsonEncode({'kind': kind.id, 'payload': payload}),
      ];
      await prefs.setStringList(
        outboxKey,
        outbox.sublist(max(0, outbox.length - _maxOutbox)),
      );
    } catch (_) {
      return;
    }
    await flush();
  }

  /// Sends what's queued. Offline, it all waits until the phone is back
  /// online or the app next starts. Every fix is checked on the dashboard
  /// before it goes live, so nothing is held back here.
  Future<void> flush() async {
    while (_flushing != null) {
      await _flushing;
    }
    final done = Completer<void>();
    _flushing = done.future;
    try {
      await _flush();
    } catch (_) {
      // Tried again when back online, or on the next start.
    } finally {
      _flushing = null;
      done.complete();
    }
  }

  Future<void> _flush() async {
    final prefs = await SharedPreferences.getInstance();
    final queued = prefs.getStringList(outboxKey) ?? const [];
    if (queued.isEmpty) return;
    final batch = queued.take(20).toList();
    final body = jsonEncode({
      'install': await _install(prefs),
      'appVersion': await _appVersion(),
      'items': [
        for (final text in batch)
          if (jsonDecode(text) case final Map item)
            {'kind': item['kind'], 'payload': item['payload']},
      ],
    });
    final response = await _withClient(
      (client) => client
          .post(
            Uri.parse('$baseUrl/v1/submit'),
            headers: {'Content-Type': 'application/json'},
            body: body,
          )
          .timeout(_timeout),
    );
    // A refused fix (400) won't do better next time; anything else will.
    if (response.statusCode != 200 && response.statusCode != 400) return;
    // Fixes shared while this ran were added after the batch.
    await prefs.setStringList(
      outboxKey,
      (prefs.getStringList(outboxKey) ?? const []).skip(batch.length).toList(),
    );
  }

  /// The user turned a shared fix off: it stops being used here. With
  /// [report], the server also hears that it read messages wrong.
  Future<void> turnOff(String hash, {bool report = true}) async {
    await repository.setOff(hash, true);
    if (!report) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final body = jsonEncode({'install': await _install(prefs), 'hash': hash});
      await _withClient(
        (client) => client
            .post(
              Uri.parse('$baseUrl/v1/report'),
              headers: {'Content-Type': 'application/json'},
              body: body,
            )
            .timeout(_timeout),
      );
    } catch (_) {}
  }

  Future<void> turnOn(String hash) => repository.setOff(hash, false);

  /// A random ID made once, so the same phone sending a fix twice counts
  /// once. It says nothing about the user.
  Future<String> _install(SharedPreferences prefs) => communityInstallId(prefs);

  Future<String?> _appVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return null;
    }
  }
}

/// The random ID this phone sends the community server, made once.
Future<String> communityInstallId(SharedPreferences prefs) async {
  if (prefs.getString(CommunitySync.installKey) case final id?) return id;
  final random = Random.secure();
  final id = [
    for (var i = 0; i < 16; i++)
      random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ].join();
  await prefs.setString(CommunitySync.installKey, id);
  return id;
}
