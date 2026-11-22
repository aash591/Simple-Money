import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/statements/upi_statement.dart';

void main() {
  // An SBI header: the address block sits right under the holder's name.
  const header = [
    'Registered Branch Code: 70773  Thank you for choosing WhatsApp Banking',
    'MANNANIYA UMARUL FAROOK  Dear Customer, as part of our green',
    'YATHEEMGHANA  initiative, all statements of account will be',
    'Statement of Mr. ASHIQUE M (A/c-xxxxxxxxxxxxxx199) between 01/04/2026',
    'Account Number : xxxxxxxxxxxxxx199',
    'Account Name :  Mr.  ASHIQUE   M',
  ];

  test('the account name line beats an address line near the top', () {
    final owner = statementOwnerIn(
      header,
      nameLines: [for (final l in header) l.split(RegExp(r'\s{2,}')).first],
    );
    expect(owner.names, {'ashique m'});
  });

  test('without a stated name, the old rules still apply', () {
    final owner = statementOwnerIn(const ['Mr. ASHIQUE M  Important']);
    expect(owner.names, {'ashique m'});
  });
}
