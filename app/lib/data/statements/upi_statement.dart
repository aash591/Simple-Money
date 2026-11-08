/// What a UPI app's PDF statement (Google Pay, PhonePe, Paytm) says
/// happened, read from the PDF's text before anything touches the ledger.
/// A bank's own PDF statement is read by bank_pdf_statement.dart.
///
/// The parsers work on lines, not on page layout: a PDF's text comes out in
/// the order its generator drew it, which differs a little between extractors
/// (spacing, wrapped names, a date fused with the next column). Each parser
/// therefore anchors on the few lines a transaction always has and reads every
/// other field by pattern within that transaction's lines.
library;

import 'bank_pdf_statement.dart';

enum UpiStatementSource {
  googlePay('Google Pay'),
  phonePe('PhonePe'),
  paytm('Paytm'),
  bank('Bank PDF'),
  csv('CSV'),
  excel('Excel');

  const UpiStatementSource(this.label);
  final String label;
}

enum UpiStatementDirection { debit, credit, selfTransfer }

/// One of the user's own bank accounts as a statement names it: the bank and
/// the trailing digits of its number — four for Google Pay and PhonePe, often
/// only two for Paytm.
class StatementAccount {
  const StatementAccount({this.bank, required this.digits});
  final String? bank;
  final String digits;

  /// Identity across rows and imports; the bank is compared loosely.
  String get key => '${_bankKey(bank)}|$digits';
  String get label => digits.isEmpty
      ? bank ?? 'Your other account'
      : bank == null
      ? '•• $digits'
      : '$bank •• $digits';

  /// One of the user's accounts the statement doesn't identify: the other
  /// side of a transfer to or from the user's own name.
  static const other = StatementAccount(digits: '');

  /// The user's cash: where an ATM withdrawal goes, and a deposit comes
  /// from.
  static const cash = StatementAccount(bank: 'Cash in hand', digits: '');

  @override
  bool operator ==(Object other) =>
      other is StatementAccount && other.key == key;
  @override
  int get hashCode => key.hashCode;
}

String _bankKey(String? bank) =>
    (bank ?? '').toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');

class UpiStatementRow {
  const UpiStatementRow({
    required this.date,
    required this.direction,
    required this.amountMinor,
    required this.counterparty,
    this.reference,
    this.account,
    this.toAccount,
    this.counterpartyBank,
    this.counterpartyId,
    this.narration,
  });
  final DateTime date;
  final UpiStatementDirection direction;

  /// Paise; always positive, the direction says which way it went.
  final int amountMinor;

  /// Who was paid or paid you; "Self transfer" for a self transfer.
  final String counterparty;

  /// The UPI reference (RRN / UTR) banks also quote in their SMS, or the
  /// app's own transaction id when the statement has no UPI reference.
  final String? reference;

  /// The user's account the money left (debit, self transfer) or reached
  /// (credit). Null when the statement doesn't say.
  final StatementAccount? account;

  /// A self transfer's destination, when the statement names it.
  final StatementAccount? toAccount;

  /// The bank on the other side, when a bank's narration names it
  /// ("UPI/ASHIQUE M/UBIN/…" → Union Bank of India).
  final String? counterpartyBank;

  /// The other side's UPI id, when a bank's narration gives it beside a
  /// name it cuts short ("…/ASHIQUE /SBIN/ashique4786-1@").
  final String? counterpartyId;

  /// The bank's whole description of the row, when it has more to say than
  /// the payee ("UPI/DR/…/Google I/ICIC/gpayrechar/UPI" is a recharge).
  final String? narration;

  UpiStatementRow copyWith({
    UpiStatementDirection? direction,
    String? counterparty,
    String? reference,
    StatementAccount? account,
    StatementAccount? toAccount,
  }) => UpiStatementRow(
    date: date,
    direction: direction ?? this.direction,
    amountMinor: amountMinor,
    counterparty: counterparty ?? this.counterparty,
    reference: reference ?? this.reference,
    account: account ?? this.account,
    toAccount: toAccount ?? this.toAccount,
    counterpartyBank: counterpartyBank,
    counterpartyId: counterpartyId,
    narration: narration,
  );
}

/// Who a statement belongs to, as far as it says: the holder's names and
/// their UPI handles — an email's or UPI id's part before the @, or a phone
/// number. Money to or from them is a transfer between their own accounts.
class StatementOwner {
  const StatementOwner({this.names = const {}, this.handles = const {}});

