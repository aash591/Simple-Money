import 'dart:convert';
import 'dart:typed_data';

const portableSchemaVersion = '0.3';
const portableEngineVersion = '0.3.0';
const portableMaxInteger = 9007199254740991;

/// Validation errors stop a pack before it can replace an active engine.
class RuleValidationException implements Exception {
  const RuleValidationException(this.message);
  final String message;
  @override
  String toString() => 'RuleValidationException: $message';
}

/// Validated, resolved runtime data. All public serialization is a deep copy.
class RuntimeRulePack {
  RuntimeRulePack._(this._data);
  final Map<String, dynamic> _data;
  int get packVersion => _data['packVersion'] as int;
  Map<String, dynamic> toJson() =>
      jsonDecode(jsonEncode(_data)) as Map<String, dynamic>;
}

/// Compiles declarative country sources, or validates a downloaded runtime pack.
/// Transport, signatures and filesystem storage belong to the host application.
class RuleCompiler {
  const RuleCompiler();

  /// Combine independently validated bank packs into one indexed snapshot.
  RuntimeRulePack mergeRuntimePacks(List<RuntimeRulePack> packs) {
    _check(packs.isNotEmpty, 'No runtime packs to merge');
    final version = packs.first.packVersion;
    _check(
      packs.every((p) => p.packVersion == version),
      'Runtime packs must share a packVersion',
    );
    return loadRuntime(
      _finish(
        [
          for (final pack in packs)
            ...(pack.toJson()['rules'] as List).cast<Map<String, dynamic>>(),
        ],
        version,
        // Every bank pack ships the same shared lists; an exact repeat can never
        // change a first-match result, so only the first copy is kept.
        categoryRules: _distinct([
          for (final pack in packs)
            ...(pack.toJson()['categoryRules'] as List? ?? [])
                .cast<Map<String, dynamic>>(),
        ]),
        counterpartyRules: _distinct([
          for (final pack in packs)
            ...(pack.toJson()['counterpartyRules'] as List? ?? [])
                .cast<Map<String, dynamic>>(),
        ]),
      ).toJson(),
    );
  }

  static List<Map<String, dynamic>> _distinct(
    List<Map<String, dynamic>> rules,
  ) {
    final seen = <String>{};
    return [
      for (final rule in rules)
        if (seen.add(jsonEncode(rule))) rule,
    ];
  }

  static const _defaults = <String, dynamic>{
    'case': 'exact',
    'digits': ['ascii'],
    'decimalMark': '.',
    'grouping': 'none',
    'exponents': <String, dynamic>{},
    'denominations': <String, dynamic>{},
  };

