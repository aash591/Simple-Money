import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/statements/upi_statement.dart';

// Shapes copied from real exports, with names, numbers and references made up.

const _googlePay = '''
Transaction statement
9876543210, someone@example.com
Note: This statement reflects payments made by you on the Google Pay app. Self transfer payments are not included in the total money paid and
received. Any payments transactions and activity deleted from your Google Account will not show up in this statement.
Page 1 of 2
Transaction statement period
01 April 2026 - 30 September 2026
Sent
1,180.90
Received
2,000
Date & time Transaction details Amount
01 Apr, 2026
02:35 PM
Paid to Asha Varghese
UPI Transaction ID: 600000000001
Paid by State Bank of India 1111
1,000
01 Apr, 2026
04:03 PM
Received from Rahul K H
UPI Transaction ID: 600000000002
Paid to Union Bank of India 2222
2,000
01 Apr, 2026
04:12 PM
Self transfer to State Bank of India 1111
UPI Transaction ID: 600000000003
Paid by Union Bank of India 2222
2,500
Transaction statement
9876543210, someone@example.com
Note: This statement reflects payments made by you on the Google Pay app.
Page 2 of 2
Date & time Transaction details Amount
01 Sep,
2026
06:52 PM
Paid to Vi Prepaid
UPI Transaction ID: 600000000004
Paid by Union Bank of India 2222
₹180.90
''';

// PhonePe as one extractor gives it (spaces dropped) …
const _phonePeRaw = '''
TransactionStatementfor9876543210
29Oct,2025- 29Oct,2026
Date Transaction Details Type Amount
Jul08, 2026
08 31am
DEBIT 201
Mobile recharged9876500000
Transaction IDNX26070808310000000000001
UTRNo. 635700000001
JioPrepaidReferenceID26259100000
Paidby XXXXXX1111 1 GiftCard 200
Mar 18, 2026
11 46pm
CREDIT ₹2.50
PaymentfromGoogle
Transaction IDOLEX2603181146000000000002
UTRNo. 648300000002
Creditedto XXXXXX1111
Page1of1
Thisisan automaticallygeneratedstatement. Customer(s)arerequestedtoimmediatelynotifyPhonePein case
''';

// … and as another gives it, with columns fused onto one line.
const _phonePeFused = '''
Transaction Statement for 9876543210
Date Transaction Details Type Amount
Feb 15, 2026 Payment to Google DEBIT 2
02 36 pm Transaction ID OLEX2602151436000000000003
UTR No. 391200000003
Paid by XXXXXX1111
Page 1 of 1
This is an automatically generated statement. Contact PhonePe.
''';

const _paytm = '''
Page of
1 2
Paytm Statement for
1 APR'24 - 31 MAR'25
Total Money Paid
- Rs.1,017
2 Payments made
Total Money Received
+ Rs.106.90
1 Payments received
Accounts Payment made Payment received
State Bank Of India - 99 Rs.1,018
Equitas Small Finance Bank - 97 Rs.999
Passbook Payments History
Date &
Time
Transaction Details Notes & Tags Your Account Amount
28 Dec
3:08 PM
Paid to Graphy Labs Private Limited
UPI ID: cf.
graphylabs@cashfreensdlpb
UPI Ref No: 436300000001
Note: ajuOt1735378
64214920
Equitas
Small
Finance
Bank - 97
- Rs.999
11 Jun
10:54 AM
Refund from Protean eGov
Technologies Limited
UPI ID: paytm-00000000@paytm on
UPI Ref No: 416300000002
Note: express State Bank
Of India - 99
+ Rs.106.90
Page of
2 2
For any queries,
Contact Us
06 Apr
10:48 AM
Automatic payment of 40 setup for
Google Play
UPI ID: playstore@axisbank
UPI Ref No: 409700000003
Note: MandateExec
ute
State Bank
Of India - 99
- Rs.18
05 Apr
3:05 PM
Transferred to Self, Union Bank of India
- 3225
UPI ID: ***********3225@UBIN0000000.
ifsc.npci A/c No: Union Bank of India-
3225
UPI Ref No: 409600000004
Equitas
Small
Finance
Bank - 97
Rs.2,300
Note: This payment is not included in the total money paid and money received calculations.
''';