  /// Normalized: lowercase words, honorifics dropped ("ashique m").
  final Set<String> names;
  final Set<String> handles;

  bool get isEmpty => names.isEmpty && handles.isEmpty;

  StatementOwner merge(StatementOwner other) => StatementOwner(
    names: {...names, ...other.names},
    handles: {...handles, ...other.handles},
  );

  /// "Mr. ASHIQUE  M" → "ashique m"; empty when it isn't a name.
  static String normalizeName(String raw) {
    final words = raw
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z\s.]'), ' ')
        .replaceAll('.', ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .toList();
    if (words.isNotEmpty &&
        const {
          'mr',
          'mrs',
          'ms',
          'miss',
          'dr',
          'shri',
          'smt',
        }.contains(words.first)) {
      words.removeAt(0);
    }
    return words.join(' ');
  }

  /// Whether [counterparty] — a name as a statement prints it, or a UPI id
  /// such as "ashique4786-1@" — is the owner; [id] is the UPI id a bank
  /// prints beside a name.
  ///
  /// A bank that cuts names short ("ASHIQUE ") and masks the holder's email
  /// ("a*********6@gmail.com") is matched on both: the cut name must begin
  /// the holder's, and the id must fit the mask.
  bool matches(String counterparty, {String? id}) {
    bool byHandle(String raw) {
      final text = raw.trim().toLowerCase();
      if (text.isEmpty) return false;
      for (final handle in handles) {
        if (!handle.contains('*') &&
            text.startsWith(handle) &&
            (text.length == handle.length ||
                !RegExp(r'[a-z]').hasMatch(text[handle.length]))) {
          return true;
        }
      }
      return false;
    }

    if (byHandle(counterparty) || (id != null && byHandle(id))) return true;
    final name = normalizeName(counterparty);
    if (name.contains(' ') && names.contains(name)) return true;
    if (id == null ||
        name.length < 5 ||
        !names.any((n) => n.startsWith(name))) {
      return false;
    }
    final token = RegExp(r'^[a-z0-9._]+').firstMatch(id.toLowerCase())?[0];
    return token != null && handles.any((h) => _fitsMask(token, h));
  }

  static bool _fitsMask(String token, String mask) {
    if (!mask.contains('*') || token.length != mask.length) return false;
    for (var i = 0; i < mask.length; i++) {
      if (mask[i] != '*' && mask[i] != token[i]) return false;
    }
    return true;
  }

  Map<String, Object> toJson() => {
    'names': names.toList(),
    'handles': handles.toList(),
  };

  static StatementOwner fromJson(Map<String, Object?> json) => StatementOwner(
    names: {...(json['names'] as List? ?? const []).whereType<String>()},
    handles: {...(json['handles'] as List? ?? const []).whereType<String>()},
  );
}

// Not a masked one ("a*********6@gmail.com"): its tail isn't the handle.
final _email = RegExp(
  r'(?<![A-Za-z0-9._%+*-])([A-Za-z0-9._%+-]{3,})@([A-Za-z0-9.-]+\.[A-Za-z]{2,})',
);
final _maskedEmail = RegExp(
  r'(?<![A-Za-z0-9._%+-])([A-Za-z0-9])(\*{3,})([A-Za-z0-9])@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
);
// A bank's or a service's own mailbox: "sbi.70773@sbi.co.in".
final _serviceMailbox = RegExp(
  r'care|support|help|service|reply|info|customer|branch|alert|statement',
);
final _phone = RegExp(
  r'(?:\+91[\s-]?|statement\s+for\s+)([6-9]\d{9})\b',
  caseSensitive: false,
);
final _honorific = RegExp(
  r'^(?:mr|mrs|ms|miss|shri|smt)\.?\s+\S',
  caseSensitive: false,
);
final _honorificGap = RegExp(
  r'^((?:mr|mrs|ms|miss|shri|smt)\.?)\s+',
  caseSensitive: false,
);
final _plainName = RegExp(r"^[A-Za-z][A-Za-z.' ]{1,40}$");
const _notNames = {
  'account',
  'statement',
  'bank',
  'branch',
  'transaction',
  'period',
  'customer',
  'india',
  'contact',
  'queries',
  'details',
  'summary',
  'savings',
  'page',
  'status',
  'kyc',
  'address',
  'name',
  'email',
  'mobile',
  'nominee',
  'balance',
  'opening',
  'closing',
};

