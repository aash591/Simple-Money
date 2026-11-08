/// What a bank's own PDF statement says happened, read from the PDF's text
/// like the UPI apps' statements (see upi_statement.dart). A bank prints one
/// account: its number, the bank and the holder sit above the table, and
/// each row's narration is read as a bank export's is (see [narrationPayee]).
///
/// Four layouts are known, each anchored on the lines a row always has:
///
///   Union Bank of India — a row per line, the way in brackets:
///     30-10-2025 S54834933 UPIAR/566978104137/DR/ASHIQUE /SBIN/… 710.00(Dr) 6514.34(Cr)
///
///   Kotak Mahindra Bank — numbered rows, the narration may wrap, and the
///   way shows only in the balance:
///     1 05 Sep 2026 UPI/ANWARSHAH P
///     M/HDFC/624835231853/UPI
///     UPI-624897805268 116.82 188.32
///
///   State Bank of India — the transaction and value dates, the narration
///   over several lines, then reference, debit, credit and balance:
///     02/01/2025 02/01/2025
///     WDL TFR
///     UPI/DR/500290521549/E O
///     SAID/YESB/paytm.s13q/UPI …
///     - 20.00 - 38,415.83
///
///   HDFC Bank — the date, the narration, then on the line where the
///   narration first breaks its reference, value date, amount and balance;
///   the narration runs on below, and the way shows only in the balance:
///     01/04/26 UPI-JUNIO-JUNIO@PTYBL-YESB0PTMUPI-609138 0000609138218279 01/04/26 150.00 14,458.07
///     218279-PAID VIA NAVI UPI
library;

import 'statement_table.dart';
import 'upi_statement.dart';

/// Reads [lines] as one of the known bank statements, or null when it is
/// none of them.
UpiStatement? parseBankPdfStatement(List<String> lines) {
  for (final parse in [_unionRows, _kotakRows, _sbiRows, _hdfcRows]) {
    final read = parse(lines);
    if (read == null || (read.rows.isEmpty && read.unreadable == 0)) continue;
    final header = read.header ?? lines.take(read.firstRow).toList();
    final text = header.join('\n');
    final account =
        statementAccountIn([
          for (final line in header) [line],
        ]) ??
        // SBI prints its labels apart from their values: the bank alone
        // still finds the user's one account there.
        switch (statementBankIn(text)) {
          final bank? => StatementAccount(bank: bank, digits: ''),
          null => null,
        };
    return UpiStatement(
      source: UpiStatementSource.bank,
      rows: [
        for (final row in read.rows)
          row.account == null ? row.copyWith(account: account) : row,
      ],
      unreadable: read.unreadable,
      reportedSentMinor: read.totals?.sent,
      reportedReceivedMinor: read.totals?.received,
      owner: statementOwnerIn(
        header,
        nameLines: [
          // Kotak prints the holder alone near the top.
          ...header.take(4),
          // Union: "Name MR ASHIQUE M", "Account Name ASHIQUE M".
          for (final line in header)
            if (_nameLabel.firstMatch(line) case final name?) name[1]!,
        ],
      ),
    );
  }
  return null;
}

final _nameLabel = RegExp(r'^(?:Account\s+)?Name\s+(.+)$');

/// A layout's rows, and where they start: the lines above are the header,
/// unless the layout says where its [header] is. [totals] are what the
/// statement says went out and came in, when it prints them.
typedef _Read = ({
  List<UpiStatementRow> rows,
  int unreadable,
  int firstRow,
  List<String>? header,
  ({int sent, int received})? totals,
});

/// "1,52,430.01" → 15243001, keeping zero and a sign, which a balance can
/// have and an amount can't.
int? _balance(String value) {
  final negative = value.startsWith('-');
  final digits = negative ? value.substring(1) : value;
  if (RegExp(r'^0+(?:\.0+)?$').hasMatch(digits.replaceAll(',', ''))) return 0;
  final minor = parseStatementAmount(digits);
  return minor == null ? null : (negative ? -minor : minor);
}

UpiStatementRow _row(
  DateTime date,
  bool out,
  int amountMinor,
  String narration, {
  String reference = '',
}) {
  final payee = narrationPayee(narration);
  return UpiStatementRow(
    date: date,
    direction: out ? UpiStatementDirection.debit : UpiStatementDirection.credit,
    amountMinor: amountMinor,
    counterparty: payee.name,
    reference: statementReference(reference, narration),
    counterpartyBank: payee.bank,
    counterpartyId: payee.id,
    narration: narration,
  );
}

/// A date alone: noon keeps it on its day in any time zone.
DateTime? _day(int year, int month, int day) {
  final date = DateTime(year, month, day, 12);
  return date.month == month && date.day == day ? date : null;
}

// ─── Union Bank of India ─────────────────────────────────────────────────────

