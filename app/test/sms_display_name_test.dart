import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/realtime_sms.dart';

void main() {
  test('smsDisplayName tidies counterparties for notifications', () {
    expect(smsDisplayName('NIZAR AHAMMED KUNJU'), 'Nizar Ahammed Kunju');
    expect(smsDisplayName('KFC'), 'KFC');
    expect(
      smsDisplayName('Sri.lakshmi.venkateswara.supermarket'),
      'Sri Lakshmi Venkateswara Supermarket',
    );
    expect(smsDisplayName('swiggy@icici'), 'Swiggy');
    expect(smsDisplayName('VPA ashique@okicici'), 'Ashique');
    expect(
      smsDisplayName('SWIGGY INSTAMART PRIVATE LIMITED'),
      'Swiggy Instamart',
    );
    expect(smsDisplayName('Amazon Pay 629912345678'), 'Amazon Pay');
    expect(smsDisplayName(null), '');
  });
}
