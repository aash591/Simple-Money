import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../domain/account.dart';
import '../../domain/budget.dart';
import '../../domain/category.dart';
import '../../domain/transaction.dart';
import '../../state/account_store.dart';
import '../../state/budget_store.dart';
import '../../state/category_store.dart';
import '../../state/transaction_store.dart';
import '../components/adaptive_sheet.dart';
import '../components/app_icon.dart';
import '../components/charts/charts.dart';
import '../components/common.dart';
import '../components/feature_page.dart';
import '../components/money_text.dart';
import '../components/skeleton.dart';
import '../theme/app_theme.dart';
import '../transactions/transaction_sheet.dart';
import 'budget_widgets.dart';
import 'set_budget_screen.dart';

/// One budget's month at a glance: what's left, how the spending is pacing,
/// where it went, how recent months compare, and the transactions behind it.
/// The pencil up top opens the editor.
///
/// [budgetId] is a category or custom budget; null is the month's total,
/// whether one of its own or the category budgets added up.
class BudgetSummaryScreen extends StatefulWidget {
  const BudgetSummaryScreen({
    super.key,
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    required this.budgetStore,
    required this.month,
    required this.currency,
    required this.digits,
    this.budgetId,
  });
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final BudgetStore budgetStore;
  final DateTime month;
  final String currency;
  final int digits;
  final int? budgetId;

  @override
  State<BudgetSummaryScreen> createState() => _BudgetSummaryScreenState();
}

enum _Period { past, current, future }

class _BudgetSummaryScreenState extends State<BudgetSummaryScreen> {
  static const _trendMonths = 6;
  static const _previewCount = 8;

  late final DateTime _month = DateTime(widget.month.year, widget.month.month);

  /// Saving changed categories can replace the budget with a new one, so
  /// this follows whatever the editor hands back.
  late int? _budgetId = widget.budgetId;
  BudgetMonth? _budgets;

  /// This budget in each of the last [_trendMonths] months, oldest first and
  /// ending with [_month]; null where it wasn't set.
  List<BudgetLine?> _history = const [];
  String? _error;
  int _generation = 0;
  bool _editing = false, _showAll = false;
  late final Listenable _stores = Listenable.merge([
    widget.accountStore,
    widget.categoryStore,
    widget.transactionStore,
    widget.budgetStore,
  ]);

  @override
  void initState() {
    super.initState();
    _stores.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    _generation++;
    _stores.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    if (!mounted) return;
    final request = ++_generation;
    if (widget.accountStore.loading ||
        widget.categoryStore.loading ||
        widget.transactionStore.loading) {
      return;
    }
    try {
      final loaded = <BudgetMonth>[];
      for (var i = _trendMonths - 1; i >= 0; i--) {
        loaded.add(
          await widget.budgetStore.loadMonth(
            DateTime(_month.year, _month.month - i),
            widget.currency,
            widget.digits,
          ),
        );
      }
      if (!mounted || request != _generation) return;
      // A save in the open editor may have moved the budget to a new id that
      // only arrives when it closes; keep the last numbers until then.
      if (_editing && _lineIn(loaded.last) == null) return;
      setState(() {
        _budgets = loaded.last;
        _history = [for (final month in loaded) _lineIn(month)];
        _error = null;
      });
    } catch (_) {
      if (!mounted || request != _generation) return;
      setState(() => _error = 'This budget could not be loaded.');
    }
  }

  BudgetLine? _lineIn(BudgetMonth month) => _budgetId == null
      ? month.total
      : month.budgets.where((line) => line.id == _budgetId).firstOrNull;

  BudgetLine? get _line => switch (_budgets) {
    final budgets? => _lineIn(budgets),
    null => null,
  };

  /// The total that only adds up the category budgets.
  bool get _derived => _budgetId == null && _budgets!.totalIsDerived;

  _Period get _period {
    final now = DateTime.now();
    final thisMonth = DateTime(now.year, now.month);
    if (_month.isBefore(thisMonth)) return _Period.past;
    return _month.isAfter(thisMonth) ? _Period.future : _Period.current;
  }

  int get _daysInMonth => DateUtils.getDaysInMonth(_month.year, _month.month);

  String _money(int minor) => formatAccountMoney(
    minor,
    currency: widget.currency,
    digits: widget.digits,
  );
  String _chartMoney(double minor) => _money(minor.round());
  String _axisMoney(double minor) =>
      '${currencyPrefix(widget.currency)}'
      '${NumberFormat.compact().format(minor / math.pow(10, widget.digits))}';

