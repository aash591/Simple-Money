import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

const maxStatementRows = 20000;

/// Uncompressed budget for every part read, together: a statement is
/// kilobytes, and one shared budget stops a small, highly compressed file
/// from expanding into gigabytes.
const _maxExpandedBytes = 32 * 1024 * 1024;

/// Reads the first sheet of an .xlsx workbook into rows of cell text.
///
/// An .xlsx is a zip of XML parts; a statement needs only its values, not
/// styles, formulas or charts. Numbers come back as their stored text
/// ("45567", "1234.5"): a date cell is a day serial and a time cell a
/// fraction of a day, which the statement table converts once it knows which
/// column holds them.
///
/// Legacy binary .xls isn't read; every spreadsheet app can save as .xlsx or
/// .csv.
List<List<String>> readXlsxRows(Uint8List bytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    throw const FormatException('This spreadsheet could not be opened.');
  }
  var budget = _maxExpandedBytes;
  XmlDocument? part(String name) {
    final file = archive.findFile(name);
    if (file == null) return null;
    budget -= file.size;
    if (budget < 0) {
      throw const FormatException('This spreadsheet is too large to import.');
    }
    return XmlDocument.parse(utf8.decode(file.content, allowMalformed: true));
  }

  final workbook = part('xl/workbook.xml');
  final date1904 = workbook
      ?.findAllElements('workbookPr')
      .firstOrNull
      ?.getAttribute('date1904');
  if (date1904 == '1' || date1904?.toLowerCase() == 'true') {
    // Its day numbers count from 1904; read as 1900 dates they'd land four
    // years early.
    throw const FormatException(
      'This workbook uses the 1904 date system. Save it as .csv and import that.',
    );
  }

  final firstSheet = _firstSheetPath(
    workbook,
    part('xl/_rels/workbook.xml.rels'),
  );
  final fallback =
      archive.files
          .map((f) => f.name)
          .where((n) => n.startsWith('xl/worksheets/') && n.endsWith('.xml'))
          .toList()
        ..sort();
  final sheet =
      (firstSheet == null ? null : part(firstSheet)) ??
      (fallback.isEmpty ? null : part(fallback.first));
  if (sheet == null) {
    throw const FormatException('This spreadsheet has no sheets.');
  }
  final shared = [
    for (final item
        in part('xl/sharedStrings.xml')?.findAllElements('si') ??
            const <XmlElement>[])
      _text(item),
  ];

  final rows = <List<String>>[];
  for (final row in sheet.findAllElements('row')) {
    // Empty rows are left out of the XML; keep their place so row numbers
    // match what the spreadsheet app shows.
    final number = int.tryParse(row.getAttribute('r') ?? '');
    if (number != null) {
      while (rows.length < number - 1) {
        rows.add(const []);
      }
    }
    if (rows.length >= maxStatementRows) throw const TooManyRowsException();
    final cells = <String>[];
    for (final cell in row.findElements('c')) {
      final column = _column(cell.getAttribute('r')) ?? cells.length;
      while (cells.length < column) {
        cells.add('');
      }
      final value = cell.findElements('v').firstOrNull?.innerText ?? '';
      final text = switch (cell.getAttribute('t')) {
        's' => shared.elementAtOrNull(int.tryParse(value) ?? -1) ?? '',
        'inlineStr' => _text(cell.findElements('is').firstOrNull),
        'b' => value == '1' ? 'TRUE' : 'FALSE',
        _ => value,
      };
      if (column < cells.length) {
        cells[column] = text;
      } else {
        cells.add(text);
      }
    }
    rows.add(cells);
  }
  return rows;
}

/// Refused rather than silently cut: a partial statement would import as if
/// it were complete.
class TooManyRowsException extends FormatException {
  const TooManyRowsException()
    : super(
        'This statement has more than $maxStatementRows rows. '
        'Export a shorter period and import that.',
      );
}

/// The text of a shared or inline string: its plain `<t>`, or every run's.
/// Phonetic guides (`<rPh>`) aren't part of the value.
String _text(XmlElement? item) {
  if (item == null) return '';
  return item.descendants
      .whereType<XmlElement>()
      .where(
        (e) =>
            e.name.local == 't' &&
            !e.ancestors.any((a) => a is XmlElement && a.name.local == 'rPh'),
      )
      .map((e) => e.innerText)
      .join();
}

/// "C12" → 2.
int? _column(String? reference) {
  final letters = RegExp(r'^[A-Z]+').stringMatch(reference ?? '');
  if (letters == null) return null;
  var index = 0;
  for (final unit in letters.codeUnits) {
    index = index * 26 + unit - 64;
  }
  return index - 1;
}

/// The workbook's first sheet by its order in workbook.xml, not file name.
String? _firstSheetPath(XmlDocument? workbook, XmlDocument? relations) {
  final first = workbook?.findAllElements('sheet').firstOrNull;
  if (first == null || relations == null) return null;
  final id = first.attributes
      .where((a) => a.name.local == 'id')
      .firstOrNull
      ?.value;
  final target = relations
      .findAllElements('Relationship')
      .where((r) => r.getAttribute('Id') == id)
      .firstOrNull
      ?.getAttribute('Target');
  if (target == null) return null;
  return target.startsWith('/') ? target.substring(1) : 'xl/$target';
}
