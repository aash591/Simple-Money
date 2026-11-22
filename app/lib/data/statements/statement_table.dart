/// Bank and UPI-app statements exported as CSV or Excel: reading the table,
/// guessing which column is which, and turning rows into [UpiStatementRow]s
/// that go through the same matching and preview as a PDF statement.
///
/// The hard part of a spreadsheet is the direction of each amount. Many
/// exports print every amount unsigned, and a column that looks like a
/// direction ("Credit/debit instrument") may only name the card or UPI app
/// used. So a row's direction comes from the strongest evidence it has —
/// separate debit and credit columns, then a sign or Dr/Cr marker on the
/// amount, then a column whose cells really are Dr/Cr words, then the
/// description ("Paid to …", "Received from …") — and a row with none of
/// these is counted and given the direction the user picks, never silently
/// assumed to be income.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'upi_statement.dart';
import 'xlsx_reader.dart';

// ─── Reading ─────────────────────────────────────────────────────────────────

/// The rows of an Excel workbook's first sheet. Throws a [FormatException]
/// for anything that isn't an .xlsx, naming what to do instead.
List<List<String>> readExcelTable(Uint8List bytes) {
  if (_startsWith(bytes, const [0x50, 0x4B, 0x03, 0x04])) {
    return readXlsxRows(bytes);
  }
  if (_startsWith(bytes, const [0xD0, 0xCF, 0x11, 0xE0])) {
    throw const FormatException(
      'Old .xls files can’t be read. Save it as .xlsx or .csv and import that.',
    );
  }
  throw const FormatException(
    'This isn’t an Excel file. If it’s a CSV, import it as CSV.',
  );
}

/// The rows of a CSV file, in whichever text encoding it was saved.
List<List<String>> readCsvTable(Uint8List bytes) {
  if (_startsWith(bytes, const [0x50, 0x4B, 0x03, 0x04]) ||
      _startsWith(bytes, const [0xD0, 0xCF, 0x11, 0xE0])) {
    throw const FormatException('This is an Excel file. Import it as Excel.');
  }
  return readCsvRows(_decodeText(bytes));
}

bool _startsWith(Uint8List bytes, List<int> magic) =>
    bytes.length >= magic.length &&
    Iterable.generate(magic.length).every((i) => bytes[i] == magic[i]);

String _decodeText(Uint8List bytes) {
  if (bytes.length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) {
    return _utf16(bytes.sublist(2), littleEndian: true);
  }
  if (bytes.length >= 2 && bytes[0] == 0xFE && bytes[1] == 0xFF) {
    return _utf16(bytes.sublist(2), littleEndian: false);
  }
  final text = utf8.decode(bytes, allowMalformed: true);
  final start = text.startsWith('﻿') ? 1 : 0;
  // Not UTF-8 at all (an old Windows export): every byte is a character.
  if ('�'.allMatches(text).length > 3) return latin1.decode(bytes);
  return text.substring(start);
}

String _utf16(Uint8List bytes, {required bool littleEndian}) {
  final view = ByteData.sublistView(bytes);
  return String.fromCharCodes([
    for (var i = 0; i + 1 < bytes.length; i += 2)
      view.getUint16(i, littleEndian ? Endian.little : Endian.big),
  ]);
}

