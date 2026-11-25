import 'dart:convert';

import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../../domain/account.dart';
import '../../state/sms_import_store.dart';
import '../bank_sms_parser.dart';
import '../sms_amounts.dart';
import '../db/app_database.dart';
import '../user_sms_rules.dart';
import 'agent_suggestion_repository.dart';

/// How an AI app should write a format, for the rule tools' descriptions.
const agentRuleGuide =
    'A format matches an SMS as a sequence of tokens. '
    '{"op":"match_literal","value":"..."} is fixed text: ASCII letters match '
    'in any case, any run of whitespace is one space, and spaces at its ends '
    'count. The first token must be a literal (text before it is skipped); '
    'the last must be a literal or {"op":"match_end"}. Every capture needs '
    '"name" (camelCase, unique) and "maxLength" (1–256) and must be followed '
    'by a literal or match_end. Captures: capture_money (the amount, "," '
    'grouping and "." decimals), capture_account (a masked number such as '
    'XX1234; optional "minDigits" 1–4), capture_reference (letters, digits, '
    'hyphens), capture_text (any text; optional "excludeCharacters" and '
    '"rejectDateTime": true), capture_datetime, capture_number, capture_enum '
    '("values": [...]). 3–48 tokens. '
    'Format fields: "direction" "debit" or "credit" (on the user\'s account), '
    '"channel" one of upi, card, bankTransfer, atm, wallet, other, and '
    '"output": {"amount":{"capture":"amount"}, '
    '"accountLast4":{"capture":"account","operation":"extract_account_suffix",'
    '"length":4}, "counterparty":{"capture":"party"} or {"value":"ATM"}, '
    '"reference":{"capture":"ref"}}; only amount is required. Optional '
    '"requires": {"all":[...],"any":[...],"none":[...]} literal selectors '
    'tell similar messages apart. "senderRole" says who sends it: bank, '
    'card or wallet when the SMS reports the user\'s own account there; '
    'merchant, biller, lender, government or other when it only says money '
    'moved (a refund, an order paid, a bill received). Such a sender is never '
    'an account: the bank\'s own SMS or the user gives it. Outside India, '
    'give "country" (ISO code, e.g. AE) and "defaults": {"currency":"AED", '
    '"decimalMark":"." or ",", "grouping":"western"}; a sender a bundled '
    'bank uses keeps that bank\'s country. Never put a '
    'sample\'s amount, merchant, '
    'date or account number in a literal: capture it, so the rule reads every '
    'message of that shape. Read the bank\'s existing formats with '
    'get_parser_rules first.';

class RuleSample {
  const RuleSample(this.text, {this.sender});
  final String text;

  /// The sender it came from; the rule's first sender when null.
  final String? sender;
}

/// What a rule made of its samples, with the pack it was tested in.
class RuleTrial {
  const RuleTrial({
    required this.bankName,
    required this.senders,
    required this.format,
    required this.results,
  });
  final String bankName;
  final List<String> senders;

  /// The format as it would be saved.
  final Map<String, dynamic> format;

  /// One per sample: whether the new rule read it, and what it read.
  final List<({bool matched, PortableParseResult result})> results;

  bool get allMatched => results.every((r) => r.matched);

  Map<String, Object?> toJson() => {
    'bank_name': bankName,
    'senders': senders,
    'all_samples_read_by_new_rule': allMatched,
    'samples': [
      for (final (index, r) in results.indexed)
        {
          'sample': index,
          'read_by_new_rule': r.matched,
          'classification': r.result.classification.name,
          'reason': r.result.reason,
          if (!r.matched && r.result.ruleId != null)
            'read_by_rule': r.result.ruleId,
          if (r.result.candidate case final c?) 'read': readCandidate(c),
        },
    ],
  };

