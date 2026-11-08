import 'dart:math' as math;

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import '../../domain/currency_scope.dart';
import 'ledger_scope.dart';

/// One month's money in and out.
typedef MonthFlow = ({DateTime month, int income, int spent});

/// A top-level category's spending this month against its usual.
typedef CategoryChange = ({
  String name,
  String? icon,
  int current,
  int average,
});

/// What Home's trend charts plot, beyond the month's own summary.
class HomeInsights {
  const HomeInsights({
    required this.previousDailyExpenses,
    required this.flows,
    required this.categoryChanges,
    required this.comparedMonths,
    required this.balances,
    this.missingCurrencies = const {},
  });

  /// Spending per day of the month before, for pacing this one against it.
  final List<int> previousDailyExpenses;

  /// Six months ending with the one shown, oldest first.
  final List<MonthFlow> flows;

  /// Every category spent in this month or the ones compared, biggest change
  /// first.
  final List<CategoryChange> categoryChanges;

  /// How many earlier months had any spending to average over (0–3).
  final int comparedMonths;

  /// Accounts' combined balance at the end of each month in [flows].
  final List<int> balances;
  final Set<String> missingCurrencies;
}

/// Trend aggregates for Home's charts. Like [HomeRepository], transfers and
/// debt/loan movements are never counted as income or spending.
class InsightsRepository {
  InsightsRepository(this.database);
  final AppDatabase database;

  static const months = 6;
  static const _compared = 3;
  static const _source = ledgerSource;

  Future<HomeInsights> load(
    DateTime month,
    String currency,
    int digits, {
    DateTime? now,
  }) => loadScope(month, SingleCurrency(currency, digits), now: now);

