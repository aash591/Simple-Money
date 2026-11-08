import '../models.dart';
import 'compiler.dart';
import 'categorizer.dart';

enum RuleClassification {
  completed,
  security,
  promotional,
  failed,
  pending,
  future,
  notice,
  unknown,
}

/// Language-neutral contract, including the rule and pack used for extraction.
class PortableParseResult {
  const PortableParseResult({
    required this.classification,
    required this.decision,
    required this.reason,
    required this.packVersion,
    this.ruleId,
    this.candidate,
  });
  final RuleClassification classification;
  final SmsDecision decision;
  final String reason;
  final int packVersion;
  final String? ruleId;
  final SmsTransactionCandidate? candidate;

  Map<String, dynamic> toJson() => {
    'classification': classification.name,
    'decision': decision.name,
    'reason': reason,
    'packVersion': packVersion,
    'ruleId': ruleId,
    'candidate': candidate?.toJson(),
  };
}

/// Offline interpreter. Construct once when a verified pack is activated.
/// No sender, bank, country, currency, or rejection phrase is built into it.
class PortableSmsEngine {
  PortableSmsEngine(RuntimeRulePack pack) : packVersion = pack.packVersion {
    _categorizer = PortableCategorizer(pack);
    final data = pack.toJson();
    _rules = (data['rules'] as List).cast<Map<String, dynamic>>();
    _index = (data['senderIndex'] as Map<String, dynamic>).map(
      (k, v) => MapEntry(k, (v as List).cast<int>()),
    );
    final selectors = <String, _Selector>{};
    _plans = _rules.map((rule) => _Plan(rule, selectors)).toList();
  }
  final int packVersion;
  late final List<Map<String, dynamic>> _rules;
  late final Map<String, List<int>> _index;
  late final List<_Plan> _plans;
  late final PortableCategorizer _categorizer;

  /// Also usable for historical or externally extracted candidates.
  SmsTransactionCandidate enrichCandidate(
    BankSms sms,
    SmsTransactionCandidate candidate,
  ) => _categorizer.enrich(sms.body, candidate);

  PortableParseResult parse(BankSms sms) {
    PortableParseResult ignored(
      String reason, [
      RuleClassification classification = RuleClassification.unknown,
    ]) => PortableParseResult(
      classification: classification,
      decision: SmsDecision.ignored,
      reason: reason,
      packVersion: packVersion,
    );
    if (sms.body.isEmpty || sms.body.length > 4000) {
      return ignored('invalidMessage');
    }
    final sender = normalizeRuleSender(sms.sender);
    final indexes = sender == null ? null : _index[sender];
    if (indexes == null) return ignored('unregisteredSender');
    // Normalize once per unique digit profile. Case-fold each normalized body once.
    final normalized = <String, String>{};
    final folded = <String, String>{};
    final applicable = <(_Plan, String, String)>[];
    for (final index in indexes) {
      final plan = _plans[index];
      final key = plan.digitKey;
      final body = normalized.putIfAbsent(
        key,
        () => normalizeRuleText(sms.body, plan.digits),
      );
      final comparable = plan.ignoreCase
          ? folded.putIfAbsent(key, () => foldRuleAscii(body))
          : body;
      if (plan.requires.every((selector) => selector.matches(comparable))) {
        applicable.add((plan, body, comparable));
      }
    }
    // Classification is a separate pass, before extraction. A rejection anywhere
    // among applicable rules takes precedence according to the fixed ordering.
    const rejectionOrder = [
      RuleClassification.security,
      RuleClassification.promotional,
      RuleClassification.failed,
      RuleClassification.pending,
      RuleClassification.future,
      RuleClassification.notice,
    ];
    RuleClassification? rejection;
    var rank = rejectionOrder.length;
    // A bank's rules repeat the same classifiers; each is tested once per text.
    final tested = <(_Selector, String), bool>{};
    for (final (plan, _, comparable) in applicable) {
      for (final (classification, selector) in plan.classifiers) {
        final order = rejectionOrder.indexOf(classification);
        if (order < 0 || order >= rank) continue;
        if (tested.putIfAbsent((
          selector,
          comparable,
        ), () => selector.matches(comparable))) {
          rejection = classification;
          rank = order;
        }
      }
    }
    if (rejection != null) return ignored(rejection.name, rejection);
    final matches = <(String, SmsTransactionCandidate)>[];
    final budget = _MatchBudget();
    for (final (plan, body, comparable) in applicable) {
      final anchor = plan.literals.first;
      var offset = 0;
      var attempts = 0;
      while (offset < comparable.length) {
        final start = comparable.indexOf(anchor, offset);
        if (start < 0) break;
        if (++attempts > 16) return ignored('workLimit');
        final captures = plan.match(body, comparable, start, budget);
        if (budget.exhausted) return ignored('workLimit');
        if (captures != null) {
          final candidate = plan.extract(captures, sms.receivedAt);
          if (candidate != null) {
            matches.add((plan.rule['id'] as String, candidate));
          }
        }
        offset = start + 1;
      }
    }
    if (matches.isEmpty) return ignored('noMatchingFormat');
    final first = matches.first.$2;
    if (matches.any((m) => !_equivalent(first, m.$2))) {
      return PortableParseResult(
        classification: RuleClassification.completed,
        decision: SmsDecision.review,
        reason: 'ambiguousMatches',
        packVersion: packVersion,
      );
    }
    // Rule authors cannot enable automatic imports. Caller review policy is separate.
    return PortableParseResult(
      classification: RuleClassification.completed,
      decision: SmsDecision.review,
      reason: 'completedNeedsReview',
      packVersion: packVersion,
      ruleId: matches.first.$1,
      candidate: enrichCandidate(sms, first),
    );
  }
}