  /// The fields a person checks, from a parse result.
  static Map<String, Object?> readCandidate(SmsTransactionCandidate c) => {
    'amount': smsRuleAmountText(c.amountMinor, c.currencyCode),
    'currency': c.currencyCode,
    'direction': c.direction.name,
    'channel': c.channel.name,
    'account_last4': ?c.accountLast4,
    'counterparty': ?c.counterparty,
    'reference': ?c.reference,
    'category': ?c.category?.name,
  };
}

/// Tries SMS rules an AI app writes against sample messages, in the same
/// engine the app parses with, and turns a working one into a suggestion.
class AgentRuleLab {
  AgentRuleLab(this.database);
  final AppDatabase database;

  /// The label a rule under test gets in its ID.
  static const _trialLabel = 'new';

  Future<RuleTrial> trial({
    String? bankName,
    required List<String> senders,
    required Map<String, dynamic> format,
    required List<RuleSample> samples,
    // A rule the new one is to replace: left out of the clash check.
    int? ignoringRuleId,
  }) async {
    if (samples.isEmpty || samples.length > 20) {
      throw ArgumentError('Give 1–20 sample messages.');
    }
    final canonical = <String>[];
    for (final sender in senders) {
      final normalized = normalizeRuleSender(sender);
      if (normalized == null) {
        throw ArgumentError('“$sender” isn’t a sender ID, such as HDFCBK.');
      }
      if (!canonical.contains(normalized)) canonical.add(normalized);
    }
    if (canonical.isEmpty || canonical.length > 16) {
      throw ArgumentError('Give 1–16 sender IDs.');
    }
    final bundled = await bundledSmsPacks(
      where: (text) => canonical.any((s) => text.contains('"$s"')),
    );
    final saved = [
      for (final r in await UserSmsRuleRepository(database).load())
        if (r.id != ignoringRuleId) r,
    ];
    final name = _bankName(canonical, bundled, saved, bankName);
    final clean = {...format}
      ..remove('id')
      ..remove('senders')
      ..putIfAbsent('classification', () => 'completed');
    if (clean.containsKey(smsSenderRoleKey) &&
        SmsSenderRole.tryParse(clean[smsSenderRoleKey]) == null) {
      throw ArgumentError(
        'senderRole must be one of '
        '${SmsSenderRole.values.map((r) => r.name).join(', ')}.',
      );
    }
    // A sender a bundled pack knows reads SMS for that pack's country.
    final known = {
      for (final pack in bundled)
        for (final rule in (jsonDecode(pack) as Map)['rules'] as List)
          if ((rule['senders'] as List).any(canonical.contains))
            rule['country'] as String,
    };
    if (known.length == 1) {
      clean[smsRuleCountryKey] = known.single;
    } else if (clean.containsKey(smsRuleCountryKey) &&
        ruleCountry(clean) != clean[smsRuleCountryKey]) {
      throw ArgumentError(
        'country must be a two-letter ISO code, such as IN, AE or US.',
      );
    }
    if (clean['defaults'] case {'currency': final Object currency}
        when currency is! String || !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      throw ArgumentError(
        'defaults.currency must be a three-letter ISO code, such as INR, '
        'AED or USD.',
      );
    }
    final RuntimeRulePack user;
    try {
      user = await compileUserSmsRules(
        saved,
        extra: (_trialLabel, name, canonical, clean),
      );
    } on RuleValidationException catch (error) {
      throw ArgumentError('The rule isn’t valid: ${error.message}.');
    }
    final PortableSmsEngine engine;
    try {
      const compiler = RuleCompiler();
      engine = BankSmsParser(
        compiler.mergeRuntimePacks([
          for (final pack in bundled)
            compiler.loadRuntime(jsonDecode(pack) as Map<String, dynamic>),
          user,
        ]),
      );
    } on RuleValidationException catch (error) {
      throw ArgumentError(
        'The rule clashes with an existing one: ${error.message}.',
      );
    }
    final id = userSmsRuleId(name, _trialLabel, country: ruleCountry(clean));
    return RuleTrial(
      bankName: name,
      senders: canonical,
      format: clean,
      results: [
        for (final sample in samples)
          () {
            final result = engine.parse(
              BankSms(
                sender: sample.sender ?? canonical.first,
                body: sample.text,
                receivedAt: DateTime.now(),
              ),
            );
            return (matched: result.ruleId == id, result: result);
          }(),
      ],
    );
  }

