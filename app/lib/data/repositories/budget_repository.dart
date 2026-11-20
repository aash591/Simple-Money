import 'package:drift/drift.dart';

import '../../domain/budget.dart';
import '../db/app_database.dart';

/// A budget is either the total — every expense counts toward it — or one
/// over a set of expense categories or subcategories: one, or several
/// combined into a custom budget. No category is in two budgets at once, so
/// the budgets never count the same spending twice.
///
/// Amounts carry forward: a `budget_amounts` row applies from its
/// `start_month` until a later row for the same budget replaces it, and a
/// null amount ends the budget from that month on, so earlier months still
/// show what was set back then. Like Home, only expenses count; transfers
/// never do.
class BudgetRepository {
  BudgetRepository(this.database);
  final AppDatabase database;

  Future<BudgetMonth> loadMonth(
    DateTime month,
    String currency,
    int digits,
  ) => database.transaction(() async {
    final scope = [Variable(currency), Variable(digits)];
    final budgets = await database
        .customSelect(
          '''
      SELECT b.id, b.kind, b.name, b.icon, a.amount_minor FROM budgets b
      JOIN budget_amounts a ON a.budget_id = b.id
      WHERE b.currency = ? AND b.digits = ? AND a.amount_minor IS NOT NULL
        AND a.start_month = (
          SELECT MAX(l.start_month) FROM budget_amounts l
          WHERE l.budget_id = b.id AND l.start_month <= ?)
      ORDER BY b.id''',
          variables: [...scope, Variable(budgetMonthKey(month))],
        )
        .get();
    final members = await database.customSelect('''
      SELECT bc.budget_id, bc.category_id FROM budget_categories bc
      JOIN budgets b ON b.id = bc.budget_id
      JOIN categories c ON c.id = bc.category_id
      WHERE b.currency = ? AND b.digits = ?
        AND c.type = 'expense'
      ORDER BY c.sort_order, c.id''', variables: scope).get();
    // Keep direct spending separate so a child can have its own budget.
    final spending = await database
        .customSelect(
          '''
      SELECT c.id AS category_id, c.parent_id, SUM(t.amount_minor) AS amount
      FROM transactions t JOIN accounts a ON a.id = t.account_id
      LEFT JOIN categories c ON c.id = t.category_id
      WHERE t.type = 'expense' AND (c.type IS NULL OR c.type <> 'debt_loan')
        AND t.date >= ? AND t.date < ?
        AND a.currency = ? AND a.digits = ?
      GROUP BY c.id, c.parent_id''',
          variables: [
            Variable(DateTime(month.year, month.month).millisecondsSinceEpoch),
            Variable(
              DateTime(month.year, month.month + 1).millisecondsSinceEpoch,
            ),
            ...scope,
          ],
        )
        .get();
    final spent = <int?, int>{
      for (final row in spending)
        row.readNullable<int>('category_id'): row.read<int>('amount'),
    };
    final categoriesOf = <int, List<int>>{};
    for (final row in members) {
      categoriesOf
          .putIfAbsent(row.read<int>('budget_id'), () => [])
          .add(row.read<int>('category_id'));
    }
    // Budgets follow the category list, by the first category each covers.
    final position = <int, int>{};
    for (final (i, row) in members.indexed) {
      position.putIfAbsent(row.read<int>('budget_id'), () => i);
    }
    BudgetLine? allSpending;
    final lines = <BudgetLine>[];
    for (final row in budgets) {
      final id = row.read<int>('id');
      final limit = row.read<int>('amount_minor');
      if (row.read<String>('kind') == 'total') {
        allSpending = BudgetLine(
          id: id,
          limit: limit,
          spent: spent.values.fold(0, (sum, amount) => sum + amount),
        );
        continue;
      }
      final categoryIds = categoriesOf[id];
      // Every category it covered has been deleted.
      if (categoryIds == null) continue;
      lines.add(
        BudgetLine(
          id: id,
          name: row.readNullable<String>('name'),
          icon: row.readNullable<String>('icon'),
          categoryIds: categoryIds,
          limit: limit,
          spent: spending
              .where(
                (entry) =>
                    categoryIds.contains(
                      entry.readNullable<int>('category_id'),
                    ) ||
                    categoryIds.contains(entry.readNullable<int>('parent_id')),
              )
              .fold(0, (sum, entry) => sum + entry.read<int>('amount')),
        ),
      );
    }
    lines.sort((a, b) => position[a.id]!.compareTo(position[b.id]!));
    return BudgetMonth(allSpending: allSpending, budgets: lines);
  });