  RuntimeRulePack compileSources(List<Map<String, dynamic>> sources) {
    _check(
      sources.isNotEmpty && sources.length <= 32,
      'Expected 1–32 country sources',
    );
    _check(
      utf8.encode(jsonEncode(sources)).length <= 4 * 1024 * 1024,
      'Sources exceed 4 MiB',
    );
    final rules = <Map<String, dynamic>>[];
    int? version;
    final bankIds = <String>{};
    final countries = <String>{};
    final categoryRules = <Map<String, dynamic>>[];
    final counterpartyRules = <Map<String, dynamic>>[];
    for (final source in sources) {
      _keys(source, {
        'schemaVersion',
        'minEngineVersion',
        'packVersion',
        'country',
        'defaults',
        'classifiers',
        'banks',
        'categoryRules',
        'counterpartyRules',
      }, 'source');
      _versions(source);
      version ??= source['packVersion'] as int;
      _check(
        version == source['packVersion'],
        'Sources must share a packVersion',
      );
      final country = _string(source['country'], 'country');
      _check(
        RegExp(r'^[A-Z]{2}$').hasMatch(country) && countries.add(country),
        'Duplicate or invalid country',
      );
      final countryDefaults = _inherit(
        _defaults,
        _map(source['defaults'], 'defaults'),
      );
      final countryClassifiers = _classifiers(source['classifiers']);
      for (final rule in _list(
        source['categoryRules'] ?? [],
        'categoryRules',
      )) {
        categoryRules.add({..._map(rule, 'categoryRule'), 'country': country});
      }
      for (final rule in _list(
        source['counterpartyRules'] ?? [],
        'counterpartyRules',
      )) {
        counterpartyRules.add({
          ..._map(rule, 'counterpartyRule'),
          'country': country,
        });
      }
      final banks = _list(source['banks'], 'banks');
      _check(banks.isNotEmpty, 'Country has no banks');
      for (final bankValue in banks) {
        final bank = _map(bankValue, 'bank');
        _keys(bank, {
          'id',
          'name',
          'senders',
          'defaults',
          'requires',
          'classifiers',
          'formats',
        }, 'bank');
        final bankId = _string(bank['id'], 'bank.id');
        _check(bankIds.add(bankId), 'Duplicate bank ID $bankId');
        final name = _string(bank['name'], 'bank.name');
        final senders = _strings(bank['senders'], 'senders');
        _check(
          senders.isNotEmpty && senders.length <= 64,
          'Expected 1–64 sender IDs',
        );
        for (final sender in senders) {
          _check(
            normalizeRuleSender(sender) == sender,
            'Sender must be canonical: $sender',
          );
        }
        _check(senders.toSet().length == senders.length, 'Duplicate sender');
        final defaults = _inherit(
          countryDefaults,
          _map(bank['defaults'] ?? <String, dynamic>{}, 'bank.defaults'),
        );
        final bankRequires = _selector(bank['requires'] ?? <String, dynamic>{});
        final classifiers = [
          ...countryClassifiers,
          ..._classifiers(bank['classifiers']),
        ];
        final formats = _list(bank['formats'], 'formats');
        _check(formats.isNotEmpty, 'Bank has no formats');
        for (final formatValue in formats) {
          final format = _map(formatValue, 'format');
          _keys(format, {
            'id',
            'senders',
            'defaults',
            'requires',
            'classifiers',
            'classification',
            'direction',
            'channel',
            'tokens',
            'output',
          }, 'format');
          final resolved = _inherit(
            defaults,
            _map(format['defaults'] ?? <String, dynamic>{}, 'format.defaults'),
          );
          final formatSenders = format.containsKey('senders')
              ? _strings(format['senders'], 'format.senders')
              : senders;
          _check(
            formatSenders.isNotEmpty &&
                formatSenders.toSet().length == formatSenders.length &&
                formatSenders.every(senders.contains),
            'Format senders must be a nonempty subset of bank senders',
          );
          rules.add({
            'id': format['id'],
            'bankId': bankId,
            'bankName': name,
            'country': country,
            'senders': formatSenders,
            'defaults': resolved,
            'requires': [
              bankRequires,
              _selector(format['requires'] ?? <String, dynamic>{}),
            ],
            'classifiers': [
              ...classifiers,
              ..._classifiers(format['classifiers']),
            ],
            'classification': format['classification'],
            'direction': format['direction'],
            'channel': format['channel'],
            'tokens': format['tokens'],
            'output': format['output'],
          });
        }
      }
    }
    return _finish(
      rules,
      version!,
      categoryRules: categoryRules,
      counterpartyRules: counterpartyRules,
    );
  }

  RuntimeRulePack loadRuntime(Map<String, dynamic> runtime) {
    _check(
      utf8.encode(jsonEncode(runtime)).length <= 4 * 1024 * 1024,
      'Runtime exceeds 4 MiB',
    );
    _keys(runtime, {
      'format',
      'schemaVersion',
      'minEngineVersion',
      'packVersion',
      'rules',
      'senderIndex',
      'categoryRules',
      'counterpartyRules',
    }, 'runtime');
    _check(runtime['format'] == 'sms-rules-runtime', 'Unknown runtime format');
    _versions(runtime);
    final rules = _list(
      runtime['rules'],
      'rules',
    ).map((r) => _map(r, 'rule')).toList();
    final result = _finish(
      rules,
      runtime['packVersion'] as int,
      categoryRules: _list(
        runtime['categoryRules'] ?? [],
        'categoryRules',
      ).map((r) => _map(r, 'categoryRule')).toList(),
      counterpartyRules: _list(
        runtime['counterpartyRules'] ?? [],
        'counterpartyRules',
      ).map((r) => _map(r, 'counterpartyRule')).toList(),
    );
    _check(
      jsonEncode(runtime['senderIndex']) ==
          jsonEncode(result._data['senderIndex']),
      'Invalid or noncanonical sender index',
    );
    return result;
  }