/// RFC 4180 CSV: quotes are escaped by doubling, and a quoted field may hold
/// separators and line breaks. The separator — comma, semicolon, tab or
/// pipe — is whichever appears most outside quotes.
List<List<String>> readCsvRows(String text) {
  final separator = _detectSeparator(text);
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  var i = 0;
  void endField() {
    row.add(field.toString());
    field.clear();
  }

  void endRow() {
    endField();
    if (rows.length >= maxStatementRows) throw const TooManyRowsException();
    rows.add(row);
    row = <String>[];
  }

  while (i < text.length) {
    final char = text[i];
    if (quoted) {
      if (char == '"') {
        if (i + 1 < text.length && text[i + 1] == '"') {
          field.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        field.write(char);
      }
    } else if (char == '"' && field.isEmpty) {
      quoted = true;
    } else if (char == separator) {
      endField();
    } else if (char == '\r' || char == '\n') {
      endRow();
      if (char == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
    } else {
      field.write(char);
    }
    i++;
  }
  if (field.isNotEmpty || row.isNotEmpty) endRow();
  return rows;
}

String _detectSeparator(String text) {
  const candidates = [',', ';', '\t', '|'];
  final counts = List.filled(candidates.length, 0);
  var quoted = false;
  var lines = 0;
  for (var i = 0; i < text.length && lines < 30; i++) {
    final char = text[i];
    if (char == '"') {
      quoted = !quoted;
    } else if (!quoted) {
      if (char == '\n') lines++;
      final index = candidates.indexOf(char);
      if (index >= 0) counts[index]++;
    }
  }
  var best = 0;
  for (var i = 1; i < counts.length; i++) {
    if (counts[i] > counts[best]) best = i;
  }
  return candidates[best];
}

// ─── Mapping ─────────────────────────────────────────────────────────────────

enum TableField {
  date('Date'),
  time('Time'),
  description('Description'),
  amount('Amount'),
  debit('Money out (debit)'),
  credit('Money in (credit)'),
  direction('Dr/Cr column'),
  reference('Reference / UTR'),
  account('Your account'),
  balance('Balance');

  const TableField(this.label);
  final String label;
}

enum DateOrder {
  auto('Auto-detect'),
  dayFirst('Day first · 31/12/2025'),
  monthFirst('Month first · 12/31/2025'),
  yearFirst('Year first · 2025-12-31'),
  excelSerial('Excel date numbers');

  const DateOrder(this.label);
  final String label;
}

/// Which column is which, and how to read the ambiguous parts. Saved per
/// header signature so the next file with the same columns imports straight
/// away.
class TableMapping {
  const TableMapping({
    required this.headerRow,
    this.columns = const {},
    this.dateOrder = DateOrder.auto,
    this.fallback = UpiStatementDirection.debit,
    this.joins = const {},
  });
  final int headerRow;
  final Map<TableField, int> columns;
  final DateOrder dateOrder;

  /// Columns that are part of another: a PDF table can split one column in
  /// two where its text wraps or an amount sits out of line. Column → the
  /// column it belongs to, read together with it.
  final Map<int, int> joins;

  /// The direction of a row nothing else gives one.
  final UpiStatementDirection fallback;

  int? operator [](TableField field) => columns[field];

  bool get usesDebitCredit =>
      columns.containsKey(TableField.debit) ||
      columns.containsKey(TableField.credit);

  bool get isComplete =>
      columns.containsKey(TableField.date) &&
      (columns.containsKey(TableField.amount) || usesDebitCredit);

  /// [field] read from [column] (null clears it). A column serves one field,
  /// and an amount column excludes debit/credit columns and back.
  TableMapping withColumn(TableField field, int? column) {
    final next = {...columns}
      ..remove(field)
      ..removeWhere((_, c) => c == column);
    if (column != null) {
      next[field] = column;
      if (field == TableField.amount) {
        next.remove(TableField.debit);
        next.remove(TableField.credit);
      } else if (field == TableField.debit || field == TableField.credit) {
        next.remove(TableField.amount);
        next.remove(TableField.direction);
      }
    }
    return copyWith(columns: next);
  }

  TableMapping copyWith({
    int? headerRow,
    Map<TableField, int>? columns,
    DateOrder? dateOrder,
    UpiStatementDirection? fallback,
    Map<int, int>? joins,
  }) => TableMapping(
    headerRow: headerRow ?? this.headerRow,
    columns: columns ?? this.columns,
    dateOrder: dateOrder ?? this.dateOrder,
    fallback: fallback ?? this.fallback,
    joins: joins ?? this.joins,
  );

  /// [column] and the columns joined to it, left to right.
  List<int> partsOf(int column) => {
    column,
    ...joins.keys.where((k) => joins[k] == column),
  }.toList()..sort();

  Map<String, Object> toJson() => {
    'columns': {for (final e in columns.entries) e.key.name: e.value},
    'dateOrder': dateOrder.name,
    'fallback': fallback.name,
    if (joins.isNotEmpty)
      'joins': {for (final e in joins.entries) '${e.key}': e.value},
  };

  /// A saved mapping for a header found at [headerRow].
  static TableMapping? fromJson(Object? json, int headerRow) {
    if (json is! Map) return null;
    final columns = <TableField, int>{};
    final saved = json['columns'];
    if (saved is Map) {
      for (final field in TableField.values) {
        final column = saved[field.name];
        if (column is int && column >= 0) columns[field] = column;
      }
    }
    return TableMapping(
      headerRow: headerRow,
      columns: columns,
      dateOrder:
          DateOrder.values
              .where((o) => o.name == json['dateOrder'])
              .firstOrNull ??
          DateOrder.auto,
      fallback: json['fallback'] == UpiStatementDirection.credit.name
          ? UpiStatementDirection.credit
          : UpiStatementDirection.debit,
      joins: {
        if (json['joins'] case final Map saved)
          for (final e in saved.entries)
            if (int.tryParse('${e.key}') case final from?)
              if (e.value case final int into when into >= 0 && from >= 0)
                from: into,
      },
    );
  }
}

/// A header row's identity: its normalized cell texts in place, so a saved
/// mapping (column positions) is reused only for the same layout.
String tableSignature(List<String> row) {
  final cells = [
    for (final cell in row)
      cell.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' '),
  ];
  while (cells.isNotEmpty && cells.last.isEmpty) {
    cells.removeLast();
  }
  return cells.join('|');
}

const _headerScanRows = 50;

/// A saved mapping whose header appears in the first rows of [rows].
/// The header signature [findSavedMapping] matched in [rows], or null.
String? savedMappingSignature(
  List<List<String>> rows,
  Map<String, Object?> saved,
) {
  for (var i = 0; i < rows.length && i < _headerScanRows; i++) {
    final signature = tableSignature(rows[i]);
    if (signature.isEmpty) continue;
    if (TableMapping.fromJson(saved[signature], i) != null) return signature;
  }
  return null;
}

TableMapping? findSavedMapping(
  List<List<String>> rows,
  Map<String, Object?> saved,
) {
  for (var i = 0; i < rows.length && i < _headerScanRows; i++) {
    final signature = tableSignature(rows[i]);
    if (signature.isEmpty) continue;
    final mapping = TableMapping.fromJson(saved[signature], i);
    if (mapping != null) return mapping;
  }
  return null;
}

/// The row of column names right above the first transaction (a date and
/// an amount), so details above the table ("Statement date : 31/10/2026")
/// aren't taken for it; else the first row naming a date among three or
/// more filled cells; else the widest early row.
int guessHeaderRow(List<List<String>> rows) {
  final scan = rows.take(_headerScanRows).toList();
  final first = scan.indexWhere(_looksLikeTransaction);
  for (var i = first - 1; i >= 0; i--) {
    if (_namesColumns(scan[i])) return i;
  }
  for (var i = 0; i < scan.length; i++) {
    final filled = scan[i].where((c) => c.trim().isNotEmpty).length;
    if (filled >= 3 && scan[i].any((c) => c.toLowerCase().contains('date'))) {
      return i;
    }
  }
  var best = 0;
  for (var i = 1; i < scan.length; i++) {
    if (_filled(scan[i]) > _filled(scan[best])) best = i;
  }
  return best;
}

int _filled(List<String> row) => row.where((c) => c.trim().isNotEmpty).length;

bool _looksLikeTransaction(List<String> row) {
  if (_filled(row) < 3) return false;
  final dateAt = row.indexWhere(
    (c) => c.trim().isNotEmpty && parseTableDate(c, DateOrder.auto) != null,
  );
  return dateAt >= 0 &&
      row.indexed.any(
        (e) =>
            e.$1 != dateAt &&
            e.$2.contains(RegExp(r'\d')) &&
            parseTableAmount(e.$2) != null,
      );
}

/// Three or more cells of words, none a date.
bool _namesColumns(List<String> row) {
  final filled = [
    for (final c in row)
      if (c.trim().isNotEmpty) c,
  ];
  return filled.length >= 3 &&
      filled.every((c) => parseTableDate(c, DateOrder.auto) == null) &&
      filled.where((c) => c.contains(RegExp('[A-Za-z]'))).length * 4 >=
          filled.length * 3;
}

/// The best guess from header names and cell contents; the user confirms or
/// fixes it.
TableMapping guessMapping(List<List<String>> rows, [int? headerRow]) {
  final header = headerRow ?? guessHeaderRow(rows);
  final names = [
    for (final cell in rows.elementAtOrNull(header) ?? const <String>[])
      cell.trim().toLowerCase(),
  ];
  final body = rows.skip(header + 1).take(300).toList();
  final used = <int>{};
  final columns = <TableField, int>{};

  List<String> cells(int column) => [
    for (final row in body)
      if (column < row.length && row[column].trim().isNotEmpty) row[column],
  ];
  bool mostly(int column, bool Function(String) test) {
    final filled = cells(column);
    return filled.isNotEmpty &&
        filled.where(test).length * 10 >= filled.length * 9;
  }

  // A name's words: "Dr Amount" has "dr", "Value Dt" has "dt".
  Set<String> wordsOf(int column) =>
      names[column].split(RegExp('[^a-z]+')).where((w) => w.isNotEmpty).toSet();

  int? find(
    List<String> keys, {
    Set<String> exact = const {},
    Set<String> words = const {},
    bool Function(int column)? accept,
  }) {
    for (final key in keys) {
      for (var i = 0; i < names.length; i++) {
        if (!used.contains(i) &&
            names[i].contains(key) &&
            (accept == null || accept(i))) {
          return i;
        }
      }
    }
    for (var i = 0; i < names.length; i++) {
      if (!used.contains(i) &&
          exact.contains(names[i]) &&
          (accept == null || accept(i))) {
        return i;
      }
    }
    for (var i = 0; i < names.length; i++) {
      if (!used.contains(i) &&
          wordsOf(i).intersection(words).isNotEmpty &&
          (accept == null || accept(i))) {
        return i;
      }
    }
    return null;
  }

  void put(TableField field, int? column) {
    if (column == null) return;
    columns[field] = column;
    used.add(column);
  }

  bool amounts(int c) =>
      !names[c].contains('balance') &&
      !wordsOf(c).contains('bal') &&
      mostly(c, (v) => parseTableAmount(v) != null);
  // "Credit/debit instrument" names both and is neither amount column.
  bool namesOneSide(int c) =>
      !(names[c].contains('debit') && names[c].contains('credit'));

  put(
    TableField.date,
    find(
      ['transaction date', 'txn date', 'tran date', 'date'],
      words: {'dt'},
      accept: (c) => cells(c).any(
        (v) =>
            parseTableDate(v, DateOrder.auto) != null ||
            parseTableDate(v, DateOrder.excelSerial) != null,
      ),
    ),
  );
  put(
    TableField.time,
    find([
      'time',
    ], accept: (c) => cells(c).any((v) => parseTableTime(v) != null)),
  );
  // A side no row used is still that side's column: a page of payments
  // only has nothing under Credit.
  bool side(int c) => namesOneSide(c) && (amounts(c) || cells(c).isEmpty);
  final debit = find(
    ['debit', 'withdrawal', 'paid out', 'money out'],
    exact: {'dr', 'out'},
    words: {'dr'},
    accept: side,
  );
  final credit = find(
    ['credit', 'deposit', 'paid in', 'money in'],
    exact: {'cr', 'in'},
    words: {'cr'},
    accept: (c) => c != debit && side(c),
  );
  if (debit != null && credit != null) {
    put(TableField.debit, debit);
    put(TableField.credit, credit);
  } else {
    put(TableField.amount, find(['amount', 'amt'], accept: amounts));
    // Named or not, a direction column is one whose cells are Dr/Cr words.
    bool directional(int c) => mostly(c, (v) => directionWord(v) != null);
    put(
      TableField.direction,
      find([
            'dr/cr',
            'cr/dr',
            'dr / cr',
            'debit/credit',
            'credit/debit',
            'type',
          ], accept: directional) ??
          Iterable<int>.generate(names.length)
              .where((c) => !used.contains(c) && directional(c))
              .firstOrNull,
    );
  }
  put(
    TableField.description,
    find([
      'narration',
      'description',
      'particulars',
      'transaction details',
      'details',
      'remarks',
    ]),
  );
  put(
    TableField.reference,
    find(['utr', 'upi ref', 'ref no', 'reference', 'ref.', 'chq', 'cheque']),
  );
  put(
    TableField.balance,
    find(
      ['balance'],
      words: {'bal'},
      accept: (c) => mostly(c, (v) => parseTableAmount(v) != null),
    ),
  );
  bool accountCells(int c) =>
      mostly(c, (v) => parseStatementAccount(v) != null);
  put(
    TableField.account,
    find(['your account', 'account'], accept: accountCells) ??
        // Masked numbers under any name: PhonePe's "Credit/debit
        // instrument" is the account each payment used, though some rows
        // only say "Account" or "Wallet".
        Iterable<int>.generate(names.length).where((c) {
          if (used.contains(c)) return false;
          final filled = cells(c);
          final masked = filled.where(
            (v) => RegExp(r'[Xx*•]{2,}\s?\d{2,4}').hasMatch(v),
          );
          return masked.length * 2 >= filled.length && masked.isNotEmpty;
        }).firstOrNull,
  );
  return TableMapping(headerRow: header, columns: columns);
}

// ─── Cells ───────────────────────────────────────────────────────────────────

/// "1,23,456.78", "₹ 500.00 Cr", "(250.00)", "-99", "1.234,56" → paise, and
/// whether the cell marked it as money out (null: nothing marked it).
({int minor, bool? out})? parseTableAmount(String? raw) {
  var text = (raw ?? '').replaceAll(' ', ' ').trim();
  if (text.isEmpty) return null;
  bool? out;
  // "500.00 Cr", "1,52,430.01CR", Union's "710.00(Dr)".
  final mark = RegExp(
    r'\(?\s*(dr|cr)\.?\s*\)?$',
    caseSensitive: false,
  ).firstMatch(text);
  if (mark != null) {
    out = mark[1]!.toLowerCase() == 'dr';
    text = text.substring(0, mark.start);
  }
  text = text.trim();
  if (text.startsWith('(') && text.endsWith(')')) out = true;
  if (RegExp(r'^[^\d]*-').hasMatch(text) || text.endsWith('-')) out = true;
  if (RegExp(r'^[^\d]*\+').hasMatch(text)) out = false;
  // Anything but currency marks around the number means it isn't an amount.
  if (RegExp(
    r'[A-QS-Za-qs-z]',
  ).hasMatch(text.replaceAll(RegExp(r'rs\.?|inr', caseSensitive: false), ''))) {
    return null;
  }
  final start = text.indexOf(RegExp(r'\d'));
  if (start < 0) return null;
  final end = text.lastIndexOf(RegExp(r'\d'));
  var digits = text.substring(start, end + 1);
  if (RegExp(r'[^\d.,eE+-]').hasMatch(digits)) return null;
  final comma = digits.lastIndexOf(',');
  final dot = digits.lastIndexOf('.');
  // A decimal comma ("1.234,56", "12,5"): Indian grouping never ends in a
  // one- or two-digit group.
  digits = comma > dot && digits.length - comma - 1 <= 2
      ? digits.replaceAll('.', '').replaceAll(',', '.')
      : digits.replaceAll(',', '');
  final value = double.tryParse(digits);
  if (value == null || value.isNaN || value.abs() >= 1e13) return null;
  // Excel stores results as doubles ("24521.000000000004"); paise is exact
  // enough for a rupee statement.
  final minor = (value.abs() * 100).round();
  if (value < 0) out = true;
  return (minor: minor, out: out);
}

/// Money out (true) or in (false) for a Dr/Cr word, else null. A channel
/// ("UPI", "Card") says nothing about direction.
bool? directionWord(String raw) =>
    switch (raw.trim().toLowerCase().replaceAll('.', '')) {
      'dr' ||
      'd' ||
      'debit' ||
      'debited' ||
      'withdrawal' ||
      'paid' ||
      'sent' ||
      'out' ||
      'expense' => true,
      'cr' ||
      'c' ||
      'credit' ||
      'credited' ||
      'deposit' ||
      'received' ||
      'in' ||
      'income' ||
      'refund' => false,
      _ => null,
    };

final _excelEpoch = DateTime.utc(1899, 12, 30);

/// The date (and time, when the cell has one) in [raw]; null when it isn't
/// one. Month names ("05-Jan-25", "Jan 5, 2025") read in any [order].
DateTime? parseTableDate(String? raw, DateOrder order) {
  final text = (raw ?? '').trim();
  if (text.isEmpty) return null;
  if (order == DateOrder.excelSerial) {
    final serial = double.tryParse(text);
    // Only plausible days (1990–2100): a reference number picked as the
    // date column isn't a date.
    if (serial == null || serial < 32874 || serial > 73415) return null;
    final whole = serial.floor();
    final day = _excelEpoch.add(Duration(days: whole));
    final minutes = ((serial - whole) * 24 * 60).round();
    return DateTime(day.year, day.month, day.day, minutes ~/ 60, minutes % 60);
  }

  int? year, month, day;
  String rest;
  final numeric = RegExp(r'^(\d{1,4})[/\-.](\d{1,2})[/\-.](\d{1,4})(.*)$')
      .firstMatch(text);
  final dayName = RegExp(
    r'^(\d{1,2})[\s\-/.]*([A-Za-z]{3,9})\.?[\s\-/.,]*(\d{2,4})(.*)$',
  ).firstMatch(text);
  final nameDay = RegExp(
    r'^([A-Za-z]{3,9})\.?\s*(\d{1,2})(?:st|nd|rd|th)?,?\s*(\d{2,4})(.*)$',
  ).firstMatch(text);
  if (numeric != null) {
    final a = numeric[1]!, b = int.parse(numeric[2]!), c = numeric[3]!;
    rest = numeric[4]!;
    if (a.length == 4) {
      (year, month, day) = (int.parse(a), b, int.parse(c));
    } else if (c.length == 4 || c.length == 2) {
      year = int.parse(c);
      (month, day) = order == DateOrder.monthFirst
          ? (int.parse(a), b)
          : order == DateOrder.yearFirst
          ? (null, null)
          : (b, int.parse(a));
    } else {
      return null;
    }
  } else if (dayName != null) {
    (day, month, year) = (
      int.parse(dayName[1]!),
      monthNumber(dayName[2]!),
      int.parse(dayName[3]!),
    );
    rest = dayName[4]!;
  } else if (nameDay != null) {
    (month, day, year) = (
      monthNumber(nameDay[1]!),
      int.parse(nameDay[2]!),
      int.parse(nameDay[3]!),
    );
    rest = nameDay[4]!;
  } else {
    return null;
  }
  if (month == null || day == null) return null;
  if (year < 100) year += 2000;
  if (year < 1990 || year > 2100 || month < 1 || month > 12 || day < 1) {
    return null;
  }
  final date = DateTime(year, month, day);
  if (date.month != month) return null;
  rest = rest.trim();
  if (rest.isEmpty) return date;
  final time = parseTableTime(rest.replaceFirst(RegExp(r'^[T,]\s*'), ''));
  if (time == null) {
    // "05/01/2025" mustn't read as dd/MM/yy plus a stray "25".
    return RegExp(r'^\s').hasMatch(rest) ? date : null;
  }
  return DateTime(year, month, day, time.hour, time.minute);
}

/// "Sep" or "September" → 9.
int? monthNumber(String name) {
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
  final index = months.indexOf(name.substring(0, 3).toLowerCase());
  return index < 0 ? null : index + 1;
}

/// "20:11", "8:11 PM", "20:11:05", or an Excel time (a fraction of a day).
({int hour, int minute})? parseTableTime(String? raw) {
  final text = (raw ?? '').trim();
  final fraction = double.tryParse(text);
  if (fraction != null) {
    if (fraction < 0 || fraction >= 1) return null;
    final minutes = (fraction * 24 * 60).round() % (24 * 60);
    return (hour: minutes ~/ 60, minute: minutes % 60);
  }
  final match = RegExp(
    r'^(\d{1,2}):(\d{2})(?::\d{2}(?:\.\d+)?)?\s*([AaPp])?\.?[Mm]?\.?(?:\s.*)?$',
  ).firstMatch(text);
  if (match == null) return null;
  var hour = int.parse(match[1]!);
  final minute = int.parse(match[2]!);
  final meridiem = match[3]?.toLowerCase();
  if (meridiem != null) {
    if (hour < 1 || hour > 12) return null;
    hour = hour % 12 + (meridiem == 'p' ? 12 : 0);
  }
  if (hour > 23 || minute > 59) return null;
  return (hour: hour, minute: minute);
}

/// How [cells] hold their dates: Excel serials when most are bare numbers,
/// else whichever text order reads the most (day first wins ties — Indian
/// statements write dates that way).
DateOrder detectDateOrder(Iterable<String> cells) {
  final filled = cells.where((c) => c.trim().isNotEmpty).take(300).toList();
  if (filled.isEmpty) return DateOrder.dayFirst;
  if (filled.where((c) => double.tryParse(c.trim()) != null).length * 2 >
      filled.length) {
    return DateOrder.excelSerial;
  }
  int reads(DateOrder order) =>
      filled.where((c) => parseTableDate(c, order) != null).length;
  return reads(DateOrder.monthFirst) > reads(DateOrder.dayFirst)
      ? DateOrder.monthFirst
      : DateOrder.dayFirst;
}

/// "State Bank Of India - 99", "XXXXXX2199", "HDFC Bank 4321" → the account.
StatementAccount? parseStatementAccount(String raw) {
  final text = raw.trim();
  final masked = RegExp(r'[Xx*•]{2,}\s?(\d{2,4})\b').firstMatch(text);
  if (masked != null) {
    final bank = text
        .substring(0, masked.start)
        .replaceAll(RegExp(r'[\s\-–:]+$'), '')
        .trim();
    return StatementAccount(
      bank: bank.isEmpty ? null : bank,
      digits: masked[1]!,
    );
  }
  final named = RegExp(r'^([A-Za-z][A-Za-z .&]+?)\s*[-–]?\s*(\d{2,4})$')
      .firstMatch(text);
  if (named == null) return null;
  return StatementAccount(bank: named[1]!.trim(), digits: named[2]!);
}

/// The account a bank's export is for, from the lines above its table:
/// "Account Number : 67333062199" (or "Account No.", "9150444825" in the
/// next cell) and the bank by name or by IFSC.
StatementAccount? statementAccountIn(List<List<String>> above) {
  final text = [for (final row in above) row.map((c) => c.trim()).join('  ')]
      .join('\n');
  final number = RegExp(
    r'(?:account|a/c)\s*(?:no\.?|number|num)\s*[:.\-]?\s*(?:\S*:\s*)?([0-9Xx*]{6,})',
    caseSensitive: false,
  ).firstMatch(text);
  if (number == null) return null;
  final digits = RegExp(r'\d+$').firstMatch(number[1]!)?[0];
  if (digits == null || digits.length < 2) return null;
  return StatementAccount(
    bank: statementBankIn(text),
    digits: digits.substring(digits.length > 4 ? digits.length - 4 : 0),
  );
}

/// The bank a statement's header names: by its IFSC, else by name.
String? statementBankIn(String text) {
  final ifsc = RegExp(r'\b([A-Z]{4})0[A-Z0-9]{6}\b').firstMatch(text);
  return bankCodes[ifsc?[1]] ??
      bankCodes.values
          .where((bank) => text.toLowerCase().contains(bank.toLowerCase()))
          .firstOrNull;
}

// ─── Rows → statement ────────────────────────────────────────────────────────

class TableParseResult {
  const TableParseResult({
    required this.statement,
    required this.skipped,
    required this.undirected,
    required this.dateOrder,
    this.account,
    this.balanceBreaks,
  });
  final UpiStatement statement;

  /// The account the lines above the table name, when they name one.
  final StatementAccount? account;

  /// Rows whose running balance doesn't follow from the row before — a
  /// misread amount or direction, or a row missed. Null without a balance
  /// column to check against.
  final int? balanceBreaks;

  /// Rows below the header that aren't transactions: totals, opening
  /// balances, footers. Blank rows aren't counted.
  final int skipped;

  /// Rows nothing gave a direction, which took the mapping's fallback.
  final int undirected;

  /// The date order used: the chosen one, or the one detected.
  final DateOrder dateOrder;
}

final _outWords = RegExp(
  r'^(?:paid\s+to|paid\s+for|sent\s+to|money\s+sent|payment\s+to|transfer(?:red)?\s+to|debit(?:ed)?\b|purchase|withdrawal|atm\s|pos\s|bill\s?pay|recharge|automatic\s+payment)',
  caseSensitive: false,
);
final _inWords = RegExp(
  r'^(?:received\s+from|refund|cashback|credit(?:ed)?\b|deposit|salary|interest|reversal)',
  caseSensitive: false,
);
final _selfWords = RegExp(
  r'self\s+transfer|transferred\s+to\s+self|to\s+self\b',
  caseSensitive: false,
);
final _payeePrefix = RegExp(
  r'^(?:paid\s+to|paid\s+for|sent\s+to|money\s+sent\s+to|payment\s+to|received\s+from|refund\s+from|cashback\s+(?:received\s+)?from|transfer(?:red)?\s+to)\s+',
  caseSensitive: false,
);
final _channelParts = {
  'UPI',
  'IMPS',
  'NEFT',
  'RTGS',
  'POS',
  'ACH',
  'NACH',
  'BIL',
  'MMT',
  'INF',
  // Union Bank of India's UPI payments (AR) and receipts (AB).
  'UPIAR',
  'UPIAB',
};
final _ifsc = RegExp(r'^[A-Z]{4}0[A-Z0-9]{6}$');
final _upiReference = RegExp(r'(?<!\d)\d{12}(?!\d)');
final _channelReference = RegExp(
  r'^(?:UPI|IMPS|NEFT|RTGS)[/\-: ]+([A-Za-z0-9]*\d[A-Za-z0-9]{5,})',
  caseSensitive: false,
);

/// The rows below [mapping]'s header as a statement. Rows without a readable
/// date or a non-zero amount are skipped and counted.
TableParseResult parseStatementTable(
  List<List<String>> rows,
  TableMapping mapping, {
  UpiStatementSource source = UpiStatementSource.csv,
}) {
  // A column joined to another reads with it: text runs on, an amount is
  // whichever part has one.
  const amounts = {
    TableField.amount,
    TableField.debit,
    TableField.credit,
    TableField.balance,
  };
  String cell(List<String> row, TableField field) {
    final column = mapping[field];
    if (column == null) return '';
    final parts = [
      for (final c in mapping.partsOf(column))
        if ((row.elementAtOrNull(c) ?? '').trim() case final v
            when v.isNotEmpty)
          v,
    ];
    if (parts.isEmpty) return '';
    return amounts.contains(field) ? parts.first : parts.join(' ');
  }

  final body = rows.skip(mapping.headerRow + 1).toList();
  // A bank's export names its one account above the table.
  final above = rows.take(mapping.headerRow).toList();
  final ownAccount = statementAccountIn(above);
  final order = mapping.dateOrder != DateOrder.auto
      ? mapping.dateOrder
      : detectDateOrder(body.map((r) => cell(r, TableField.date)));
  final parsed = <UpiStatementRow>[];
  final balances = <({int signedMinor, int balanceMinor})>[];
  var skipped = 0, undirected = 0;
  for (final row in body) {
    if (row.every((c) => c.trim().isEmpty)) continue;
    var date = parseTableDate(cell(row, TableField.date), order);
    if (date == null) {
      skipped++;
      continue;
    }
    final time = parseTableTime(cell(row, TableField.time));
    if (time != null) {
      date = DateTime(date.year, date.month, date.day, time.hour, time.minute);
    } else if (date.hour == 0 && date.minute == 0) {
      // A date alone: noon keeps it on its day in any time zone.
      date = DateTime(date.year, date.month, date.day, 12);
    }

    final description = cell(
      row,
      TableField.description,
    ).replaceAll(RegExp(r'\s+'), ' ');
    int? minor;
    bool? out;
    if (mapping.usesDebitCredit) {
      final debit = parseTableAmount(cell(row, TableField.debit))?.minor ?? 0;
      final credit = parseTableAmount(cell(row, TableField.credit))?.minor ?? 0;
      if (debit > 0) {
        (minor, out) = (debit, true);
      } else if (credit > 0) {
        (minor, out) = (credit, false);
      }
    } else {
      final amount = parseTableAmount(cell(row, TableField.amount));
      if (amount != null && amount.minor > 0) {
        minor = amount.minor;
        out =
            amount.out ??
            directionWord(cell(row, TableField.direction)) ??
            (_outWords.hasMatch(description)
                ? true
                : _inWords.hasMatch(description)
                ? false
                : null);
      }
    }
    if (minor == null) {
      skipped++;
      continue;
    }
    if (out == null) undirected++;
    var direction = switch (out) {
      true => UpiStatementDirection.debit,
      false => UpiStatementDirection.credit,
      null => mapping.fallback,
    };
    StatementAccount? toAccount;
    if (direction == UpiStatementDirection.debit &&
        _selfWords.hasMatch(description)) {
      direction = UpiStatementDirection.selfTransfer;
      final to = RegExp(
        r'(?:self\s+transfer\s+to|transferred\s+to\s+self,?)\s*(.+)$',
        caseSensitive: false,
      ).firstMatch(description);
      toAccount = to == null ? null : parseStatementAccount(to[1]!);
    }
    if (parseTableAmount(cell(row, TableField.balance)) case final b?) {
      balances.add((
        signedMinor: direction == UpiStatementDirection.credit ? minor : -minor,
        balanceMinor: b.out == true ? -b.minor : b.minor,
      ));
    }
    final payee = narrationPayee(description);
    parsed.add(
      UpiStatementRow(
        date: date,
        direction: direction,
        amountMinor: minor,
        counterparty: direction == UpiStatementDirection.selfTransfer
            ? 'Self transfer'
            : payee.name,
        reference: statementReference(
          cell(row, TableField.reference),
          description,
        ),
        account:
            parseStatementAccount(cell(row, TableField.account)) ?? ownAccount,
        toAccount: toAccount,
        counterpartyBank: payee.bank,
        counterpartyId: payee.id,
        narration: description.isEmpty ? null : description,
      ),
    );
  }
  return TableParseResult(
    statement: UpiStatement(
      source: source,
      rows: parsed,
      owner: statementOwnerIn(
        // A row's cells read as one line, so "Mr. ASHIQUE M" split over
        // cells (or a PDF line's phrases) is still one name; and each part
        // of a line printed in two columns ("Name  MR ASHIQUE M  Customer
        // ID  273115036") on its own.
        [
          for (final row in above)
            for (final line
                in row
                    .where((c) => c.trim().isNotEmpty)
                    .join('  ')
                    .split('\n')) ...[line, ...line.split(RegExp(r'\s{2,}'))],
        ],
        // The holder alone at the top, or first on a line of two columns.
        nameLines: [
          for (final row in above.take(4))
            if (row.where((c) => c.trim().isNotEmpty).firstOrNull
                case final cell?)
              cell.trim().split(RegExp(r'\s{2,}')).first,
        ],
      ),
    ),
    skipped: skipped,
    undirected: undirected,
    dateOrder: order,
    account: ownAccount,
    balanceBreaks: balanceBreaks(balances),
  );
}

/// How many rows' running balance doesn't follow from the row before it —
/// its balance plus what the row moved — reading the statement oldest
/// first or newest first, whichever fits. Null without two balances.
int? balanceBreaks(List<({int signedMinor, int balanceMinor})> rows) {
  if (rows.length < 2) return null;
  var forward = 0, backward = 0;
  for (var i = 1; i < rows.length; i++) {
    final (before, after) = (rows[i - 1], rows[i]);
    if (before.balanceMinor + after.signedMinor != after.balanceMinor) {
      forward++;
    }
    if (after.balanceMinor + before.signedMinor != before.balanceMinor) {
      backward++;
    }
  }
  return forward < backward ? forward : backward;
}

/// The bank each IFSC prefix stands for: the code a bank's narration puts
/// beside the other side's name ("UPI/ASHIQUE M/UBIN/…").
const bankCodes = {
  'SBIN': 'State Bank of India',
  'UBIN': 'Union Bank of India',
  'KKBK': 'Kotak Mahindra Bank',
  'HDFC': 'HDFC Bank',
  'ICIC': 'ICICI Bank',
  'UTIB': 'Axis Bank',
  'YESB': 'Yes Bank',
  'FDRL': 'Federal Bank',
  'CNRB': 'Canara Bank',
  'IOBA': 'Indian Overseas Bank',
  'PUNB': 'Punjab National Bank',
  'BARB': 'Bank of Baroda',
  'IDIB': 'Indian Bank',
  'IDFB': 'IDFC First Bank',
  'INDB': 'IndusInd Bank',
  'CBIN': 'Central Bank of India',
  'BKID': 'Bank of India',
  'MAHB': 'Bank of Maharashtra',
  'UCBA': 'UCO Bank',
  'PSIB': 'Punjab & Sind Bank',
  'SIBL': 'South Indian Bank',
  'CSBK': 'CSB Bank',
  'KVBL': 'Karur Vysya Bank',
  'TMBL': 'Tamilnad Mercantile Bank',
  'ESFB': 'Equitas Small Finance Bank',
  'AUBL': 'AU Small Finance Bank',
  'AIRP': 'Airtel Payments Bank',
  'PYTM': 'Paytm Payments Bank',
  'FINO': 'Fino Payments Bank',
  'IPOS': 'India Post Payments Bank',
  'CITI': 'Citibank',
  'SCBL': 'Standard Chartered',
  'HSBC': 'HSBC',
  'DBSS': 'DBS Bank',
  'RATN': 'RBL Bank',
  'KARB': 'Karnataka Bank',
  'DLXB': 'Dhanlaxmi Bank',
  'JAKA': 'J&K Bank',
  'SVCB': 'SVC Co-operative Bank',
};

/// A bank's prefix before its narration: "WDL TFR", "DEP TFR", "BY TRANSFER"…
final _bankPrefix = RegExp(
  r'^(?:(?:WDL|DEP|CSH)\s+TFR|BY\s+TRANSFER|TO\s+TRANSFER|TRANSFER\s+(?:TO|FROM))\s*[-:]?\s*',
  caseSensitive: false,
);

/// The payee: the name in a channel narration — "UPI/612345678901/GROCERY
/// MART/okaxis", SBI's "WDL TFR UPI/DR/500290521549/E O SAID/YESB/…", or
/// Kotak's "UPI/ASHIQUE M/UBIN/629920840430/UPI" — with the bank the other
/// side uses when the narration gives its code, and their UPI id when it
/// follows that code (Union's "…/ASHIQUE /SBIN/ashique4786-1@"); else the
/// description without its "Paid to" / "Received from".
({String name, String? bank, String? id}) narrationPayee(String description) {
  final text = description.replaceFirst(_bankPrefix, '');
  // Most banks part a narration with "/"; HDFC with "-":
  // "UPI-NAME-VPA-IFSC-REF-REMARK", or "NEFT CR-IFSC-NAME-…".
  for (final separator in const ['/', '-']) {
    final parts = [
      for (final part in text.split(separator))
        if (part.trim().isNotEmpty) part.trim(),
    ];
    if (parts.length < 2 || !_channel(parts.first)) continue;
    String? bank;
    final names = <String>[], handles = <String>[];
    for (final (i, part) in parts.indexed.skip(1)) {
      final upper = part.toUpperCase();
      // A narration wrapped mid-code reads "FDRL 0001861", "ABC @OKSBI".
      final joined = upper.replaceAll(RegExp(r'\s+'), '');
      if (bankCodes.containsKey(upper) || _ifsc.hasMatch(joined)) {
        bank = bankCodes[joined.substring(0, 4)];
        if (parts.elementAtOrNull(i + 1) case final id? when id.contains('@')) {
          handles.add(id.replaceAll(RegExp(r'\s+'), ''));
        }
      } else if (part.contains('@')) {
        handles.add(part.replaceAll(RegExp(r'\s+'), ''));
      } else if (const {'DR', 'CR', 'UPI', 'P2A', 'P2M'}.contains(upper) ||
          !part.contains(RegExp(r'[A-Za-z]')) ||
          // A reference code ("N289", "AXOMB123") is letters and digits in
          // one word; a name rarely is.
          RegExp(r'^[A-Za-z0-9]*\d[A-Za-z0-9]*$').hasMatch(part)) {
        continue;
      } else {
        names.add(part.replaceAll(RegExp(r'\s+'), ' '));
      }
      // The name comes right after the channel and reference; whatever
      // follows the bank code is the other side's UPI id or a remark —
      // unless the bank code came first, as in a NEFT credit's narration.
      if (bank != null && (names.isNotEmpty || handles.isNotEmpty)) break;
    }
    final name = names.firstOrNull ?? handles.firstOrNull;
    if (name != null) {
      return (name: name, bank: bank, id: handles.firstOrNull);
    }
  }
  final payee = description.replaceFirst(_payeePrefix, '').trim();
  return (name: payee.isEmpty ? 'Unknown' : payee, bank: null, id: null);
}

bool _channel(String part) {
  final upper = part.toUpperCase();
  return _channelParts.contains(upper) ||
      RegExp(r'^(?:NEFT|RTGS|IMPS)\s+(?:CR|DR)$').hasMatch(upper);
}

/// A row's UPI reference: the reference column's value when it is one,
/// else the one its narration quotes.
String? statementReference(String cell, String description) {
  if (RegExp(r'^\d+$').hasMatch(cell)) {
    // HDFC pads a UPI reference with zeros ("0000645791710429"), as other
    // banks and their SMS never do; all zeros is none at all.
    final reference = cell.replaceFirst(RegExp(r'^0+'), '');
    if (reference.length >= 6) return reference;
  } else if (RegExp(r'^[A-Za-z0-9]{6,32}$').hasMatch(cell) &&
      cell.contains(RegExp(r'\d'))) {
    return cell;
  }
  final channel = _channelReference.firstMatch(description);
  if (channel != null) return channel[1];
  return _upiReference.allMatches(description).lastOrNull?[0];
}