class _Selector {
  _Selector(Map<String, dynamic> json, String Function(String) compare)
    : all = (json['all'] as List? ?? []).cast<String>().map(compare).toList(),
      any = (json['any'] as List? ?? []).cast<String>().map(compare).toList(),
      none = (json['none'] as List? ?? []).cast<String>().map(compare).toList();
  final List<String> all, any, none;
  late final String key = [
    all,
    any,
    none,
  ].map((l) => l.join('\x00')).join('\x01');
  bool matches(String text) =>
      all.every(text.contains) &&
      (any.isEmpty || any.any(text.contains)) &&
      !none.any(text.contains);
}

class _Plan {
  /// [selectors] is shared by every plan, so identical classifiers are one object.
  _Plan(this.rule, Map<String, _Selector> selectors) {
    defaults = rule['defaults'] as Map<String, dynamic>;
    digits = (defaults['digits'] as List).cast<String>();
    digitKey = digits.join(',');
    ignoreCase = defaults['case'] == 'ascii_insensitive';
    String compare(String text) {
      final normalized = normalizeRuleText(text, digits);
      return ignoreCase ? foldRuleAscii(normalized) : normalized;
    }

    requires = (rule['requires'] as List)
        .map((r) => _Selector(r as Map<String, dynamic>, compare))
        .toList();
    classifiers = (rule['classifiers'] as List).map((c) {
      final json = c as Map<String, dynamic>;
      return (
        RuleClassification.values.byName(json['classification'] as String),
        () {
          final selector = _Selector(
            json['when'] as Map<String, dynamic>,
            compare,
          );
          return selectors.putIfAbsent(selector.key, () => selector);
        }(),
      );
    }).toList();
    tokens = (rule['tokens'] as List).cast<Map<String, dynamic>>();
    literals = tokens
        .map(
          (t) => t['op'] == 'match_literal'
              ? (ignoreCase
                    ? foldRuleAscii(t['value'] as String)
                    : t['value'] as String)
              : '',
        )
        .toList();
    enums = {
      for (var i = 0; i < tokens.length; i++)
        if (tokens[i]['op'] == 'capture_enum')
          i: {
            for (final value in tokens[i]['values'] as List)
              compare(value as String): value,
          },
    };
  }
  final Map<String, dynamic> rule;
  late final Map<String, dynamic> defaults;
  late final List<String> digits;
  late final String digitKey;
  late final bool ignoreCase;
  late final List<_Selector> requires;
  late final List<(RuleClassification, _Selector)> classifiers;
  late final List<Map<String, dynamic>> tokens;
  late final List<String> literals;
  late final Map<int, Map<String, dynamic>> enums;