  RuntimeRulePack _finish(
    List<Map<String, dynamic>> rules,
    int version, {
    List<Map<String, dynamic>> categoryRules = const [],
    List<Map<String, dynamic>> counterpartyRules = const [],
  }) {
    _check(rules.isNotEmpty && rules.length <= 4096, 'Expected 1–4096 rules');
    final ids = <String>{};
    final signatures = <String>{};
    for (final rule in rules) {
      _validateRule(rule);
      _check(ids.add(rule['id'] as String), 'Duplicate rule ID ${rule['id']}');
      for (final sender in rule['senders'] as List) {
        final signature = jsonEncode([
          sender,
          rule['defaults'],
          rule['requires'],
          rule['tokens'],
        ]);
        _check(
          signatures.add(signature),
          'Duplicate matching pattern for $sender',
        );
      }
    }
    rules.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    final index = <String, List<int>>{};
    for (var i = 0; i < rules.length; i++) {
      for (final sender in rules[i]['senders'] as List) {
        index.putIfAbsent(sender as String, () => []).add(i);
      }
    }
    for (final entry in index.entries) {
      _check(entry.value.length <= 128, 'More than 128 rules for ${entry.key}');
    }
    final sortedIndex = {
      for (final key in index.keys.toList()..sort()) key: index[key],
    };
    final data = {
      'format': 'sms-rules-runtime',
      'schemaVersion': portableSchemaVersion,
      'minEngineVersion': portableEngineVersion,
      'packVersion': version,
      'rules': rules,
      'senderIndex': sortedIndex,
      'categoryRules': _enrichmentRules(categoryRules, category: true),
      'counterpartyRules': _enrichmentRules(counterpartyRules, category: false),
    };
    return RuntimeRulePack._(
      jsonDecode(jsonEncode(data)) as Map<String, dynamic>,
    );
  }

  List<Map<String, dynamic>> _enrichmentRules(
    List<Map<String, dynamic>> rules, {
    required bool category,
  }) {
    _check(rules.length <= 16384, 'Too many enrichment rules before merge');
    final unique = <String, Map<String, dynamic>>{};
    for (final rule in rules) {
      _keys(rule, {
        'id',
        'country',
        'priority',
        'when',
        if (category) ...{
          'directions',
          'channels',
          'source',
          'match',
          'requires',
          'categoryId',
          'name',
          'aliases',
          'isFallback',
        } else ...{
          'prefix',
          'suffixes',
          'maxLength',
        },
      }, 'enrichment rule');
      final id = _string(rule['id'], 'enrichment id');
      _check(
        RegExp(r'^[a-z][a-zA-Z0-9_.-]*$').hasMatch(id),
        'Invalid enrichment ID',
      );
      _check(
        RegExp(r'^[A-Z]{2}$').hasMatch(_string(rule['country'], 'country')),
        'Invalid enrichment country',
      );
      _check(
        rule['priority'] is int &&
            (rule['priority'] as int) >= 0 &&
            (rule['priority'] as int) <= 100000,
        'Invalid enrichment priority',
      );
      final when = _selector(rule['when']);
      if (category) {
        _check(
          {'body', 'merchant'}.contains(rule['source']),
          'Invalid category source',
        );
        _check(
          {'substring', 'words', 'exact'}.contains(rule['match']),
          'Invalid category match',
        );
        final directions = _strings(rule['directions'], 'directions');
        _check(
          directions.isNotEmpty &&
              directions.toSet().length == directions.length &&
              directions.every({'debit', 'credit'}.contains),
          'Invalid category directions',
        );
        if (rule['channels'] != null) {
          final channels = _strings(rule['channels'], 'channels');
          _check(
            channels.isNotEmpty &&
                channels.every(
                  {
                    'atm',
                    'upi',
                    'card',
                    'bankTransfer',
                    'wallet',
                    'other',
                  }.contains,
                ),
            'Invalid category channels',
          );
        }
        _selector(rule['requires'] ?? <String, dynamic>{});
        _check(
          RegExp(r'^[a-z][a-z0-9_]*$')
              .hasMatch(_string(rule['categoryId'], 'categoryId')),
          'Invalid category ID',
        );
        _string(rule['name'], 'category name');
        _check(
          _strings(rule['aliases'] ?? [], 'aliases').length <= 16,
          'Too many aliases',
        );
        _check(
          rule['isFallback'] == null || rule['isFallback'] is bool,
          'Invalid fallback flag',
        );
        _check(
          rule['isFallback'] == true ||
              (when['all'] as List? ?? []).isNotEmpty ||
              (when['any'] as List? ?? []).isNotEmpty,
          'Category rule needs positive evidence',
        );
      } else {
        _check(
          _string(rule['prefix'], 'prefix').length <= 128,
          'Counterparty prefix too long',
        );
        final suffixes = _strings(rule['suffixes'], 'suffixes');
        _check(
          suffixes.isNotEmpty &&
              suffixes.length <= 16 &&
              suffixes.every((s) => s.length <= 128),
          'Invalid counterparty suffixes',
        );
        _check(
          rule['maxLength'] is int &&
              (rule['maxLength'] as int) >= 1 &&
              (rule['maxLength'] as int) <= 256,
          'Invalid counterparty bound',
        );
      }
      final previous = unique[id];
      _check(
        previous == null || jsonEncode(previous) == jsonEncode(rule),
        'Conflicting enrichment rule $id',
      );
      unique[id] = rule;
    }
    _check(unique.length <= 256, 'Too many unique enrichment rules');
    return unique.values.toList()..sort((a, b) {
      final priority = (a['priority'] as int).compareTo(b['priority'] as int);
      return priority != 0
          ? priority
          : (a['id'] as String).compareTo(b['id'] as String);
    });
  }

