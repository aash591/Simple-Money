import 'dart:math' as math;

import 'package:intl/intl.dart';

import 'account_place.dart';

/// How the "Adjust balance" quick-action changes an account's balance.
/// Not logged as a transaction — it corrects the balance directly, the way
/// an opening balance does, rather than recording a categorized entry.
enum BalanceAdjustmentMode { setTo, add, subtract }

enum AccountType {
  bank('Bank account'),
  creditCard('Credit card'),
  cash('Cash');

  const AccountType(this.label);
  final String label;
}

class Account {
  const Account({
    required this.id,
    required this.name,
    required this.currency,
    this.territory,
    this.icon,
    required this.digits,
    required this.balanceMinor,
    this.transactionCount = 0,
    this.archivedAt,
    this.type = AccountType.bank,
    this.lastDigits,
    this.institution,
    this.creditLimitMinor,
    this.availableCreditLimitMinor,
    this.balanceReportedAt,
    this.hasDebitCard = false,
    this.isBroker = false,
    this.placeId,
  });
  final int id;

  /// An investment account (a broker or investing platform, so far): its
  /// balance is cash waiting to be invested, and the stocks and funds held
  /// there sit under it. It is only offered in transfers (deposits and
  /// withdrawals), never for spending.
  final bool isBroker;

  /// The place as stored, or null for an account saved before places existed.
  final String? placeId;

  /// Which kind of investment account this is, or null for a bank, card or
  /// cash account. See [AccountPlace] for how more kinds get added.
  AccountPlace? get place => isBroker ? AccountPlace.parse(placeId) : null;

  /// A debit card is paid from this account, or this account is one: the
  /// card icon is shown beside the account's kind.
  final bool hasDebitCard;
  final String name, currency;
  final AccountType type;
  final String? lastDigits, institution;
  final int? creditLimitMinor, availableCreditLimitMinor;
  final DateTime? balanceReportedAt;
  double? get creditUtilization =>
      creditLimitMinor == null ||
          creditLimitMinor! <= 0 ||
          availableCreditLimitMinor == null
      ? null
      : ((creditLimitMinor! - availableCreditLimitMinor!) / creditLimitMinor!)
            .clamp(0.0, 1.0);

  /// ISO 3166-1 alpha-2 code of the country this account's currency was
  /// picked for (e.g. 'IN' for INR chosen via India rather than Bhutan).
  /// Null for accounts saved before this was tracked.
  final String? territory;

  /// One of `appIconKeys`. Null for accounts saved before icons existed;
  /// resolve with `appIconAsset` rather than using this directly.
  final String? icon;
  final int digits, balanceMinor, transactionCount;

  /// When this account was archived, or null while it is active. An archived
  /// account is gone from every picker and from the balance totals, but its
  /// row stays: a transaction stores no currency of its own, so its past
  /// entries would have no way to be read without it.
  final DateTime? archivedAt;

  bool get isArchived => archivedAt != null;

  String get formattedBalance =>
      formatAccountAmount(balanceMinor, digits: digits, currency: currency);
}

/// Formats minor units the same way [Account.formattedBalance] does, for an
/// arbitrary amount (e.g. a transaction) rather than only an account's own
/// stored balance.
String formatAccountAmount(
  int minor, {
  required int digits,
  required String currency,
}) => NumberFormat.decimalPatternDigits(
  locale: currency == 'INR' ? 'en_IN' : 'en_US',
  decimalDigits: minor % math.pow(10, digits) == 0 ? 0 : digits,
).format(minor / math.pow(10, digits));

/// The short prefix shown before an amount: a symbol for the few currencies
/// with an unambiguous one, otherwise the ISO code and a space.
String currencyPrefix(String? currency) => switch (currency) {
  'USD' => r'$',
  'EUR' => '€',
  'GBP' => '£',
  'JPY' => '¥',
  'INR' || null => '₹',
  final code => '$code ',
};

/// [formatAccountAmount] with the currency's [currencyPrefix] in front,
/// e.g. "₹56,800" — for showing a single amount on its own. A negative amount
/// keeps its sign ahead of the prefix ("-₹1,200"), because a minus stranded
/// between the two ("₹-1,200") reads as part of the number rather than of it.
String formatAccountMoney(
  int minor, {
  required int digits,
  required String currency,
}) =>
    '${minor < 0 ? '-' : ''}${currencyPrefix(currency)}'
    '${formatAccountAmount(minor.abs(), digits: digits, currency: currency)}';

/// Parses decimal input directly to integer minor units, without floating point.
int? parseAccountAmount(String input, int digits) {
  final value = input.trim();
  if (value.isEmpty) return 0;
  final pattern = digits == 0
      ? r'^-?\d{1,10}$'
      : '^-?\\d{1,10}(\\.\\d{1,$digits})?\$';
  if (!RegExp(pattern).hasMatch(value)) return null;
  final negative = value.startsWith('-');
  final parts = value.replaceFirst('-', '').split('.');
  final scale = math.pow(10, digits).toInt();
  final amount =
      int.parse(parts[0]) * scale +
      (parts.length > 1 ? int.parse(parts[1].padRight(digits, '0')) : 0);
  return negative ? -amount : amount;
}

/// Relabels an amount while preserving its numeric value; never converts FX.
/// Refuses a precision change that would silently round away money.
int? relabelAmount(int amount, int oldDigits, int newDigits) {
  if (newDigits >= oldDigits) {
    return amount * math.pow(10, newDigits - oldDigits).toInt();
  }
  final divisor = math.pow(10, oldDigits - newDigits).toInt();
  return amount % divisor == 0 ? amount ~/ divisor : null;
}
