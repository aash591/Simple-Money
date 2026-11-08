import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/statements/statement_table.dart';
import 'package:simple_money/data/statements/upi_statement.dart';

// A UPI app's export: unsigned amounts, and a "Credit/debit instrument"
// column that names the payment method, not the direction.
const _upiExport = '''
Paytm Statement
"Ashique M, ******1846"
1 JUN'24 - 30 SEP'24
Date,Time,Transaction Details,Other Transaction Details (UPI ID or A/c No),UTR,Your Account,Credit/debit instrument,Amount
2024-06-01,20:11,Paid to Sakkeer P M,sakkeer@okaxis,415300000001,State Bank Of India - 99,UPI,10
2024-06-01,22:01,Received from Insam P S,insam@oksbi,415300000002,State Bank Of India - 99,UPI,"1,950.50"
2024-06-02,13:19,Transferred to Self,******1846@ptsbi,415300000003,State Bank Of India - 99,UPI,500
2024-06-06,21:45,Money sent to Amina Beevi,amina@ybl,415300000004,Equitas Small Finance Bank - 97,UPI,1
,,,,,,,
Total,,,,,,,2461.50
''';

// A bank statement: separate withdrawal/deposit columns, day-first dates,
// channel narrations and an opening balance row.
const _bankExport = '''
Account Statement;;;;;
Account No: XXXXXXXX4321;;;;;
Date;Narration;Chq./Ref.No.;Withdrawal Amt.;Deposit Amt.;Closing Balance
;Opening Balance;;;;10000.00
05/01/25;UPI/612345678901/GROCERY MART/okaxis;0000612345678901;450.00;;9550.00
06/01/25;"NEFT/N289/SALARY, ACME LTD";N289;;50000.00;59550.00
13/01/25;ATM WDL KOCHI;;2000.00;;57550.00
''';

