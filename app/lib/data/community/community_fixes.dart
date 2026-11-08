import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../db/app_database.dart';
import '../sms_inbox_platform.dart';
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
              variables: [
                Variable(kind?.id),
                Variable(includeOff),
              ],
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

  /// Shared layouts by header signature, as saved mappings are stored.
  Future<Map<String, Object?>> statementLayouts() async => {
    for (final fix in await load(kind: CommunityKind.statementLayout))
      fix.payload['signature'] as String: fix.payload['mapping'],
  };

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
      for (final (i, fix) in fixes.indexed)
        if (!own.contains(_canonical(fix.payload['format'])))
          _asRule(i, fix.payload),
    ];
    if (rules.isEmpty) return null;
    try {
      return jsonEncode(
        compileUserSmsRules(
          await indiaRuleSource(),
          rules,
          prefix: 'community',
        ).toJson(),
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
    SmsInboxPlatform? inbox,
    this.baseUrl = communityUrl,
    DateTime Function()? now,
  }) : inbox = inbox ?? SmsInboxPlatform(),
       _now = now ?? DateTime.now;
  final AppDatabase database;

  /// For tests; each call opens its own otherwise.
  final http.Client? client;
  final SmsInboxPlatform inbox;
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

  /// How far back a format's fixed text is looked for.
  static const repeatWindow = Duration(days: 180);

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
    final country = await indiaRuleSource();
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
        compileUserSmsRules(country, [
          _asRule(i, payload),
        ], prefix: 'community');
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
          payload: {
            'signature': item['signature'],
            'mapping': item['mapping'],
          },
        ),
      );
    }
    return fixes;
  }

  /// Shares fixes the user chose to share. They wait in a queue until the
  /// phone is online.
  Future<void> share(
    List<(CommunityKind, Map<String, Object?>)> fixes,
  ) async {
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

  /// Sends what's queued. Kept for later when offline; an SMS format that
  /// fails the repeat check is dropped.
  Future<void> flush() async {
    while (_flushing != null) {
      await _flushing;
    }
    final done = Completer<void>();
    _flushing = done.future;
    try {
      await _flush();
    } catch (_) {
      // Tried again on the next start.
    } finally {
      _flushing = null;
      done.complete();
    }
  }

  Future<void> _flush() async {
    final prefs = await SharedPreferences.getInstance();
    final queued = prefs.getStringList(outboxKey) ?? const [];
    if (queued.isEmpty) return;
    final items = <Map<String, Object?>>[];
    for (final text in queued.take(20)) {
      final item = Map<String, Object?>.from(jsonDecode(text) as Map);
      final payload = Map<String, Object?>.from(item['payload'] as Map);
      if (item['kind'] == CommunityKind.smsRule.id &&
          !await repeatsInInbox(payload)) {
        continue;
      }
      items.add(item);
    }
    if (items.isNotEmpty) {
      final body = jsonEncode({
        'install': await _install(prefs),
        'appVersion': await _appVersion(),
        'items': items,
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
    }
    await prefs.setStringList(
      outboxKey,
      (prefs.getStringList(outboxKey) ?? const []).skip(queued.take(20).length).toList(),
    );
  }

  /// Whether every piece of fixed text in an SMS format shows up in two or
  /// more of that bank's messages on this phone. Bank wording repeats; a
  /// name or reference copied by mistake usually doesn't, so a format
  /// carrying one stays on this phone. Without SMS access nothing is shared.
  Future<bool> repeatsInInbox(Map<String, Object?> payload) async {
    final senders = {
      for (final s in (payload['senders'] as List? ?? const [])) '$s',
    };
    final literals = _fixedText(payload['format'])
        .map(_plain)
        .where((t) => t.contains(RegExp('[a-z]')))
        .toSet();
    if (literals.isEmpty) return true;
    if (senders.isEmpty ||
        !inbox.supported ||
        !await inbox.hasPermission()) {
      return false;
    }
    final seen = {for (final t in literals) t: 0};
    final since = _now().subtract(repeatWindow).millisecondsSinceEpoch;
    var after = 0;
    // Up to 10,000 messages, newest pages last.
    for (var page = 0; page < 50; page++) {
      final rows = await inbox.readPage(afterId: after, since: since);
      if (rows.isEmpty) break;
      for (final row in rows) {
        after = max(after, row.id);
        if (!senders.contains(normalizeRuleSender(row.sms.sender))) continue;
        final body = _plain(row.sms.body);
        for (final text in literals) {
          if (body.contains(text)) seen[text] = seen[text]! + 1;
        }
      }
      if (seen.values.every((n) => n >= 2)) return true;
    }
    return seen.values.every((n) => n >= 2);
  }

  /// The user turned a shared fix off: it stops being used here, and the
  /// server hears that it read messages wrong.
  Future<void> turnOff(String hash) async {
    await repository.setOff(hash, true);
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
  Future<String> _install(SharedPreferences prefs) async {
    if (prefs.getString(installKey) case final id?) return id;
    final random = Random.secure();
    final id = [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    await prefs.setString(installKey, id);
    return id;
  }

  Future<String?> _appVersion() async {
    try {
      return (await PackageInfo.fromPlatform()).version;
    } catch (_) {
      return null;
    }
  }
}

/// A format's fixed text: its literals and its "requires" selectors.
Iterable<String> _fixedText(Object? format) sync* {
  if (format is! Map) return;
  for (final token in (format['tokens'] as List?) ?? const []) {
    if (token is Map && token['op'] == 'match_literal') {
      if (token['value'] case final String value) yield value;
    }
  }
  if (format['requires'] case final Map requires) {
    for (final list in requires.values) {
      if (list is List) yield* list.whereType<String>();
    }
  }
}

/// Text as a literal matches it: letters in any case, spaces collapsed.
String _plain(String text) =>
    text.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
