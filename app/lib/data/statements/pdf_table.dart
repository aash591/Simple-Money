/// A bank statement PDF of a layout no parser knows, rebuilt as the rows and
/// columns of a table from where each word sits on its page, for the column
/// screen a CSV or Excel export goes through: the user sees what was read,
/// fixes any column that's off, and the layout is remembered.
///
/// Rows are anchored on the transaction date: the date column is where most
/// dates line up, and a line with a date there starts a row. The columns are
/// found from those lines too — text and dates line up on their left edge,
/// amounts on their right — so a table whose headings aren't text (SBI draws
/// them) still divides; headings, where there are some, only name them. A
/// line without a date belongs to the row on its side of the widest gap:
/// narrations wrap under their row, and some banks centre a row on its date.
library;

import 'dart:math' as math;

import 'statement_table.dart';

/// One word of a PDF page, as PdfBox placed it: in points from the page's
/// top-left corner.
class PdfWord {
  const PdfWord(
    this.page,
    this.left,
    this.top,
    this.right,
    this.bottom,
    this.text,
  );
  final int page;
  final double left, top, right, bottom;
  final String text;

  double get height => bottom - top;
  double get middle => (top + bottom) / 2;
}

/// The statement's table: the lines above it (bank, account, holder) one
/// row each, a header row naming every column, then a row per transaction.
/// Null when no column of dates runs down the pages.
List<List<String>>? pdfStatementTable(List<PdfWord> words) {
  final lines = _lines(words.where((w) => w.text.trim().isNotEmpty));
  if (lines.isEmpty) return null;
  final unit = _median([for (final w in words) w.height]);

  // The date column: where most whole-cell dates start. A row prints its
  // transaction date before any value date, so of two columns as full,
  // the left one.
  final dateLefts = [
    for (final line in lines)
      for (final p in line.phrases)
        if (p.kind == _Kind.date) p.left,
  ];
  final dateClusters = _cluster(dateLefts, unit);
  if (dateClusters.isEmpty) return null;
  final most = dateClusters.map((c) => c.length).reduce(math.max);
  final dateLeft = _median(
    dateClusters.firstWhere((c) => c.length * 5 >= most * 4),
  );
  bool startsRow(_Line line) => line.phrases.any(
    (p) => p.kind == _Kind.date && (p.left - dateLeft).abs() <= unit,
  );
  final rowLines = [
    for (final (i, line) in lines.indexed)
      if (startsRow(line)) i,
  ];
  if (rowLines.length < 2) return null;

  final columns = _columns([for (final i in rowLines) lines[i]], unit);
  if (columns.length < 2) return null;
  final dateColumn = [
    for (final (i, c) in columns.indexed)
      if (!c.rightAligned) (i, (c.anchor - dateLeft).abs()),
  ].reduce((a, b) => a.$2 <= b.$2 ? a : b).$1;

  // Which row each line between two row lines belongs to.
  final owner = List<int?>.filled(lines.length, null);
  for (final (n, i) in rowLines.indexed) {
    owner[i] = n;
  }
  // A narration's next line sits a line's spacing below — some statements
  // space their lines wide, so the limit follows the table's own spacing.
  final spacing = _median([
    for (var i = rowLines.first + 1; i <= rowLines.last; i++)
      if (lines[i].page == lines[i - 1].page)
        lines[i].middle - lines[i - 1].middle,
  ]);
  final limit = math.max(2.2 * unit, 1.3 * spacing);
  bool near(_Line a, _Line b) =>
      a.page == b.page && (b.middle - a.middle).abs() <= limit;
  for (var n = 0; n <= rowLines.length; n++) {
    final from = n == 0 ? -1 : rowLines[n - 1];
    final to = n == rowLines.length ? lines.length : rowLines[n];
    final between = [for (var i = from + 1; i < to; i++) i];
    if (between.isEmpty) continue;
    // The widest gap, the row boundary, splits them: before it they wrap
    // under the row above, after it they lead into the row below. Evenly
    // spaced lines leave no wider gap: a narration then wraps under its row,
    // as most banks print it, so the last of the widest gaps splits.
    var split = between.length;
    if (from >= 0 && to < lines.length) {
      final chain = [from, ...between, to];
      final gaps = [
        for (var k = 0; k + 1 < chain.length; k++)
          lines[chain[k]].page == lines[chain[k + 1]].page
              ? lines[chain[k + 1]].middle - lines[chain[k]].middle
              : double.infinity,
      ];
      final widest = gaps.reduce(math.max);
      split = gaps.lastIndexWhere((g) => g >= widest * 0.95);
    } else if (from < 0) {
      split = 0;
    }
    // Each side keeps only the lines that run on from its row; a page's
    // footer or the next page's letterhead is left out.
    if (from >= 0) {
      var last = lines[from];
      for (final i in between.take(split)) {
        if (!near(last, lines[i]) || _isHeading(lines[i])) break;
        owner[i] = n - 1;
        last = lines[i];
      }
    }
    if (to < lines.length) {
      var first = lines[to];
      for (final i in between.skip(split).toList().reversed) {
        if (!near(lines[i], first) || _isHeading(lines[i])) break;
        owner[i] = n;
        first = lines[i];
      }
    }
  }

  final cells = [
    for (final _ in rowLines)
      List<List<String>>.generate(columns.length, (_) => []),
  ];
  final ownerRow = [for (final _ in rowLines) <int>[]];
  for (final (i, line) in lines.indexed) {
    final n = owner[i];
    if (n == null || _summary.hasMatch(line.text)) continue;
    final placed = [
      for (final p in line.phrases) (p, _place(p, columns, unit)),
    ];
    // A line that isn't the row's own but brings an amount where the row
    // has one is a line of its own: an opening balance, a total. Nor does a
    // narration wrap into the date column: what does is the page's own — a
    // footer, the next page's letterhead.
    if (i != rowLines[n] &&
        placed.any(
          (e) =>
              e.$2 == dateColumn ||
              (e.$1.kind == _Kind.amount && cells[n][e.$2].isNotEmpty),
        )) {
      continue;
    }
    ownerRow[n].add(i);
    for (final (phrase, column) in placed) {
      cells[n][column].add(phrase.text);
    }
  }
  final body = [
    for (final row in cells) [for (final cell in row) cell.join(' ')],
  ];

  // Headings: the line just above the first row naming any column, and one
  // more above it when the labels wrap.
  final first = rowLines.first;
  final used = {for (final rows in ownerRow) ...rows};
  final headerLines = <int>[];
  for (var i = first - 1; i >= 0; i--) {
    if (used.contains(i)) continue;
    final line = lines[i];
    if (line.page != lines[first].page ||
        lines[first].middle - line.middle > 8 * unit) {
      break;
    }
    if (_namesColumns(line)) {
      headerLines.add(i);
      final above = i > 0 ? lines[i - 1] : null;
      if (above != null &&
          above.page == line.page &&
          line.middle - above.middle <= 1.6 * unit &&
          _namesColumns(above)) {
        headerLines.add(i - 1);
      }
      break;
    }
  }
  final names = List<List<String>>.generate(columns.length, (_) => []);
  for (final i in headerLines.reversed) {
    for (final p in lines[i].phrases) {
      names[_nearest(p, columns)].add(p.text);
    }
  }
  final header = _nameColumns(
    [for (final n in names) n.join(' ').trim()],
    columns,
    body,
  );

  // Above the table: the bank, the account and its holder, a line to a
  // single cell so no letterhead line passes for the header row. A long
  // letterhead is folded to keep the header where a column screen looks.
  final above = [
    for (var i = 0; i < first; i++)
      if (!headerLines.contains(i) && !used.contains(i))
        [lines[i].phrases.map((p) => p.text).join('  ')],
  ];
  const keep = 4, fold = 36;
  final folded = above.length <= fold
      ? above
      : [
          ...above.take(keep),
          for (final chunk in _chunks(
            above.skip(keep).toList(),
            ((above.length - keep) / (fold - keep)).ceil(),
          ))
            [chunk.map((r) => r.single).join('\n')],
        ];
  return [...folded, header, ...body];
}