  void _validateRule(Map<String, dynamic> rule) {
    _keys(rule, {
      'id',
      'bankId',
      'bankName',
      'country',
      'senders',
      'defaults',
      'requires',
      'classifiers',
      'classification',
      'direction',
      'channel',
      'tokens',
      'output',
    }, 'rule');
    for (final key in ['id', 'bankId', 'bankName', 'country']) {
      _string(rule[key], key);
    }
    _check(
      RegExp(r'^[A-Z]{2}$').hasMatch(rule['country'] as String),
      'Invalid country',
    );
    final senders = _strings(rule['senders'], 'senders');
    _check(
      senders.isNotEmpty &&
          senders.length <= 64 &&
          senders.toSet().length == senders.length,
      'Invalid senders',
    );
    for (final sender in senders) {
      _check(
        normalizeRuleSender(sender) == sender,
        'Noncanonical sender $sender',
      );
    }
    final defaults = _map(rule['defaults'], 'defaults');
    _keys(defaults, _defaults.keys.toSet()..add('currency'), 'defaults');
    _check(
      {'exact', 'ascii_insensitive'}.contains(defaults['case']),
      'Unsupported case handling',
    );
    final digits = _strings(defaults['digits'], 'digits');
    _check(
      digits.contains('ascii') &&
          digits.toSet().length == digits.length &&
          digits.every({'ascii', 'persian', 'arabic_indic', 'thai'}.contains),
      'Digits must include ascii and supported scripts only',
    );
    _check(
      {'.', ','}.contains(defaults['decimalMark']),
      'Unsupported decimal mark',
    );
    _check(
      {'none', 'western', 'indian'}.contains(defaults['grouping']),
      'Unsupported grouping',
    );
    final exponents = _map(defaults['exponents'], 'exponents');
    _check(
      exponents.isNotEmpty && exponents.length <= 64,
      'Missing currency exponents',
    );
    for (final entry in exponents.entries) {
      _check(
        RegExp(r'^[A-Z]{3}$').hasMatch(entry.key) &&
            entry.value is int &&
            entry.value >= 0 &&
            entry.value <= 3,
        'Invalid currency exponent',
      );
    }
    _check(
      exponents.containsKey(defaults['currency']),
      'Default currency has no exponent',
    );
    final denominations = _map(defaults['denominations'], 'denominations');
    _check(denominations.length <= 32, 'Too many denominations');
    for (final entry in denominations.entries) {
      _string(entry.key, 'denomination label');
      final value = _map(entry.value, 'denomination');
      _keys(value, {'currency', 'multiplier'}, 'denomination');
      _check(
        exponents.containsKey(value['currency']),
        'Unknown denomination currency',
      );
      _check(
        value['multiplier'] is int &&
            value['multiplier'] > 0 &&
            value['multiplier'] <= 1000000,
        'Invalid denomination multiplier',
      );
    }
    for (final requirement in _list(rule['requires'], 'requires')) {
      _selector(requirement);
    }
    _classifiers(rule['classifiers']);
    _check(
      rule['classification'] == 'completed',
      'Only completed formats may extract',
    );
    _check(
      {'debit', 'credit'}.contains(rule['direction']),
      'Invalid direction',
    );
    _check(
      {
        'atm',
        'upi',
        'card',
        'bankTransfer',
        'wallet',
        'other',
      }.contains(rule['channel']),
      'Invalid channel',
    );
    final tokens = _list(rule['tokens'], 'tokens');
    _check(tokens.length >= 3 && tokens.length <= 48, 'Expected 3–48 tokens');
    final captures = <String, String>{};
    final enumValues = <String, List<String>>{};
    for (var i = 0; i < tokens.length; i++) {
      final token = _map(tokens[i], 'token');
      final op = token['op'];
      if (op == 'match_end') {
        _keys(token, {'op'}, 'end');
        _check(i == tokens.length - 1, 'match_end must be the last token');
        continue;
      }
      if (op == 'match_literal') {
        _keys(token, {'op', 'value'}, 'literal');
        final literal = _string(token['value'], 'literal.value');
        final surrounded = normalizeRuleText('a${literal}z', const ['ascii']);
        _check(
          surrounded.substring(1, surrounded.length - 1) == literal,
          'Literal must have canonical whitespace',
        );
        continue;
      }
      _check(
        {
          'capture_money',
          'capture_account',
          'capture_text',
          'capture_reference',
          'capture_enum',
          'capture_number',
          'capture_datetime',
        }.contains(op),
        'Unsupported operation $op',
      );
      _keys(token, {
        'op',
        'name',
        'maxLength',
        if (op == 'capture_enum') 'values',
        if (op == 'capture_account') 'minDigits',
        if (op == 'capture_text') 'excludeCharacters',
        if (op == 'capture_text') 'rejectDateTime',
      }, 'capture');
      final name = _string(token['name'], 'capture.name');
      _check(
        RegExp(r'^[a-z][a-zA-Z0-9_]{0,31}$').hasMatch(name) &&
            !captures.containsKey(name),
        'Invalid or duplicate capture $name',
      );
      captures[name] = op as String;
      if (token.containsKey('excludeCharacters')) {
        _string(token['excludeCharacters'], 'excluded characters');
      }
      _check(
        token['rejectDateTime'] == null || token['rejectDateTime'] is bool,
        'rejectDateTime must be boolean',
      );
      if (op == 'capture_account') {
        final minimum = token['minDigits'] ?? 4;
        _check(
          minimum is int && minimum >= 1 && minimum <= 4,
          'Account minDigits must be 1–4',
        );
      }
      final length = token['maxLength'];
      _check(
        length is int && length > 0 && length <= 256,
        'Capture maxLength must be 1–256',
      );
      _check(
        i > 0 &&
            i + 1 < tokens.length &&
            {
              'match_literal',
              'match_end',
            }.contains(_map(tokens[i + 1], 'delimiter')['op']),
        'Captures must be followed by a literal or message end',
      );
      if (op == 'capture_enum') {
        final values = _strings(token['values'], 'enum values');
        _check(
          values.isNotEmpty &&
              values.length <= 32 &&
              values.toSet().length == values.length,
          'Invalid enum',
        );
        final normalized = values.map((v) {
          final text = normalizeRuleText(v, digits);
          return defaults['case'] == 'ascii_insensitive'
              ? foldRuleAscii(text)
              : text;
        }).toList();
        _check(
          normalized.every((s) => s.isNotEmpty) &&
              normalized.toSet().length == normalized.length,
          'Enum values collide after normalization',
        );
        enumValues[name] = values;
      }
    }
    _check(
      _map(tokens.first, 'first token')['op'] == 'match_literal' &&
          {
            'match_literal',
            'match_end',
          }.contains(_map(tokens.last, 'last token')['op']),
      'Formats start with a literal and end with a literal or message end',
    );
    final output = _map(rule['output'], 'output');
    _keys(output, {
      'amount',
      'currency',
      'accountLast4',
      'reference',
      'counterparty',
    }, 'output');
    final amount = _map(output['amount'], 'amount');
    _keys(amount, {'capture', 'denominationCapture'}, 'amount');
    _check(
      captures[amount['capture']] == 'capture_money',
      'Amount requires capture_money',
    );
    if (amount.containsKey('denominationCapture')) {
      final values = enumValues[amount['denominationCapture']];
      _check(
        values != null && values.every(denominations.containsKey),
        'Denomination capture has unmapped labels',
      );
      _check(
        !output.containsKey('currency'),
        'Denomination determines currency; omit output.currency',
      );
    }
    if (output.containsKey('currency')) {
      final currency = _binding(output['currency'], captures);
      if (currency.containsKey('value')) {
        _check(
          exponents.containsKey(currency['value']),
          'Unknown output currency',
        );
      } else {
        final values = enumValues[currency['capture']];
        _check(
          values != null && values.every(exponents.containsKey),
          'Currency must be a mapped enum',
        );
      }
    }
    if (output.containsKey('accountLast4')) {
      final account = _map(output['accountLast4'], 'accountLast4');
      _keys(account, {
        'capture',
        'operation',
        'length',
        'allowShort',
        'preserveMask',
      }, 'accountLast4');
      _check(
        account['allowShort'] == null || account['allowShort'] is bool,
        'allowShort must be boolean',
      );
      _check(
        account['preserveMask'] == null || account['preserveMask'] is bool,
        'preserveMask must be boolean',
      );
      _check(
        captures[account['capture']] == 'capture_account' &&
            account['operation'] == 'extract_account_suffix' &&
            account['length'] == 4,
        'Invalid account suffix operation',
      );
    }
    for (final key in ['reference', 'counterparty']) {
      if (output.containsKey(key)) {
        _binding(output[key], captures, allowPrefix: true);
      }
    }
  }