/// The owner a statement's header names: its emails and phone number as
/// handles, and the holder's name — after an honorific ("Mr. ASHIQUE M"), on
/// the line before a contact line, or in [nameLines], the lines a bank
/// prints its holder on.
StatementOwner statementOwnerIn(
  List<String> lines, {
  List<String> nameLines = const [],
}) {
  final names = <String>{};
  final handles = <String>{};
  bool plausible(String line) {
    final name = StatementOwner.normalizeName(line);
    return _plainName.hasMatch(line.trim()) &&
        name.contains(' ') &&
        name.split(' ').length <= 4 &&
        !name.split(' ').any(_notNames.contains);
  }

  for (final (i, line) in lines.indexed) {
    for (final m in _email.allMatches(line)) {
      final local = m[1]!.toLowerCase();
      if (_serviceMailbox.hasMatch(local) ||
          local.startsWith(m[2]!.toLowerCase().split('.').first)) {
        continue;
      }
      handles.add(local);
      // Paytm prints the holder's name on the line before their contact.
      if (i > 0 && plausible(lines[i - 1])) {
        names.add(StatementOwner.normalizeName(lines[i - 1]));
      }
    }
    for (final m in _maskedEmail.allMatches(line)) {
      handles.add('${m[1]}${m[2]}${m[3]}'.toLowerCase());
    }
    for (final m in _phone.allMatches(line)) {
      handles.add(m[1]!);
    }
    if (_honorific.hasMatch(line)) {
      // "MR  HARIKRISHNA P": a PDF can set the title apart from the name.
      final name = line
          .replaceFirstMapped(_honorificGap, (m) => '${m[1]} ')
          .split(RegExp(r'\s{2,}|,|:'))
          .first;
      if (plausible(name)) names.add(StatementOwner.normalizeName(name));
    }
  }
  // Lines where a bank might print the holder, when nothing surer named
  // them: the line under "Mr. ASHIQUE M" is their address.
  if (names.isEmpty) {
    if (nameLines.where(plausible).firstOrNull case final line?) {
      names.add(StatementOwner.normalizeName(line));
    }
  }
  return StatementOwner(names: names, handles: handles);
}

class UpiStatement {
  const UpiStatement({
    required this.source,
    required this.rows,
    this.unreadable = 0,
    this.reportedSentMinor,
    this.reportedReceivedMinor,
    this.owner = const StatementOwner(),
  });
  final UpiStatementSource source;
  final List<UpiStatementRow> rows;

  /// Who the statement says it belongs to.
  final StatementOwner owner;

  UpiStatement withOwner(StatementOwner owner) => UpiStatement(
    source: source,
    rows: rows,
    unreadable: unreadable,
    reportedSentMinor: reportedSentMinor,
    reportedReceivedMinor: reportedReceivedMinor,
    owner: owner,
  );

  /// Transactions that were found but couldn't be read completely.
  final int unreadable;

  /// The statement's own printed totals, when it has them. Self transfers
  /// are excluded from both, as every one of these apps does.
  final int? reportedSentMinor, reportedReceivedMinor;

  int get sentMinor => _sum(UpiStatementDirection.debit);
  int get receivedMinor => _sum(UpiStatementDirection.credit);
  int _sum(UpiStatementDirection direction) => rows
      .where((r) => r.direction == direction)
      .fold(0, (sum, r) => sum + r.amountMinor);

  /// False when the statement prints totals and the rows don't add up to
  /// them — a sign its format changed and something was misread.
  bool get totalsMatch =>
      unreadable == 0 &&
      (reportedSentMinor == null || reportedSentMinor == sentMinor) &&
      (reportedReceivedMinor == null || reportedReceivedMinor == receivedMinor);
}

/// Reads [text] as whichever supported statement it is, or null when it is
/// none of them.
UpiStatement? parseUpiStatement(String text) {
  final lines = statementLines(text);
  final joined = lines.join(' ');
  final lower = joined.toLowerCase();
  final UpiStatement statement;
  if (lower.contains('google pay') && lower.contains('upi transaction id')) {
    statement = parseGooglePayStatement(lines);
  } else if (lower.contains('paytm') && lower.contains('upi ref no')) {
    statement = parsePaytmStatement(lines);
  } else if (lower.contains('phonepe') &&
      RegExp(r'transaction\s*id', caseSensitive: false).hasMatch(joined)) {
    statement = parsePhonePeStatement(lines);
  } else if (parseBankPdfStatement(lines) case final bank?) {
    statement = bank;
  } else {
    return null;
  }
  // The holder is named at the top; the rest is transactions.
  return statement.withOwner(
    statement.owner.merge(statementOwnerIn(lines.take(40).toList())),
  );
}