  Map<int, Category> get _categoryById => {
    for (final category in widget.categoryStore.categories)
      category.id: category,
  };

  List<Category> _categoriesOf(BudgetLine line) => widget
      .categoryStore
      .categories
      .where((c) => line.categoryIds.contains(c.id))
      .toList();

  /// The categories this budget counts, or null when every expense counts.
  Set<int>? get _covered {
    if (_budgetId != null) return _line!.categoryIds.toSet();
    if (!_budgets!.totalIsDerived) return null;
    return {for (final line in _budgets!.budgets) ...line.categoryIds};
  }

  /// The expenses that count toward this budget in [month], newest first —
  /// the same ones the budget's spent figure adds up.
  List<MoneyTransaction> _spendingIn(DateTime month) {
    final start = DateTime(month.year, month.month);
    final end = DateTime(month.year, month.month + 1);
    // Archived accounts included: money spent out of one still counts against
    // the budget of the month it was spent in.
    final accounts = {
      for (final account in widget.accountStore.allAccounts)
        account.id: account,
    };
    final categories = _categoryById;
    final covered = _covered;
    return widget.transactionStore.transactions.where((t) {
      if (t.type != TransactionType.expense ||
          t.date.isBefore(start) ||
          !t.date.isBefore(end)) {
        return false;
      }
      final account = accounts[t.accountId];
      if (account == null ||
          account.currency != widget.currency ||
          account.digits != widget.digits) {
        return false;
      }
      final category = categories[t.categoryId];
      if (category?.isDebtLoan ?? false) return false;
      if (covered == null) return true;
      return category != null &&
          (covered.contains(category.id) ||
              covered.contains(category.parentId));
    }).toList()..sort((a, b) => b.date.compareTo(a.date));
  }

  Future<void> _edit() async {
    final budgets = _budgets, line = _line;
    if (budgets == null || line == null || _editing) return;
    _editing = true;
    final result = await Navigator.of(context).push(
      FeatureRoute<BudgetEditResult>(
        SetBudgetScreen(
          budgetStore: widget.budgetStore,
          categoryStore: widget.categoryStore,
          month: _month,
          currency: widget.currency,
          digits: widget.digits,
          budgets: budgets,
          total: _budgetId == null,
          budget: _budgetId == null ? null : line,
        ),
      ),
    );
    _editing = false;
    if (!mounted) return;
    if (result != null && result.removed) {
      Navigator.of(context).pop();
      return;
    }
    if (result != null && _budgetId != null) _budgetId = result.budgetId;
    await _reload();
  }

  void _openBudget(int budgetId) => Navigator.of(context).push(
    FeatureRoute<void>(
      BudgetSummaryScreen(
        accountStore: widget.accountStore,
        categoryStore: widget.categoryStore,
        transactionStore: widget.transactionStore,
        budgetStore: widget.budgetStore,
        month: _month,
        currency: widget.currency,
        digits: widget.digits,
        budgetId: budgetId,
      ),
    ),
  );

  Future<void> _openTransaction(MoneyTransaction transaction) =>
      showViewTransactionSheet(
        context,
        transaction: transaction,
        accountStore: widget.accountStore,
        categoryStore: widget.categoryStore,
        transactionStore: widget.transactionStore,
      );

