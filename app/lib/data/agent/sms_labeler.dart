/// Builds an SMS rule from values an AI copied out of one message: the
/// amount, and optionally the account, payee and reference. The model only
/// points at text; this writes the token grammar ([agentRuleGuide]) a small
/// model would get wrong.
///
/// The text between the values becomes fixed words, except words with
/// digits in them (dates, times, balances, other numbers), which become
/// "any text" so the rule reads the next message of the same shape too.
library;

import '../../domain/currency_digits.dart';
import '../sms_amounts.dart';
import '../sms_sender_role.dart';

/// Digits in any script the rule engine reads: ASCII, Arabic-Indic,
/// Persian and Thai.
const _digit = '[0-9٠-٩۰-۹๐-๙]';

/// Whitespace the way the rule engine reads it: any run of spaces, tabs,
/// line breaks and non-breaking spaces is one space, with none at the ends.
/// The engine reads every message this way and only accepts rule text
/// already written this way, so a rule built from an SMS with a line break
/// in it must be built from the message as the engine sees it.
String ruleWhitespace(String text) =>
    text.replaceAll(RegExp('[\u0009-\u000d \u00a0\u202f]+'), ' ').trim();

/// How [amount], copied from an SMS, writes numbers, as rule defaults: the
/// decimal mark, the grouping, and any digits other than ASCII. 1,250.00 and
/// 1.250,00 and ١٬٢٥٠ all read. [currency]'s decimal places settle 1.250:
/// three decimals for a dinar, a thousand separator for a peso.
Map<String, Object> numberStyle(String amount, String currency) {
  final scripts = <String>[
    'ascii',
    if (RegExp('[٠-٩]').hasMatch(amount)) 'arabic_indic',
    if (RegExp('[۰-۹]').hasMatch(amount)) 'persian',
    if (RegExp('[๐-๙]').hasMatch(amount)) 'thai',
  ];
  // Arabic's own separators read as the Latin ones.
  final plain = amount.replaceAll('٬', ',').replaceAll('٫', '.');
  final dots = '.'.allMatches(plain).length;
  final commas = ','.allMatches(plain).length;
  String decimal;
  if (dots > 0 && commas > 0) {
    decimal = plain.lastIndexOf('.') > plain.lastIndexOf(',') ? '.' : ',';
  } else if (dots + commas == 0) {
    decimal = '.';
  } else {
    final mark = dots > 0 ? '.' : ',';
    final tail = plain.substring(plain.lastIndexOf(mark) + 1);
    final groups = dots + commas > 1;
    // One mark before exactly three digits is grouping, unless the currency
    // has three decimals.
    decimal = groups || (tail.length == 3 && currencyDigits(currency) != 3)
        ? (mark == '.' ? ',' : '.')
        : mark;
  }
  final grouping =
      RegExp('^$_digit{1,2}([,.]$_digit{2})+[,.]$_digit{3}([,.]|\$)')
          .hasMatch(plain)
      ? 'indian'
      : 'western';
  return {
    'currency': currency,
    'decimalMark': decimal,
    'grouping': grouping,
    if (scripts.length > 1) 'digits': scripts,
    'exponents': <String, dynamic>{currency: smsRuleExponent(currency)},
  };
}

/// One value the AI copied, and how the rule captures it.
class _Label {
  _Label(this.field, this.value, this.start);
  final String field, value;
  final int start;
  int get end => start + value.length;
}