/// The text's non-empty lines with runs of whitespace collapsed.
List<String> statementLines(String text) => [
  for (final raw in text.split(RegExp(r'\r?\n|\r')))
    if (raw.replaceAll(RegExp(r'\s+'), ' ').trim() case final line
        when line.isNotEmpty)
      line,
];

const _amount = r'([0-9][0-9,]*(?:\.[0-9]{1,2})?)';
const _currency = r'(?:₹|Rs\.?|INR)?\s?';
final _plainAmount = RegExp('^$_currency$_amount\$');

/// "6,23,366.67" → 62336667 paise.
int? parseStatementAmount(String value) {
  final match = RegExp(r'^([0-9]+)(?:\.([0-9]{1,2}))?$')
      .firstMatch(value.replaceAll(',', ''));
  if (match == null) return null;
  final rupees = int.parse(match[1]!);
  final paise = int.parse((match[2] ?? '').padRight(2, '0'));
  final minor = rupees * 100 + paise;
  return minor > 0 ? minor : null;
}

int? _month(String name) {
  const months = [
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];
  final index = months.indexOf(name.toLowerCase());
  return index < 0 ? null : index + 1;
}

/// Hours on a 24-hour clock from "02:35" + "PM".
int _hour(int hour, String meridiem) {
  final pm = meridiem.toLowerCase() == 'pm';
  return hour % 12 + (pm ? 12 : 0);
}

DateTime? _date(
  int year,
  String month,
  String day, [
  int hour = 12,
  int minute = 0,
]) {
  final m = _month(month);
  final d = int.tryParse(day);
  if (m == null || d == null || d < 1 || d > 31) return null;
  final date = DateTime(year, m, d, hour, minute);
  // Reject a rolled-over date such as 31 Feb → 3 Mar.
  return date.month == m ? date : null;
}

final _time = RegExp(r'^(\d{1,2})[:\s](\d{2})\s?([AaPp][Mm])(?:\s+(.*))?$');

// ─── Google Pay ──────────────────────────────────────────────────────────────
//
//   01 Apr, 2026
//   04:12 PM
//   Self transfer to State Bank of India 2199     ← what happened
//   UPI Transaction ID: 609191990216
//   Paid by Union Bank of India 3225              ← the user's account
//   2,500
//
// For money received the account line reads "Paid to <bank> 1234": it is the
// line after the UPI id, never the transaction's own "Paid to <payee>".

final _gpayDate = RegExp(r'^(\d{1,2}) ([A-Za-z]{3}),? (\d{4})(?:\s+(.*))?$');
final _gpayDayMonth = RegExp(r'^(\d{1,2}) ([A-Za-z]{3}),?$');
final _gpayYear = RegExp(r'^(\d{4})(?:\s+(.*))?$');
final _gpayUpiId = RegExp(
  r'UPI\s*Transaction\s*ID\s*:?\s*([0-9A-Za-z]+)',
  caseSensitive: false,
);
final _gpayAnchor = RegExp(
  r'^(Paid to|Sent to|Paid for|Received from|Refund from|Cashback from|Self transfer to)\s+(.+)$',
  caseSensitive: false,
);
final _gpayAccount = RegExp(
  r'^Paid (?:by|to) (.+?) (\d{4})$',
  caseSensitive: false,
);
final _bankAndDigits = RegExp(r'^(.+?)\s*-?\s*(\d{2,4})$');
final _gpayTotals = RegExp(
  'Sent\\s+(?:Received\\s+)?$_currency$_amount\\s+(?:Received\\s+)?$_currency$_amount',
);

