import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/number_keypad.dart';

void main() {
  testWidgets('quick keypad taps softly shrink and return without overshoot', (
    tester,
  ) async {
    var digits = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NumberKeypad(
            onDigit: (digit) => digits += digit,
            onDecimalPoint: () {},
            onBackspace: () {},
          ),
        ),
      ),
    );
    final key = find.text('1');
    double scale() => tester
        .widget<Transform>(
          find.ancestor(of: key, matching: find.byType(Transform)).first,
        )
        .transform
        .entry(0, 0);

    await tester.tap(key);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(digits, '1');
    expect(scale(), closeTo(.95, .001));
    var previousScale = scale();
    for (var frame = 0; frame < 25; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
      expect(scale(), inInclusiveRange(.95, 1.0));
      expect(scale(), greaterThanOrEqualTo(previousScale - .000001));
      previousScale = scale();
    }
    await tester.pumpAndSettle();
    expect(scale(), 1);
  });
}
