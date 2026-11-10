import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import 'db/app_database.dart';

/// One SMS format the user approved: a format of the portable rule spec
/// (tokens, output, direction, channel) for one bank's senders. These rules
/// sit beside the bundled packs and are compiled with India's defaults and
/// classifiers, so OTPs, offers and declined payments are still rejected.
class UserSmsRule {
  const UserSmsRule({
    required this.id,
    required this.bankName,
    required this.senders,
    required this.format,
    required this.samples,
    required this.createdAt,
  });
  final int id;
  final String bankName;

  /// Canonical sender IDs (see `normalizeRuleSender`).
  final List<String> senders;

  /// The format without its `id` or `senders`; the compiler adds both.
  final Map<String, dynamic> format;

  /// The messages it was tested against when it was approved.
  final List<String> samples;
  final DateTime createdAt;
}

const _countryAsset =
    'packages/universal_bank_sms_parser/rules/india/country.json';
Map<String, dynamic>? _country;

/// India's source file, whose defaults and classifiers user rules inherit.
Future<Map<String, dynamic>> indiaRuleSource() async => _country ??= jsonDecode(
  await rootBundle.loadString(_countryAsset),
) as Map<String, dynamic>;

/// `user.<bank>`, so a user rule never shares an ID with a bundled one.
/// Shared rules from other users use the `community` prefix.
String userSmsBankId(String bankName, {String prefix = 'user'}) {
  final slug = bankName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return '$prefix.${slug.isEmpty ? 'bank' : slug}';
}

/// The rule ID a format gets: its bank's ID and its row (or any label).
String userSmsRuleId(String bankName, Object label, {String prefix = 'user'}) =>
    '${userSmsBankId(bankName, prefix: prefix)}.r$label';

/// Compiles [rules] into one runtime pack. [extra] is a rule being tried,
/// keyed by its label. Throws [RuleValidationException] for a bad format.
RuntimeRulePack compileUserSmsRules(
  Map<String, dynamic> country,
  List<UserSmsRule> rules, {
  (String label, String bankName, List<String> senders, Map<String, dynamic>)?
  extra,
  String prefix = 'user',
}) {
  final banks = <String, Map<String, dynamic>>{};
  void add(
    Object label,
    String bankName,
    List<String> senders,
    Map<String, dynamic> format,
  ) {
    final id = userSmsBankId(bankName, prefix: prefix);
    final bank = banks.putIfAbsent(
      id,
      () => {
        'id': id,
        'name': bankName,
        'senders': <String>[],
        'formats': <Map<String, dynamic>>[],
      },
    );
    final bankSenders = bank['senders'] as List<String>;
    for (final sender in senders) {
      if (!bankSenders.contains(sender)) bankSenders.add(sender);
    }
    (bank['formats'] as List<Map<String, dynamic>>).add({
      ...format,
      'id': userSmsRuleId(bankName, label, prefix: prefix),
      'senders': senders,
    });
  }

  for (final rule in rules) {
    add(rule.id, rule.bankName, rule.senders, rule.format);
  }
  if (extra case (final label, final bankName, final senders, final format)) {
    add(label, bankName, senders, format);
  }
  return const RuleCompiler().compileSources([
    {
      for (final key in const [
        'schemaVersion',
        'minEngineVersion',
        'packVersion',
        'country',
        'defaults',
        'classifiers',
        'categoryRules',
        'counterpartyRules',
      ])
        if (country.containsKey(key)) key: country[key],
      'banks': banks.values.toList(),
    },
  ]);
}

class UserSmsRuleRepository {
  UserSmsRuleRepository(this.database);
  final AppDatabase database;

  Future<List<UserSmsRule>> load() async => [
    for (final r
        in await database
            .customSelect('SELECT * FROM user_sms_rules ORDER BY id')
            .get())
      UserSmsRule(
        id: r.read<int>('id'),
        bankName: r.read<String>('bank_name'),
        senders: (jsonDecode(r.read<String>('senders')) as List).cast(),
        format: jsonDecode(r.read<String>('format')) as Map<String, dynamic>,
        samples: (jsonDecode(r.read<String>('samples')) as List).cast(),
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          r.read<int>('created_at'),
        ),
      ),
  ];

  Future<int> add({
    required String bankName,
    required List<String> senders,
    required Map<String, dynamic> format,
    required List<String> samples,
  }) => database.customInsert(
    'INSERT INTO user_sms_rules (bank_name, senders, format, samples, created_at) VALUES (?, ?, ?, ?, ?)',
    variables: [
      Variable(bankName),
      Variable(jsonEncode(senders)),
      Variable(jsonEncode(format)),
      Variable(jsonEncode(samples)),
      Variable(DateTime.now().millisecondsSinceEpoch),
    ],
  );

  Future<void> delete(int id) =>
      database.customStatement('DELETE FROM user_sms_rules WHERE id = ?', [id]);

  /// Changes whenever a rule is added or removed, so the SMS review index
  /// knows to read pending messages again.
  Future<String> signature() async =>
      (await database
              .customSelect(
                "SELECT coalesce(group_concat(id), '') AS ids FROM user_sms_rules",
              )
              .getSingle())
          .read<String>('ids');

  /// The user's rules as one runtime pack's JSON, or null with none. Rules
  /// that no longer compile (after an app update changed the spec, say) are
  /// left out rather than stopping SMS import.
  Future<String?> runtimePack() async {
    final rules = await load();
    if (rules.isEmpty) return null;
    try {
      return jsonEncode(
        compileUserSmsRules(await indiaRuleSource(), rules).toJson(),
      );
    } on RuleValidationException {
      return null;
    }
  }
}