UpiStatement parseGooglePayStatement(List<String> input) {
  // Older exports split the date over two lines: "01 Sep," then "2025".
  final lines = <String>[];
  for (var i = 0; i < input.length; i++) {
    final dayMonth = _gpayDayMonth.firstMatch(input[i]);
    final year = i + 1 < input.length
        ? _gpayYear.firstMatch(input[i + 1])
        : null;
    if (dayMonth != null && year != null) {
      lines.add(
        '${dayMonth[1]} ${dayMonth[2]}, ${year[1]}'
        '${year[2] == null ? '' : ' ${year[2]}'}',
      );
      i++;
    } else {
      lines.add(input[i]);
    }
  }

  final blocks = <_Block>[];
  for (final line in lines) {
    var rest = line;
    final date = _gpayDate.firstMatch(rest);
    if (date != null) {
      blocks.add(_Block(int.parse(date[3]!), date[2]!, date[1]!));
      rest = date[4] ?? '';
    }
    final block = blocks.lastOrNull;
    if (block == null) continue;
    if (block.time == null) {
      final time = _time.firstMatch(rest);
      if (time != null) {
        block.time = time;
        rest = time[4] ?? '';
      }
    }
    if (rest.isNotEmpty) block.lines.add(rest);
  }

  final rows = <UpiStatementRow>[];
  var unreadable = 0;
  for (final block in blocks) {
    final row = _googlePayRow(block);
    if (row == null) {
      unreadable++;
    } else {
      rows.add(row);
    }
  }
  final totals = _gpayTotals.firstMatch(lines.take(40).join(' '));
  return UpiStatement(
    source: UpiStatementSource.googlePay,
    rows: rows,
    unreadable: unreadable,
    reportedSentMinor: totals == null ? null : parseStatementAmount(totals[1]!),
    reportedReceivedMinor: totals == null
        ? null
        : parseStatementAmount(totals[2]!),
  );
}

UpiStatementRow? _googlePayRow(_Block block) {
  final lines = block.lines;
  final upiIndex = lines.indexWhere(_gpayUpiId.hasMatch);
  final before = upiIndex < 0 ? lines : lines.sublist(0, upiIndex);
  final after = upiIndex < 0 ? lines : lines.sublist(upiIndex + 1);

  final anchorIndex = before.indexWhere(_gpayAnchor.hasMatch);
  if (anchorIndex < 0) return null;
  final anchor = _gpayAnchor.firstMatch(before[anchorIndex])!;
  final kind = anchor[1]!.toLowerCase();
  // A long payee name wraps onto the lines before the UPI id.
  final counterparty = [
    anchor[2]!,
    ...before.skip(anchorIndex + 1).where((l) => !_plainAmount.hasMatch(l)),
  ].join(' ').trim();

  final amountLine =
      after.where(_plainAmount.hasMatch).firstOrNull ??
      lines.where(_plainAmount.hasMatch).firstOrNull;
  final amount = amountLine == null
      ? null
      : parseStatementAmount(_plainAmount.firstMatch(amountLine)![1]!);
  if (amount == null) return null;

  final accountMatch = after.map(_gpayAccount.firstMatch).nonNulls.firstOrNull;
  final account = accountMatch == null
      ? null
      : StatementAccount(bank: accountMatch[1], digits: accountMatch[2]!);

  final time = block.time;
  final date = _date(
    block.year,
    block.month,
    block.day,
    time == null ? 12 : _hour(int.parse(time[1]!), time[3]!),
    time == null ? 0 : int.parse(time[2]!),
  );
  if (date == null) return null;

  final reference = upiIndex < 0
      ? null
      : _gpayUpiId.firstMatch(lines[upiIndex])![1];
  if (kind == 'self transfer to') {
    final to = _bankAndDigits.firstMatch(counterparty);
    return UpiStatementRow(
      date: date,
      direction: UpiStatementDirection.selfTransfer,
      amountMinor: amount,
      counterparty: 'Self transfer',
      reference: reference,
      account: account,
      toAccount: to == null
          ? null
          : StatementAccount(bank: to[1], digits: to[2]!),
    );
  }
  final credit = const {
    'received from',
    'refund from',
    'cashback from',
  }.contains(kind);
  return UpiStatementRow(
    date: date,
    direction: credit
        ? UpiStatementDirection.credit
        : UpiStatementDirection.debit,
    amountMinor: amount,
    counterparty: counterparty,
    reference: reference,
    account: account,
  );
}

class _Block {
  _Block(this.year, this.month, this.day);
  final int year;
  final String month, day;
  RegExpMatch? time;
  final lines = <String>[];
}