  Future<HomeInsights> loadScope(
    DateTime month,
    CurrencyScope scope, {
    DateTime? now,
  }) => database.transaction(() async {
    final conversion = CurrencyTotals(scope);
    int? amount(QueryRow row) => conversion.convert(
      row.read<int>('amount'),
      row.read<String>('currency'),
      row.read<int>('digits'),
    );
    final filter = ledgerFilter(scope);
    final today = now ?? DateTime.now();
    List<Variable> args(DateTime from, DateTime to) =>
        ledgerArgs(scope, from, to);

    final previous = DateTime(month.year, month.month - 1);
    final start = DateTime(month.year, month.month);
    final daily = await database.customSelect(
      '''
      SELECT CAST(strftime('%d', t.date / 1000, 'unixepoch', 'localtime') AS INTEGER) AS day,
        a.currency, a.digits, SUM(t.amount_minor) AS amount
      $_source WHERE $filter AND t.type = 'expense' GROUP BY day, a.currency, a.digits''',
      variables: args(previous, start),
    ).get();
    final previousDaily = List<int>.filled(
      DateTime(previous.year, previous.month + 1, 0).day,
      0,
    );
    for (final row in daily) {
      final converted = amount(row);
      if (converted != null) {
        previousDaily[row.read<int>('day') - 1] += converted;
      }
    }

    final first = DateTime(month.year, month.month - months + 1);
    final end = DateTime(month.year, month.month + 1);
    final monthly = await database.customSelect(
      '''
      SELECT strftime('%Y-%m', t.date / 1000, 'unixepoch', 'localtime') AS ym,
        t.type, a.currency, a.digits, SUM(t.amount_minor) AS amount
      $_source WHERE $filter AND t.type IN ('expense', 'income')
      GROUP BY ym, t.type, a.currency, a.digits''',
      variables: args(first, end),
    ).get();
    final totals = <String, ({int income, int spent})>{};
    for (final row in monthly) {
      final key = row.read<String>('ym');
      final converted = amount(row);
      if (converted == null) continue;
      final was = totals[key] ?? (income: 0, spent: 0);
      totals[key] = row.read<String>('type') == 'income'
          ? (income: was.income + converted, spent: was.spent)
          : (income: was.income, spent: was.spent + converted);
    }
    final flows = [
      for (var i = 0; i < months; i++)
        () {
          final m = DateTime(first.year, first.month + i);
          final total =
              totals['${m.year}-${m.month.toString().padLeft(2, '0')}'];
          return (
            month: m,
            income: total?.income ?? 0,
            spent: total?.spent ?? 0,
          );
        }(),
    ];

    // While a month is still running, compare it with the same stretch of
    // the months before — the 1st to today — not with their whole length.
    final running = start.year == today.year && start.month == today.month;
    Future<List<QueryRow>> byCategory(DateTime from, DateTime to) =>
        database.customSelect(
          '''
      SELECT COALESCE(p.id, c.id, 0) AS id,
        COALESCE(p.name, c.name, 'Uncategorized') AS name,
        COALESCE(p.icon, c.icon) AS icon, a.currency, a.digits, SUM(t.amount_minor) AS amount
      $_source LEFT JOIN categories c ON c.id = t.category_id
      LEFT JOIN categories p ON p.id = c.parent_id
      WHERE $filter AND t.type = 'expense'
      GROUP BY COALESCE(p.id, c.id), a.currency, a.digits''',
          variables: args(from, to),
        ).get();
    final changes = <int, CategoryChange>{};
    void add(QueryRow row, {required bool current}) {
      final id = row.read<int>('id');
      final converted = amount(row);
      if (converted == null) return;
      final was =
          changes[id] ??
          (
            name: row.read<String>('name'),
            icon: row.readNullable<String>('icon'),
            current: 0,
            average: 0,
          );
      changes[id] = (
        name: was.name,
        icon: was.icon,
        current: was.current + (current ? converted : 0),
        // Summed here; divided once every month is in.
        average: was.average + (current ? 0 : converted),
      );
    }

    for (final row in await byCategory(start, end)) {
      add(row, current: true);
    }
    var compared = 0;
    for (var i = 1; i <= _compared; i++) {
      final from = DateTime(month.year, month.month - i);
      final to = running
          ? DateTime(
              from.year,
              from.month,
              math.min(today.day, DateTime(from.year, from.month + 1, 0).day) +
                  1,
            )
          : DateTime(from.year, from.month + 1);
      final rows = await byCategory(from, to);
      if (rows.isNotEmpty) compared++;
      for (final row in rows) {
        add(row, current: false);
      }
    }
    final categoryChanges =
        [
          for (final c in changes.values)
            (
              name: c.name,
              icon: c.icon,
              current: c.current,
              average: compared == 0 ? 0 : (c.average / compared).round(),
            ),
        ]..sort(
          (a, b) => (b.current - b.average).abs().compareTo(
            (a.current - a.average).abs(),
          ),
        );

    // Balances are only stored as they are now, so earlier month-ends are
    // worked back from every transaction dated after them. Archived accounts
    // sit out of all three queries below rather than only the first: their
    // balance is no longer part of what you hold, so subtracting their
    // movements from a total that never included them would bend every
    // earlier month. Net worth therefore reads as if they had never been.
    final current = await database.customSelect(
      '''SELECT currency, digits, SUM(balance_minor) AS amount FROM accounts
             WHERE archived_at IS NULL GROUP BY currency, digits''',
    ).get();
    // Scan the balance movements once, in six disjoint intervals. Previously
    // each month rescanned all later transactions. The last interval includes
    // future-dated entries too, since they already affect today's balances.
    final cutoffs = [
      for (final flow in flows)
        DateTime(flow.month.year, flow.month.month + 1).millisecondsSinceEpoch,
    ];
    final bucket =
        'CASE ${[for (var i = 1; i < months; i++) 'WHEN date < ? THEN ${i - 1}'].join(' ')} ELSE ${months - 1} END';
    final movements = await database
        .customSelect(
          '''
        SELECT $bucket AS bucket, currency, digits, SUM(amount) AS amount FROM (
          SELECT t.date, a.currency, a.digits,
            CASE WHEN t.type = 'income' THEN t.amount_minor ELSE -t.amount_minor END AS amount
          FROM transactions t JOIN accounts a ON a.id = t.account_id
          WHERE t.date >= ? AND a.archived_at IS NULL
          UNION ALL
          SELECT t.date, a.currency, a.digits, t.amount_minor AS amount
          FROM transactions t JOIN accounts a ON a.id = t.to_account_id
          WHERE t.type = 'transfer' AND t.date >= ? AND a.archived_at IS NULL
        ) GROUP BY bucket, currency, digits
      ''',
          variables: [
            for (final cutoff in cutoffs.skip(1)) Variable(cutoff),
            Variable(cutoffs.first),
            Variable(cutoffs.first),
          ],
        )
        .get();
    final buckets = List.generate(months, (_) => <(String, int), int>{});
    for (final row in movements) {
      buckets[row.read<int>('bucket')][(
        row.read<String>('currency'),
        row.read<int>('digits'),
      )] = row.read<int>(
        'amount',
      );
    }
    final balanceChanges = <(String, int), int>{};
    final balances = List<int>.filled(months, 0);
    for (var i = months - 1; i >= 0; i--) {
      for (final entry in buckets[i].entries) {
        balanceChanges.update(
          entry.key,
          (value) => value + entry.value,
          ifAbsent: () => entry.value,
        );
      }
      var total = 0;
      for (final row in current) {
        final code = row.read<String>('currency');
        final digits = row.read<int>('digits');
        final value = conversion.convert(
          row.read<int>('amount') - (balanceChanges[(code, digits)] ?? 0),
          code,
          digits,
        );
        if (value != null) total += value;
      }
      balances[i] = total;
    }
    return HomeInsights(
      previousDailyExpenses: previousDaily,
      flows: flows,
      categoryChanges: categoryChanges,
      comparedMonths: compared,
      balances: balances,
      missingCurrencies: Set.unmodifiable(conversion.missing),
    );
  });
}