  @override
  Widget build(BuildContext context) {
    final line = _line;
    return FeaturePage(
      title: DateFormat.yMMMM().format(_month),
      actions: [
        if (line != null && !_derived)
          IconButton(
            tooltip: 'Edit budget',
            onPressed: _edit,
            icon: const Icon(Icons.edit_outlined),
          ),
      ],
      child: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    const padding = EdgeInsets.fromLTRB(18, 8, 18, 32);
    const gap = SizedBox(height: 14);
    if (_error != null) {
      return ListView(
        padding: padding,
        children: [
          MoneyCard(
            child: Column(
              children: [
                Text(_error!),
                TextButton(onPressed: _reload, child: const Text('Try again')),
              ],
            ),
          ),
        ],
      );
    }
    if (_budgets == null) {
      return ListView(
        padding: padding,
        children: const [SkeletonCards(cards: 3, rows: 2)],
      );
    }
    final line = _line;
    if (line == null) return _buildGone(context);
    final spending = _spendingIn(_month);
    final breakdown = _breakdown(line, spending);
    return ListView(
      padding: padding,
      children: [
        _buildHero(context, line),
        if (_period != _Period.future) ...[
          gap,
          _buildPace(context, line, spending),
        ],
        if (breakdown.length > 1) ...[
          gap,
          _buildBreakdown(context, line, breakdown),
        ],
        if (_trend() case final trend?) ...[gap, _buildTrend(context, trend)],
        gap,
        _buildTransactions(context, spending),
      ],
    );
  }

  /// The budget was removed or its categories deleted while this was open.
  Widget _buildGone(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
      children: [
        MoneyCard(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const IconTile(Icons.savings_outlined, size: 52),
              const SizedBox(height: 14),
              Text(
                'No budget here',
                style: text.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 6),
              Text(
                'This budget doesn\'t apply to ${DateFormat.yMMMM().format(_month)}.',
                style: text.bodySmall?.copyWith(height: 1.5),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 18),
              FilledButton(
                onPressed: () => Navigator.of(context).maybePop(),
                child: const Text('Back to budgets'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// The budget's name over a ring filled to how much is used, with what's
  /// left in the middle, then spent, budget and share used side by side.
  Widget _buildHero(BuildContext context, BudgetLine line) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final leftColor = budgetLeftColor(line);
    final categories = _categoriesOf(line);
    final (label, title, icon) = _budgetId == null
        ? (
            _derived ? 'Total of category budgets' : 'Total monthly budget',
            _derived ? 'All budgeted spending' : 'All spending',
            const IconTile(Icons.donut_large_rounded, size: 44),
          )
        : (
            line.isCustom ? 'Custom budget' : 'Category budget',
            line.isCustom
                ? line.name ?? categories.first.name
                : budgetTitle(line.name, categories),
            budgetIcon(categories, icon: line.icon, size: 44),
          );
    return MoneyCard(
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: InkWell(
              onTap: line.isCustom ? () => _showCategories(line) : null,
              borderRadius: BorderRadius.circular(18),
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  children: [
                    icon,
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(label, style: text.bodySmall),
                          const SizedBox(height: 2),
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(text: title),
                                if (line.isCustom)
                                  WidgetSpan(
                                    alignment: PlaceholderAlignment.middle,
                                    child: Padding(
                                      padding: const EdgeInsets.only(left: 8),
                                      child: _CategoriesPill(
                                        label: line.name == null
                                            ? '+${categories.length - 1} more'
                                            : '${categories.length} categories',
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleLarge?.copyWith(
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                              letterSpacing: -0.3,
                              height: 1.3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Center(
            child: _BudgetRing(
              fraction: line.fraction,
              color: leftColor,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    line.isOver ? 'Over budget by' : 'Left to spend',
                    style: text.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: MoneyText(_money(line.left.abs()), color: leftColor),
                  ),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      'of ${_money(line.limit)}',
                      style: text.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            margin: const EdgeInsets.fromLTRB(14, 0, 14, 14),
            padding: const EdgeInsets.symmetric(vertical: 12),
            decoration: BoxDecoration(
              color: scheme.onSurface.withValues(alpha: .04),
              borderRadius: BorderRadius.circular(18),
            ),
            child: IntrinsicHeight(
              child: Row(
                children: [
                  _HeroStat(label: 'Spent', value: _money(line.spent)),
                  const VerticalDivider(width: 1, indent: 4, endIndent: 4),
                  _HeroStat(label: 'Budget', value: _money(line.limit)),
                  const VerticalDivider(width: 1, indent: 4, endIndent: 4),
                  _HeroStat(
                    label: 'Used',
                    value: '${line.percentUsed}%',
                    color: leftColor,
                  ),
                ],
              ),
            ),
          ),
          if (_derived) ...[
            const Divider(height: 1, indent: 18, endIndent: 18),
            _buildDerivedNote(context),
          ],
        ],
      ),
    );
  }

  /// A derived total has nothing to edit; say what it adds up instead, and
  /// offer a total of its own.
  Widget _buildDerivedNote(BuildContext context) {
    final count = _budgets!.budgets.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 10, 10, 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              'Adds up your $count category ${count == 1 ? 'budget' : 'budgets'}.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: _edit, child: const Text('Set a total')),
        ],
      ),
    );
  }

  /// Every category a custom budget combines, with what each has spent
  /// this month. Spending in a subcategory that's chosen on its own counts
  /// there, not under its parent too.
  void _showCategories(BudgetLine line) {
    final categories = _categoriesOf(line);
    final all = _categoryById;
    final spent = <int, int>{};
    for (final t in _spendingIn(_month)) {
      final category = all[t.categoryId];
      if (category == null) continue;
      final key = line.categoryIds.contains(category.id)
          ? category.id
          : category.parentId!;
      spent[key] = (spent[key] ?? 0) + t.amountMinor;
    }
    showAdaptiveSheet<void>(
      context,
      builder: (context) {
        final text = Theme.of(context).textTheme;
        return SheetPage(
          header: const SheetHeader('Included categories'),
          body: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                child: Text(
                  '${categories.length} categories · spent in '
                  '${DateFormat.MMMM().format(_month)}',
                  style: text.bodySmall?.copyWith(height: 1.4),
                ),
              ),
              SheetCard(
                child: Column(
                  children: [
                    for (final (i, category) in categories.indexed) ...[
                      if (i > 0)
                        const Divider(height: 1, indent: 66, endIndent: 16),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        child: Row(
                          children: [
                            AppIcon(category.icon, size: 36),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    category.name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 14.5,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  if (_subtitleOf(category) case final note?)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 2),
                                      child: Text(
                                        note,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: text.bodySmall,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 10),
                            Text(
                              _money(spent[category.id] ?? 0),
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: spent[category.id] == null
                                    ? text.bodySmall?.color
                                    : null,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// "In Food & Beverage" for a subcategory; "With its subcategories" for a
  /// category that has some, since choosing it includes them.
  String? _subtitleOf(Category category) {
    final all = widget.categoryStore.categories;
    if (category.parentId case final parentId?) {
      final parent = all.where((c) => c.id == parentId).firstOrNull;
      return parent == null ? null : 'In ${parent.name}';
    }
    return all.any((c) => c.parentId == category.id)
        ? 'With its subcategories'
        : null;
  }

  /// This month: what's safe to spend each day, where it's heading, and
  /// what's spent so far beside what an even pace would have spent by today.
  /// A past month: how it ended, week by week.
  Widget _buildPace(
    BuildContext context,
    BudgetLine line,
    List<MoneyTransaction> spending,
  ) {
    final days = _daysInMonth;
    final current = _period == _Period.current;
    final today = current ? DateTime.now().day : days;
    final daily = List.filled(days, 0);
    for (final t in spending) {
      daily[t.date.day - 1] += t.amountMinor;
    }
    final (String, Color, IconData) status;
    final List<Widget> stats;
    final Widget visual;
    if (current) {
      final daysLeft = days - today + 1;
      final projected = (line.spent / today * days).round();
      status = line.isOver
          ? ('Over budget', coral, Icons.error_outline_rounded)
          : projected > line.limit
          ? ('Spending fast', budgetAmber, Icons.trending_up_rounded)
          : ('On track', green, Icons.check_circle_outline_rounded);
      stats = [
        _Stat(
          label: 'Safe to spend',
          value: _money(math.max(0, line.left) ~/ daysLeft),
          footnote: daysLeft == 1
              ? 'today, the last day'
              : 'a day, $daysLeft days left',
        ),
        _Stat(
          label: 'By month end',
          value: _money(projected),
          footnote: projected > line.limit
              ? '${_money(projected - line.limit)} over'
              : '${_money(line.limit - projected)} under',
        ),
      ];
      visual = _PaceComparison(
        line: line,
        expected: (line.limit * today / days).round(),
        format: _money,
      );
    } else {
      status = line.isOver
          ? ('Went over', coral, Icons.error_outline_rounded)
          : ('Stayed within', green, Icons.check_circle_outline_rounded);
      final busiest = daily.indexed.fold((
        0,
        0,
      ), (best, day) => day.$2 > best.$2 ? day : best);
      stats = [
        _Stat(
          label: 'Daily average',
          value: _money(line.spent ~/ days),
          footnote: 'across $days days',
        ),
        _Stat(
          label: 'Biggest day',
          value: busiest.$2 == 0 ? '—' : _money(busiest.$2),
          footnote: busiest.$2 == 0
              ? 'no spending'
              : DateFormat.MMMd().format(
                  DateTime(_month.year, _month.month, busiest.$1 + 1),
                ),
        ),
      ];
      visual = _buildWeeks(context, line, daily);
    }
    return _SectionCard(
      title: current
          ? 'Spending pace'
          : 'How ${DateFormat.MMMM().format(_month)} went',
      trailing: _Pill(label: status.$1, color: status.$2, icon: status.$3),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: stats[0]),
              const SizedBox(width: 14),
              Expanded(child: stats[1]),
            ],
          ),
          const SizedBox(height: 18),
          visual,
        ],
      ),
    );
  }

  /// A past month's spending in weeks (1–7, 8–14, …), red where a week spent
  /// more than its share of the budget.
  Widget _buildWeeks(BuildContext context, BudgetLine line, List<int> daily) {
    final primary = Theme.of(context).colorScheme.primary;
    final weeks = [
      for (var first = 0; first < daily.length; first += 7)
        (
          first: first + 1,
          last: math.min(first + 7, daily.length),
          spent: daily
              .skip(first)
              .take(7)
              .fold(0, (sum, amount) => sum + amount),
        ),
    ];
    bool over(({int first, int last, int spent}) week) =>
        week.spent > line.limit * (week.last - week.first + 1) / daily.length;
    final anyOver = weeks.any(over);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BarChart(
          height: 130,
          series: [
            ChartSeries(
              label: 'Spent',
              values: [for (final week in weeks) week.spent],
              color: primary,
              valueColors: [
                for (final week in weeks) over(week) ? coral : primary,
              ],
            ),
          ],
          labels: [
            for (final week in weeks)
              week.first == week.last
                  ? '${week.first}'
                  : '${week.first}–${week.last}',
          ],
          formatValue: _chartMoney,
          formatAxis: _axisMoney,
        ),
        const SizedBox(height: 10),
        Text(
          'A week\'s share is about ${_money(line.limit * 7 ~/ daily.length)}'
          '${anyOver ? ' · red weeks went over it' : ''}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  /// Where the money went, biggest first: by budget for a derived total, by
  /// top-level category for the total, by chosen category for a custom
  /// budget, and by subcategory for a category budget.
  List<_Share> _breakdown(BudgetLine line, List<MoneyTransaction> spending) {
    if (_derived) {
      return [
        for (final budget in _budgets!.budgets)
          if (budget.spent > 0)
            _Share(
              budgetTitle(budget.name, _categoriesOf(budget)),
              budget.spent,
              budgetId: budget.id,
            ),
      ]..sort((a, b) => b.amount.compareTo(a.amount));
    }
    final categories = _categoryById;
    final totals = <int?, int>{};
    for (final t in spending) {
      final category = categories[t.categoryId];
      final key = _budgetId == null
          ? category?.parentId ?? category?.id
          : line.isCustom && !line.categoryIds.contains(category?.id)
          ? category?.parentId
          : category?.id;
      totals[key] = (totals[key] ?? 0) + t.amountMinor;
    }
    return [
      for (final MapEntry(:key, :value) in totals.entries)
        _Share(categories[key]?.name ?? 'Uncategorized', value),
    ]..sort((a, b) => b.amount.compareTo(a.amount));
  }

  Widget _buildBreakdown(
    BuildContext context,
    BudgetLine line,
    List<_Share> shares,
  ) {
    final palette = ChartPalette.of(context);
    return _SectionCard(
      title: _derived
          ? 'By budget'
          : _budgetId != null && !line.isCustom
          ? 'By subcategory'
          : 'By category',
      child: RankedBarChart(
        entries: [
          for (final (i, share) in shares.indexed)
            ChartEntry(
              label: share.label,
              value: share.amount + .0,
              color: palette.series(i),
            ),
        ],
        formatValue: _chartMoney,
        showShare: true,
        onTap: _derived
            ? (i) => switch (shares[i].budgetId) {
                final id? => _openBudget(id),
                null => null,
              }
            : null,
      ),
    );
  }

  /// Spending in each of the last few months, or null while there's no
  /// earlier month to compare with.
  List<({DateTime month, int spent, int? limit})>? _trend() {
    final months = [
      for (final (i, line) in _history.indexed)
        (
          month: DateTime(
            _month.year,
            _month.month - (_history.length - 1 - i),
          ),
          line: line,
        ),
    ];
    final trend = [
      for (final entry in months)
        (
          month: entry.month,
          spent:
              entry.line?.spent ??
              _spendingIn(entry.month)
                  .fold<int>(0, (sum, t) => sum + t.amountMinor),
          limit: entry.line?.limit,
        ),
    ];
    final earlier = trend.take(trend.length - 1);
    if (!earlier.any((m) => m.spent > 0 || m.limit != null)) return null;
    return trend;
  }

  Widget _buildTrend(
    BuildContext context,
    List<({DateTime month, int spent, int? limit})> trend,
  ) {
    final text = Theme.of(context).textTheme;
    final primary = Theme.of(context).colorScheme.primary;
    final average = trend.fold(0, (sum, m) => sum + m.spent) ~/ trend.length;
    final anyOver = trend.any((m) => m.limit != null && m.spent > m.limit!);
    return _SectionCard(
      title: 'Last $_trendMonths months',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          BarChart(
            height: 140,
            series: [
              ChartSeries(
                label: 'Spent',
                values: [for (final m in trend) m.spent],
                color: primary,
                valueColors: [
                  for (final (i, m) in trend.indexed)
                    m.limit != null && m.spent > m.limit!
                        ? coral
                        : i == trend.length - 1
                        ? primary
                        : primary.withValues(alpha: .45),
                ],
              ),
            ],
            labels: [for (final m in trend) DateFormat.MMM().format(m.month)],
            formatValue: _chartMoney,
            formatAxis: _axisMoney,
          ),
          const SizedBox(height: 12),
          Text(
            'Averaging ${_money(average)} a month'
            '${anyOver ? ' · coral months went over budget' : ''}',
            style: text.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _buildTransactions(
    BuildContext context,
    List<MoneyTransaction> spending,
  ) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final accounts = {
      for (final account in widget.accountStore.allAccounts)
        account.id: account,
    };
    final categories = _categoryById;
    final shown = _showAll ? spending : spending.take(_previewCount).toList();
    return MoneyCard(
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
              child: Row(
                children: [
                  Expanded(
                    child: Text('Transactions', style: text.titleMedium),
                  ),
                  if (spending.isNotEmpty)
                    Text('${spending.length}', style: text.bodySmall),
                ],
              ),
            ),
            if (spending.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 18, 18, 26),
                child: Column(
                  children: [
                    Icon(
                      Icons.receipt_long_outlined,
                      size: 32,
                      color: scheme.onSurfaceVariant.withValues(alpha: .6),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _period == _Period.past
                          ? 'Nothing was spent in ${DateFormat.MMMM().format(_month)}.'
                          : 'Nothing spent yet in ${DateFormat.MMMM().format(_month)}.',
                      textAlign: TextAlign.center,
                      style: text.bodySmall,
                    ),
                  ],
                ),
              ),
            for (final (i, t) in shown.indexed) ...[
              if (i > 0) const Divider(height: 1, indent: 68, endIndent: 18),
              _SpendingRow(
                transaction: t,
                category: categories[t.categoryId],
                account: accounts[t.accountId],
                amount: _money(t.amountMinor),
                onTap: () => _openTransaction(t),
              ),
            ],
            if (spending.length > _previewCount)
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                child: TextButton(
                  onPressed: () => setState(() => _showAll = !_showAll),
                  child: Text(
                    _showAll ? 'Show less' : 'Show all ${spending.length}',
                  ),
                ),
              )
            else
              const SizedBox(height: 6),
          ],
        ),
      ),
    );
  }
}

/// A tappable-looking count of a custom budget's other categories, beside
/// its title.
class _CategoriesPill extends StatelessWidget {
  const _CategoriesPill({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 3, 5, 3),
      decoration: BoxDecoration(
        color: primary.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0,
              color: primary,
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 18, color: primary),
        ],
      ),
    );
  }
}

/// What's been spent so far against what an even pace would have spent by
/// today, as two bars on the same scale — the budget — and a line saying
/// which is ahead.
class _PaceComparison extends StatelessWidget {
  const _PaceComparison({
    required this.line,
    required this.expected,
    required this.format,
  });
  final BudgetLine line;

  /// What an even pace would have spent by the end of today.
  final int expected;
  final String Function(int) format;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final ahead = line.spent > expected;
    final gap = (line.spent - expected).abs();
    final noteColor = ahead ? (line.isOver ? coral : budgetAmber) : green;
    Widget bar(String label, int amount, Color color) => Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(child: Text(label, style: text.bodySmall)),
            const SizedBox(width: 8),
            Text(
              format(amount),
              style: const TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        BudgetProgressBar(
          fraction: line.limit <= 0 ? 0 : amount / line.limit,
          color: color,
          height: 10,
        ),
      ],
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        bar('Spent so far', line.spent, budgetColor(context, line)),
        const SizedBox(height: 14),
        bar(
          'Even pace by today',
          expected,
          scheme.onSurfaceVariant.withValues(alpha: .4),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.fromLTRB(10, 9, 12, 9),
          decoration: BoxDecoration(
            color: noteColor.withValues(alpha: .1),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: [
              Icon(
                ahead ? Icons.speed_rounded : Icons.thumb_up_alt_outlined,
                size: 18,
                color: noteColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  gap == 0
                      ? 'Right on an even pace.'
                      : ahead
                      ? '${format(gap)} over an even pace. Slow down to stay on budget.'
                      : '${format(gap)} under an even pace — you have room.',
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurface,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A ring filled clockwise from the top to [fraction] of a full turn, with
/// [child] in the middle; the fill eases to new values unless motion is
/// reduced.
class _BudgetRing extends StatelessWidget {
  const _BudgetRing({
    required this.fraction,
    required this.color,
    required this.child,
  });
  static const _size = 196.0, _stroke = 14.0;
  final double fraction;
  final Color color;
  final Widget child;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: _size,
    child: Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: fraction.clamp(0, 1).toDouble()),
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 650),
            curve: Curves.easeOutCubic,
            builder: (context, value, _) => CustomPaint(
              painter: _RingPainter(
                value: value,
                color: color,
                track: Theme.of(context).colorScheme.onSurface
                    .withValues(alpha: .07),
                stroke: _stroke,
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(_stroke + 18),
          child: Center(child: child),
        ),
      ],
    ),
  );
}

class _RingPainter extends CustomPainter {
  const _RingPainter({
    required this.value,
    required this.color,
    required this.track,
    required this.stroke,
  });
  final double value, stroke;
  final Color color, track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = track);
    if (value <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      math.pi * 2 * value,
      false,
      paint..color = color,
    );
  }

  @override
  bool shouldRepaint(_RingPainter old) =>
      old.value != value || old.color != color || old.track != track;
}

/// One of the figures under the ring.
class _HeroStat extends StatelessWidget {
  const _HeroStat({required this.label, required this.value, this.color});
  final String label, value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: color,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _Share {
  const _Share(this.label, this.amount, {this.budgetId});
  final String label;
  final int amount;

  /// The budget this share is, when a derived total is broken down.
  final int? budgetId;
}

/// A card with a title row and its content below.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child, this.trailing});
  final String title;
  final Widget child;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) => MoneyCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 10), trailing!],
          ],
        ),
        const SizedBox(height: 14),
        child,
      ],
    ),
  );
}

