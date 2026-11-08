import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/number_keypad.dart';
import 'package:simple_money/ui/transactions/amount_calculator.dart';
import 'package:simple_money/ui/transactions/transaction_widgets.dart';

void main() {
  test('Live result preserves the operand and expression until committed', () {
    final calculator = AmountCalculator();
    var text = calculator.press('+', '100', 2);
    expect(calculator.resultFor(text, 2), '100');
    text = calculator.digit(text, '2', 2);
    expect(calculator.resultFor(text, 2), '102');
    text = calculator.digit(text, '5', 2);
    expect(calculator.resultFor(text, 2), '125');
    expect(calculator.expressionFor(text), '100 + 25');
    text = calculator.backspace(text, 2);
    expect(calculator.resultFor(text, 2), '102');
    expect(calculator.press('=', text, 2), '102');
    calculator.press('÷', '102', 2);
    text = calculator.digit('102', '7', 2);
    expect(calculator.resultFor(text, 2), '14.57');
    expect(calculator.error, isNull);
    expect(calculator.press('=', text, 2), '14.57');
  });
  test('Percent supports a following rate, decimals, deletion and equals', () {
    final calculator = AmountCalculator();
    var text = calculator.press('%', '4000', 2);
    expect(text, '40');
    expect(calculator.expressionFor(text), '4000 %');
    text = calculator.digit(text, '6', 2);
    expect(text, '240');
    expect(calculator.expressionFor(text), '4000 % 6');
    text = calculator.point(text, 2);
    text = calculator.digit(text, '5', 2);
    expect(text, '260');
    text = calculator.backspace(text, 2);
    expect(text, '240');
    text = calculator.press('=', text, 2);
    expect(text, '240');
    expect(calculator.expression, '4000 % 6. = 240');
    calculator.clear();
    text = calculator.press('%', '4000', 2);
    text = calculator.digit(text, '6', 2);
    text = calculator.backspace(text, 2);
    expect(text, '40');
    expect(calculator.backspace(text, 2), '4000');
  });

  test('History retains operands and includes the current entry', () {
    final calculator = AmountCalculator();
    calculator.press('+', '110', 2);
    expect(calculator.expression, '110 +');
    final next = calculator.digit('110', '5', 2);
    expect(calculator.expressionFor(next), '110 + 5');
    calculator.press('×', next, 2);
    expect(calculator.expression, '110 + 5 ×');
    final last = calculator.digit('115', '2', 2);
    calculator.press('=', last, 2);
    expect(calculator.expression, '110 + 5 × 2 = 230');
    calculator.digit('230', '7', 2);
    expect(calculator.expression, isNull);
  });

  testWidgets('Calculation history scrolls and returns to new input', (
    tester,
  ) async {
    final history = List.filled(30, '12345 +').join(' ');
    Future<void> pump(String text) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            height: 20,
            child: CalculationHistory(text: text),
          ),
        ),
      ),
    );
    await pump(history);
    final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
    expect(scrollable.position.maxScrollExtent, greaterThan(0));
    await tester.drag(find.byType(CalculationHistory), const Offset(100, 0));
    await tester.pumpAndSettle();
    expect(scrollable.position.pixels, greaterThan(0));
    await pump('$history 9');
    await tester.pump();
    expect(scrollable.position.pixels, 0);
    expect(tester.takeException(), isNull);
  });

  test('Chained arithmetic, percent, rounding and starting a new entry', () {
    final calculator = AmountCalculator();
    var text = '200';
    text = calculator.press('+', text, 2);
    text = calculator.digit(text, '1', 2);
    text = calculator.digit(text, '0', 2);
    text = calculator.press('%', text, 2);
    expect(text, '20');
    text = calculator.press('=', text, 2);
    expect(text, '220');
    text = calculator.press('×', text, 2);
    text = calculator.digit(text, '2', 2);
    text = calculator.press('−', text, 2);
    expect(text, '440');
    text = calculator.digit(text, '5', 2);
    text = calculator.press('=', text, 2);
    expect(text, '435');
    text = calculator.press('÷', text, 2);
    text = calculator.digit(text, '7', 2);
    expect(calculator.press('=', text, 2), '62.14');
    expect(calculator.digit('62.14', '9', 2), '9');
    expect(calculator.press('±', '9', 2), '-9');
    calculator.clear();
    expect(calculator.press('%', '50', 2), '0.5');
  });

  test('Errors preserve the input and allow correction', () {
    final calculator = AmountCalculator();
    calculator.press('÷', '10', 2);
    final zero = calculator.digit('10', '0', 2);
    expect(calculator.press('=', zero, 2), '0');
    expect(calculator.error, 'Cannot divide by zero');
    final two = calculator.digit('0', '2', 2);
    expect(calculator.press('=', two, 2), '5');
    calculator.clear();
    calculator.press('×', '999999999', 2);
    final operand = calculator.digit('999999999', '9', 2);
    calculator.press('=', operand, 2);
    expect(calculator.error, 'Amount is too large');
    calculator.clear();
    expect(calculator.operation, isNull);
    expect(calculator.error, isNull);
    calculator.press('÷', '10', 0);
    calculator.digit('10', '3', 0);
    expect(calculator.press('=', '3', 0), '3');
  });

  testWidgets('Calculator fits the existing keypad height at narrow widths', (
    tester,
  ) async {
    Future<void> pump({ValueChanged<String>? operation}) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 280,
              child: NumberKeypad(
                onDigit: (_) {},
                onDecimalPoint: () {},
                onBackspace: () {},
                onClear: () {},
                onOperation: operation,
              ),
            ),
          ),
        ),
      ),
    );
    await pump();
    final originalHeight = tester.getSize(find.byType(NumberKeypad)).height;
    await pump(operation: (_) {});
    expect(
      tester.getSize(find.byType(NumberKeypad)).height,
      lessThanOrEqualTo(originalHeight + 16),
    );
    for (final label in ['AC', '%', '÷', '×', '−', '+', '±', '=']) {
      expect(find.text(label), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });
}