// ─── PhonePe ─────────────────────────────────────────────────────────────────
//
//   Jul 08, 2026
//   08 31 am
//   DEBIT ₹201                       ← sometimes on the description's line
//   Mobile recharged 8075215356
//   Transaction ID NX2607080831…
//   UTR No. 635714896440
//   Paid by XXXXXX2199
//
// Some extractors drop PhonePe's spaces ("PaymenttoGoogle", "Paidby"), so
// every keyword below allows them to be missing.

final _phonePeDate = RegExp(
  r'^([A-Za-z]{3})\s?(\d{1,2}),\s?(\d{4})(?:\s+(.*))?$',
);
final _phonePeType = RegExp(
  '(?:^|\\s)(DEBIT|CREDIT)\\s?$_currency$_amount\$',
  caseSensitive: false,
);
final _phonePeTransactionId = RegExp(
  r'Transaction\s?ID\s?:?\s?([A-Za-z0-9]+)',
  caseSensitive: false,
);
final _phonePeUtr = RegExp(
  r'UTR\s?No\.?\s?:?\s?([A-Za-z0-9]+)',
  caseSensitive: false,
);
final _phonePeAccount = RegExp(
  r'(?:Paid\s?by|Credited\s?to|Debited\s?from)\s?[X*•]*(\d{4})\b',
  caseSensitive: false,
);
final _phonePeCounterparty = RegExp(
  r'^(?:Paid\s?to|Payment\s?to|Money\s?sent\s?to|Sent\s?to|Transfer(?:red)?\s?to|Received\s?from)\s?(.+)$',
  caseSensitive: false,
);

UpiStatement parsePhonePeStatement(List<String> lines) {
  final blocks = <({DateTime day, List<String> lines, RegExpMatch? time})>[];
  RegExpMatch? time;
  for (final line in lines) {
    var rest = line;
    final date = _phonePeDate.firstMatch(rest);
    if (date != null) {
      final day = _date(int.parse(date[3]!), date[1]!, date[2]!);
      if (day != null) {
        if (blocks.isNotEmpty) {
          final last = blocks.removeLast();
          blocks.add((day: last.day, lines: last.lines, time: time));
        }
        blocks.add((day: day, lines: <String>[], time: null));
        time = null;
        rest = date[4] ?? '';
      }
    }
    if (blocks.isEmpty) continue;
    if (time == null) {
      final match = _time.firstMatch(rest);
      if (match != null) {
        time = match;
        rest = match[4] ?? '';
      }
    }
    if (rest.isNotEmpty) blocks.last.lines.add(rest);
  }
  if (blocks.isNotEmpty) {
    final last = blocks.removeLast();
    blocks.add((day: last.day, lines: last.lines, time: time));
  }

  final rows = <UpiStatementRow>[];
  var unreadable = 0;
  for (final block in blocks) {
    final row = _phonePeRow(block.day, block.time, block.lines);
    if (row == null) {
      unreadable++;
    } else {
      rows.add(row);
    }
  }
  return UpiStatement(
    source: UpiStatementSource.phonePe,
    rows: rows,
    unreadable: unreadable,
  );
}

UpiStatementRow? _phonePeRow(
  DateTime day,
  RegExpMatch? time,
  List<String> lines,
) {
  String? description;
  RegExpMatch? type;
  for (final line in lines) {
    final match = _phonePeType.firstMatch(line);
    if (match == null) continue;
    type = match;
    final before = line.substring(0, match.start).trim();
    if (before.isNotEmpty) description = before;
    break;
  }
  if (type == null) return null;
  final amount = parseStatementAmount(type[2]!);
  if (amount == null) return null;
  bool isField(String l) =>
      _phonePeType.hasMatch(l) ||
      _phonePeTransactionId.hasMatch(l) ||
      _phonePeUtr.hasMatch(l) ||
      _phonePeAccount.hasMatch(l);
  description ??= lines
      .takeWhile((l) => !_phonePeTransactionId.hasMatch(l))
      .where((l) => !isField(l))
      .firstOrNull;
  if (description == null) return null;

  String? find(RegExp pattern) =>
      lines.map(pattern.firstMatch).nonNulls.firstOrNull?[1];
  final digits = find(_phonePeAccount);
  final date = time == null
      ? day
      : DateTime(
          day.year,
          day.month,
          day.day,
          _hour(int.parse(time[1]!), time[3]!),
          int.parse(time[2]!),
        );
  return UpiStatementRow(
    date: date,
    direction: type[1]!.toUpperCase() == 'CREDIT'
        ? UpiStatementDirection.credit
        : UpiStatementDirection.debit,
    amountMinor: amount,
    counterparty:
        _phonePeCounterparty.firstMatch(description)?[1]?.trim() ?? description,
    reference: find(_phonePeUtr) ?? find(_phonePeTransactionId),
    account: digits == null ? null : StatementAccount(digits: digits),
  );
}