/// Opening and closing balances, totals: a statement's own sums, never a
/// transaction's continuation.
final _summary = RegExp(
  r'\b(?:opening|closing)\s+balance\b|\bbrought\s+forward\b|\bcarried\s+forward\b|^\s*(?:grand\s+)?total\b',
  caseSensitive: false,
);
final _heading = RegExp(
  r'\b(?:date|balance|debit|credit|withdrawals?|deposits?|amount|description|narration|particulars|remarks|details)\b',
  caseSensitive: false,
);
final _amount = RegExp(
  r'^[-+]?(?:₹|Rs\.?|INR)?\s?\(?(?:\d[\d,]*\.\d{1,2}|\d{1,3}(?:,\d{2,3})+)\)?\s?(?:\(?\s?(?:Dr|Cr)\.?\s?\)?)?$',
  caseSensitive: false,
);
// A column with nothing in it: "-", "--", "—".
final _blank = RegExp(r'^[-–—]+$');

/// A line naming columns: a heading, and no amount of its own (an opening
/// balance line names a balance too, and "Closing Balance" is a heading).
bool _namesColumns(_Line line) =>
    _heading.hasMatch(line.text) &&
    line.phrases.every((p) => p.kind != _Kind.amount);

/// A line of column headings: two or more of them.
bool _isHeading(_Line line) =>
    {for (final m in _heading.allMatches(line.text)) m[0]!.toLowerCase()}
        .length >=
    2;

