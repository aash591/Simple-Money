/// The key a budget amount's starting month is stored under, e.g. 202603
/// for March 2026 — ordered, so "the latest change on or before a month" is
/// a plain comparison.
int budgetMonthKey(DateTime month) => month.year * 100 + month.month;

/// One budget's monthly limit and what was spent against it, both in the
/// currency's minor units.
class BudgetLine {
  const BudgetLine({
    this.id,
    this.name,
    this.icon,
    this.categoryIds = const [],
    required this.limit,
    required this.spent,
  });

  /// The saved budget; null for a total that only adds up the others.
  final int? id;

  /// A custom budget's own name, or null to name it after its categories.
  final String? name;

  /// A picked icon key (see domain/app_icons.dart), or null to show its
  /// categories'.
  final String? icon;

  /// The top-level expense categories it covers, in the category list's
  /// order: one for a category budget, several for a custom budget, none
  /// for the total.
  final List<int> categoryIds;
  final int limit, spent;

  bool get isCustom => categoryIds.length > 1;

  /// Negative once spending passes the limit.
  int get left => limit - spent;
  bool get isOver => spent > limit;
  double get fraction => limit <= 0 ? 0 : spent / limit;
  int get percentUsed => (fraction * 100).round();
}

/// Every budget in effect for one month and currency.
class BudgetMonth {
  const BudgetMonth({this.allSpending, required this.budgets});

  /// The total monthly budget, which every expense counts toward.
  final BudgetLine? allSpending;

  /// Category and custom budgets, ordered by their first category in the
  /// category list. No category is in more than one.
  final List<BudgetLine> budgets;

  bool get isEmpty => allSpending == null && budgets.isEmpty;

  /// Without a total budget of its own, the total is the other budgets
  /// added together — counting only the spending in their categories.
  bool get totalIsDerived => allSpending == null;

  BudgetLine? get total {
    if (allSpending != null) return allSpending;
    if (budgets.isEmpty) return null;
    return BudgetLine(
      limit: budgets.fold(0, (sum, line) => sum + line.limit),
      spent: budgets.fold(0, (sum, line) => sum + line.spent),
    );
  }

  /// The budget that covers [categoryId] this month, if any.
  BudgetLine? budgetCovering(int categoryId) => budgets
      .where((line) => line.categoryIds.contains(categoryId))
      .firstOrNull;
}