/// A short status in its colour, on a wash of it.
class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.color, this.icon});
  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.fromLTRB(icon == null ? 10 : 8, 5, 10, 5),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 4),
        ],
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    ),
  );
}

/// One figure in the pace card: what it is, the amount, and a line of
/// context under it.
class _Stat extends StatelessWidget {
  const _Stat({
    required this.label,
    required this.value,
    required this.footnote,
  });
  final String label, value, footnote;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: text.bodySmall),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            maxLines: 1,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(footnote, style: text.bodySmall),
      ],
    );
  }
}

/// One expense counted by the budget: its category icon, its title (or
/// category), when and from which account, and the amount.
class _SpendingRow extends StatelessWidget {
  const _SpendingRow({
    required this.transaction,
    required this.category,
    required this.account,
    required this.amount,
    required this.onTap,
  });
  final MoneyTransaction transaction;
  final Category? category;
  final Account? account;
  final String amount;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final custom = transaction.title?.trim();
    final hasTitle = custom != null && custom.isNotEmpty;
    final title = hasTitle ? custom : category?.name ?? 'Expense';
    final detail = hasTitle ? category?.name : account?.name;
    final subtitle = [
      DateFormat.MMMd().format(transaction.date),
      ?detail,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
        child: Row(
          children: [
            AppIcon(category?.icon, size: 36),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              amount,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
            ),
          ],
        ),
      ),
    );
  }
}