enum _Kind { date, amount, text }

class _Phrase {
  _Phrase(this.left, this.right, this.text)
    : kind = _amount.hasMatch(text)
          ? _Kind.amount
          : text.length <= 19 && parseTableDate(text, DateOrder.auto) != null
          ? _Kind.date
          : _Kind.text;
  final double left, right;
  final String text;
  final _Kind kind;
}

class _Line {
  _Line(this.page, this.middle, this.phrases);
  final int page;
  final double middle;
  final List<_Phrase> phrases;
  late final String text = phrases.map((p) => p.text).join(' ');
}

/// Words on one baseline, page by page, top to bottom; each line's words
/// joined into phrases where the gap between them is a space's, not a
/// column's.
List<_Line> _lines(Iterable<PdfWord> words) {
  final sorted = words.toList()
    ..sort(
      (a, b) => a.page != b.page
          ? a.page.compareTo(b.page)
          : a.middle.compareTo(b.middle),
    );
  final grouped = <List<PdfWord>>[];
  for (final word in sorted) {
    final line = grouped.lastOrNull;
    if (line != null &&
        line.first.page == word.page &&
        (word.middle - line.first.middle).abs() <=
            0.35 * math.max(word.height, line.first.height)) {
      line.add(word);
    } else {
      grouped.add([word]);
    }
  }
  return [
    for (final line in grouped)
      if ((line..sort((a, b) => a.left.compareTo(b.left))).isNotEmpty)
        _Line(line.first.page, _median([for (final w in line) w.middle]), [
          for (final phrase in _phrases(line))
            if (!_blank.hasMatch(phrase.text)) phrase,
        ]),
  ].where((l) => l.phrases.isNotEmpty).toList();
}

Iterable<_Phrase> _phrases(List<PdfWord> line) sync* {
  var start = 0;
  for (var i = 1; i <= line.length; i++) {
    final split =
        i == line.length ||
        line[i].left - line[i - 1].right >
            0.6 * math.min(line[i].height, line[i - 1].height) ||
        // A dash alone is an empty column, never part of a phrase.
        _blank.hasMatch(line[i].text) ||
        _blank.hasMatch(line[i - 1].text);
    if (!split) continue;
    final words = line.sublist(start, i);
    yield _Phrase(
      words.first.left,
      words.last.right,
      words.map((w) => w.text.trim()).join(' '),
    );
    start = i;
  }
}

/// A column: where its cells line up — text on the left, amounts on the
/// right — and how far they reach.
class _Column {
  _Column(this.rightAligned, this.anchor, this.left, this.right);
  final bool rightAligned;
  final double anchor, left, right;
}

/// The columns the row lines' cells line up in. An edge only a few rows
/// share is a narration that ran long, not a column.
List<_Column> _columns(List<_Line> rows, double unit) {
  final lefts = <double>[], rights = <double>[];
  for (final row in rows) {
    for (final p in row.phrases) {
      (p.kind == _Kind.amount ? rights : lefts).add(
        p.kind == _Kind.amount ? p.right : p.left,
      );
    }
  }
  // An amount on a dated row is always a column's, however rarely that
  // column is used: money out in a statement of mostly receipts.
  final enough = math.max(2, rows.length ~/ 10);
  final columns = <_Column>[];
  for (final (aligned, edges) in [(false, lefts), (true, rights)]) {
    for (final cluster in _cluster(edges, 1.2 * unit)) {
      if (!aligned && cluster.length < enough) continue;
      final anchor = _median(cluster);
      final phrases = [
        for (final row in rows)
          for (final p in row.phrases)
            if ((p.kind == _Kind.amount) == aligned &&
                ((aligned ? p.right : p.left) - anchor).abs() <= 1.2 * unit)
              p,
      ];
      columns.add(
        _Column(
          aligned,
          anchor,
          phrases.map((p) => p.left).reduce(math.min),
          phrases.map((p) => p.right).reduce(math.max),
        ),
      );
    }
  }
  return columns..sort((a, b) => a.left.compareTo(b.left));
}

