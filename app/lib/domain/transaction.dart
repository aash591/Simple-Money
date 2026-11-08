/// Named `MoneyTransaction`, not `Transaction` — a generic name that risks
/// colliding with an unrelated `Transaction` export from some package (the
/// same problem `Category` hit against `flutter/foundation.dart`).
library;

/// What a transaction does to account balances. A transfer moves money
/// between two accounts and is never counted as income or expense — see the
/// README's "core idea" for why categories and accounts stay separate.
enum TransactionType { expense, income, transfer }

extension TransactionTypeStorage on TransactionType {
  String get storageValue => switch (this) {
    TransactionType.expense => 'expense',
    TransactionType.income => 'income',
    TransactionType.transfer => 'transfer',
  };

  static TransactionType fromStorage(String value) => switch (value) {
    'income' => TransactionType.income,
    'transfer' => TransactionType.transfer,
    _ => TransactionType.expense,
  };
}

class MoneyTransaction {
  const MoneyTransaction({
    required this.id,
    required this.type,
    required this.amountMinor,
    required this.accountId,
    this.toAccountId,
    this.toAmountMinor,
    this.categoryId,
    this.title,
    this.note,
    required this.date,
    this.icon,
    this.badgeIcon,
    this.isCreditCard = false,
  });
  final int id;
  final TransactionType type;
  final bool isCreditCard;

  /// Always positive; direction is implied by [type].
  final int amountMinor;

  /// The account paid from (expense), deposited to (income), or the
  /// transfer's source account.
  final int accountId;

  /// The transfer's destination account. Null for expense/income.
  final int? toAccountId;

  /// What actually reached [toAccountId], when that is not [amountMinor] — a
  /// transfer across currencies, or one a charge was taken from. Null
  /// everywhere else; read it through [receivedMinor] rather than defaulting
  /// at each use.
  final int? toAmountMinor;

  /// The amount credited to the destination: [toAmountMinor] when one was
  /// recorded, otherwise the whole amount sent.
  int get receivedMinor => toAmountMinor ?? amountMinor;

  /// Null for transfers, which have no category by definition.
  final int? categoryId;
  final String? title;
  final String? note;
  final DateTime date;

  /// Artwork of the loan or subscription that recorded this, shown instead of
  /// the category's: what it paid for, with the lender (or a subscription
  /// mark) as [badgeIcon] when they differ.
  final String? icon, badgeIcon;
}