  Map<String, dynamic> _binding(
    dynamic input,
    Map<String, String> captures, {
    bool allowPrefix = false,
  }) {
    final binding = _map(input, 'binding');
    _keys(binding, {'value', 'capture', if (allowPrefix) 'prefix'}, 'binding');
    _check(
      binding.containsKey('value') != binding.containsKey('capture'),
      'Binding needs exactly one value or capture',
    );
    if (binding.containsKey('prefix')) {
      _string(binding['prefix'], 'binding prefix');
    }
    if (binding.containsKey('value')) {
      _string(binding['value'], 'binding.value');
    } else {
      _check(
        captures.containsKey(binding['capture']),
        'Unknown output capture',
      );
    }
    return binding;
  }

  Map<String, dynamic> _inherit(
    Map<String, dynamic> parent,
    Map<String, dynamic> child,
  ) {
    _keys(child, _defaults.keys.toSet()..add('currency'), 'defaults override');
    final result = {...parent, ...child};
    for (final key in ['exponents', 'denominations']) {
      result[key] = {
        ..._map(parent[key], key),
        ..._map(child[key] ?? <String, dynamic>{}, key),
      };
    }
    return result;
  }

  List<Map<String, dynamic>> _classifiers(dynamic input) {
    final result = <Map<String, dynamic>>[];
    for (final value in _list(input ?? [], 'classifiers')) {
      final classifier = _map(value, 'classifier');
      _keys(classifier, {'classification', 'when'}, 'classifier');
      _check(
        {
          'security',
          'promotional',
          'failed',
          'pending',
          'future',
          'notice',
        }.contains(classifier['classification']),
        'Invalid rejection classification',
      );
      final when = _selector(classifier['when']);
      _check(
        (when['all'] as List? ?? []).isNotEmpty ||
            (when['any'] as List? ?? []).isNotEmpty,
        'Classifier requires positive evidence',
      );
      result.add({
        'classification': classifier['classification'],
        'when': when,
      });
    }
    _check(result.length <= 64, 'Too many classifiers');
    return result;
  }