final _unionRow = RegExp(
  r'^(\d{2})-(\d{2})-(\d{4}) (\S+) (.+?) ([\d,]+\.\d{2})\((Dr|Cr)\) (-?[\d,]+\.\d{2})\((?:Dr|Cr)\)$',
);

_Read? _unionRows(List<String> lines) {
  final first = lines.indexWhere(_unionRow.hasMatch);
  if (first < 0) return null;
  final rows = <UpiStatementRow>[];
  var unreadable = 0;
  for (final line in lines.skip(first)) {
    final match = _unionRow.firstMatch(line);
    if (match == null) continue;
    final date = _day(
      int.parse(match[3]!),
      int.parse(match[2]!),
      int.parse(match[1]!),
    );
    final amount = parseStatementAmount(match[6]!);
    if (date == null || amount == null) {
      unreadable++;
      continue;
    }
    rows.add(_row(date, match[7] == 'Dr', amount, match[5]!));
  }
  return (
    rows: rows,
    unreadable: unreadable,
    firstRow: first,
    header: null,
    totals: null,
  );
}

// ─── Kotak Mahindra Bank ─────────────────────────────────────────────────────

final _kotakStart = RegExp(
  r'^(\d+) (\d{1,2}) ([A-Za-z]{3}) (\d{4})(?: (.*))?$',
);
final _kotakAmounts = RegExp(r'(?:^|\s)([\d,]+\.\d{2}) (-?[\d,]+\.\d{2})$');
final _kotakOpening = RegExp(
  r'Opening Balance\b.*\s(-?[\d,]+\.\d{2})$',
  caseSensitive: false,
);
// Kotak's own reference column ("UPI-624897805268"); the UPI reference both
// banks quote is the one in the narration.
final _kotakReference = RegExp(r'\s*\b[A-Z]{2,6}-\d{6,}$');

_Read? _kotakRows(List<String> lines) {
  if (!lines.any(_kotakOpening.hasMatch)) return null;
  final first = lines.indexWhere(_kotakStart.hasMatch);
  if (first < 0) return null;
  final rows = <UpiStatementRow>[];
  var unreadable = 0;
  int? balance;
  ({DateTime? date, List<String> text})? open;
  for (final line in lines) {
    if (open == null) {
      if (_kotakOpening.firstMatch(line) case final opening?) {
        balance = _balance(opening[1]!);
        continue;
      }
      final start = _kotakStart.firstMatch(line);
      if (start == null) continue;
      final month = monthNumber(start[3]!);
      open = (
        date: month == null
            ? null
            : _day(int.parse(start[4]!), month, int.parse(start[2]!)),
        text: [?start[5]],
      );
    } else {
      open.text.add(line);
    }
    final last = open.text.lastOrNull ?? '';
    final amounts = _kotakAmounts.firstMatch(last);
    if (amounts == null) continue;
    open.text.last = last.substring(0, amounts.start);
    final row = open;
    open = null;
    final amount = parseStatementAmount(amounts[1]!);
    final after = _balance(amounts[2]!);
    final before = balance;
    balance = after;
    // Which column the amount sat in shows only in what it did to the
    // balance.
    final out = before == null || after == null || amount == null
        ? null
        : after == before - amount
        ? true
        : after == before + amount
        ? false
        : null;
    if (row.date == null || amount == null || out == null) {
      unreadable++;
      continue;
    }
    rows.add(
      _row(
        row.date!,
        out,
        amount,
        row.text
            .join(' ')
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim()
            .replaceFirst(_kotakReference, ''),
      ),
    );
  }
  return (
    rows: rows,
    unreadable: unreadable,
    firstRow: first,
    header: null,
    totals: null,
  );
}

// ─── State Bank of India ─────────────────────────────────────────────────────

final _sbiStart = RegExp(
  r'^(\d{2})/(\d{2})/(\d{4}) \d{2}/\d{2}/\d{4}(?: (.*))?$',
);
final _sbiAmounts = RegExp(
  r'(?:^|\s)(\S+) (-|[\d,]+\.\d{2}) (-|[\d,]+\.\d{2}) (-?[\d,]+\.\d{2})$',
);

_Read? _sbiRows(List<String> lines) {
  final first = lines.indexWhere(_sbiStart.hasMatch);
  if (first < 0) return null;
  final rows = <UpiStatementRow>[];
  var unreadable = 0;
  ({DateTime? date, List<String> text})? open;
  for (final line in lines.skip(first)) {
    if (open == null) {
      final start = _sbiStart.firstMatch(line);
      if (start == null) continue;
      open = (
        date: _day(
          int.parse(start[3]!),
          int.parse(start[2]!),
          int.parse(start[1]!),
        ),
        text: [?start[4]],
      );
    } else {
      open.text.add(line);
    }
    final last = open.text.lastOrNull ?? '';
    final amounts = _sbiAmounts.firstMatch(last);
    if (amounts == null) continue;
    open.text.last = last.substring(0, amounts.start);
    final row = open;
    open = null;
    final debit = amounts[2] == '-' ? null : parseStatementAmount(amounts[2]!);
    final credit = amounts[3] == '-' ? null : parseStatementAmount(amounts[3]!);
    if (row.date == null || (debit == null) == (credit == null)) {
      unreadable++;
      continue;
    }
    rows.add(
      _row(
        row.date!,
        debit != null,
        debit ?? credit!,
        // A narration wraps at the column's edge, mid-word when it must:
        // "…/MUHAMM" + "ED/IOBA/…" reads "MUHAMM ED", which still names
        // the same payee every time.
        row.text.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim(),
        reference: amounts[1] == '-' ? '' : amounts[1]!,
      ),
    );
  }
  return (
    rows: rows,
    unreadable: unreadable,
    firstRow: first,
    header: null,
    totals: null,
  );
}

