import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/statements/statement_reconciliation.dart';
import 'package:simple_money/data/statements/upi_statement.dart';

// Bank PDFs' text as PdfBox reads it: the order each bank drew it in.

const _union = '''
Savings Account
Page of
1 8
Your Details
Name MR RAVI KUMAR
Mobile No 9**** *1234
Email id r********9@gmail.com
Statement Period 01-01-2026 to 31-01-2026
Account Name RAVI KUMAR
Account Number 123402010001234
IFSC UBIN0531234
Date Transaction Id Remarks Amount( ) Balance( )
02-01-2026 S1234567 UPIAR/600000000001/DR/RAVI KUM/SBIN/ravikumar9-1@ 500.00(Dr) 1500.00(Cr)
02-01-2026 S1234568 UPIAR/600000000007/DR/RAVI KUM/SBIN/ravikumar1-1@ 40.00(Dr) 1460.00(Cr)
03-01-2026 V7654321 UPIAB/600000000002/CR/ANITHA /CNRB/anitha12@okax 250.00(Cr) 1710.00(Cr)
05-01-2026 T1111111 Sms Charges For Dec Qtr ,2025 5.31(Dr) 1704.69(Cr)
''';

const _kotak = '''
Account Statement
01 Jan 2026 - 31 Jan 2026
Ravi Kumar
CRN xxxxxx034
MICR 691485002 IFSC Code KKBK0009296
Account No. 9150441234
Savings Account Transactions
# Date Description Chq/Ref. No. Withdrawal (Dr.) Deposit (Cr.) Balance
- - Opening Balance - - - 71.50
1 05 Jan 2026 UPI/ANITHA P
M/HDFC/600000000003/UPI
UPI-624897805268 116.82 188.32
2 07 Jan 2026 UPI/ravikumar9-1@/SBIN/600000000004/UPI UPI-625023299244 100.00 88.32
3 12 Jan 2026 CASHBACK EARNED ONBF-
c89385e0eb13a92
6.00 94.32
Statement Generated on 30 Jan 2026, 12:03 Page 1 of 2
Savings Account Transactions
# Date Description Chq/Ref. No. Withdrawal (Dr.) Deposit (Cr.) Balance
4 30 Jan 2026 Int.Pd:9150441234:01-10-2025 to 31-12-2025 1.00 95.32
Ravi Kumar
Account No. 9150441234
End of Statement
Savings Account (SA): 71.50 95.32
''';

// SBI prints its labels apart from their values, and wraps narrations at
// the column's edge, mid-word when it must.
const _sbi = '''
Mr. RAVI KUMAR
ravikumar9@gmail.com
Branch Email ID
sbi.70773@sbi.co.in
CIF Number
:
Account Number
:
IFSC Code
:
77132230000
67333060000
SBIN0070773
STATEMENT OF ACCOUNT
State Bank of India
Balance
01/01/2026 01/01/2026
WDL TFR
UPI/DR/600000000005/MUHAMM
ED/IOBA/rashid/UPI
0097693162093 AT 70773 PBB,
KADAPPAKKADA, KOLLAM
- 300.90 - 38,435.83
1
Page no.
Balance
02/01/2026 02/01/2026 DEP TFR
UPI/CR/600000000006/RAVI
KUMAR/UBIN/ravikumar9/UPI
0097735162098 AT 70773 PBB, KOLLAM - - 2,000.00 40,435.83
''';

// HDFC continues a narration below its amounts, and repeats its letterhead
// wherever a page break falls — here inside a row.
const _hdfc = '''
Date Narration Chq./Ref.No. Value Dt Withdrawal Amt. Deposit Amt. Closing Balance
01/04/26 UPI-ANITHA
P-ANITHAP99@OKAXIS-FDRL
0000600000000011 01/04/26 250.00 1,250.00
0001861-600000000011-UPI
02/04/26 UPI-GROCERY MART-GROCERYMART@YBL-YESB0YBLUPI-600000 0000600000000022 02/04/26 150.00 1,100.00
Page No .: 1
MR RAVI KUMAR
HOUSE 12 KOCHI
Email : RAVIKUMAR9@GMAIL.COM
Account No : 50100400001234 OTHER
RTGS/NEFT IFSC: HDFC0001512 MICR : 682240016
HDFC BANK LIMITED
Registered Office Address: HDFC Bank House,Senapati Bapat Marg,Mumbai 400013
000022-PAID VIA PHONEPE
05/04/26 NEFT CR-CNRB0002896-ACME TRADERS-RAVI KU CNRBH00100000033 05/04/26 1,000.00 2,100.00
MAR1001-CNRBH00100000033
30/04/26 INTEREST PAID TILL 30-APR-2026 000000000000000 30/04/26 5.00 2,105.00
STATEMENT SUMMARY :-
Opening Balance Dr Count Cr Count Debits Credits Closing Bal
1,000.00 1 3 150.00 1,255.00 2,105.00
Generated On: 30-Oct-2026 17:53
''';

