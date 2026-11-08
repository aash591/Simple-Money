import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/domain/convert_minor.dart';
import 'package:simple_money/domain/currency_scope.dart';

void main() {
  test('inverts main-to-source rates across currency precisions', () {
    // One JPY = 0.5 INR; 100 INR = 200 JPY.
    expect(convertMinor(10000, fromDigits: 2, toDigits: 0, perMain: .5), 200);
    // One KWD = 3.25 USD; 3.25 USD = 1.000 KWD.
    expect(convertMinor(325, fromDigits: 2, toDigits: 3, perMain: 3.25), 1000);
    expect(
      convertMinor(-325, fromDigits: 2, toDigits: 3, perMain: 3.25),
      -1000,
    );
    expect(convertMinor(0, fromDigits: 2, toDigits: 2, perMain: .0125), 0);
  });
  test('rounds exact decimal half units once, away from zero', () {
    expect(convertMinor(201, fromDigits: 0, toDigits: 2, perMain: 200), 101);
    expect(convertMinor(-201, fromDigits: 0, toDigits: 2, perMain: 200), -101);
    expect(convertMinor(2009, fromDigits: 1, toDigits: 2, perMain: 200), 100);
    expect(
      convertMinor(1, fromDigits: 2, toDigits: 2, perMain: 1e-7),
      10000000,
    );
  });
  test('identity does not round-trip through floating point', () {
    const scope = CombinedCurrency('JPY', 0);
    expect(scope.convert(9007199254740993, 'JPY', 0), 9007199254740993);
    expect(scope.convert(-9007199254740993, 'JPY', 0), -9007199254740993);
    expect(scope.convert(1, 'USD', 2), isNull);
  });
  test('missing and invalid rates stay missing, never become zero', () {
    for (final rate in [null, 0.0, -1.0, double.nan, double.infinity]) {
      expect(
        convertMinor(100, fromDigits: 2, toDigits: 2, perMain: rate),
        isNull,
      );
    }
    final total = CurrencyTotals(const CombinedCurrency('INR', 2));
    total.add(100, 'INR', 2);
    total.add(100, 'USD', 2);
    expect(total.total, 100);
    expect(total.missing, {'USD'});
    expect(const SingleCurrency('INR', 2).convert(100, 'USD', 2), isNull);
  });
}
