/// What a category groups: an expense, income, or debt/loan movement. Never
/// tied to an account — see the README's "core idea" for why.
enum CategoryType { expense, income, debtLoan }

extension CategoryTypeStorage on CategoryType {
  /// The value persisted in the `categories.type` column.
  String get storageValue => switch (this) {
    CategoryType.expense => 'expense',
    CategoryType.income => 'income',
    CategoryType.debtLoan => 'debt_loan',
  };

  String get label => switch (this) {
    CategoryType.expense => 'Expense',
    CategoryType.income => 'Income',
    CategoryType.debtLoan => 'Debt/Loan',
  };

  static CategoryType fromStorage(String value) => switch (value) {
    'income' => CategoryType.income,
    'debt_loan' => CategoryType.debtLoan,
    _ => CategoryType.expense,
  };
}

class Category {
  const Category({
    required this.id,
    required this.name,
    required this.type,
    this.icon,
    this.parentId,
  });
  final int id;
  final String name;
  final CategoryType type;

  /// Debt and loan movements shift balances but are neither income nor
  /// spending, so totals, budgets and insights all leave them out.
  bool get isDebtLoan => type == CategoryType.debtLoan;

  /// One of `appIconKeys`. Null for categories saved before icons existed;
  /// resolve with `appIconAsset` rather than using this directly.
  final String? icon;

  /// The parent category's id, or null for a top-level category. Only
  /// top-level categories may be chosen as a parent, so nesting is one
  /// level deep.
  final int? parentId;
}

/// Display each parent immediately followed by its children, regardless of
/// insertion order (including temporary SMS suggestions).
List<Category> categoriesInDisplayOrder(Iterable<Category> categories) {
  final rows = categories.toList();
  return [
    for (final parent in rows.where((c) => c.parentId == null)) ...[
      parent,
      ...rows.where((c) => c.parentId == parent.id),
    ],
  ];
}
