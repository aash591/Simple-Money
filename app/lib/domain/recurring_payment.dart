import 'dart:math' as math;

enum BillingCycle { weekly, monthly, quarterly, yearly }

extension BillingCycleLabels on BillingCycle {
  String get label => switch (this) {
    BillingCycle.weekly => 'Weekly',
    BillingCycle.monthly => 'Monthly',
    BillingCycle.quarterly => 'Every 3 months',
    BillingCycle.yearly => 'Yearly',
  };

  /// "₹649/month".
  String get per => switch (this) {
    BillingCycle.weekly => 'week',
    BillingCycle.monthly => 'month',
    BillingCycle.quarterly => '3 months',
    BillingCycle.yearly => 'year',
  };

  static BillingCycle fromStorage(String value) =>
      BillingCycle.values.firstWhere(
        (cycle) => cycle.name == value,
        orElse: () => BillingCycle.monthly,
      );

  /// The renewal after [due]. Month-based cycles keep to [day], so a
  /// recurring payment started on the 31st renews on the last day of shorter
  /// months and returns to the 31st afterwards.
  DateTime after(DateTime due, int day) => switch (this) {
    BillingCycle.weekly => DateTime(due.year, due.month, due.day + 7),
    BillingCycle.monthly => addMonths(due, 1, day),
    BillingCycle.quarterly => addMonths(due, 3, day),
    BillingCycle.yearly => addMonths(due, 12, day),
  };

  /// [amount] spread over an average month.
  int monthly(int amount) => switch (this) {
    BillingCycle.weekly => (amount * 52 / 12).round(),
    BillingCycle.monthly => amount,
    BillingCycle.quarterly => (amount / 3).round(),
    BillingCycle.yearly => (amount / 12).round(),
  };

  /// [amount] over a whole year.
  int yearly(int amount) => switch (this) {
    BillingCycle.weekly => amount * 52,
    BillingCycle.monthly => amount * 12,
    BillingCycle.quarterly => amount * 4,
    BillingCycle.yearly => amount,
  };
}

DateTime addMonths(DateTime date, int months, int day) {
  final lastDay = DateTime(date.year, date.month + months + 1, 0).day;
  return DateTime(date.year, date.month + months, math.min(day, lastDay));
}

DateTime dateOnly(DateTime date) => DateTime(date.year, date.month, date.day);

String dateToStorage(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

DateTime dateFromStorage(String value) {
  final parts = value.split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}

class RecurringPayment {
  const RecurringPayment({
    required this.id,
    required this.name,
    required this.icon,
    required this.amountMinor,
    required this.currency,
    required this.digits,
    required this.cycle,
    required this.nextDue,
    required this.day,
    required this.accountId,
    required this.categoryId,
    required this.remind,
    required this.paused,
    this.incoming = false,
  });
  final int id;
  final String name;
  final String? icon;
  final int amountMinor, digits;
  final String currency;
  final BillingCycle cycle;
  final DateTime nextDue;

  /// The day of the month it renews on, which [nextDue] can fall short of in
  /// a shorter month.
  final int day;

  /// Null once the account it's paid from has been deleted.
  final int? accountId;
  final int? categoryId;
  final bool remind, paused;

  /// Money coming in, such as rent received, rather than going out.
  final bool incoming;

  int get monthlyAmount => cycle.monthly(amountMinor);
  int get yearlyAmount => cycle.yearly(amountMinor);
  DateTime get followingDue => cycle.after(nextDue, day);
}

/// What the add/edit sheet saves. Currency and precision come from the
/// account at save time.
class RecurringPaymentDraft {
  const RecurringPaymentDraft({
    required this.name,
    required this.icon,
    required this.amountMinor,
    required this.cycle,
    required this.nextDue,
    required this.accountId,
    required this.categoryId,
    required this.remind,
    this.incoming = false,
  });
  final String name;
  final String? icon;
  final int amountMinor;
  final BillingCycle cycle;
  final DateTime nextDue;
  final int accountId;
  final int? categoryId;
  final bool remind;

  /// Whether it is money coming in rather than going out.
  final bool incoming;

  void validate() {
    final length = name.trim().length;
    if (length < 1 || length > 40) {
      throw ArgumentError('Give the recurring payment a name.');
    }
    if (amountMinor <= 0) throw ArgumentError('Enter an amount above zero.');
  }
}

/// One renewal that was actually paid, linked to the expense it logged.
class RecurringPaymentRecord {
  const RecurringPaymentRecord({
    required this.transactionId,
    required this.amountMinor,
    required this.date,
    required this.account,
  });
  final int transactionId, amountMinor;
  final DateTime date;

  /// Null once the account it was paid from has been deleted.
  final String? account;
}
