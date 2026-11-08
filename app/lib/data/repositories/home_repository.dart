import 'package:drift/drift.dart';

import '../../domain/transaction.dart';
import '../../domain/currency_scope.dart';
import '../db/app_database.dart';
import 'ledger_scope.dart';
import 'transaction_repository.dart';

class HomeSummary {
  const HomeSummary({
    required this.income,
    required this.spent,
    required this.previousSpent,
    required this.dailyIncome,
    required this.dailyExpenses,
    required this.categories,
    required this.recent,
    this.missingCurrencies = const {},
  });
  final int income, spent, previousSpent;
  final Set<String> missingCurrencies;
  final List<int> dailyIncome, dailyExpenses;

  /// Spending per top-level category, biggest first. [icon] is the parent's
  /// icon key, null for uncategorized spending.
  final List<({String name, String? icon, int amount})> categories;
  final List<MoneyTransaction> recent;
}

/// Bounded, database-side aggregates. Transfers never count as spending/income.
class HomeRepository {
  HomeRepository(this.database);
  final AppDatabase database;

  Future<HomeSummary> load(DateTime month, String currency, int digits) =>
      loadScope(month, SingleCurrency(currency, digits));

  Future<HomeSummary> loadScope(DateTime month, CurrencyScope scope) =>
      database.transaction(() async {
        final conversion = CurrencyTotals(scope);
        int? amount(QueryRow row) => conversion.convert(
          row.read<int>('amount'),
          row.read<String>('currency'),
          row.read<int>('digits'),
        );
        final start = DateTime(month.year, month.month);
        final end = DateTime(month.year, month.month + 1);
        final previous = DateTime(month.year, month.month - 1);
        const source = ledgerSource;
        final filter = ledgerFilter(scope);
        List<Variable> args(DateTime from, DateTime to) =>
            ledgerArgs(scope, from, to);
        final daily = await database.customSelect(
          '''
      SELECT CAST(strftime('%d', t.date / 1000, 'unixepoch', 'localtime') AS INTEGER) AS day,
        t.type, a.currency, a.digits, SUM(t.amount_minor) AS amount
      $source WHERE $filter AND t.type IN ('expense', 'income')
      GROUP BY day, t.type, a.currency, a.digits''',
          variables: args(start, end),
        ).get();
        final income = List<int>.filled(
          DateTime(month.year, month.month + 1, 0).day,
          0,
        );
        final expenses = List<int>.filled(income.length, 0);
        for (final row in daily) {
          final values = row.read<String>('type') == 'income'
              ? income
              : expenses;
          final converted = amount(row);
          if (converted != null) values[row.read<int>('day') - 1] += converted;
        }
        final categories = await database.customSelect(
          '''
      SELECT COALESCE(p.id, c.id, 0) AS id, COALESCE(p.name, c.name, 'Uncategorized') AS name,
        COALESCE(p.icon, c.icon) AS icon, a.currency, a.digits, SUM(t.amount_minor) AS amount
      $source LEFT JOIN categories c ON c.id = t.category_id
      LEFT JOIN categories p ON p.id = c.parent_id
      WHERE $filter AND t.type = 'expense'
      GROUP BY COALESCE(p.id, c.id), a.currency, a.digits''',
          variables: args(start, end),
        ).get();
        final before = await database.customSelect(
          '''
      SELECT a.currency, a.digits, SUM(t.amount_minor) AS amount $source
      WHERE $filter AND t.type = 'expense' GROUP BY a.currency, a.digits''',
          variables: args(previous, start),
        ).get();
        var previousSpent = 0;
        for (final row in before) {
          final converted = amount(row);
          if (converted != null) previousSpent += converted;
        }
        final grouped = <int, ({String name, String? icon, int amount})>{};
        for (final row in categories) {
          final converted = amount(row);
          if (converted == null) continue;
          final id = row.read<int>('id');
          grouped[id] = (
            name: row.read<String>('name'),
            icon: row.readNullable<String>('icon'),
            amount: (grouped[id]?.amount ?? 0) + converted,
          );
        }
        final categoryTotals = grouped.values.toList()
          ..sort((a, b) {
            final order = b.amount.compareTo(a.amount);
            return order == 0 ? a.name.compareTo(b.name) : order;
          });
        return HomeSummary(
          income: income.fold(0, (a, b) => a + b),
          spent: expenses.fold(0, (a, b) => a + b),
          previousSpent: previousSpent,
          missingCurrencies: Set.unmodifiable(conversion.missing),
          dailyIncome: income,
          dailyExpenses: expenses,
          categories: categoryTotals,
          recent: await TransactionRepository(database).load(
            start: start,
            end: end,
            currency: scope is SingleCurrency ? scope.code : null,
            digits: scope is SingleCurrency ? scope.digits : null,
            limit: 5,
          ),
        );
      });
}