// ─── Paytm ───────────────────────────────────────────────────────────────────
//
//   28 Dec                                ← no year: taken from the period
//   3:08 PM
//   Paid to Graphy Labs Private Limited   ← may wrap
//   UPI ID: cf.                           ← may wrap
//   graphylabsprivate@cashfreensdlpb
//   UPI Ref No: 436331900838
//   Note: ajuOt1735378                    ← optional, may wrap and may be
//   64214920                                fused with the account's first line
//   Equitas
//   Small
//   Finance
//   Bank - 97                             ← the account, two digits
//   - Rs.999                              ← "+" received, unsigned = self
//
// A block starts at a date line followed by a time, so a date-like Note
// ("Note: Badminton / 28 Jun") never starts one.

final _paytmDate = RegExp(r'^(\d{1,2}) ([A-Za-z]{3})(?:\s+(.*))?$');
final _paytmPeriod = RegExp(
  r"(\d{1,2})\s?([A-Za-z]{3})\s?'(\d{2})\s*-\s*(\d{1,2})\s?([A-Za-z]{3})\s?'(\d{2})",
);
final _paytmAmount = RegExp('(?:^|\\s)([+-])?\\s?Rs\\.?\\s?$_amount\$');
final _paytmRef = RegExp(r'UPI\s?Ref\s?No\s?:?\s?(\d+)', caseSensitive: false);
final _paytmTrailingDigits = RegExp(r'-\s?(\d{1,4})$');
final _paytmSummaryAccount = RegExp(r'^(.+?) - (\d{1,4})(?:\s+Rs\..*)?$');
final _paytmSelf = RegExp(
  r'^Transferred to Self,?\s*(.*)$',
  caseSensitive: false,
);
final _paytmCounterparty = RegExp(
  r'^(?:Paid to|Money sent to|Received from|Refund from|Cashback received from|Paid for|Recharge of|Purchase of|Automatic payment (?:of [\d,.]+ setup )?for|Automatic payment of)\s+(.+)$',
  caseSensitive: false,
);
final _paytmSkipped = RegExp(
  r'^Money (?:un)?blocked for\b',
  caseSensitive: false,
);

UpiStatement parsePaytmStatement(List<String> lines) {
  final joined = lines.join(' ');
  final period = _paytmPeriod.firstMatch(joined);
  final periodEnd = period == null
      ? null
      : _date(2000 + int.parse(period[6]!), period[5]!, period[4]!, 23, 59);

  // The summary table names each account in full: "Equitas Small Finance
  // Bank - 97". Rows wrap the name unpredictably, so look it up by digits.
  final banks = <String, Set<String>>{};
  final passbook = lines.indexWhere(
    (l) => l.startsWith('Passbook Payments History'),
  );
  for (final line in lines.take(passbook < 0 ? 0 : passbook)) {
    final match = _paytmSummaryAccount.firstMatch(line);
    if (match != null) {
      (banks[match[2]!] ??= {}).add(match[1]!.trim());
    }
  }

  final blocks = <({DateTime day, List<String> lines, RegExpMatch time})>[];
  for (var i = 0; i < lines.length; i++) {
    final date = _paytmDate.firstMatch(lines[i]);
    if (date != null && _month(date[2]!) != null) {
      // The time is on the same line or the next one.
      var rest = date[3];
      var time = rest == null ? null : _time.firstMatch(rest);
      var consumed = i;
      if (rest == null && i + 1 < lines.length) {
        time = _time.firstMatch(lines[i + 1]);
        consumed = i + 1;
      }
      if (time != null) {
        final day = _paytmDay(date[2]!, date[1]!, periodEnd);
        if (day != null) {
          blocks.add((day: day, lines: <String>[], time: time));
          if (time[4] != null) blocks.last.lines.add(time[4]!);
          i = consumed;
          continue;
        }
      }
    }
    if (blocks.isNotEmpty) blocks.last.lines.add(lines[i]);
  }

  final rows = <UpiStatementRow>[];
  var unreadable = 0;
  for (final block in blocks) {
    final row = _paytmRow(block.day, block.time, block.lines, banks);
    if (row == null) {
      unreadable++;
    } else if (row != _skipped) {
      rows.add(row);
    }
  }

  int? total(String label) {
    final match = RegExp(
      '$label\\s*[+-]?\\s?Rs\\.?\\s?$_amount',
      caseSensitive: false,
    ).firstMatch(joined);
    return match == null ? null : parseStatementAmount(match[1]!);
  }

  return UpiStatement(
    source: UpiStatementSource.paytm,
    rows: rows,
    unreadable: unreadable,
    reportedSentMinor: total('Total Money Paid'),
    reportedReceivedMinor: total('Total Money Received'),
  );
}

