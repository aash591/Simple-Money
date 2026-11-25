import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/statements/pdf_table.dart';
import 'package:simple_money/data/statements/statement_table.dart';
import 'package:simple_money/data/statements/upi_statement.dart';

// Pages laid out as PdfBox reports them: each word with its box, in points
// from the page's top-left. Text starts at its column's left; amounts end
// at its right.

const _char = 4.5, _space = 2.0;

/// A line's words: each cell's words a space apart, the cell starting at
/// its x (or, for [right], ending there).
List<PdfWord> _line(int page, double y, List<(double, String)> cells) => [
  for (final (x, text) in cells) ..._words(page, y, x, text),
];

Iterable<PdfWord> _words(int page, double y, double x, String text) sync* {
  final right = x < 0;
  var left = right
      ? -x -
            text.length * _char -
            (text.split(' ').length - 1) * (_space - _char)
      : x;
  for (final word in text.split(' ')) {
    final width = word.length * _char;
    yield PdfWord(page, left, y - 4, left + width, y + 4, word);
    left += width + _space;
  }
}

/// A cell right-aligned to [x].
double r(double x) => -x;

List<List<String>> _table(List<List<PdfWord>> lines) =>
    pdfStatementTable([for (final l in lines) ...l])!;

TableParseResult _parse(List<List<String>> rows) => parseStatementTable(
  rows,
  guessMapping(rows),
  source: UpiStatementSource.bank,
);