  Map<String, String>? match(
    String body,
    String comparable,
    int start,
    _MatchBudget budget,
  ) {
    final captures = <String, String>{};
    bool visit(int i, int cursor) {
      if (i == tokens.length) return true;
      if (!budget.consume()) return false;
      final token = tokens[i];
      if (token['op'] == 'match_end') {
        return cursor == body.length;
      }
      if (token['op'] == 'match_literal') {
        return comparable.startsWith(literals[i], cursor) &&
            visit(i + 1, cursor + literals[i].length);
      }
      final ends = <int>[];
      if (tokens[i + 1]['op'] == 'match_end') {
        ends.add(body.length);
      } else {
        var end = comparable.indexOf(literals[i + 1], cursor);
        while (end >= 0 && end - cursor <= (token['maxLength'] as int)) {
          if (!budget.consume()) return false;
          ends.add(end);
          end = comparable.indexOf(literals[i + 1], end + 1);
        }
      }
      // A date-time prefers its optional time component; all other captures use
      // the earliest delimiter that allows the remaining tokens to match.
      for (final end
          in token['op'] == 'capture_datetime' ? ends.reversed : ends) {
        if (end - cursor > (token['maxLength'] as int)) continue;
        var value = body.substring(cursor, end).trim();
        if (value.isEmpty) continue;
        var valid = true;
        switch (token['op']) {
          case 'capture_money':
            valid = _moneyLexical(value, defaults);
          case 'capture_account':
            valid = _account(value, token['minDigits'] as int? ?? 4);
          case 'capture_reference':
            valid = value.codeUnits.every(
              (c) => _asciiLetter(c) || _digit(c) || c == 45,
            );
          case 'capture_number':
            valid = _number.hasMatch(value);
          case 'capture_datetime':
            valid = _dateTime.hasMatch(value);
          case 'capture_enum':
            final key = ignoreCase ? foldRuleAscii(value) : value;
            final canonical = enums[i]![key];
            valid = canonical != null;
            if (valid) value = canonical as String;
          case 'capture_text':
            if (token['rejectDateTime'] == true) {
              valid = !_dateTime.hasMatch(value);
            }
            final excluded = token['excludeCharacters'] as String?;
            if (excluded != null) {
              valid =
                  valid && !excluded.codeUnits.any(value.codeUnits.contains);
            }
            break;
        }
        if (valid) {
          captures[token['name'] as String] = value;
          if (visit(i + 1, end)) return true;
          captures.remove(token['name']);
        }
      }
      return false;
    }

    return visit(0, start) ? captures : null;
  }

  SmsTransactionCandidate? extract(
    Map<String, String> captures,
    DateTime receivedAt,
  ) {
    final output = rule['output'] as Map<String, dynamic>;
    final amountOutput = output['amount'] as Map<String, dynamic>;
    String? binding(String name) {
      final value = output[name] as Map<String, dynamic>?;
      if (value == null) return null;
      return '${value['prefix'] ?? ''}${value['value'] as String? ?? captures[value['capture']]}';
    }

    var currency = binding('currency') ?? defaults['currency'] as String;
    var multiplier = 1;
    if (amountOutput.containsKey('denominationCapture')) {
      final label = captures[amountOutput['denominationCapture']];
      final denomination =
          (defaults['denominations'] as Map<String, dynamic>)[label]
              as Map<String, dynamic>;
      currency = denomination['currency'] as String;
      multiplier = denomination['multiplier'] as int;
    }
    final exponent =
        (defaults['exponents'] as Map<String, dynamic>)[currency] as int;
    final minor = _minor(
      captures[amountOutput['capture']]!,
      defaults,
      exponent,
      multiplier,
    );
    if (minor == null) return null;
    String? account;
    final accountOutput = output['accountLast4'] as Map<String, dynamic>?;
    if (accountOutput != null) {
      final raw = captures[accountOutput['capture']]!;
      final digits = accountOutput['preserveMask'] == true
          ? raw
          : String.fromCharCodes(raw.codeUnits.where(_digit));
      if (digits.length < 4 && accountOutput['allowShort'] != true) return null;
      account = digits.length < 4
          ? digits
          : digits.substring(digits.length - 4);
    }
    return SmsTransactionCandidate(
      amountMinor: minor,
      currencyCode: currency,
      direction: SmsDirection.values.byName(rule['direction'] as String),
      channel: SmsPaymentChannel.values.byName(rule['channel'] as String),
      occurredAt: receivedAt,
      bankName: rule['bankName'] as String,
      countryCode: rule['country'] as String,
      accountLast4: account,
      reference: binding('reference'),
      counterparty: binding('counterparty'),
    );
  }
}

