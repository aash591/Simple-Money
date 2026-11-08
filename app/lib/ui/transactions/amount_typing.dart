import 'dart:math' as math;

import 'package:intl/intl.dart';

import '../../domain/account.dart';

/// The keypad's editing rules for a typed amount, kept as plain string
/// functions: one decimal point at most, no more decimal places than the
/// account's currency has, and at most [maxWholeDigits] before the point.
abstract final class AmountTyping {
  static const maxWholeDigits = 9;

  static String digit(String text, String digit, int decimals) {
    final point = text.indexOf('.');
    if (point >= 0) {
      return text.length - point - 1 < decimals ? '$text$digit' : text;
    }
    // "0" then "5" reads as 5, never "05".
    if (text == '0') return digit;
    return text.length < maxWholeDigits ? '$text$digit' : text;
  }

  static String point(String text, int decimals) {
    if (decimals == 0 || text.contains('.')) return text;
    return text.isEmpty ? '0.' : '$text.';
  }

  static String backspace(String text) =>
      text.isEmpty ? text : text.substring(0, text.length - 1);

  /// The text that would re-type [minor] units, for pre-filling an edit.
  static String fromMinor(int minor, int decimals) {
    if (decimals == 0) return '$minor';
    final scale = math.pow(10, decimals).toInt();
    final whole = minor ~/ scale;
    final fraction = minor % scale;
    if (fraction == 0) return '$whole';
    final digits = fraction
        .toString()
        .padLeft(decimals, '0')
        .replaceFirst(RegExp(r'0+$'), '');
    return '$whole.$digits';
  }

  /// How the typed amount reads on screen: "₹0.00" before anything is
  /// typed, then exactly what was typed with the whole part grouped, e.g.
  /// "₹1,250." or "₹1,250.5" mid-entry.
  static String display(
    String text, {
    required String currency,
    required int decimals,
    bool showCurrency = true,
  }) {
    final prefix = showCurrency ? currencyPrefix(currency) : '';
    if (text.isEmpty) {
      return decimals == 0 ? '${prefix}0' : '${prefix}0.${'0' * decimals}';
    }
    final point = text.indexOf('.');
    final whole = point < 0 ? text : text.substring(0, point);
    final grouped = NumberFormat.decimalPattern(
      currency == 'INR' ? 'en_IN' : 'en_US',
    ).format(int.parse(whole.isEmpty ? '0' : whole));
    return '$prefix$grouped${point < 0 ? '' : text.substring(point)}';
  }
}