  Map<String, dynamic> _selector(dynamic input) {
    final selector = _map(input, 'selector');
    _keys(selector, {'all', 'any', 'none'}, 'selector');
    for (final value in selector.values) {
      _check(
        _strings(value, 'selector literals').length <= 32,
        'Too many selector literals',
      );
    }
    return selector;
  }

  void _versions(Map<String, dynamic> data) {
    _check(
      data['schemaVersion'] == portableSchemaVersion,
      'Unsupported schemaVersion',
    );
    final minimum = _string(data['minEngineVersion'], 'minEngineVersion');
    _check(
      RegExp(r'^\d+\.\d+\.\d+$').hasMatch(minimum),
      'Engine version must be x.y.z',
    );
    final requested = minimum.split('.').map(int.parse).toList();
    final available = portableEngineVersion.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (requested[i] < available[i]) break;
      _check(requested[i] <= available[i], 'Pack requires a newer engine');
    }
    _check(
      data['packVersion'] is int &&
          data['packVersion'] > 0 &&
          data['packVersion'] <= portableMaxInteger,
      'packVersion must be a positive safe integer',
    );
  }
}

void _check(bool condition, String message) {
  if (!condition) throw RuleValidationException(message);
}

Map<String, dynamic> _map(dynamic value, String label) {
  _check(value is Map<String, dynamic>, '$label must be an object');
  return value as Map<String, dynamic>;
}