final _number = RegExp(r'^[0-9]+(?:[,.][0-9]+)*$');
final _dateTime = RegExp(
  r'^(?:[0-9]{1,4}[-/][A-Za-z0-9]{1,9}[-/][0-9]{1,4}(?: [0-9:]+(?: ?[aApP][mM])?)?|[0-9]{1,2}:[0-9]{2}(?::[0-9]{2})?(?: ?[aApP][mM])?|[0-9]{1,2}[A-Za-z]{3,9}[0-9]{2,4}|[A-Za-z]{3,9} [0-9]{1,2}(?:,? [0-9]{4})?)$',
);

class _MatchBudget {
  int remaining = 8192;
  bool get exhausted => remaining < 0;
  bool consume() => --remaining >= 0;
}

bool _digit(int c) => c >= 48 && c <= 57;
bool _asciiLetter(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122);
bool _account(String value, int minimum) =>
    value.codeUnits.every(
      (c) => _digit(c) || const [88, 120, 42, 46, 45, 35].contains(c),
    ) &&
    value.codeUnits.where(_digit).length >= minimum;

bool _moneyLexical(String text, Map<String, dynamic> defaults) {
  final decimal = defaults['decimalMark'] as String;
  if (text.startsWith(decimal)) text = '0$text';
  final groupMark = decimal == '.' ? ',' : '.';
  final pieces = text.split(decimal);
  if (pieces.length > 2 || pieces.first.isEmpty) return false;
  if (pieces.length == 2 &&
      (pieces.last.isEmpty ||
          pieces.last.length > 3 ||
          !pieces.last.codeUnits.every(_digit))) {
    return false;
  }
  final groups = pieces.first.split(groupMark);
  if (groups.any((g) => g.isEmpty || !g.codeUnits.every(_digit))) return false;
  if (groups.length == 1) return true;
  if (defaults['grouping'] == 'none') return false;
  if (groups.first.length >
          (defaults['grouping'] == 'indian' && groups.length > 2 ? 2 : 3) ||
      groups.last.length != 3) {
    return false;
  }
  final middleLength = defaults['grouping'] == 'indian' ? 2 : 3;
  return groups
      .sublist(1, groups.length - 1)
      .every((g) => g.length == middleLength);
}

int? _minor(
  String raw,
  Map<String, dynamic> defaults,
  int exponent,
  int multiplier,
) {
  if (!_moneyLexical(raw, defaults)) return null;
  final decimal = defaults['decimalMark'] as String;
  var ungrouped = raw.replaceAll(decimal == '.' ? ',' : '.', '');
  if (ungrouped.startsWith(decimal)) ungrouped = '0$ungrouped';
  final pieces = ungrouped.split(decimal);
  final fraction = pieces.length == 2 ? pieces[1] : '';
  if (fraction.length > exponent) return null;
  final value =
      BigInt.parse('${pieces[0]}${fraction.padRight(exponent, '0')}') *
      BigInt.from(multiplier);
  if (value <= BigInt.zero || value > BigInt.from(portableMaxInteger)) {
    return null;
  }
  return value.toInt();
}

bool _equivalent(SmsTransactionCandidate a, SmsTransactionCandidate b) =>
    a.amountMinor == b.amountMinor &&
    a.currencyCode == b.currencyCode &&
    a.direction == b.direction &&
    a.channel == b.channel &&
    a.bankName == b.bankName &&
    a.countryCode == b.countryCode &&
    a.accountLast4 == b.accountLast4 &&
    a.reference == b.reference &&
    a.counterparty == b.counterparty;