void main() {
  test('amounts are read as exact paise', () {
    expect(parseStatementAmount('6,23,366.67'), 62336667);
    expect(parseStatementAmount('180.9'), 18090);
    expect(parseStatementAmount('2'), 200);
    expect(parseStatementAmount('0'), isNull);
    expect(parseStatementAmount('1.234'), isNull);
  });

  test('Google Pay: payments, receipts and self transfers', () {
    final statement = parseUpiStatement(_googlePay)!;
    expect(statement.source, UpiStatementSource.googlePay);
    expect(statement.rows, hasLength(4));
    expect(statement.unreadable, 0);

    final paid = statement.rows[0];
    expect(paid.direction, UpiStatementDirection.debit);
    expect(paid.counterparty, 'Asha Varghese');
    expect(paid.amountMinor, 100000);
    expect(paid.date, DateTime(2026, 4, 1, 14, 35));
    expect(paid.reference, '600000000001');
    expect(
      paid.account,
      const StatementAccount(bank: 'State Bank of India', digits: '1111'),
    );

    // "Paid to <bank> 2222" after the UPI id is the account, not a payment.
    final received = statement.rows[1];
    expect(received.direction, UpiStatementDirection.credit);
    expect(received.counterparty, 'Rahul K H');
    expect(received.account?.digits, '2222');

    final self = statement.rows[2];
    expect(self.direction, UpiStatementDirection.selfTransfer);
    expect(self.account?.digits, '2222');
    expect(
      self.toAccount,
      const StatementAccount(bank: 'State Bank of India', digits: '1111'),
    );

    // The older split date, and a ₹ the extractor kept.
    final split = statement.rows[3];
    expect(split.date, DateTime(2026, 9, 1, 18, 52));
    expect(split.amountMinor, 18090);

    expect(statement.reportedSentMinor, 118090);
    expect(statement.reportedReceivedMinor, 200000);
    expect(statement.totalsMatch, isTrue);
  });

  test('PhonePe: with spaces dropped', () {
    final statement = parseUpiStatement(_phonePeRaw)!;
    expect(statement.source, UpiStatementSource.phonePe);
    expect(statement.rows, hasLength(2));
    final recharge = statement.rows[0];
    expect(recharge.direction, UpiStatementDirection.debit);
    expect(recharge.amountMinor, 20100);
    expect(recharge.date, DateTime(2026, 7, 8, 8, 31));
    expect(recharge.reference, '635700000001');
    expect(recharge.account?.digits, '1111');
    expect(recharge.counterparty, 'Mobile recharged9876500000');

    final credit = statement.rows[1];
    expect(credit.direction, UpiStatementDirection.credit);
    expect(credit.amountMinor, 250);
    expect(credit.date, DateTime(2026, 3, 18, 23, 46));
    expect(credit.account?.digits, '1111');
  });

  test('PhonePe: with columns fused onto one line', () {
    final statement = parseUpiStatement(_phonePeFused)!;
    expect(statement.rows, hasLength(1));
    final row = statement.rows.single;
    expect(row.counterparty, 'Google');
    expect(row.amountMinor, 200);
    expect(row.date, DateTime(2026, 2, 15, 14, 36));
    expect(row.reference, '391200000003');
    expect(row.account?.digits, '1111');
  });

  test('Paytm: years from the period, wrapped names and accounts', () {
    final statement = parseUpiStatement(_paytm)!;
    expect(statement.source, UpiStatementSource.paytm);
    expect(statement.unreadable, 0);
    expect(statement.rows, hasLength(4));

    final paid = statement.rows[0];
    expect(paid.date, DateTime(2024, 12, 28, 15, 8));
    expect(paid.direction, UpiStatementDirection.debit);
    expect(paid.counterparty, 'Graphy Labs Private Limited');
    expect(paid.amountMinor, 99900);
    expect(paid.reference, '436300000001');
    expect(
      paid.account,
      const StatementAccount(bank: 'Equitas Small Finance Bank', digits: '97'),
    );

    final refund = statement.rows[1];
    expect(refund.date, DateTime(2024, 6, 11, 10, 54));
    expect(refund.direction, UpiStatementDirection.credit);
    expect(refund.counterparty, 'Protean eGov Technologies Limited');
    expect(refund.account?.digits, '99');

    final mandate = statement.rows[2];
    expect(mandate.counterparty, 'Google Play');
    expect(mandate.amountMinor, 1800);

    final self = statement.rows[3];
    expect(self.date, DateTime(2024, 4, 5, 15, 5));
    expect(self.direction, UpiStatementDirection.selfTransfer);
    expect(self.account?.digits, '97');
    expect(
      self.toAccount,
      const StatementAccount(bank: 'Union Bank of India', digits: '3225'),
    );

    expect(statement.reportedSentMinor, 101700);
    expect(statement.reportedReceivedMinor, 10690);
    expect(statement.totalsMatch, isTrue);
  });

  test('a statement that does not add up is flagged', () {
    final statement = parseUpiStatement(
      _googlePay.replaceFirst('1,180.90', '1,280.90'),
    )!;
    expect(statement.totalsMatch, isFalse);
  });

  test('other PDFs are not statements', () {
    expect(parseUpiStatement('Invoice\nTotal 1,000'), isNull);
  });

  // Real exports are private and never committed: drop their extracted text
  // into devtimefiles/statements/PERSON 1/ (gpay.txt, phonepe.txt,
  // paytm.txt) to run these.
  for (final (file, source) in [
    ('gpay.txt', UpiStatementSource.googlePay),
    ('phonepe.txt', UpiStatementSource.phonePe),
    ('paytm.txt', UpiStatementSource.paytm),
  ]) {
    final path = File('../devtimefiles/statements/PERSON 1/$file');
    test('local export $file adds up', () {
      final statement = parseUpiStatement(path.readAsStringSync())!;
      expect(statement.source, source);
      expect(statement.rows, isNotEmpty);
      expect(statement.unreadable, 0);
      expect(statement.totalsMatch, isTrue);
      for (final row in statement.rows) {
        expect(row.reference, isNotNull);
        expect(row.account, isNotNull);
      }
    }, skip: path.existsSync() ? false : 'no local export');
  }
}