/// The column a body phrase is in: an amount by its right edge, text by the
/// column it starts in.
int _place(_Phrase p, List<_Column> columns, double unit) {
  final aligned = [
    for (final (i, c) in columns.indexed)
      if (c.rightAligned == (p.kind == _Kind.amount)) i,
  ];
  if (aligned.isEmpty) return _nearest(p, columns);
  if (p.kind == _Kind.amount) {
    return aligned.reduce(
      (a, b) =>
          (columns[a].anchor - p.right).abs() <=
              (columns[b].anchor - p.right).abs()
          ? a
          : b,
    );
  }
  return aligned.lastWhere(
    (i) => columns[i].anchor <= p.left + unit,
    orElse: () => aligned.first,
  );
}

/// The column a heading sits over: the one it overlaps most, else the
/// nearest.
int _nearest(_Phrase p, List<_Column> columns) {
  var best = 0;
  var score = double.negativeInfinity;
  for (final (i, c) in columns.indexed) {
    final overlap = math.min(p.right, c.right) - math.max(p.left, c.left);
    if (overlap > score) (score, best) = (overlap, i);
  }
  return best;
}

/// Each column's heading: the PDF's own where it has one, else what its
/// cells show — dates, the balance every row has, money out and in (the
/// balance tells which is which), the narration.
List<String> _nameColumns(
  List<String> headings,
  List<_Column> columns,
  List<List<String>> body,
) {
  final names = [...headings];
  bool named(String word) => names.any((n) => n.toLowerCase().contains(word));
  int filled(int c) => body.where((r) => r[c].trim().isNotEmpty).length;
  final unnamed = [
    for (var i = 0; i < names.length; i++)
      if (names[i].isEmpty) i,
  ];

  for (final i in unnamed) {
    final cells = [
      for (final r in body)
        if (r[i].trim().isNotEmpty) r[i],
    ];
    if (cells.isNotEmpty &&
        cells.every((c) => parseTableDate(c, DateOrder.auto) != null)) {
      names[i] = named('date') ? 'Value date' : 'Date';
    }
  }

  final amounts = [
    for (final i in unnamed)
      if (columns[i].rightAligned && names[i].isEmpty) i,
  ];
  var balance = names.indexWhere((n) => n.toLowerCase().contains('balance'));
  if (balance < 0 &&
      amounts.length >= 2 &&
      filled(amounts.last) * 10 >= body.length * 9) {
    balance = amounts.removeLast();
    names[balance] = 'Balance';
  }
  if (amounts.length == 2 && !named('debit') && !named('credit')) {
    final [a, b] = amounts;
    // Money out lowers the balance: whichever way round fits more rows.
    final asIs = balance < 0 ? 0 : _breaks(body, a, b, balance);
    final swapped = balance < 0 ? 1 : _breaks(body, b, a, balance);
    final (debit, credit) = asIs <= swapped ? (a, b) : (b, a);
    names[debit] = 'Debit';
    names[credit] = 'Credit';
  } else if (amounts.length == 1 && !named('amount')) {
    names[amounts.single] = 'Amount';
  }

  final text = [
    for (final i in unnamed)
      if (names[i].isEmpty && !columns[i].rightAligned) i,
  ];
  if (text.isNotEmpty && !named('description') && !named('narration')) {
    int length(int c) => body.fold(0, (sum, r) => sum + r[c].length);
    final widest = text.reduce((a, b) => length(a) >= length(b) ? a : b);
    names[widest] = 'Description';
  }
  for (var i = 0; i < names.length; i++) {
    if (names[i].isEmpty) names[i] = 'Column ${i + 1}';
  }
  return names;
}

/// Rows whose balance doesn't follow from the row before with [debit] as
/// money out and [credit] as money in.
int _breaks(List<List<String>> body, int debit, int credit, int balance) =>
    balanceBreaks([
      for (final r in body)
        if (parseTableAmount(r[balance]) case final b?)
          (
            signedMinor:
                (parseTableAmount(r[credit])?.minor ?? 0) -
                (parseTableAmount(r[debit])?.minor ?? 0),
            balanceMinor: b.out == true ? -b.minor : b.minor,
          ),
    ]) ??
    0;

/// Values within [tolerance] of their neighbour, grouped, left to right.
List<List<double>> _cluster(List<double> values, double tolerance) {
  final sorted = [...values]..sort();
  final clusters = <List<double>>[];
  for (final v in sorted) {
    if (clusters.isNotEmpty && v - clusters.last.last <= tolerance) {
      clusters.last.add(v);
    } else {
      clusters.add([v]);
    }
  }
  return clusters;
}

double _median(List<double> values) {
  if (values.isEmpty) return 0;
  final sorted = [...values]..sort();
  return sorted[sorted.length ~/ 2];
}

Iterable<List<T>> _chunks<T>(List<T> items, int size) sync* {
  for (var i = 0; i < items.length; i += size) {
    yield items.sublist(i, math.min(i + size, items.length));
  }
}