void main() {
  test('headed columns, wrapped narrations, totals and page breaks', () {
    final rows = _table([
      _line(1, 20, [(40, 'Account Statement')]),
      _line(1, 32, [(40, 'Ravi Kumar'), (300, 'Account No. 9150441234')]),
      _line(1, 44, [(40, 'IFSC Code KKBK0009296')]),
      _line(1, 80, [
        (40, 'Date'),
        (110, 'Description'),
        (300, 'Withdrawal (Dr.)'),
        (390, 'Deposit (Cr.)'),
        (470, 'Balance'),
      ]),
      _line(1, 94, [(110, 'Opening Balance'), (r(520), '100.00')]),
      _line(1, 106, [
        (40, '05 Sep 2026'),
        (110, 'UPI/ANITHA P'),
        (r(450), '20.00'),
        (r(520), '120.00'),
      ]),
      _line(1, 114, [(110, 'M/HDFC/600000000003/UPI')]),
      _line(1, 128, [
        (40, '07 Sep 2026'),
        (110, 'UPI/GROCERY MART/600000000004/UPI'),
        (r(370), '50.00'),
        (r(520), '70.00'),
      ]),
      _line(1, 300, [(40, 'Statement generated on 30 Sep 2026 Page 1 of 2')]),
      _line(2, 20, [
        (40, 'Date'),
        (110, 'Description'),
        (300, 'Withdrawal (Dr.)'),
        (390, 'Deposit (Cr.)'),
        (470, 'Balance'),
      ]),
      _line(2, 40, [
        (40, '09 Sep 2026'),
        (110, 'Int.Pd:9150441234:01-07-2026 to 30-09-2026'),
        (r(450), '1.00'),
        (r(520), '71.00'),
      ]),
      _line(2, 60, [(110, 'Closing Balance'), (r(520), '71.00')]),
    ]);
    final header = rows.indexWhere((r) => r.contains('Balance'));
    expect(rows[header], [
      'Date',
      'Description',
      'Withdrawal (Dr.)',
      'Deposit (Cr.)',
      'Balance',
    ]);
    expect(rows.skip(header + 1), [
      [
        '05 Sep 2026',
        'UPI/ANITHA P M/HDFC/600000000003/UPI',
        '',
        '20.00',
        '120.00',
      ],
      [
        '07 Sep 2026',
        'UPI/GROCERY MART/600000000004/UPI',
        '50.00',
        '',
        '70.00',
      ],
      [
        '09 Sep 2026',
        'Int.Pd:9150441234:01-07-2026 to 30-09-2026',
        '',
        '1.00',
        '71.00',
      ],
    ]);

    final result = _parse(rows);
    expect(result.statement.rows.map((r) => (r.direction, r.amountMinor)), [
      (UpiStatementDirection.credit, 2000),
      (UpiStatementDirection.debit, 5000),
      (UpiStatementDirection.credit, 100),
    ]);
    expect(result.balanceBreaks, 0);
    expect(result.account?.label, 'Kotak Mahindra Bank •• 1234');
    expect(result.statement.owner.names, {'ravi kumar'});
  });

  test('no headings: columns from the rows, the balance tells debit from '
      'credit, a row centred on its date', () {
    // Money in prints left of money out here, and only "Balance" is text.
    List<PdfWord> row(
      double y,
      String date,
      String first,
      String? inn,
      String? out,
      String balance,
    ) => _line(1, y, [
      (30, date),
      (90, date),
      (150, first),
      if (inn == null) (330, '-') else (r(350), inn),
      if (out == null) (410, '-') else (r(430), out),
      (r(520), balance),
    ]);
    final rows = _table([
      _line(1, 20, [(40, 'Mr. RAVI KUMAR')]),
      _line(1, 30, [(40, 'Account Number : 67333060000')]),
      _line(1, 40, [(40, 'IFSC Code : SBIN0070773')]),
      _line(1, 90, [(480, 'Balance')]),
      _line(1, 113, [(150, 'WDL TFR')]),
      row(
        120,
        '01/01/2026',
        'UPI/DR/600000000005/MUHAMM',
        null,
        '300.90',
        '1,699.10',
      ),
      _line(1, 131, [(150, 'ED/IOBA/rashid/UPI')]),
      _line(1, 141, [(150, '0097693162093 AT 70773 PBB')]),
      _line(1, 155, [(150, 'DEP TFR')]),
      row(
        162,
        '02/01/2026',
        'UPI/CR/600000000006/RAVI',
        '2,000.00',
        null,
        '3,699.10',
      ),
      _line(1, 173, [(150, 'KUMAR/UBIN/ravikumar9/UPI')]),
    ]);
    final header = rows.indexWhere((r) => r.contains('Balance'));
    expect(rows[header], [
      'Date',
      'Value date',
      'Description',
      'Credit',
      'Debit',
      'Balance',
    ]);
    final body = rows.skip(header + 1).toList();
    expect(
      body[0][2],
      'WDL TFR UPI/DR/600000000005/MUHAMM ED/IOBA/rashid/UPI '
      '0097693162093 AT 70773 PBB',
    );
    expect(
      body[1][2],
      'DEP TFR UPI/CR/600000000006/RAVI KUMAR/UBIN/ravikumar9/UPI',
    );

    final result = _parse(rows);
    expect(result.statement.rows.map((r) => (r.direction, r.amountMinor)), [
      (UpiStatementDirection.debit, 30090),
      (UpiStatementDirection.credit, 200000),
    ]);
    expect(result.statement.rows.first.reference, '600000000005');
    expect(result.balanceBreaks, 0);
    expect(result.account?.label, 'State Bank of India •• 0000');
  });

  test('one amount column marked (Dr)/(Cr); a two-column letterhead line '
      'is never the header', () {
    final rows = _table([
      _line(1, 20, [
        (40, 'Name'),
        (120, 'MR RAVI KUMAR'),
        (300, 'Account Number'),
        (400, '123402010001234'),
      ]),
      _line(1, 32, [
        (40, 'Statement Date'),
        (120, '30-10-2026 12:09'),
        (300, 'IFSC'),
        (400, 'UBIN0531234'),
      ]),
      _line(1, 60, [
        (30, 'Date'),
        (90, 'Transaction Id'),
        (160, 'Remarks'),
        (400, 'Amount'),
        (470, 'Balance'),
      ]),
      _line(1, 80, [
        (30, '02-01-2026'),
        (90, 'S1234567'),
        (160, 'UPIAR/600000000001/DR/ANITHA /CNRB/anitha12@okax'),
        (r(450), '500.00(Dr)'),
        (r(520), '1500.00(Cr)'),
      ]),
      _line(1, 100, [
        (30, '03-01-2026'),
        (90, 'V7654321'),
        (160, 'UPIAB/600000000002/CR/ANITHA /CNRB/anitha12@okax'),
        (r(450), '250.00(Cr)'),
        (r(520), '1750.00(Cr)'),
      ]),
    ]);
    final mapping = guessMapping(rows);
    expect(rows[mapping.headerRow], [
      'Date',
      'Transaction Id',
      'Remarks',
      'Amount',
      'Balance',
    ]);
    final result = parseStatementTable(rows, mapping);
    expect(result.statement.rows.map((r) => (r.direction, r.amountMinor)), [
      (UpiStatementDirection.debit, 50000),
      (UpiStatementDirection.credit, 25000),
    ]);
    expect(result.balanceBreaks, 0);
    expect(result.account?.label, 'Union Bank of India •• 1234');
    // Its holder, not the address line under them.
    expect(result.statement.owner.names, {'ravi kumar'});
  });

  test('evenly spaced lines wrap under their row; page furniture in the '
      'date column is left out', () {
    List<PdfWord> row(
      int page,
      double y,
      String date,
      String text,
      String amount,
      String balance,
    ) => _line(page, y, [
      (30, date),
      (100, text),
      (r(450), amount),
      (r(530), balance),
    ]);
    final rows = _table([
      _line(1, 80, [
        (30, 'Date'),
        (100, 'Narration'),
        (400, 'Withdrawal Amt.'),
        (480, 'Closing Balance'),
      ]),
      row(1, 100, '01/04/26', 'UPI-ANITHA P-ANITHAP99', '250.00', '750.00'),
      _line(1, 117, [(100, '@OKAXIS-600000000011-UPI')]),
      row(1, 134, '02/04/26', 'UPI-GROCERY MART', '150.00', '600.00'),
      _line(1, 151, [(100, 'GROCERYMART@YBL-600000000022')]),
      _line(1, 168, [(30, 'HDFC BANK LIMITED Registered Office Address')]),
      _line(2, 20, [(30, 'From : 01/04/2026 To : 30/09/2026')]),
      row(2, 37, '03/04/26', 'UPI-MANU M-MANU@OKSBI', '100.00', '500.00'),
    ]);
    final header = rows.indexWhere((r) => r.contains('Narration'));
    expect(rows[header], [
      'Date',
      'Narration',
      'Withdrawal Amt.',
      'Closing Balance',
    ]);
    expect(rows.skip(header + 1), [
      [
        '01/04/26',
        'UPI-ANITHA P-ANITHAP99 @OKAXIS-600000000011-UPI',
        '250.00',
        '750.00',
      ],
      [
        '02/04/26',
        'UPI-GROCERY MART GROCERYMART@YBL-600000000022',
        '150.00',
        '600.00',
      ],
      ['03/04/26', 'UPI-MANU M-MANU@OKSBI', '100.00', '500.00'],
    ]);
  });

  test('HDFC-style narrations and references', () {
    final rows = [
      [
        'Date',
        'Narration',
        'Chq./Ref.No.',
        'Withdrawal Amt.',
        'Deposit Amt.',
        'Closing Balance',
      ],
      [
        '01/04/26',
        'UPI-ANITHA P-ANITHAP99 @OKAXIS-FDRL 0001861-600000000011-UPI',
        '0000600000000011',
        '250.00',
        '',
        '750.00',
      ],
      [
        '05/04/26',
        'NEFT CR-CNRB0002896-ACME TRADERS-RAVI KUMAR-CNRBH00100000033',
        'CNRBH00100000033',
        '',
        '1,000.00',
        '1,750.00',
      ],
      [
        '30/04/26',
        'INTEREST PAID TILL 30-APR-2026',
        '000000000000000',
        '',
        '5.00',
        '1,755.00',
      ],
    ];
    final statement = parseStatementTable(rows, guessMapping(rows)).statement;
    final [anitha, neft, interest] = statement.rows;
    expect(
      (anitha.counterparty, anitha.counterpartyId, anitha.counterpartyBank),
      ('ANITHA P', 'ANITHAP99@OKAXIS', 'Federal Bank'),
    );
    expect(anitha.reference, '600000000011');
    expect(
      (neft.counterparty, neft.counterpartyBank),
      ('ACME TRADERS', 'Canara Bank'),
    );
    expect(interest.reference, isNull);
    expect(statementOwnerIn(['MR  RAVI KUMAR']).names, {'ravi kumar'});
  });

  test('a page without a column of dates is no table', () {
    expect(
      pdfStatementTable([
        ..._line(1, 20, [(40, 'Invoice 42')]),
        ..._line(1, 40, [(40, 'Total'), (r(520), '1,000.00')]),
      ]),
      isNull,
    );
  });

  test('a balance checks the rows, oldest or newest first', () {
    const oldestFirst = [
      (signedMinor: -2000, balanceMinor: 8000),
      (signedMinor: 500, balanceMinor: 8500),
      (signedMinor: -100, balanceMinor: 8400),
    ];
    expect(balanceBreaks(oldestFirst), 0);
    expect(balanceBreaks(oldestFirst.reversed.toList()), 0);
    // A misread amount breaks the chain.
    expect(
      balanceBreaks([
        oldestFirst[0],
        (signedMinor: 50, balanceMinor: 8500),
        oldestFirst[2],
      ]),
      1,
    );
    expect(balanceBreaks([oldestFirst.first]), isNull);
    expect(parseTableAmount('710.00(Dr)'), (minor: 71000, out: true));
    expect(parseTableAmount('6514.34(Cr)'), (minor: 651434, out: false));
    expect(parseTableAmount('1,52,430.01CR'), (minor: 15243001, out: false));
  });

  group('amount columns line up on any edge', () {
    // Money out, money in and the balance, each four rows: short and long
    // amounts in each, so their edges differ unless they line up.
    List<List<PdfWord>> statement(double Function(double x, String text) at) {
      List<PdfWord> row(
        double y,
        String date,
        String text, {
        String? debit,
        String? credit,
        required String balance,
      }) => _line(1, y, [
        (30, date),
        (100, text),
        if (debit != null) (at(320, debit), debit),
        if (credit != null) (at(390, credit), credit),
        (at(460, balance), balance),
      ]);
      return [
        _line(1, 80, [
          (30, 'Date'),
          (100, 'Narration'),
          (300, 'Debit'),
          (370, 'Credit'),
          (440, 'Balance'),
        ]),
        row(100, '01/04/26', 'SHOP A', debit: '90.00', balance: '7,414.41'),
        row(
          120,
          '02/04/26',
          'SALARY',
          credit: '16,800.00',
          balance: '24,214.41',
        ),
        row(140, '03/04/26', 'RENT', debit: '23,500.00', balance: '714.41'),
        row(160, '04/04/26', 'TEA', debit: '14.00', balance: '700.41'),
      ];
    }

    double width(String text) => text.length * _char;
    for (final (name, at) in [
      ('left', (double x, String t) => x - 20),
      ('right', (double x, String t) => r(x + 22)),
      ('centred', (double x, String t) => x - width(t) / 2),
    ]) {
      test(name, () {
        final rows = _table(statement(at));
        final header = rows.indexWhere((r) => r.contains('Narration'));
        expect(rows[header], [
          'Date',
          'Narration',
          'Debit',
          'Credit',
          'Balance',
        ]);
        final result = _parse(rows);
        expect(result.statement.rows, hasLength(4));
        expect(result.balanceBreaks, 0);
      });
    }

    test('columns close enough to touch are still told apart', () {
      // Money in right-aligned so close to money out that a long amount
      // reaches under it.
      final rows = _table([
        _line(1, 80, [
          (30, 'Date'),
          (100, 'Narration'),
          (300, 'Debit'),
          (345, 'Credit'),
          (420, 'Balance'),
        ]),
        _line(1, 100, [
          (30, '01/04/26'),
          (100, 'SHOP A'),
          (r(340), '90.00'),
          (r(470), '7,414.41'),
        ]),
        _line(1, 120, [
          (30, '02/04/26'),
          (100, 'SALARY'),
          (r(380), '1,16,800.00'),
          (r(470), '1,24,214.41'),
        ]),
        _line(1, 140, [
          (30, '03/04/26'),
          (100, 'RENT'),
          (r(340), '23,500.00'),
          (r(470), '1,00,714.41'),
        ]),
        _line(1, 160, [
          (30, '04/04/26'),
          (100, 'TEA'),
          (r(380), '14.00'),
          (r(470), '1,00,728.41'),
        ]),
      ]);
      final header = rows.indexWhere((r) => r.contains('Narration'));
      expect(rows[header], ['Date', 'Narration', 'Debit', 'Credit', 'Balance']);
      expect(_parse(rows).balanceBreaks, 0);
    });
  });

  test('a narration split by a wide space, or run into an amount, is one '
      'cell; an amount inside it stays', () {
    final rows = _table([
      _line(1, 80, [
        (30, 'Date'),
        (100, 'Narration'),
        (360, 'Debit'),
        (430, 'Credit'),
        (510, 'Balance'),
      ]),
      // "DEP TFR", a wide space, then the rest; it wraps across that space.
      _line(1, 100, [
        (30, '01/04/26'),
        (100, 'DEP TFR'),
        (150, 'UPI/CR/1/ANITHA'),
        (r(470), '2,500.00'),
        (r(550), '3,500.00'),
      ]),
      _line(1, 112, [(100, 'UPI/CR/1/ANITHA/OKAXIS/REF')]),
      _line(1, 130, [
        (30, '02/04/26'),
        (100, 'WDL TFR'),
        (150, 'UPI/DR/2/GROCERY'),
        (r(400), '500.00'),
        (r(550), '3,000.00'),
      ]),
      _line(1, 142, [(100, 'UPI/DR/2/GROCERY/YBL/REF')]),
      _line(1, 160, [
        (30, '03/04/26'),
        (100, 'REFUND 500.00 FROM SHOP'),
        (r(470), '100.00'),
        (r(550), '3,100.00'),
      ]),
      // A narration so long it runs up to the money-out column.
      _line(1, 180, [
        (30, '04/04/26'),
        (r(400), 'UPI/DR/4/SHOPKEEPERNAMEISLONG 12.00'),
        (r(550), '3,088.00'),
      ]),
    ]);
    final header = rows.indexWhere((r) => r.contains('Narration'));
    expect(rows[header], ['Date', 'Narration', 'Debit', 'Credit', 'Balance']);
    final body = rows.skip(header + 1).toList();
    expect(body[0][1], 'DEP TFR UPI/CR/1/ANITHA UPI/CR/1/ANITHA/OKAXIS/REF');
    expect(body[2][1], 'REFUND 500.00 FROM SHOP');
    expect(body[3].sublist(1), [
      'UPI/DR/4/SHOPKEEPERNAMEISLONG',
      '12.00',
      '',
      '3,088.00',
    ]);
    final result = _parse(rows);
    expect(result.statement.rows, hasLength(4));
    expect(result.balanceBreaks, 0);
  });

  test('a column of D and C is the direction, not the description', () {
    final rows = _table([
      _line(1, 80, [
        (30, 'Date'),
        (100, 'Transaction Details'),
        (330, 'Amount'),
      ]),
      _line(1, 100, [
        (30, '03 Sep 26'),
        (100, 'WED INN MALL'),
        (r(380), '5,000.00'),
        (400, 'D'),
      ]),
      _line(1, 120, [
        (30, '07 Sep 26'),
        (100, 'PAYMENT RECEIVED'),
        (r(380), '36,854.00'),
        (400, 'C'),
      ]),
    ]);
    final header = rows.indexWhere((r) => r.contains('Date'));
    expect(rows[header], ['Date', 'Transaction Details', 'Amount', 'Dr/Cr']);
  });
}
