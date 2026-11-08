import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../domain/account.dart';
import '../../domain/budget.dart';
import '../../domain/category.dart';
import '../../state/account_store.dart';
import '../../state/budget_store.dart';
import '../../state/category_store.dart';
import '../../state/transaction_store.dart';
import '../components/app_back_button.dart' show GlassPillButton;
import '../components/choice_list_sheet.dart';
import '../components/common.dart';
import '../components/empty_state.dart';
import '../components/tab_header.dart';
import '../components/feature_page.dart';
import '../components/month_picker_popup.dart';
import '../components/skeleton.dart';
import '../components/status_bar_blur_scope.dart';
import 'budget_summary_screen.dart';
import 'budget_widgets.dart';
import 'set_budget_screen.dart';

class BudgetsScreen extends StatefulWidget {
  const BudgetsScreen({
    super.key,
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    required this.budgetStore,
    this.initialMonth,
    this.initialCurrency,
    this.monthRequest = 0,
  });
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final BudgetStore budgetStore;

  /// Set when Home opens this tab, so it shows the month and currency Home
  /// was showing; [monthRequest] changes each time that happens.
  final DateTime? initialMonth;
  final (String, int)? initialCurrency;
  final int monthRequest;

  @override
  State<BudgetsScreen> createState() => BudgetsScreenState();
}

/// Public so the tab bar's "+" button can start a new budget for whichever
/// month and currency this screen is showing.
class BudgetsScreenState extends State<BudgetsScreen> {
  late DateTime month =
      widget.initialMonth ??
      DateTime(DateTime.now().year, DateTime.now().month);
  late (String, int)? selectedCurrency = widget.initialCurrency;
  BudgetMonth? budgets;
  bool loading = true;
  String? error;
  int generation = 0;
  final _monthAnchor = GlobalKey();
  bool _pickingMonth = false;
  late final Listenable stores = Listenable.merge([
    widget.accountStore,
    widget.categoryStore,
    widget.transactionStore,
    widget.budgetStore,
  ]);

  /// Built from every account, archived included: a budget is kept per
  /// currency, so archiving the last account in one would otherwise put its
  /// budgets out of reach along with it.
  List<(String, int)> get currencies => widget.accountStore.allAccounts
      .map((a) => (a.currency, a.digits))
      .toSet()
      .toList();
  (String, int) get currency => selectedCurrency ?? ('INR', 2);
  String amount(int value) =>
      formatAccountMoney(value, currency: currency.$1, digits: currency.$2);

  @override
  void initState() {
    super.initState();
    stores.addListener(_reload);
    _reload();
  }

