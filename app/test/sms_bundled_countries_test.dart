// Banks of many countries ship with the app: each country's own pack reads
// its messages, in the country's currency and number style.
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

Future<SmsTransactionCandidate?> _read(String sender, String body) async {
  final engine = await loadBundledSmsEngineFor(sender);
  expect(engine, isNotNull, reason: sender);
  return engine!
      .parse(
        BankSms(sender: sender, body: body, receivedAt: DateTime(2026, 11)),
      )
      .candidate;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('a UAE card purchase reads in dirhams', () async {
    final sms = await _read(
      'EmiratesNBD',
      'Purchase of AED 27.74 with Credit Card ending 9074 at Keeta, Dubai. '
          'Avl Cr. Limit is AED 30,978.13',
    );
    expect(sms!.amountMinor, 2774);
    expect(sms.currencyCode, 'AED');
    expect(sms.countryCode, 'AE');
    expect(sms.bankName, 'Emirates NBD');
  });

  test('a Nepal withdrawal reads in rupees', () async {
    final sms = await _read(
      'NABIL_ALERT',
      'Dear Customer, Your 091##04118 has been withdrawn by NPR 20,008.00 on '
          '17/04/2026 07:58:06, Remarks: MTXN0000517374-130',
    );
    expect(sms!.amountMinor, 2000800);
    expect(sms.countryCode, 'NP');
  });
}
