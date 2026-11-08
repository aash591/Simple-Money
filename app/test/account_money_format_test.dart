import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/domain/account.dart';

void main() {
  test('A negative amount keeps its sign ahead of the currency mark', () {
    // "₹-1,200" strands the minus between the symbol and the digits, where it
    // reads as part of the number rather than as the sign of the amount.
    expect(formatAccountMoney(-120000, digits: 2, currency: 'INR'), '-₹1,200');
    expect(formatAccountMoney(-5000, digits: 2, currency: 'USD'), r'-$50');
    expect(formatAccountMoney(-5000, digits: 2, currency: 'SAR'), '-SAR 50');
    expect(formatAccountMoney(-12345, digits: 2, currency: 'USD'), r'-$123.45');
  });

  test('Positive and zero amounts are unchanged', () {
    expect(formatAccountMoney(120000, digits: 2, currency: 'INR'), '₹1,200');
    expect(formatAccountMoney(0, digits: 2, currency: 'SAR'), 'SAR 0');
    expect(formatAccountMoney(12345, digits: 2, currency: 'USD'), r'$123.45');
  });

  test('Zero-decimal currencies round-trip through the sign change', () {
    expect(formatAccountMoney(-1200, digits: 0, currency: 'JPY'), '-¥1,200');
    expect(formatAccountMoney(1200, digits: 0, currency: 'JPY'), '¥1,200');
  });
}