void main() {
  test('amount cells: signs, Dr/Cr, brackets and grouping', () {
    expect(parseTableAmount('1,23,456.78'), (minor: 12345678, out: null));
    expect(parseTableAmount('₹ 500.00 Cr'), (minor: 50000, out: false));
    expect(parseTableAmount('500 DR'), (minor: 50000, out: true));
    expect(parseTableAmount('(250.00)'), (minor: 25000, out: true));
    expect(parseTableAmount('-99'), (minor: 9900, out: true));
    expect(parseTableAmount('+Rs.1,353.80'), (minor: 135380, out: false));
    expect(parseTableAmount('1.234,56'), (minor: 123456, out: null));
    expect(parseTableAmount('24521.000000000004'), (minor: 2452100, out: null));
    expect(parseTableAmount('Opening Balance'), isNull);
    expect(parseTableAmount('01/06/2024'), isNull);
    expect(parseTableAmount(''), isNull);
  });

  test('dates in every common shape', () {
    DateTime? read(String raw, [DateOrder order = DateOrder.dayFirst]) =>
        parseTableDate(raw, order);
    expect(read('05/01/25'), DateTime(2025, 1, 5));
    expect(read('05/01/2025', DateOrder.monthFirst), DateTime(2025, 5, 1));
    expect(read('2024-06-01'), DateTime(2024, 6, 1));
    expect(read('2024-06-01T20:11:00'), DateTime(2024, 6, 1, 20, 11));
    expect(read('01/06/2024 8:11 PM'), DateTime(2024, 6, 1, 20, 11));
    expect(read('05-Jan-25'), DateTime(2025, 1, 5));
    expect(read('Jan 5, 2025'), DateTime(2025, 1, 5));
    expect(read('23 Sept 2024'), DateTime(2024, 9, 23));
    expect(read('31/02/2025'), isNull);
    expect(read('Opening Balance'), isNull);
    expect(read('45444', DateOrder.excelSerial), DateTime(2024, 6, 1));
    expect(read('45444.5', DateOrder.excelSerial), DateTime(2024, 6, 1, 12));
    expect(read('612345678901', DateOrder.excelSerial), isNull);
    expect(parseTableTime('0.8409722'), (hour: 20, minute: 11));
    expect(parseTableTime('9:05 am'), (hour: 9, minute: 5));
  });

  test('date order is detected from the column', () {
    expect(detectDateOrder(['12/31/2024', '01/15/2025']), DateOrder.monthFirst);
    expect(detectDateOrder(['31/12/2024', '15/01/2025']), DateOrder.dayFirst);
    expect(detectDateOrder(['01/02/2025']), DateOrder.dayFirst);
    expect(detectDateOrder(['45444', '45445']), DateOrder.excelSerial);
  });

  test('a UPI export: columns guessed, directions from the descriptions', () {
    final rows = readCsvTable(Uint8List.fromList(utf8.encode(_upiExport)));
    final mapping = guessMapping(rows);
    expect(mapping.headerRow, 3);
    expect(mapping[TableField.date], 0);
    expect(mapping[TableField.time], 1);
    expect(mapping[TableField.description], 2);
    expect(mapping[TableField.reference], 4);
    expect(mapping[TableField.account], 5);
    expect(mapping[TableField.amount], 7);
    // The instrument column holds "UPI", not Dr/Cr words.
    expect(mapping[TableField.direction], isNull);

    final result = parseStatementTable(rows, mapping);
    final parsed = result.statement.rows;
    expect(parsed, hasLength(4));
    expect(result.skipped, 1); // the Total row
    expect(result.undirected, 0);

    expect(parsed[0].direction, UpiStatementDirection.debit);
    expect(parsed[0].counterparty, 'Sakkeer P M');
    expect(parsed[0].date, DateTime(2024, 6, 1, 20, 11));
    expect(parsed[0].amountMinor, 1000);
    expect(parsed[0].reference, '415300000001');
    expect(
      parsed[0].account,
      const StatementAccount(bank: 'State Bank Of India', digits: '99'),
    );

    expect(parsed[1].direction, UpiStatementDirection.credit);
    expect(parsed[1].counterparty, 'Insam P S');
    expect(parsed[1].amountMinor, 195050);

    expect(parsed[2].direction, UpiStatementDirection.selfTransfer);
    expect(parsed[3].direction, UpiStatementDirection.debit);
    expect(parsed[3].counterparty, 'Amina Beevi');
    expect(parsed[3].account?.digits, '97');
  });

  test('a bank statement: debit and credit columns', () {
    final rows = readCsvTable(Uint8List.fromList(utf8.encode(_bankExport)));
    final mapping = guessMapping(rows);
    expect(mapping.headerRow, 2);
    expect(mapping[TableField.debit], 3);
    expect(mapping[TableField.credit], 4);
    expect(mapping[TableField.amount], isNull);

    final result = parseStatementTable(rows, mapping);
    final parsed = result.statement.rows;
    expect(result.dateOrder, DateOrder.dayFirst);
    expect(result.skipped, 1); // the opening balance
    expect(parsed, hasLength(3));
    expect(parsed[0].direction, UpiStatementDirection.debit);
    expect(parsed[0].counterparty, 'GROCERY MART');
    expect(parsed[0].date, DateTime(2025, 1, 5, 12));
    // Unpadded, as the bank's SMS and the other side's statement quote it.
    expect(parsed[0].reference, '612345678901');
    expect(parsed[1].direction, UpiStatementDirection.credit);
    expect(parsed[1].amountMinor, 5000000);
    expect(parsed[1].counterparty, 'SALARY, ACME LTD');
    expect(parsed[2].counterparty, 'ATM WDL KOCHI');
  });

  test('signed amounts and a Dr/Cr column', () {
    final rows = readCsvRows(
      'Txn Date,Description,Amount,Type\n'
      '01-02-2025,Coffee,120.00,DR\n'
      '02-02-2025,Interest,-5.00,CR\n'
      '03-02-2025,Shop,-80.00,\n',
    );
    final mapping = guessMapping(rows);
    expect(mapping[TableField.direction], 3);
    final parsed = parseStatementTable(rows, mapping).statement.rows;
    expect(parsed.map((r) => r.direction), [
      UpiStatementDirection.debit,
      // The minus on the amount outranks the column.
      UpiStatementDirection.debit,
      UpiStatementDirection.debit,
    ]);
  });

  test('rows nothing gives a direction take the chosen fallback', () {
    final rows = readCsvRows(
      'Date,Details,Amount\n'
      '01/02/2025,Kiran,100\n'
      '02/02/2025,Paid to Shop,50\n',
    );
    final mapping = guessMapping(rows);
    final asPayments = parseStatementTable(rows, mapping);
    expect(asPayments.undirected, 1);
    expect(
      asPayments.statement.rows.first.direction,
      UpiStatementDirection.debit,
    );
    final asIncome = parseStatementTable(
      rows,
      mapping.copyWith(fallback: UpiStatementDirection.credit),
    );
    expect(
      asIncome.statement.rows.first.direction,
      UpiStatementDirection.credit,
    );
    expect(asIncome.statement.rows.last.direction, UpiStatementDirection.debit);
  });

  test('a mapping is saved by its header and found again', () {
    final rows = readCsvTable(Uint8List.fromList(utf8.encode(_upiExport)));
    final mapping = guessMapping(rows)
        .withColumn(TableField.description, 3)
        .copyWith(dateOrder: DateOrder.yearFirst);
    final saved = {
      tableSignature(rows[mapping.headerRow]): jsonDecode(
        jsonEncode(mapping.toJson()),
      ),
    };
    final found = findSavedMapping(rows, saved)!;
    expect(found.headerRow, 3);
    expect(found[TableField.description], 3);
    expect(found.dateOrder, DateOrder.yearFirst);
    expect(findSavedMapping(readCsvRows('a,b,c\n'), saved), isNull);
  });

  test('the header is the row of names above the first transaction', () {
    // "Statement Date" above the table names a date in three cells.
    expect(
      guessHeaderRow([
        ['Statement Date', ':', '31/10/2026', '', ''],
        ['Account No', ':', '1234567890', '', ''],
        ['Date', 'Narration', 'Withdrawal', 'Deposit', 'Balance'],
        ['01/10/26', 'UPI-SWIGGY', '250.00', '', '9,750.00'],
      ]),
      2,
    );
    // Short names that never say "date", under a wider details row.
    expect(
      guessHeaderRow([
        ['Customer ID', '12345', 'Branch', 'KOLLAM', 'IFSC', 'KAVR0001234'],
        ['Period', '01/10/2026', 'to', '31/10/2026', '', ''],
        ['', '', '', '', '', ''],
        ['Dt', 'Remarks', 'Out', 'In', 'Bal', ''],
        ['01/10/26', 'UPI-SWIGGY', '250.00', '', '9,750.00', ''],
      ]),
      3,
    );
  });

  test('a column serves one field', () {
    final mapping = const TableMapping(headerRow: 0)
        .withColumn(TableField.amount, 4)
        .withColumn(TableField.debit, 4);
    expect(mapping[TableField.amount], isNull);
    expect(mapping[TableField.debit], 4);
  });

  test('xlsx: shared strings, date serials and time fractions', () {
    String sheetXml(List<String> cells) =>
        '<worksheet><sheetData>${cells.join()}</sheetData></worksheet>';
    final archive = Archive()
      ..addFile(
        ArchiveFile.string(
          'xl/workbook.xml',
          '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
              '<sheets><sheet name="Txns" sheetId="1" r:id="rId1"/></sheets></workbook>',
        ),
      )
      ..addFile(
        ArchiveFile.string(
          'xl/_rels/workbook.xml.rels',
          '<Relationships><Relationship Id="rId1" Target="worksheets/sheet1.xml"/></Relationships>',
        ),
      )
      ..addFile(
        ArchiveFile.string(
          'xl/sharedStrings.xml',
          '<sst><si><t>Date</t></si><si><t>Time</t></si><si><t>Transaction Details</t></si>'
              '<si><t>Amount</t></si><si><r><t>Paid to </t></r><r><t>Sakkeer</t></r></si></sst>',
        ),
      )
      ..addFile(
        ArchiveFile.string(
          'xl/worksheets/sheet1.xml',
          sheetXml([
            '<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c>'
                '<c r="C1" t="s"><v>2</v></c><c r="E1" t="s"><v>3</v></c></row>',
            '<row r="3"><c r="A3"><v>45444</v></c><c r="B3"><v>0.8409722</v></c>'
                '<c r="C3" t="s"><v>4</v></c><c r="E3"><v>10.5</v></c></row>',
          ]),
        ),
      );
    final bytes = Uint8List.fromList(ZipEncoder().encode(archive));
    final rows = readExcelTable(bytes);
    expect(rows[0], ['Date', 'Time', 'Transaction Details', '', 'Amount']);
    expect(rows[1], isEmpty);
    expect(rows[2][2], 'Paid to Sakkeer');

    final result = parseStatementTable(rows, guessMapping(rows));
    expect(result.dateOrder, DateOrder.excelSerial);
    final row = result.statement.rows.single;
    expect(row.date, DateTime(2024, 6, 1, 20, 11));
    expect(row.amountMinor, 1050);
    expect(row.direction, UpiStatementDirection.debit);
  });

  test('old .xls files are refused with a way out', () {
    expect(
      () => readExcelTable(Uint8List.fromList([0xD0, 0xCF, 0x11, 0xE0, 0])),
      throwsA(isA<FormatException>()),
    );
  });

  test('CSV quoting, semicolons and UTF-16', () {
    expect(readCsvRows('a;"b;c";"say ""hi"""\r\n1;2;3'), [
      ['a', 'b;c', 'say "hi"'],
      ['1', '2', '3'],
    ]);
    final utf16 = [
      0xFF,
      0xFE,
      for (final c in 'x,y\n'.codeUnits) ...[c, 0],
    ];
    expect(readCsvTable(Uint8List.fromList(utf16)), [
      ['x', 'y'],
    ]);
  });

  test('bank narrations: payee, the other bank, and the account above', () {
    final rows = readCsvRows(
      '"","","Account Statement"\n'
      '"ASHIQUE M"\n'
      '"","","","","Account No.","9150444825"\n'
      '"","","","","IFSC","KKBK0009296"\n'
      '\n'
      '"Sl. No.","Transaction Date","Description","Chq /Ref No.","Amount","Dr / Cr"\n'
      '"1","05-09-2026 14:58:29","UPI/ANWARSHAH  P M/HDFC/624835231853/UPI","UPI-624897805268","116.82","CR"\n'
      '"2","07-09-2026 10:24:36","UPI/ashique4786-1@/SBIN/661638589646/UPI","UPI-625023299244","2,100.00","DR"\n'
      '"3","08-09-2026 09:00:00","WDL TFR UPI/DR/500290521549/E O SAID/YESB/paytm.s13q /UPI 0097694162092 AT 70773 PBB","","20.00","DR"\n',
    );
    final statement = parseStatementTable(rows, guessMapping(rows)).statement;
    expect(statement.owner.names, {'ashique m'});
    final [anwar, self, said] = statement.rows;
    expect(anwar.counterparty, 'ANWARSHAH P M');
    expect(anwar.counterpartyBank, 'HDFC Bank');
    expect(anwar.reference, '624835231853');
    expect(anwar.account?.label, 'Kotak Mahindra Bank •• 4825');
    expect(self.counterparty, 'ashique4786-1@');
    expect(self.counterpartyBank, 'State Bank of India');
    expect(said.counterparty, 'E O SAID');
    expect(said.counterpartyBank, 'Yes Bank');
  });

  test('masked numbers under any heading are the account column', () {
    final rows = readCsvRows(
      'Date,Time,Transaction Details,UTR,Transaction Type,Credit/debit instrument,Amount\n'
      '2024-06-01,20:11,Paid to Sakkeer,415356112924,Debit,XXXXXXXXXXX3225,10.00\n'
      '2024-09-23,18:29,Paid to salih,463386963935,Debit,XXXXXX2199,250.00\n',
    );
    final mapping = guessMapping(rows);
    expect(mapping[TableField.account], 5);
    final parsed = parseStatementTable(rows, mapping).statement.rows;
    expect(parsed.map((r) => r.account?.digits), ['3225', '2199']);
  });
}