/// Paytm rows carry no year. The statement ends on [periodEnd]: a date that
/// would fall after it belongs to the year before.
DateTime? _paytmDay(String month, String day, DateTime? periodEnd) {
  final end = periodEnd ?? DateTime.now();
  final date = _date(end.year, month, day);
  if (date == null) return null;
  return date.isAfter(end) ? _date(end.year - 1, month, day) : date;
}

/// A recognised row that isn't money moving (an IPO mandate block).
final _skipped = UpiStatementRow(
  date: DateTime(0),
  direction: UpiStatementDirection.debit,
  amountMinor: 1,
  counterparty: '',
);

UpiStatementRow? _paytmRow(
  DateTime day,
  RegExpMatch time,
  List<String> lines,
  Map<String, Set<String>> banks,
) {
  final upiId = lines.indexWhere((l) => l.startsWith('UPI ID'));
  final refIndex = lines.indexWhere(_paytmRef.hasMatch);
  final anchorEnd = upiId >= 0 ? upiId : refIndex;
  if (anchorEnd <= 0) return null;
  final anchor = lines.sublist(0, anchorEnd).join(' ');
  if (_paytmSkipped.hasMatch(anchor)) return _skipped;

  // The amount is the first signed or bare "Rs." amount after the reference,
  // alone on its line or fused onto the end of the account's last line.
  var amountIndex = -1;
  RegExpMatch? amount;
  for (var i = refIndex + 1; i < lines.length; i++) {
    amount = _paytmAmount.firstMatch(lines[i]);
    if (amount != null) {
      amountIndex = i;
      break;
    }
  }
  if (amount == null) return null;
  final amountMinor = parseStatementAmount(amount[2]!);
  if (amountMinor == null) return null;

  final accountText = [
    ...lines.sublist(refIndex + 1, amountIndex),
    lines[amountIndex].substring(0, amount.start).trim(),
  ].where((l) => l.isNotEmpty).join(' ');
  final digits = _paytmTrailingDigits.firstMatch(accountText)?[1];
  StatementAccount? account;
  if (digits != null) {
    final named = banks[digits];
    account = StatementAccount(
      bank: named != null && named.length == 1 ? named.single : null,
      digits: digits,
    );
  }

  final date = DateTime(
    day.year,
    day.month,
    day.day,
    _hour(int.parse(time[1]!), time[3]!),
    int.parse(time[2]!),
  );
  final reference = refIndex < 0
      ? null
      : _paytmRef.firstMatch(lines[refIndex])![1];
  final sign = amount[1];
  final self = _paytmSelf.firstMatch(anchor);
  if (self != null || sign == null) {
    if (self == null) return null;
    final to = _bankAndDigits.firstMatch(self[1]!.trim());
    return UpiStatementRow(
      date: date,
      direction: UpiStatementDirection.selfTransfer,
      amountMinor: amountMinor,
      counterparty: 'Self transfer',
      reference: reference,
      account: account,
      toAccount: to == null
          ? null
          : StatementAccount(bank: to[1]!.trim(), digits: to[2]!),
    );
  }
  return UpiStatementRow(
    date: date,
    direction: sign == '+'
        ? UpiStatementDirection.credit
        : UpiStatementDirection.debit,
    amountMinor: amountMinor,
    counterparty: _paytmCounterparty.firstMatch(anchor)?[1]?.trim() ?? anchor,
    reference: reference,
    account: account,
  );
}
