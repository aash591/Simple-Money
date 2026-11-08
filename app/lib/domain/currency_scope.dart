import 'convert_minor.dart';

/// Whether a summary selects one currency or combines all currencies.
sealed class CurrencyScope {
  const CurrencyScope(this.code, this.digits);
  final String code;
  final int digits;

  bool includes(String source, int precision) =>
      this is CombinedCurrency || (source == code && precision == digits);

  /// Whether amounts in [source] can be converted into this scope at all.
  /// Asking directly, rather than converting a zero and seeing whether null
  /// comes back: [convert] fails on the rate, never on the amount, but that
  /// is its contract's detail rather than something a caller should lean on.
  bool hasRateFor(String source) {
    if (source == code) return true;
    if (this is! CombinedCurrency) return false;
    final rate = (this as CombinedCurrency).rates[source];
    return rate != null && rate.isFinite && rate > 0;
  }

  int? convert(int amount, String source, int precision) {
    if (!includes(source, precision)) return null;
    if (source == code && precision == digits) return amount;
    return convertMinor(
      amount,
      fromDigits: precision,
      toDigits: digits,
      perMain: source == code ? 1 : (this as CombinedCurrency).rates[source],
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CurrencyScope &&
      other.runtimeType == runtimeType &&
      other.code == code &&
      other.digits == digits;
  @override
  int get hashCode => Object.hash(runtimeType, code, digits);
}

final class SingleCurrency extends CurrencyScope {
  const SingleCurrency(super.code, super.digits);
}

final class CombinedCurrency extends CurrencyScope {
  const CombinedCurrency(
    super.code,
    super.digits, {
    this.rates = const {},
    this.rateDate,
  });
  final Map<String, double> rates;
  final DateTime? rateDate;
}

/// Collects explicit omissions while folding converted aggregates.
class CurrencyTotals {
  CurrencyTotals(this.scope);
  final CurrencyScope scope;
  final Set<String> missing = {};
  int total = 0;

  int? convert(int amount, String code, int digits) {
    if (!scope.includes(code, digits)) return null;
    final converted = scope.convert(amount, code, digits);
    if (converted == null) missing.add(code);
    return converted;
  }

  void add(int amount, String code, int digits) {
    final value = convert(amount, code, digits);
    if (value != null) total += value;
  }
}
