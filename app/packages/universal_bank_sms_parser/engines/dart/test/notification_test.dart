import 'package:test/test.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

void main() {
  test('identical carrier retries collapse, distinct purchases do not', () {
    const body = 'Spent Rs.5677.00 at SAMPLE STORE with credit card XX1234.';
    final at = DateTime(2026, 1, 25);
    BankSms message(
      int seconds, {
      String text = body,
      String sender = 'CP-ONECRD-S',
    }) => BankSms(
      sender: sender,
      body: text,
      receivedAt: at.add(Duration(seconds: seconds)),
    );
    expect(isRepeatedSmsNotification(message(0), message(24)), isTrue);
    expect(
      isRepeatedSmsNotification(message(0), message(24, text: '$body\r\n')),
      isTrue,
    );
    expect(isRepeatedSmsNotification(message(0), message(60)), isFalse);
    expect(
      isRepeatedSmsNotification(
        message(0),
        message(24, text: body.replaceAll('1234', '5678')),
      ),
      isFalse,
    );
    expect(
      isRepeatedSmsNotification(message(0), message(24, sender: 'CP-HDFCBK-S')),
      isFalse,
    );
  });
}
