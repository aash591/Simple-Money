/// Converts between two currencies that are both quoted against a third, using
/// the rates from one table: [perMainFrom] units of the source per unit of the
/// table's base, and [perMainTo] of the destination. Folded into a single
/// [convertMinor] so the figure is rounded once rather than at each hop.
///
/// Null when either rate is missing or unusable, which is the caller's cue to
/// ask for the amount instead of guessing it.
int? crossConvertMinor(
  int amount, {
  required int fromDigits,
  required int toDigits,
  required double? perMainFrom,
  required double? perMainTo,
}) {
  if (perMainFrom == null || perMainTo == null) return null;
  if (!perMainFrom.isFinite || !perMainTo.isFinite) return null;
  if (perMainFrom <= 0 || perMainTo <= 0) return null;
  return convertMinor(
    amount,
    fromDigits: fromDigits,
    toDigits: toDigits,
    perMain: perMainFrom / perMainTo,
  );
}

/// Converts source minor units using a main-to-source rate. Decimal arithmetic
/// avoids binary floating-point errors at half-unit rounding boundaries.
/// Ties round away from zero, including negative balances.
int? convertMinor(
  int amount, {
  required int fromDigits,
  required int toDigits,
  required double? perMain,
}) {
  if (perMain == null || !perMain.isFinite || perMain <= 0) return null;
  if (fromDigits < 0 || toDigits < 0 || fromDigits > 4 || toDigits > 4) {
    throw ArgumentError('Currency precision must be between 0 and 4.');
  }
  final parts = perMain.toString().toLowerCase().split('e');
  final mantissa = parts.first.split('.');
  final fraction = mantissa.length == 2 ? mantissa[1] : '';
  final exponent = parts.length == 2 ? int.parse(parts[1]) : 0;
  var rateNumerator = BigInt.parse('${mantissa[0]}$fraction');
  var rateDenominator = BigInt.one;
  final scale = fraction.length - exponent;
  if (scale >= 0) {
    rateDenominator = BigInt.from(10).pow(scale);
  } else {
    rateNumerator *= BigInt.from(10).pow(-scale);
  }
  final numerator =
      BigInt.from(amount).abs() *
      BigInt.from(10).pow(toDigits) *
      rateDenominator;
  final denominator = BigInt.from(10).pow(fromDigits) * rateNumerator;
  var rounded = numerator ~/ denominator;
  if ((numerator % denominator) * BigInt.two >= denominator) {
    rounded += BigInt.one;
  }
  if (amount < 0) rounded = -rounded;
  // Never silently clamp a result outside SQLite/Dart's signed 64-bit range.
  if (rounded > BigInt.parse('9223372036854775807') ||
      rounded < BigInt.parse('-9223372036854775808')) {
    return null;
  }
  return rounded.toInt();
}