  /// Sets the total monthly budget to [amountMinor] from [fromMonth]
  /// onward, replacing any later changes to it. Returns its id.
  Future<int> saveTotal({
    required String currency,
    required int digits,
    required DateTime fromMonth,
    required int amountMinor,
  }) {
    _checkAmount(amountMinor);
    return database.transaction(() async {
      final existing = await database
          .customSelect(
            "SELECT id FROM budgets WHERE kind = 'total' "
            'AND currency = ? AND digits = ?',
            variables: [Variable(currency), Variable(digits)],
          )
          .getSingleOrNull();
      final id =
          existing?.read<int>('id') ??
          await database.customInsert(
            "INSERT INTO budgets (id, kind, currency, digits) VALUES (${newRowId('budgets')}, 'total', ?, ?)",
            variables: [Variable(currency), Variable(digits)],
          );
      await _setAmount(id, fromMonth, amountMinor);
      return id;
    });
  }

  /// Sets a budget over [categoryIds] — one expense category/subcategory, or
  /// several combined into a custom budget called [name] (null to name it
  /// after them) — to [amountMinor] from [fromMonth] onward, replacing any
  /// later changes to it.
  ///
  /// [budgetId] is the budget being edited, if any. Changing which
  /// categories it covers, or its name, leaves earlier months as they were:
  /// the old budget ends at [fromMonth] and a new one takes over. [icon] is
  /// only how it looks, so it changes in place. Returns the id of the
  /// budget that applies from [fromMonth].
  Future<int> save({
    int? budgetId,
    required Set<int> categoryIds,
    String? name,
    String? icon,
    required String currency,
    required int digits,
    required DateTime fromMonth,
    required int amountMinor,
  }) {
    _checkAmount(amountMinor);
    if (categoryIds.isEmpty) {
      throw ArgumentError('Choose at least one category.');
    }
    final trimmed = categoryIds.length > 1 ? name?.trim() : null;
    final budgetName = trimmed == null || trimmed.isEmpty ? null : trimmed;
    if (budgetName != null && budgetName.length > 40) {
      throw ArgumentError('Use a name of up to 40 characters.');
    }
    final ids = categoryIds.toList();
    final idList = List.filled(ids.length, '?').join(', ');
    final idArgs = [for (final id in ids) Variable(id)];
    final key = budgetMonthKey(fromMonth);
    return database.transaction(() async {
      final categories = await database.customSelect(
        '''SELECT id, name FROM categories WHERE id IN ($idList)
        AND type = 'expense' ''',
        variables: idArgs,
      ).get();
      if (categories.length != ids.length) {
        throw ArgumentError('Choose expense categories.');
      }
      // Taken: covered by another budget in effect at or after fromMonth.
      final taken = await database
          .customSelect(
            '''
        SELECT bc.category_id FROM budget_categories bc
        JOIN budgets b ON b.id = bc.budget_id
        WHERE b.kind = 'categories' AND b.currency = ? AND b.digits = ?
          AND b.id IS NOT ? AND EXISTS (
            SELECT 1 FROM categories chosen
            JOIN categories covered ON covered.id = bc.category_id
            WHERE chosen.id IN ($idList) AND (
              chosen.id = covered.id OR chosen.parent_id = covered.id
              OR covered.parent_id = chosen.id))
          AND (EXISTS (
              SELECT 1 FROM budget_amounts a WHERE a.budget_id = b.id
              AND a.start_month > ? AND a.amount_minor IS NOT NULL)
            OR (SELECT a.amount_minor FROM budget_amounts a
              WHERE a.budget_id = b.id AND a.start_month <= ?
              ORDER BY a.start_month DESC LIMIT 1) IS NOT NULL)
        LIMIT 1''',
            variables: [
              Variable(currency),
              Variable(digits),
              Variable(budgetId),
              ...idArgs,
              Variable(key),
              Variable(key),
            ],
          )
          .getSingleOrNull();
      if (taken != null) {
        throw ArgumentError(
          'A selected category is already in another budget.',
        );
      }

      var id = budgetId;
      if (id != null && !await _covers(id, categoryIds, budgetName)) {
        final startedEarlier = await database
            .customSelect(
              'SELECT 1 FROM budget_amounts '
              'WHERE budget_id = ? AND start_month < ? LIMIT 1',
              variables: [Variable(id), Variable(key)],
            )
            .getSingleOrNull();
        if (startedEarlier != null) {
          await _setAmount(id, fromMonth, null);
          id = null;
        } else {
          // Nothing earlier to keep, so it changes in place.
          await database.customUpdate(
            'UPDATE budgets SET name = ? WHERE id = ?',
            variables: [Variable(budgetName), Variable(id)],
          );
          await database.customUpdate(
            'DELETE FROM budget_categories WHERE budget_id = ?',
            variables: [Variable(id)],
          );
          await _addCategories(id, ids);
        }
      }
      if (id == null) {
        id = await database.customInsert(
          '''INSERT INTO budgets (id, kind, name, icon, currency, digits)
          VALUES (${newRowId('budgets')}, 'categories', ?, ?, ?, ?)''',
          variables: [
            Variable(budgetName),
            Variable(icon),
            Variable(currency),
            Variable(digits),
          ],
        );
        await _addCategories(id, ids);
      } else {
        await database.customUpdate(
          'UPDATE budgets SET icon = ? WHERE id = ? AND icon IS NOT ?',
          variables: [Variable(icon), Variable(id), Variable(icon)],
        );
      }
      await _setAmount(id, fromMonth, amountMinor);
      return id;
    });
  }

