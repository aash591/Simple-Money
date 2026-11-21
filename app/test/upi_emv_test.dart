import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/upi_qr_image.dart';
import 'package:simple_money/domain/upi_payment.dart';

const emvQr =
    '0002010102120216413559000044086704165533870000440868061661005600004408660820IDIB000K14944672610526350010A00000052401172164811A@indianbk27530010A0000005240135MR63221729441791232164811A007451111520479915303356540548.005502015802IN5923DISTRICT TOURISM PROMOT6006KOLLAM610669100162340518MR632217294417912307082164811A630470C4';

void main() {
  test('reads a bank EMV merchant QR', () {
    final r = UpiRecipient.parse(emvQr);
    expect(r.address, '2164811A@indianbk');
    expect(r.amount, '48.00');
    expect(r.name, 'DISTRICT TOURISM PROMOT');
    expect(r.amountLocked, isTrue);
    expect(r.paymentUri('48'), emvQr);
    expect(() => r.paymentUri('50'), throwsFormatException);
  });

  test('rejects an EMV QR with a bad checksum', () {
    expect(
      () => UpiRecipient.parse(emvQr.replaceFirst('48.00', '49.00')),
      throwsFormatException,
    );
  });

  test('draft round trip and image generation keep the EMV QR', () async {
    final r = UpiRecipient.parse(emvQr);
    expect(UpiRecipient.parse(r.rawQr!).address, r.address);
    expect((await generateUpiQrPng(emvQr)).isNotEmpty, isTrue);
  });
}
