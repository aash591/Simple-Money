import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import 'category.dart';

/// One categorizer for every way a transaction arrives — an SMS (its engine
/// runs the same rules), a statement row, a scanned UPI QR: the payee's name
/// and whatever narration came with it, matched against the shared category
/// rules ("MINA MED" is Pharmacy, "STAR AUTO PARTS" Vehicle Maintenance,
/// "ATM WDL" an ATM withdrawal) and resolved to the user's own categories.
/// No merchant knowledge lives here: it is all in the rule pack.
class PartyCategorizer {
  const PartyCategorizer(this.rules);
  final PortableCategorizer rules;

  /// What the rules say [party] is; [detail] is a narration or UPI id beside
  /// it. Null when nothing more specific than a catch-all fits.
  SmsSuggestedCategory? suggest(
    String party, {
    required bool credit,
    String? detail,
  }) {
    if (party.trim().isEmpty && (detail ?? '').trim().isEmpty) return null;
    return rules.categorize(
      party,
      direction: credit ? SmsDirection.credit : SmsDirection.debit,
      detail: detail,
    );
  }

  /// The user's category for [party], or null when the rules have none or
  /// it names a category the user doesn't have. ATM movements are transfers
  /// to or from cash, never a category: see [isCashMovement].
  Category? category(
    String party,
    List<Category> categories, {
    required bool credit,
    String? detail,
  }) {
    final suggestion = suggest(party, credit: credit, detail: detail);
    if (suggestion == null || isCashMovement(suggestion)) return null;
    return resolveSuggestedCategory(suggestion, categories);
  }
}

/// Cash taken out of or paid into a bank account at an ATM: a transfer
/// between that account and cash in hand.
bool isCashMovement(SmsSuggestedCategory suggestion) =>
    suggestion.isAtmWithdrawal || suggestion.isAtmDeposit;

/// The user's category a suggestion names: by its name, then each alias in
/// turn ("Bakery", else "Cafe", else "Restaurants"), matched without regard
/// to case among categories of its type.
Category? resolveSuggestedCategory(
  SmsSuggestedCategory suggestion,
  List<Category> categories,
) {
  final type = suggestion.type == CategoryType.income.storageValue
      ? CategoryType.income
      : CategoryType.expense;
  for (final name in [suggestion.name, ...suggestion.aliases]) {
    final category = categories
        .where(
          (c) =>
              c.type == type &&
              c.name.trim().toLowerCase() == name.toLowerCase(),
        )
        .firstOrNull;
    if (category != null) return category;
  }
  return null;
}