List<dynamic> _list(dynamic value, String label) {
  _check(value is List, '$label must be an array');
  return value as List;
}

String _string(dynamic value, String label) {
  _check(
    value is String && value.isNotEmpty && value.length <= 512,
    '$label must be a nonempty string of at most 512 UTF-16 units',
  );
  return value as String;
}

List<String> _strings(dynamic value, String label) =>
    _list(value, label).map((item) => _string(item, label)).toList();
void _keys(Map<String, dynamic> value, Set<String> allowed, String label) {
  _check(value.keys.every(allowed.contains), 'Unknown property in $label');
}

/// Portable ASCII folding: non-ASCII characters are compared exactly.
String foldRuleAscii(String text) {
  final units = text.codeUnits;
  var i = 0;
  while (i < units.length && !(units[i] >= 65 && units[i] <= 90)) {
    i++;
  }
  // Most bodies are already folded once; avoid copying them again.
  if (i == units.length) return text;
  final folded = Uint16List.fromList(units);
  for (; i < folded.length; i++) {
    final c = folded[i];
    if (c >= 65 && c <= 90) folded[i] = c + 32;
  }
  return String.fromCharCodes(folded);
}

/// Whitespace and digit mappings are explicit, independent of locale or regex.
String normalizeRuleText(String text, List<String> digits) {
  final persian = digits.contains('persian');
  final arabic = digits.contains('arabic_indic');
  final thai = digits.contains('thai');
  final units = text.codeUnits;
  final out = Uint16List(units.length);
  var length = 0;
  var space = false;
  for (var c in units) {
    if (c == 32 || (c >= 9 && c <= 13) || c == 160 || c == 0x202f) {
      space = length > 0;
      continue;
    }
    if (space) out[length++] = 32;
    space = false;
    if (persian && c >= 0x6f0 && c <= 0x6f9) {
      c = 48 + c - 0x6f0;
    } else if (arabic && c >= 0x660 && c <= 0x669) {
      c = 48 + c - 0x660;
    } else if (thai && c >= 0xe50 && c <= 0xe59) {
      c = 48 + c - 0xe50;
    }
    out[length++] = c;
  }
  return String.fromCharCodes(out, 0, length);
}

final _numericSender = RegExp(r'^[+()\d .-]+$');
final _nonDigit = RegExp(r'\D');
final _senderPrefix = RegExp(r'^[A-Z]{2}-');
final _senderSuffix = RegExp(r'-(S|T|G)$');
final _textSender = RegExp(r'^[A-Z][A-Z0-9_ -]{2,30}$');
String? _lastSenderRaw, _lastSender;

String? normalizeRuleSender(String raw) {
  // One message asks for its sender several times; reuse the last answer.
  if (identical(raw, _lastSenderRaw)) return _lastSender;
  _lastSenderRaw = raw;
  return _lastSender = _normalizeSender(raw);
}

String? _normalizeSender(String raw) {
  if (raw.length > 128) return null;
  var sender = String.fromCharCodes(
    normalizeRuleText(raw, const [
      'ascii',
    ]).codeUnits.map((c) => c >= 97 && c <= 122 ? c - 32 : c),
  );
  // Numeric IDs must be registered; unlike text senders they preserve all digits.
  if (_numericSender.hasMatch(sender)) {
    sender = sender.replaceAll(_nonDigit, '');
    return sender.isEmpty ? null : sender;
  }
  if (_senderPrefix.hasMatch(sender)) sender = sender.substring(3);
  if (sender.endsWith('-P')) return null;
  sender = sender.replaceFirst(_senderSuffix, '');
  return _textSender.hasMatch(sender) ? sender : null;
}