/// A format for [text], as `test_parser_rule` takes it. Throws
/// [ArgumentError] with a one-line fix when a value can't be used.
Map<String, Object?> buildLabeledFormat({
  required String text,
  required String amount,
  String? account,
  String? payee,
  String? reference,
  required String direction,
  required String channel,
  SmsSenderRole role = SmsSenderRole.bank,
  String? senderName,
  String country = 'IN',
  String currency = 'INR',
}) {
  text = ruleWhitespace(text);
  amount = ruleWhitespace(amount);
  account = account == null ? null : ruleWhitespace(account);
  payee = payee == null ? null : ruleWhitespace(payee);
  reference = reference == null ? null : ruleWhitespace(reference);
  if (!RegExp(r'^[A-Z]{2}$').hasMatch(country)) {
    throw ArgumentError('country must be a two-letter code, such as IN or AE.');
  }
  if (!RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
    throw ArgumentError(
      'currency must be a three-letter code, such as INR or AED.',
    );
  }
  if (!const {'debit', 'credit'}.contains(direction)) {
    throw ArgumentError('direction must be debit or credit.');
  }
  const channels = {'upi', 'card', 'bankTransfer', 'atm', 'wallet', 'other'};
  if (!channels.contains(channel)) {
    throw ArgumentError('channel must be one of ${channels.join(', ')}.');
  }
  final labels = <_Label>[];
  for (final (field, value) in [
    ('amount', amount),
    ('account', account),
    ('payee', payee),
    ('reference', reference),
  ]) {
    final copied = value?.trim();
    if (copied == null || copied.isEmpty) continue;
    var at = text.indexOf(copied);
    if (at < 0) at = text.toLowerCase().indexOf(copied.toLowerCase());
    if (at < 0) {
      throw ArgumentError(
        'The $field “$copied” isn’t in the message. Copy it exactly as written.',
      );
    }
    labels.add(_Label(field, text.substring(at, at + copied.length), at));
  }
  labels.sort((a, b) => a.start.compareTo(b.start));
  for (var i = 1; i < labels.length; i++) {
    if (labels[i].start < labels[i - 1].end) {
      throw ArgumentError(
        'The ${labels[i - 1].field} and ${labels[i].field} overlap. Copy '
        'each value on its own.',
      );
    }
  }

  final tokens = <Map<String, Object?>>[];
  var skips = 0;
  void addGap(List<_Part> parts) {
    for (final part in parts) {
      if (part.fixed) {
        tokens.add({'op': 'match_literal', 'value': part.text});
      } else {
        tokens.add({
          'op': 'capture_text',
          'name': 'skip${++skips}',
          'maxLength': 64,
        });
      }
    }
  }

  // Before the first value: from the last fixed words, so the rule starts on
  // text every message of this shape has.
  final before = _parts(text.substring(0, labels.first.start));
  final anchor = before.lastIndexWhere(
    (p) => p.fixed && RegExp('[A-Za-z]{2}').hasMatch(p.text),
  );
  if (anchor < 0) {
    throw ArgumentError(
      'There are no words before the ${labels.first.field}, so a rule can’t '
      'find where it starts.',
    );
  }
  addGap(before.sublist(anchor));

  for (final (i, label) in labels.indexed) {
    if (tokens.isNotEmpty && tokens.last['op'] != 'match_literal') {
      throw ArgumentError(
        'The ${label.field} comes right after other text with digits. Copy a '
        'value that has words before it.',
      );
    }
    tokens.add(_capture(label));
    final gapEnd = i + 1 < labels.length ? labels[i + 1].start : text.length;
    final gap = _parts(text.substring(label.end, gapEnd));
    final last = i + 1 == labels.length;
    if (last) {
      // After the last value: up to the next fixed words is enough.
      final fixed = gap.indexWhere((p) => p.fixed);
      if (gap.isEmpty) {
        tokens.add({'op': 'match_end'});
      } else if (fixed == 0) {
        tokens.add({'op': 'match_literal', 'value': gap.first.text});
      } else {
        throw ArgumentError(
          'The ${label.field} runs into other digits. Copy the whole value.',
        );
      }
    } else {
      if (gap.isEmpty || !gap.first.fixed) {
        throw ArgumentError(
          'The ${label.field} and ${labels[i + 1].field} need words between '
          'them. Leave one of them out.',
        );
      }
      addGap(gap);
    }
  }

  return {
    smsSenderRoleKey: role.name,
    'country': country,
    'defaults': numberStyle(amount.trim(), currency),
    'direction': direction,
    'channel': channel,
    'tokens': tokens,
    'output': {
      'amount': {'capture': 'amount'},
      if (labels.any((l) => l.field == 'account'))
        'accountLast4': {
          'capture': 'account',
          'operation': 'extract_account_suffix',
          'length': 4,
        },
      if (labels.any((l) => l.field == 'payee'))
        'counterparty': {'capture': 'party'}
      // A shop's or biller's own SMS: the sender is who was paid.
      else if (!role.holdsMoney && (senderName?.trim() ?? '').isNotEmpty)
        'counterparty': {'value': senderName!.trim()},
      if (labels.any((l) => l.field == 'reference'))
        'reference': {'capture': 'ref'},
    },
  };
}

Map<String, Object?> _capture(_Label label) => switch (label.field) {
  'amount' => {'op': 'capture_money', 'name': 'amount', 'maxLength': 32},
  'account' => {'op': 'capture_account', 'name': 'account', 'maxLength': 32},
  'payee' => {
    'op': 'capture_text',
    'name': 'party',
    'maxLength': 80,
    'rejectDateTime': true,
  },
  _ => {'op': 'capture_reference', 'name': 'ref', 'maxLength': 64},
};

/// A run of fixed words, or of words with digits in them.
class _Part {
  _Part(this.text, {required this.fixed});
  String text;
  final bool fixed;
}

/// [gap] split into fixed text and digit-bearing words. Spaces stay with the
/// fixed text around them; variable words next to each other merge.
List<_Part> _parts(String gap) {
  final parts = <_Part>[];
  var at = 0;
  for (final word in RegExp('\\S*$_digit\\S*').allMatches(gap)) {
    if (word.start > at) {
      parts.add(_Part(gap.substring(at, word.start), fixed: true));
    }
    if (parts.isNotEmpty && !parts.last.fixed) {
      // Only spaces between two numbers: one "any text" covers both.
    } else {
      parts.add(_Part('', fixed: false));
    }
    at = word.end;
  }
  if (at < gap.length) parts.add(_Part(gap.substring(at), fixed: true));
  // A fixed part of only spaces between two variable parts joins them.
  final merged = <_Part>[];
  for (final part in parts) {
    if (!part.fixed &&
        merged.length >= 2 &&
        merged.last.fixed &&
        merged.last.text.trim().isEmpty &&
        !merged[merged.length - 2].fixed) {
      merged.removeLast();
      continue;
    }
    merged.add(part);
  }
  return merged;
}