// ─── HDFC Bank ───────────────────────────────────────────────────────────────

final _hdfcHeading = RegExp(
  r'^Date\s+Narration\s+Chq\.?\s?/\s?Ref\.?\s?No',
  caseSensitive: false,
);
final _hdfcStart = RegExp(r'^(\d{2})/(\d{2})/(\d{2})(?: (.*))?$');
final _hdfcAmounts = RegExp(
  r'(?:^|\s)(\S+) \d{2}/\d{2}/\d{2} ([\d,]+\.\d{2}) (-?[\d,]+\.\d{2})$',
);
// "Opening Balance Dr Count Cr Count Debits Credits Closing Bal", then:
final _hdfcTotals = RegExp(
  r'^(-?[\d,]+\.\d{2}) (\d+) (\d+) ([\d,]+\.\d{2}) ([\d,]+\.\d{2}) (-?[\d,]+\.\d{2})$',
);

_Read? _hdfcRows(List<String> lines) {
  if (!lines.any(_hdfcHeading.hasMatch)) return null;
  final summary = lines.indexWhere(
    (l) => l.toUpperCase().startsWith('STATEMENT SUMMARY'),
  );
  final totals = summary < 0
      ? null
      : lines
            .skip(summary + 1)
            .take(3)
            .map(_hdfcTotals.firstMatch)
            .nonNulls
            .firstOrNull;
  final body = summary < 0 ? lines : lines.take(summary).toList();
  final first = body.indexWhere(_hdfcStart.hasMatch);
  if (first < 0) return null;

  final rows = <UpiStatementRow>[];
  final header = <String>[];
  var unreadable = 0;
  var balance = totals == null ? null : _balance(totals[1]!);
  ({DateTime? date, List<String> text, RegExpMatch? amounts})? open;
  void close() {
    final row = open;
    open = null;
    if (row == null) return;
    final amounts = row.amounts;
    final amount = amounts == null ? null : parseStatementAmount(amounts[2]!);
    final after = amounts == null ? null : _balance(amounts[3]!);
    final before = balance;
    if (after != null) balance = after;
    final out = before == null || after == null || amount == null
        ? null
        : after == before - amount
        ? true
        : after == before + amount
        ? false
        : null;
    if (row.date == null || amount == null || out == null) {
      unreadable++;
      return;
    }
    rows.add(
      _row(
        row.date!,
        out,
        amount,
        row.text.join(' ').replaceAll(RegExp(r'\s+'), ' ').trim(),
        reference: amounts![1]!,
      ),
    );
  }

  // Each page repeats the bank's letterhead — the holder, the account —
  // from "Page No" to the registered office, wherever in a row it falls.
  var letterhead = false;
  for (final line in body.skip(first)) {
    if (line.startsWith('Page No')) {
      letterhead = true;
      continue;
    }
    final start = _hdfcStart.firstMatch(line);
    if (letterhead) {
      if (start == null) {
        if (!header.contains(line)) header.add(line);
        if (line.startsWith('Registered Office')) letterhead = false;
        continue;
      }
      letterhead = false;
    }
    if (_hdfcHeading.hasMatch(line)) continue;
    if (start != null) {
      close();
      final year = 2000 + int.parse(start[3]!);
      open = (
        date: _day(year, int.parse(start[2]!), int.parse(start[1]!)),
        text: <String>[],
        amounts: null,
      );
    }
    final text = start == null ? line : start[4] ?? '';
    final row = open;
    if (row == null) continue;
    final amounts = row.amounts == null ? _hdfcAmounts.firstMatch(text) : null;
    if (amounts != null) {
      open = (date: row.date, text: row.text, amounts: amounts);
      row.text.add(text.substring(0, amounts.start));
    } else {
      row.text.add(text);
    }
  }
  close();
  return (
    rows: rows,
    unreadable: unreadable,
    firstRow: first,
    header: header,
    totals: totals == null
        ? null
        : (
            sent: parseStatementAmount(totals[4]!) ?? 0,
            received: parseStatementAmount(totals[5]!) ?? 0,
          ),
  );
}
