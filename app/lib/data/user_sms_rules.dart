import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter/services.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import 'db/app_database.dart';
import 'sms_amounts.dart';
import 'sms_sender_role.dart';

/// The role of each sender [rules] read, for senders that hold no money of
/// the user's. A sender any rule says holds money keeps doing so.
Map<String, SmsSenderRole> nonHolderSenders(Iterable<UserSmsRule> rules) {
  final roles = <String, SmsSenderRole>{};
  final holders = <String>{};
  for (final rule in rules) {
    final role = ruleSenderRole(rule.format);
    for (final sender in rule.senders) {
      if (role.holdsMoney) {
        holders.add(sender);
      } else {
        roles.putIfAbsent(sender, () => role);
      }
    }
  }
  return {
    for (final e in roles.entries)
      if (!holders.contains(e.key)) e.key: e.value,
  };
}

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

/// Countries whose rule source ships with the app, by ISO 3166 code. Any
/// other country gets [_genericSource]: India's English classifiers with the
/// rules' own currency, so a rule taught for any bank anywhere compiles.
const _bundledCountries = {
  'AE': 'uae',
  'BD': 'bangladesh',
  'CZ': 'czechia',
  'DE': 'germany',
  'EG': 'egypt',
  'ET': 'ethiopia',
  'FR': 'france',
  'GB': 'uk',
  'IN': 'india',
  'IR': 'iran',
  'JO': 'jordan',
  'KE': 'kenya',
  'LK': 'srilanka',
  'MZ': 'mozambique',
  'NG': 'nigeria',
  'NP': 'nepal',
  'OM': 'oman',
  'PK': 'pakistan',
  'RU': 'russia',
  'SA': 'saudiarabia',
  'SV': 'elsalvador',
  'TH': 'thailand',
  'TR': 'turkey',
  'TZ': 'tanzania',
  'US': 'usa',
};

/// The country a rule reads SMS for. The app keeps it in the format (rules
/// saved before countries existed are Indian) and takes it out before
/// compiling; the compiler gets it from the rule's country source.
const smsRuleCountryKey = 'country';

String ruleCountry(Map<String, dynamic> format) =>
    switch (format[smsRuleCountryKey]) {
      final String code when RegExp(r'^[A-Z]{2}$').hasMatch(code) => code,
      _ => 'IN',
    };

final _sources = <String, Map<String, dynamic>>{};

/// The bundled source for [country], or null when the app has none.
Future<Map<String, dynamic>?> bundledCountrySource(String country) async {
  final folder = _bundledCountries[country];
  if (folder == null) return null;
  return _sources[country] ??= jsonDecode(
    await rootBundle.loadString(
      'packages/universal_bank_sms_parser/rules/$folder/country.json',
    ),
  ) as Map<String, dynamic>;
}

/// India's source file, whose classifiers and categories other countries'
/// rules borrow until their own country ships.
Future<Map<String, dynamic>> indiaRuleSource() async =>
    (await bundledCountrySource('IN'))!;

/// A source for a country the app has no rules for: English classifiers,
/// and [currencies] (the ones its rules read) at their rule exponents.
Map<String, dynamic> _genericSource(
  String country,
  Map<String, dynamic> india,
  Set<String> currencies,
) => {
  for (final key in const ['schemaVersion', 'minEngineVersion', 'packVersion'])
    key: india[key],
  'country': country,
  'defaults': {
    'currency': currencies.isEmpty ? 'USD' : currencies.first,
    'case': 'ascii_insensitive',
    'digits': ['ascii'],
    'decimalMark': '.',
    'grouping': 'western',
    'exponents': <String, dynamic>{
      for (final c in currencies) c: smsRuleExponent(c),
    },
  },
  'classifiers': india['classifiers'],
};

/// `user.<bank>`, so a user rule never shares an ID with a bundled one.
/// Shared rules from other users use the `community` prefix. Outside India
/// the country leads the bank's name, so HSBC India and HSBC UAE are apart.
String userSmsBankId(
  String bankName, {
  String prefix = 'user',
  String country = 'IN',
}) {
  final slug = bankName
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');
  final name = slug.isEmpty ? 'bank' : slug;
  return '$prefix.${country == 'IN' ? '' : '${country.toLowerCase()}_'}$name';
}

/// The rule ID a format gets: its bank's ID and its row (or any label).
String userSmsRuleId(
  String bankName,
  Object label, {
  String prefix = 'user',
  String country = 'IN',
}) => '${userSmsBankId(bankName, prefix: prefix, country: country)}.r$label';

/// Compiles [rules] into one runtime pack, one source per country. [extra]
/// is a rule being tried, keyed by its label. Throws
/// [RuleValidationException] for a bad format.
Future<RuntimeRulePack> compileUserSmsRules(
  List<UserSmsRule> rules, {
  (String label, String bankName, List<String> senders, Map<String, dynamic>)?
  extra,
  String prefix = 'user',
}) async {
  final countries = <String, Map<String, Map<String, dynamic>>>{};
  final currencies = <String, Set<String>>{};
  void add(
    Object label,
    String bankName,
    List<String> senders,
    Map<String, dynamic> format,
  ) {
    final country = ruleCountry(format);
    final banks = countries.putIfAbsent(country, () => {});
    if (format['defaults'] case {'currency': final String currency}) {
      currencies.putIfAbsent(country, () => {}).add(currency);
    }
    final id = userSmsBankId(bankName, prefix: prefix, country: country);
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
      ...compilableFormat(format),
      'id': userSmsRuleId(bankName, label, prefix: prefix, country: country),
      'senders': senders,
    });
  }

  for (final rule in rules) {
    add(rule.id, rule.bankName, rule.senders, rule.format);
  }
  if (extra case (final label, final bankName, final senders, final format)) {
    add(label, bankName, senders, format);
  }
  final india = await indiaRuleSource();
  final sources = <Map<String, dynamic>>[];
  for (final MapEntry(key: country, value: banks) in countries.entries) {
    final used = currencies[country] ?? const <String>{};
    final base =
        await bundledCountrySource(country) ??
        _genericSource(country, india, used);
    final defaults = Map<String, dynamic>.from(base['defaults'] as Map);
    defaults['exponents'] = <String, dynamic>{
      ...defaults['exponents'] as Map,
      for (final c in used) c: smsRuleExponent(c),
    };
    sources.add({
      for (final key in const [
        'schemaVersion',
        'minEngineVersion',
        'packVersion',
        'country',
        'classifiers',
      ])
        if (base.containsKey(key)) key: base[key],
      'defaults': defaults,
      // The category rules are India's: the compiler ties them to the
      // source's country, and India's bundled packs carry the same ones.
      if (country == 'IN')
        for (final key in const ['categoryRules', 'counterpartyRules'])
          if (india.containsKey(key)) key: india[key],
      'banks': banks.values.toList(),
    });
  }
  if (sources.isEmpty) {
    sources.add({
      for (final key in const [
        'schemaVersion',
        'minEngineVersion',
        'packVersion',
        'country',
        'defaults',
        'classifiers',
      ])
        key: india[key],
      'banks': const [],
    });
  }
  return const RuleCompiler().compileSources(sources);
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
      return jsonEncode((await compileUserSmsRules(rules)).toJson());
    } on RuleValidationException {
      return null;
    }
  }
}