void main() {
  test('a Union Bank statement: a row a line, the way in brackets', () {
    final statement = parseUpiStatement(_union)!;
    expect(statement.source, UpiStatementSource.bank);
    expect(statement.unreadable, 0);
    expect(statement.rows.map((r) => (r.direction, r.amountMinor)), [
      (UpiStatementDirection.debit, 50000),
      (UpiStatementDirection.debit, 4000),
      (UpiStatementDirection.credit, 25000),
      (UpiStatementDirection.debit, 531),
    ]);
    final [own, _, anitha, charges] = statement.rows;
    expect(own.date, DateTime(2026, 1, 2, 12));
    expect(own.account?.label, 'Union Bank of India •• 1234');
    expect(own.counterparty, 'RAVI KUM');
    expect(own.counterpartyBank, 'State Bank of India');
    expect(own.counterpartyId, 'ravikumar9-1@');
    expect(own.reference, '600000000001');
    expect(anitha.counterparty, 'ANITHA');
    expect(charges.counterparty, 'Sms Charges For Dec Qtr ,2025');
    expect(charges.reference, isNull);

    // A masked email is a pattern, not the handle its tail looks like.
    expect(statement.owner.names, {'ravi kumar'});
    expect(statement.owner.handles, {'r********9'});
    // Union cuts names to eight letters: "RAVI KUM" with an id that fits the
    // mask is the holder; the same cut name with another id isn't.
    final rows = markOwnTransfers(statement.rows, statement.owner);
    expect(rows[0].direction, UpiStatementDirection.selfTransfer);
    expect(rows[0].toAccount?.label, 'State Bank of India');
    expect(rows[1].direction, UpiStatementDirection.debit);
  });

  test('a Kotak statement: wrapped narrations, the way from the balance', () {
    final statement = parseUpiStatement(_kotak)!;
    expect(statement.unreadable, 0);
    expect(
      statement.rows.map((r) => (r.direction, r.amountMinor, r.counterparty)),
      [
        (UpiStatementDirection.credit, 11682, 'ANITHA P M'),
        (UpiStatementDirection.debit, 10000, 'ravikumar9-1@'),
        (
          UpiStatementDirection.credit,
          600,
          'CASHBACK EARNED ONBF- c89385e0eb13a92',
        ),
        (
          UpiStatementDirection.credit,
          100,
          'Int.Pd:9150441234:01-10-2025 to 31-12-2025',
        ),
      ],
    );
    // The UPI reference both banks quote, not Kotak's own.
    expect(statement.rows.map((r) => r.reference), [
      '600000000003',
      '600000000004',
      null,
      null,
    ]);
    expect(statement.rows.first.account?.label, 'Kotak Mahindra Bank •• 1234');
    expect(statement.rows.first.counterpartyBank, 'HDFC Bank');
    expect(statement.owner.names, {'ravi kumar'});
  });

  test('an SBI statement: rows over several lines, labels apart', () {
    final statement = parseUpiStatement(_sbi)!;
    expect(statement.unreadable, 0);
    final [paid, received] = statement.rows;
    expect(paid.direction, UpiStatementDirection.debit);
    expect(paid.amountMinor, 30090);
    expect(paid.counterparty, 'MUHAMM ED');
    expect(paid.counterpartyBank, 'Indian Overseas Bank');
    expect(paid.reference, '600000000005');
    expect(received.direction, UpiStatementDirection.credit);
    expect(received.amountMinor, 200000);
    expect(received.date, DateTime(2026, 1, 2, 12));
    expect(received.counterparty, 'RAVI KUMAR');
    // The number can't be told from the CIF beside it: the bank alone
    // still finds the user's one SBI account.
    expect(
      paid.account,
      const StatementAccount(bank: 'State Bank of India', digits: ''),
    );
    // The branch's mailbox isn't the holder's.
    expect(statement.owner.handles, {'ravikumar9'});
    expect(statement.owner.names, {'ravi kumar'});
  });

  test('an HDFC statement: the way from the balance, totals checked', () {
    final statement = parseUpiStatement(_hdfc)!;
    expect(statement.unreadable, 0);
    expect(statement.rows.map((r) => (r.direction, r.amountMinor)), [
      (UpiStatementDirection.credit, 25000),
      (UpiStatementDirection.debit, 15000),
      (UpiStatementDirection.credit, 100000),
      (UpiStatementDirection.credit, 500),
    ]);
    // The statement's own totals agree with its rows.
    expect(statement.reportedSentMinor, 15000);
    expect(statement.reportedReceivedMinor, 125500);
    expect(statement.totalsMatch, isTrue);

    final [anitha, grocery, neft, interest] = statement.rows;
    expect(anitha.counterparty, 'ANITHA P');
    expect(anitha.counterpartyId, 'ANITHAP99@OKAXIS');
    // "FDRL" + "0001861", wrapped apart, is still Federal Bank's IFSC.
    expect(anitha.counterpartyBank, 'Federal Bank');
    // The reference column's, without HDFC's padding: as SMS quote it.
    expect(anitha.reference, '600000000011');
    expect(grocery.counterparty, 'GROCERY MART');
    expect(grocery.reference, '600000000022');
    expect(grocery.narration, contains('PAID VIA PHONEPE'));
    // A NEFT credit names the sender after the bank's IFSC.
    expect(neft.counterparty, 'ACME TRADERS');
    expect(neft.counterpartyBank, 'Canara Bank');
    expect(interest.reference, isNull);
    expect(anitha.account?.label, 'HDFC Bank •• 1234');
    expect(statement.owner.names, {'ravi kumar'});
    expect(statement.owner.handles, {'ravikumar9'});
  });

  test('other PDFs are none of these', () {
    expect(parseUpiStatement('Invoice\n01/01/2026 Total 1,000'), isNull);
  });
}
