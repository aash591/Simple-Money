import '../models.dart';
import 'compiler.dart';

String _fold(String value) =>
    foldRuleAscii(normalizeRuleText(value, const ['ascii']));

/// Folds a literal while keeping its edge whitespace, so " to " stays delimited.
String _delimiter(String value) {
  final folded = _fold('a${value}z');
  return folded.substring(1, folded.length - 1);
}

/// A selector whose literals are folded once, when the pack is loaded.
class _Literals {
  _Literals(Map<String, dynamic>? json, this.mode) {
    String prepare(dynamic literal) => mode == 'substring'
        ? _delimiter(literal as String)
        : _fold(literal as String);
    all = (json?['all'] as List? ?? const []).map(prepare).toList();
    any = (json?['any'] as List? ?? const []).map(prepare).toList();
    none = (json?['none'] as List? ?? const []).map(prepare).toList();
  }
  final String mode;
  late final List<String> all, any, none;

  bool _contains(String value, String needle) {
    if (mode == 'exact') return value == needle;
    if (mode == 'substring') return value.contains(needle);
    var offset = 0;
    while (offset <= value.length) {
      final index = value.indexOf(needle, offset);
      if (index < 0) return false;
      final end = index + needle.length;
      if ((index == 0 || !_word(value.codeUnitAt(index - 1))) &&
          (end == value.length || !_word(value.codeUnitAt(end)))) {
        return true;
      }
      offset = index + 1;
    }
    return false;
  }

  bool matches(String value) =>
      all.every((n) => _contains(value, n)) &&
      (any.isEmpty || any.any((n) => _contains(value, n))) &&
      !none.any((n) => _contains(value, n));
}

bool _word(int c) => c >= 97 && c <= 122 || c >= 48 && c <= 57;

class _NameRule {
  _NameRule(Map<String, dynamic> rule)
    : country = rule['country'] as String?,
      when = _Literals(rule['when'] as Map<String, dynamic>, 'substring'),
      prefix = _delimiter(rule['prefix'] as String),
      suffixes = (rule['suffixes'] as List)
          .map((s) => _delimiter(s as String))
          .toList(),
      maxLength = rule['maxLength'] as int;
  final String? country;
  final _Literals when;
  final String prefix;
  final List<String> suffixes;
  final int maxLength;
}

class _CategoryRule {
  _CategoryRule(Map<String, dynamic> rule)
    : channels = (rule['channels'] as List?)?.cast<String>().toSet(),
      requires = _Literals(
        rule['requires'] as Map<String, dynamic>?,
        'substring',
      ),
      when = _Literals(
        rule['when'] as Map<String, dynamic>,
        rule['match'] as String,
      ),
      fromBody = rule['source'] == 'body',
      id = rule['categoryId'] as String,
      name = rule['name'] as String,
      ruleId = rule['id'] as String,
      isFallback = rule['isFallback'] as bool? ?? false,
      aliases = List<String>.unmodifiable(
        (rule['aliases'] as List? ?? []).cast<String>(),
      );
  final Set<String>? channels;
  final _Literals requires, when;
  final bool fromBody, isFallback;
  final String id, name, ruleId;
  final List<String> aliases;
}

/// Generic literal interpreter: all merchant and category knowledge is JSON.
class PortableCategorizer {
  PortableCategorizer(RuntimeRulePack pack) {
    final data = pack.toJson();
    // Rules keep their pack order within each (country, direction) bucket, so
    // the first match is the same one an unindexed scan would find.
    for (final rule
        in (data['categoryRules'] as List? ?? [])
            .cast<Map<String, dynamic>>()) {
      final compiled = _CategoryRule(rule);
      for (final direction in rule['directions'] as List) {
        _categories
            .putIfAbsent('${rule['country']}|$direction', () => [])
            .add(compiled);
      }
    }
    _names = (data['counterpartyRules'] as List? ?? [])
        .map((r) => _NameRule(r as Map<String, dynamic>))
        .toList();
  }
  final Map<String, List<_CategoryRule>> _categories = {};
  late final List<_NameRule> _names;

  String? _counterparty(String body, SmsTransactionCandidate candidate) {
    final folded = foldRuleAscii(body);
    for (final rule in _names) {
      if (rule.country != candidate.countryCode || !rule.when.matches(folded)) {
        continue;
      }
      final start = folded.indexOf(rule.prefix);
      if (start < 0) continue;
      final from = start + rule.prefix.length;
      var end = body.length;
      var found = false;
      for (final suffix in rule.suffixes) {
        final index = folded.indexOf(suffix, from);
        if (index >= 0 && index < end) {
          end = index;
          found = true;
        }
      }
      if (!found || end - from > rule.maxLength) continue;
      final name = body.substring(from, end).trim();
      if (name.isEmpty ||
          !name.codeUnits.any(
            (c) => c >= 65 && c <= 90 || c >= 97 && c <= 122,
          )) {
        continue;
      }
      return name;
    }
    return candidate.counterparty;
  }

  SmsTransactionCandidate enrich(
    String rawBody,
    SmsTransactionCandidate candidate,
  ) {
    if (rawBody.length > 4000) return candidate;
    final body = normalizeRuleText(rawBody, const ['ascii']);
    final folded = foldRuleAscii(body);
    final party = _counterparty(body, candidate);
    final category = _match(
      folded,
      party == null ? folded : _fold(party),
      country: candidate.countryCode,
      direction: candidate.direction,
      channel: candidate.channel.name,
    );
    return SmsTransactionCandidate(
      amountMinor: candidate.amountMinor,
      direction: candidate.direction,
      occurredAt: candidate.occurredAt,
      currencyCode: candidate.currencyCode,
      channel: candidate.channel,
      bankName: candidate.bankName,
      countryCode: candidate.countryCode,
      accountLast4: candidate.accountLast4,
      reference: candidate.reference,
      counterparty: party,
      category: category,
    );
  }

  /// The category for a payee or a narration from anywhere else — a bank
  /// statement's row, a scanned UPI QR's payee — by the rules an SMS goes
  /// through: [text] stands for both the message and its merchant, and
  /// [detail] (a narration beside a payee's name) for the message alone.
  /// Null when nothing but the catch-all fits, or for rules that need an
  /// SMS's channel.
  SmsSuggestedCategory? categorize(
    String text, {
    required SmsDirection direction,
    String countryCode = 'IN',
    String? detail,
  }) {
    if (text.length > 4000) return null;
    final merchant = _fold(normalizeRuleText(text, const ['ascii']));
    final body = detail == null
        ? merchant
        : '$merchant ${_fold(normalizeRuleText(detail, const ['ascii']))}';
    final category = _match(
      body,
      merchant,
      country: countryCode,
      direction: direction,
    );
    return category == null || category.isFallback ? null : category;
  }

  SmsSuggestedCategory? _match(
    String body,
    String merchant, {
    required String? country,
    required SmsDirection direction,
    String? channel,
  }) {
    for (final rule
        in _categories['$country|${direction.name}'] ??
            const <_CategoryRule>[]) {
      if (rule.channels != null &&
          (channel == null || !rule.channels!.contains(channel))) {
        continue;
      }
      if (!rule.requires.matches(body)) continue;
      if (!rule.when.matches(rule.fromBody ? body : merchant)) continue;
      return SmsSuggestedCategory(
        id: rule.id,
        name: rule.name,
        type: direction == SmsDirection.credit ? 'income' : 'expense',
        ruleId: rule.ruleId,
        isFallback: rule.isFallback,
        aliases: rule.aliases,
      );
    }
    return null;
  }
}