  /// A rule that read every sample, ready for the user to approve.
  Future<AgentSuggestionDraft> prepare({
    String? bankName,
    required List<String> senders,
    required Map<String, dynamic> format,
    required List<RuleSample> samples,
    String? reason,
    // The user chose the account for this sender themselves, so it isn't left
    // for review.
    bool accountAssigned = false,
    // A person teaching by hand may accept choosing the account and category
    // in review each time; an AI app suggesting a rule may not.
    bool allowChoosing = false,
    int? ignoringRuleId,
  }) async {
    final trial = await this.trial(
      bankName: bankName,
      senders: senders,
      format: format,
      samples: samples,
      ignoringRuleId: ignoringRuleId,
    );
    final missed = [
      for (final (index, r) in trial.results.indexed)
        if (!r.matched) '$index (${r.result.reason})',
    ];
    if (missed.isNotEmpty) {
      throw ArgumentError(
        'The rule didn’t read sample ${missed.join(', ')}. Test it with '
        'test_parser_rule until it reads every sample.',
      );
    }
    final first = trial.results.first.result.candidate!;
    final read = RuleTrial.readCandidate(first);
    // Most SMS give an account or let the app tell the category. With neither,
    // every payment would need both chosen by hand, so such a rule isn't worth
    // suggesting.
    final category = first.category;
    final role = ruleSenderRole(trial.format);
    final picks = userPicks(first, role, accountAssigned);
    final knowsCategory = !picks.contains('category');
    if (picks.length == 2 && !allowChoosing) {
      throw ArgumentError(
        role.holdsMoney
            ? 'This SMS names no account and the app can’t tell its category '
                  'from it, so a rule would leave the user choosing both on '
                  'every payment. Don’t suggest it. Only suggest a rule for SMS '
                  'that carry an account number or a clear category (refund, '
                  'salary, interest…). The user picks the other one in SMS '
                  'review; tell them which.'
            : 'A ${role.name}’s SMS never gives the account, and the app can’t '
                  'tell this one’s category, so the user would choose both on '
                  'every payment. Don’t suggest it: the bank’s own SMS for it is '
                  'enough.',
      );
    }
    final readLabels = [
      'amount',
      if (format['output'] case {'accountLast4': _}) 'account',
      if (format['output'] case {'counterparty': _}) 'payee',
      if (format['output'] case {'reference': _}) 'reference',
    ];
    final cleanReason = reason?.trim();
    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.parserRule,
      target: jsonEncode([
        userSmsBankId(trial.bankName, country: ruleCountry(trial.format)),
        trial.format['tokens'],
      ]),
      payload: {
        'bankName': trial.bankName,
        'senders': trial.senders,
        'format': trial.format,
        'samples': [for (final s in samples) s.text],
      },
      summary: 'New SMS rule · ${trial.bankName}',
      detail: [
        'From: ${trial.senders.join(', ')}',
        'Reads: ${readLabels.join(', ')}',
        'Read all ${samples.length} sample${samples.length == 1 ? '' : 's'}, '
            'e.g. ${currencyPrefix(first.currencyCode)}${read['amount']} '
            '${first.direction.name}'
            '${first.counterparty == null ? '' : ' · ${first.counterparty}'}'
            '${first.accountLast4 == null ? '' : ' · ••${first.accountLast4}'}',
        if (knowsCategory) 'Category: ${category!.name}',
        // The suggestions screen reads these two lines; keep their wording.
        if (!role.holdsMoney)
          'Sender: ${role.name}, not an account. Matched to the bank’s SMS '
              'for the same amount, or you pick the account',
        if (picks.contains('account')) 'Missing: account',
        if (!knowsCategory) 'Missing: category',
        'Sample: ${_clip(samples.first.text)}',
      ],
      reason: cleanReason == null || cleanReason.isEmpty
          ? null
          : cleanReason.length > 280
          ? '${cleanReason.substring(0, 279)}…'
          : cleanReason,
    );
  }

  /// What the user picks in SMS review for a message a rule reads: the
  /// account when it names none, the category when the app can't tell it.
  /// A shop's or biller's SMS never gives the account, even when it quotes
  /// the bank account's number.
  static List<String> userPicks(
    SmsTransactionCandidate c, [
    SmsSenderRole role = SmsSenderRole.bank,
    // The account was chosen up front, for every message from this sender.
    bool accountKnown = false,
  ]) {
    final category = c.category;
    final knowsCategory =
        category != null &&
        !category.isFallback &&
        category.name.toLowerCase() != 'personal';
    return [
      if (!accountKnown && (c.accountLast4 == null || !role.holdsMoney))
        'account',
      if (!knowsCategory) 'category',
    ];
  }

  /// The bundled formats for [sender] and the user's own rules, as examples.
  Future<Map<String, Object?>> rules({String? sender, int limit = 12}) async {
    final normalized = sender == null ? null : normalizeRuleSender(sender);
    if (sender != null && normalized == null) {
      throw ArgumentError('“$sender” isn’t a sender ID, such as HDFCBK.');
    }
    final saved = await UserSmsRuleRepository(database).load();
    final bundled = normalized == null
        ? const <Map<String, dynamic>>[]
        : [
            for (final pack in await bundledSmsPacks(
              where: (text) => text.contains('"$normalized"'),
            ))
              for (final rule in (jsonDecode(pack) as Map)['rules'] as List)
                if ((rule['senders'] as List).contains(normalized))
                  rule as Map<String, dynamic>,
          ];
    return {
      'sender': ?normalized,
      if (bundled.isNotEmpty) 'bank': bundled.first['bankName'],
      if (normalized != null) 'bundled_format_count': bundled.length,
      'bundled_formats': [
        for (final rule in bundled.take(limit))
          {
            'id': rule['id'],
            'direction': rule['direction'],
            'channel': rule['channel'],
            if ((rule['requires'] as List).any((r) => (r as Map).isNotEmpty))
              'requires': rule['requires'],
            'tokens': rule['tokens'],
            'output': rule['output'],
          },
      ],
      'user_rules': [
        for (final rule in saved)
          if (normalized == null || rule.senders.contains(normalized))
            {
              'id': rule.id,
              'bank': rule.bankName,
              'senders': rule.senders,
              'format': rule.format,
            },
      ],
    };
  }

  /// One bank name per sender: the bundled bank's, else an earlier user
  /// rule's, so the messages land on the same accounts as the bank's others.
  static String _bankName(
    List<String> senders,
    List<String> bundled,
    List<UserSmsRule> saved,
    String? given,
  ) {
    final known = <String>{
      for (final pack in bundled)
        for (final rule in (jsonDecode(pack) as Map)['rules'] as List)
          if ((rule['senders'] as List).any(senders.contains))
            rule['bankName'] as String,
      for (final sender in senders) ?BankSmsParser.hostOnlySenders[sender],
    };
    if (known.isEmpty) {
      known.addAll({
        for (final rule in saved)
          if (rule.senders.any(senders.contains)) rule.bankName,
      });
    }
    if (known.length > 1) {
      throw ArgumentError(
        'These senders belong to different banks (${known.join(', ')}). '
        'Write one rule per bank.',
      );
    }
    final name = known.firstOrNull ?? given?.trim() ?? '';
    if (name.isEmpty || name.length > 40) {
      throw ArgumentError(
        'Give bank_name: the bank or service as the user knows it, '
        'up to 40 characters.',
      );
    }
    return name;
  }

  static String _clip(String text) {
    final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length > 140 ? '${flat.substring(0, 139)}…' : flat;
  }
}
