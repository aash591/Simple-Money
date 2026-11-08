import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/transactions/amount_typing.dart';

void main() {
  /// Types [keys] on the keypad: digits, '.' for the point, '<' for backspace.
  String type(String keys, {int decimals = 2}) {
    var text = '';
    for (final key in keys.split('')) {
      text = switch (key) {
        '.' => AmountTyping.point(text, decimals),
        '<' => AmountTyping.backspace(text),
        _ => AmountTyping.digit(text, key, decimals),
      };
    }
    return text;
  }

  test(
    'The keypad allows one point, the currency\'s decimals, and 9 whole digits',
    () {
      expect(type('05'), '5');
      expect(type('.5'), '0.5');
      expect(type('1.2.3'), '1.23');
      expect(type('1.234'), '1.23');
      expect(type('1234567890'), '123456789');
      expect(type('12.5', decimals: 0), '125');
      expect(type('12<'), '1');
      expect(type('<'), '');
    },
  );

  test('The typed amount displays grouped, with the currency prefix', () {
    expect(AmountTyping.display('', currency: 'INR', decimals: 2), '₹0.00');
    expect(
      AmountTyping.display('1234567.5', currency: 'INR', decimals: 2),
      '₹12,34,567.5',
    );
    expect(
      AmountTyping.display('1250.', currency: 'USD', decimals: 2),
      r'$1,250.',
    );
    expect(AmountTyping.display('', currency: 'JPY', decimals: 0), '¥0');
  });

  test('A saved amount converts back to the text that would type it', () {
    expect(AmountTyping.fromMinor(45000, 2), '450');
    expect(AmountTyping.fromMinor(45050, 2), '450.5');
    expect(AmountTyping.fromMinor(5, 2), '0.05');
    expect(AmountTyping.fromMinor(1200, 0), '1200');
  });
}