  @override
  void didUpdateWidget(BudgetsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.monthRequest != oldWidget.monthRequest) {
      month = widget.initialMonth ?? month;
      selectedCurrency = widget.initialCurrency ?? selectedCurrency;
      _reload();
    }
  }

  @override
  void dispose() {
    generation++;
    stores.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    if (!mounted) return;
    final request = ++generation;
    if (currencies.isNotEmpty && !currencies.contains(selectedCurrency)) {
      selectedCurrency = currencies.first;
    } else if (currencies.isEmpty) {
      selectedCurrency = null;
    }
    // Keep showing the last numbers while new ones load, so saving a budget
    // or switching month doesn't flash a spinner.
    setState(() {
      loading = true;
      error = null;
    });
    if (widget.accountStore.loading ||
        widget.categoryStore.loading ||
        widget.transactionStore.loading) {
      return;
    }
    final storeError =
        widget.accountStore.loadError ??
        widget.categoryStore.loadError ??
        widget.transactionStore.loadError;
    if (storeError != null) {
      setState(() {
        error = storeError;
        loading = false;
      });
      return;
    }
    try {
      final result = await widget.budgetStore.loadMonth(
        month,
        currency.$1,
        currency.$2,
      );
      if (!mounted || request != generation) return;
      setState(() {
        budgets = result;
        loading = false;
      });
    } catch (_) {
      if (!mounted || request != generation) return;
      setState(() {
        error = 'Your budgets could not be loaded.';
        loading = false;
      });
    }
  }

  Future<void> _retry() async {
    await Future.wait([
      widget.accountStore.load(),
      widget.categoryStore.load(),
      widget.transactionStore.load(),
    ]);
    await _reload();
  }

  /// Budgets are kept per currency, so this filters rather than converts —
  /// there is no combined option here the way there is on Home.
  Future<void> _pickCurrency() async {
    final picked = await showChoiceListSheet<(String, int)>(
      context,
      title: 'Budget currency',
      selected: selectedCurrency,
      items: [
        for (final option in currencies)
          ChoiceItem<(String, int)>(
            value: option,
            icon: const Icon(Icons.account_balance_wallet_outlined, size: 20),
            label: '${option.$1} accounts',
          ),
      ],
    );
    if (picked == null || picked == selectedCurrency) return;
    selectedCurrency = picked;
    _reload();
  }

  Future<void> _pickMonth() async {
    if (_pickingMonth) return;
    setState(() => _pickingMonth = true);
    final picked = await showMonthPickerPopup(
      context,
      anchorKey: _monthAnchor,
      initialMonth: month,
      alignRight: true,
    );
    if (!mounted) return;
    setState(() => _pickingMonth = false);
    if (picked != null) {
      month = DateTime(picked.year, picked.month);
      _reload();
    }
  }

  /// The categories [line] covers, in the category list's order.
  List<Category> _categoriesOf(BudgetLine line) => widget
      .categoryStore
      .categories
      .where((c) => line.categoryIds.contains(c.id))
      .toList();

  /// A new budget starts on the first top-level expense category that no
  /// budget covers yet, or on picking categories if every one is taken.
  Set<int> _defaultCategories(BudgetMonth budgets) => {
    ?widget.categoryStore.categories
        .where(
          (c) =>
              c.type == CategoryType.expense &&
              c.parentId == null &&
              budgets.budgetCovering(c.id) == null &&
              !widget.categoryStore.categories.any(
                (child) =>
                    child.parentId == c.id &&
                    budgets.budgetCovering(child.id) != null,
              ),
        )
        .firstOrNull
        ?.id,
  };

  void addBudget() {
    final current = budgets;
    if (current == null) return;
    Navigator.of(context).push(
      FeatureRoute<BudgetEditResult>(
        SetBudgetScreen(
          budgetStore: widget.budgetStore,
          categoryStore: widget.categoryStore,
          month: month,
          currency: currency.$1,
          digits: currency.$2,
          budgets: current,
          initialCategoryIds: _defaultCategories(current),
        ),
      ),
    );
  }

  /// A budget's month at a glance, where it can be edited; [budgetId] null
  /// opens the total.
  void _openSummary({int? budgetId}) => Navigator.of(context).push(
    FeatureRoute<void>(
      BudgetSummaryScreen(
        accountStore: widget.accountStore,
        categoryStore: widget.categoryStore,
        transactionStore: widget.transactionStore,
        budgetStore: widget.budgetStore,
        month: month,
        currency: currency.$1,
        digits: currency.$2,
        budgetId: budgetId,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final current = budgets;
    return StatusBarBlurScope(
      builder: (context, scrollController, topInset) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: RefreshIndicator(
            onRefresh: _retry,
            edgeOffset: topInset,
            child: CustomScrollView(
              controller: scrollController,
              physics: const AlwaysScrollableScrollPhysics(),
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    TabHeader.sideMargin,
                    topInset + 4,
                    TabHeader.sideMargin,
                    error == null && current?.isEmpty == true
                        ? 0
                        : 96 + MediaQuery.paddingOf(context).bottom,
                  ),
                  sliver: SliverList.list(
                    children: [
                      TabHeader(
                        title: 'Budgets',
                        // A glass pill at the far right, matching the header
                        // discs; an action's square cut the month off.
                        trailing: GlassPillButton(
                          key: _monthAnchor,
                          onPressed: _pickMonth,
                          semanticLabel:
                              'Month: ${DateFormat.yMMMM().format(month)}',
                          label: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                DateFormat.yMMM().format(month),
                                maxLines: 1,
                                style: const TextStyle(
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                _pickingMonth
                                    ? Icons.keyboard_arrow_up_rounded
                                    : Icons.keyboard_arrow_down_rounded,
                                size: 18,
                                color: scheme.onSurfaceVariant,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (currencies.length > 1)
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _pickCurrency,
                            style: TextButton.styleFrom(
                              foregroundColor: scheme.onSurface,
                              padding: EdgeInsets.zero,
                              minimumSize: const Size(0, 36),
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  '${currency.$1} accounts',
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  size: 18,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ],
                            ),
                          ),
                        ),
                      const SizedBox(height: 10),
                      if (error != null)
                        MoneyCard(
                          child: Column(
                            children: [
                              Text(error!),
                              TextButton(
                                onPressed: _retry,
                                child: const Text('Try again'),
                              ),
                            ],
                          ),
                        )
                      else if (current == null)
                        const SkeletonCards(cards: 2, rows: 2)
                      else if (!current.isEmpty) ...[
                        TotalBudgetCard(
                          line: current.total!,
                          derived: current.totalIsDerived,
                          format: amount,
                          onTap: _openSummary,
                        ),
                        const SizedBox(height: appCardGap),
                        if (current.budgets.isEmpty)
                          _addCategoryCard()
                        else
                          _budgetsCard(current),
                      ],
                    ],
                  ),
                ),
                if (error == null && current?.isEmpty == true)
                  SliverLayoutBuilder(
                    builder: (context, constraints) => SliverToBoxAdapter(
                      child: SizedBox(
                        height:
                            (constraints.viewportMainAxisExtent -
                                    constraints.precedingScrollExtent)
                                .clamp(0.0, double.infinity),
                        child: EmptyState(
                          icon: Icons.savings_outlined,
                          title: 'Set your first budget',
                          message:
                              'Set a spending limit for ${DateFormat.MMMM().format(month)}. One category, or a few together.',
                          actionLabel: 'Set a budget',
                          onAction: addBudget,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _addCategoryCard() => MoneyCard(
    padding: EdgeInsets.zero,
    child: Material(
      type: MaterialType.transparency,
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        leading: const IconTile(Icons.add_rounded, size: 36),
        title: const Text(
          'Add a category budget',
          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        subtitle: const Text('One category, or several combined'),
        onTap: addBudget,
      ),
    ),
  );

  Widget _budgetsCard(BudgetMonth current) {
    final rows = [
      for (final line in current.budgets)
        if (_categoriesOf(line) case final categories
            when categories.isNotEmpty)
          BudgetRow(
            line: line,
            categories: categories,
            format: amount,
            onTap: () => _openSummary(budgetId: line.id),
          ),
    ];
    return MoneyCard(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                const Divider(
                  height: 1,
                  indent: BudgetRow.dividerIndent,
                  endIndent: 18,
                ),
              rows[i],
            ],
          ],
        ),
      ),
    );
  }
}