  /// Ends [budgetId] from [fromMonth] on; earlier months keep it.
  Future<void> remove(int budgetId, DateTime fromMonth) =>
      database.transaction(() => _setAmount(budgetId, fromMonth, null));

  void _checkAmount(int amountMinor) {
    if (amountMinor <= 0) {
      throw ArgumentError('Enter an amount greater than zero.');
    }
  }

  /// Whether [budgetId] already covers exactly [categoryIds] under [name].
  Future<bool> _covers(int budgetId, Set<int> categoryIds, String? name) async {
    final budget = await database
        .customSelect(
          "SELECT name FROM budgets WHERE id = ? AND kind = 'categories'",
          variables: [Variable(budgetId)],
        )
        .getSingleOrNull();
    if (budget == null) throw StateError('Budget $budgetId does not exist.');
    final covered = await database
        .customSelect(
          'SELECT category_id FROM budget_categories WHERE budget_id = ?',
          variables: [Variable(budgetId)],
        )
        .get();
    return budget.readNullable<String>('name') == name &&
        covered.length == categoryIds.length &&
        covered.every(
          (row) => categoryIds.contains(row.read<int>('category_id')),
        );
  }

  Future<void> _addCategories(int budgetId, List<int> categoryIds) async {
    for (final categoryId in categoryIds) {
      await database.customInsert(
        'INSERT INTO budget_categories (budget_id, category_id) VALUES (?, ?)',
        variables: [Variable(budgetId), Variable(categoryId)],
      );
    }
  }

  /// Sets [budgetId]'s amount from [fromMonth] on, dropping later changes;
  /// null ends it. A budget left with no amount in any month is deleted.
  Future<void> _setAmount(
    int budgetId,
    DateTime fromMonth,
    int? amountMinor,
  ) async {
    final key = budgetMonthKey(fromMonth);
    await database.customUpdate(
      'DELETE FROM budget_amounts WHERE budget_id = ? AND start_month >= ?',
      variables: [Variable(budgetId), Variable(key)],
    );
    final earlier = await database
        .customSelect(
          'SELECT amount_minor FROM budget_amounts WHERE budget_id = ? '
          'ORDER BY start_month DESC LIMIT 1',
          variables: [Variable(budgetId)],
        )
        .getSingleOrNull();
    if (earlier == null && amountMinor == null) {
      await database.customUpdate(
        'DELETE FROM budget_categories WHERE budget_id = ?',
        variables: [Variable(budgetId)],
      );
      await database.customUpdate(
        'DELETE FROM budgets WHERE id = ?',
        variables: [Variable(budgetId)],
      );
      return;
    }
    // Earlier months already carry this amount (or no budget) forward.
    if (earlier?.readNullable<int>('amount_minor') == amountMinor) return;
    await database.customInsert(
      '''INSERT INTO budget_amounts (budget_id, start_month, amount_minor)
      VALUES (?, ?, ?)''',
      variables: [Variable(budgetId), Variable(key), Variable(amountMinor)],
    );
  }
}
