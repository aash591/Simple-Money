import 'package:flutter/foundation.dart';

import '../data/repositories/budget_repository.dart';
import '../domain/budget.dart';

/// Budgets are shown per month and currency, so screens load the month they
/// need through [loadMonth] and reload whenever this store notifies.
class BudgetStore extends ChangeNotifier {
  BudgetStore(this.repository);
  final BudgetRepository repository;
  bool saving = false;

  Future<BudgetMonth> loadMonth(DateTime month, String currency, int digits) =>
      repository.loadMonth(month, currency, digits);

  /// See [BudgetRepository.saveTotal].
  Future<int> saveTotal({
    required String currency,
    required int digits,
    required DateTime fromMonth,
    required int amountMinor,
  }) => _write(
    () => repository.saveTotal(
      currency: currency,
      digits: digits,
      fromMonth: fromMonth,
      amountMinor: amountMinor,
    ),
  );

  /// See [BudgetRepository.save].
  Future<int> save({
    int? budgetId,
    required Set<int> categoryIds,
    String? name,
    String? icon,
    required String currency,
    required int digits,
    required DateTime fromMonth,
    required int amountMinor,
  }) => _write(
    () => repository.save(
      budgetId: budgetId,
      categoryIds: categoryIds,
      name: name,
      icon: icon,
      currency: currency,
      digits: digits,
      fromMonth: fromMonth,
      amountMinor: amountMinor,
    ),
  );

  /// Makes screens reload after the ledger was replaced, e.g. by a restore.
  void reload() => notifyListeners();

  /// Ends [budgetId] from [fromMonth] on; earlier months keep it.
  Future<void> remove(int budgetId, DateTime fromMonth) =>
      _write(() => repository.remove(budgetId, fromMonth));

  Future<T> _write<T>(Future<T> Function() write) async {
    if (saving) throw StateError('A budget is already being saved.');
    saving = true;
    try {
      return await write();
    } finally {
      saving = false;
      notifyListeners();
    }
  }
}
