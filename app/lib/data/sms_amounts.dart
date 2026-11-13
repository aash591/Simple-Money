/// How SMS rule amounts meet the app's. Rule packs count a currency in at
/// least two decimal places (its "rule exponent") so an SMS that shows cents
/// parses even where the app keeps whole units (COP 50.000,00, JPY 1,200.00).
/// The app's own decimal places come from its currency table; amounts are
/// converted once, when a message is queued.
///
/// Every bundled country pack, and every rule the app compiles, declares
/// exponents this way, so a candidate's amount always means the same thing.
library;

import 'dart:math' as math;

import '../domain/currency_digits.dart';

/// Decimal places a rule pack uses for [currency].
int smsRuleExponent(String currency) => math.max(currencyDigits(currency), 2);

/// [ruleMinor], read by a rule, in the app's minor units for [currency],
/// rounded half up (a ¥1,200.00 SMS is 1200).
int smsAmountToApp(int ruleMinor, String currency) {
  final drop = smsRuleExponent(currency) - currencyDigits(currency);
  if (drop <= 0) return ruleMinor;
  final factor = math.pow(10, drop).toInt();
  return (ruleMinor + factor ~/ 2) ~/ factor;
}

/// [ruleMinor] as a decimal string with the rule's decimal places.
String smsRuleAmountText(int ruleMinor, String currency) {
  final exponent = smsRuleExponent(currency);
  final factor = math.pow(10, exponent).toInt();
  final whole = ruleMinor ~/ factor;
  final fraction = (ruleMinor % factor).toString().padLeft(exponent, '0');
  return '$whole.$fraction';
}
