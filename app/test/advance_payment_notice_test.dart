import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/advance_payment_notice.dart';

void main() {
  test('Only later calendar days require advance payment acknowledgment', () {
    final now = DateTime(2026, 12, 31, 12);
    expect(isFuturePayment(DateTime(2027, 1, 1), now: now), isTrue);
    expect(isFuturePayment(DateTime(2026, 12, 31, 23), now: now), isFalse);
    expect(isFuturePayment(DateTime(2026, 12, 30), now: now), isFalse);
  });
}
