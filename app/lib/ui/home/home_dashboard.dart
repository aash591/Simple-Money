import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/repositories/sms_import_repository.dart';
import '../../state/sms_import_store.dart';
import '../../data/repositories/home_repository.dart';
import '../../data/repositories/insights_repository.dart';
import '../../domain/budget.dart';
import '../../domain/currency_scope.dart';
import '../../state/account_store.dart';
import '../../state/budget_store.dart';
import '../../state/category_store.dart';
import '../../state/debt_store.dart';
import '../../state/home_layout.dart';
import '../../state/loan_store.dart';
import '../../state/main_currency_controller.dart';
import '../../state/recurring_payment_store.dart';
import '../../state/transaction_store.dart';
import '../components/currency_notice.dart';
import '../components/feature_page.dart';
import '../more/home_layout_screen.dart';
import '../theme/surface_style.dart';
import '../components/month_picker_popup.dart';
import '../components/status_bar_blur_scope.dart';
import 'cards/currency_scope_bar.dart';
import 'cards/home_card.dart';
import 'cards/home_skeleton.dart';
import 'home_cards.dart';
import '../sms/balance_mismatch_card.dart';
import 'cards/home_header.dart';

class HomeDashboard extends StatefulWidget {
  const HomeDashboard({
    super.key,
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    required this.budgetStore,
    required this.themeMode,
    required this.onChangeThemeMode,
    required this.onOpenTransactions,
    required this.onOpenBudgets,
    this.loanStore,
    this.recurringPaymentStore,
    this.debtStore,
    this.smsStore,
    this.onReviewSms,
  });
  final LoanStore? loanStore;
  final RecurringPaymentStore? recurringPaymentStore;
  final DebtStore? debtStore;
  final SmsImportStore? smsStore;
  final ValueChanged<PendingSmsImport>? onReviewSms;
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final BudgetStore budgetStore;
  final ValueListenable<ThemeMode> themeMode;
  final ValueChanged<ThemeMode> onChangeThemeMode;
  final ValueChanged<DateTime> onOpenTransactions;
  final void Function(DateTime month, (String, int) currency) onOpenBudgets;
  @override
  State<HomeDashboard> createState() => _HomeDashboardState();
}

class _HomeDashboardState extends State<HomeDashboard> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  CurrencyScope? selectedCurrency;
  MainCurrencyController? _mainCurrency;
  CurrencyScope? _loadedCurrency;
  HomeSummary? summary;
  HomeInsights? insights;
  BudgetMonth? budget;
  bool loading = true;
  String? error;
  int generation = 0;
  Future<void>? _reloadFuture;
  final _monthAnchor = GlobalKey();

  /// Used when no saved layout is provided, as in tests.
  static final _defaultLayout = HomeLayout();
  bool _pickingMonth = false;
  late final Listenable stores = Listenable.merge([
    widget.accountStore,
    widget.categoryStore,
    widget.transactionStore,
    widget.budgetStore,
    ?widget.loanStore,
    ?widget.debtStore,
    ?widget.recurringPaymentStore,
  ]);
  List<SingleCurrency> get currencies => widget.accountStore.accounts
      .map((a) => SingleCurrency(a.currency, a.digits))
      .toSet()
      .toList();

  /// The "All accounts" scope, carrying whatever rates are currently loaded.
  CombinedCurrency get _combined =>
      _mainCurrency?.combined ??
      CombinedCurrency(
        currencies.firstOrNull?.code ?? 'INR',
        currencies.firstOrNull?.digits ?? 2,
      );
  CurrencyScope get currency => selectedCurrency is SingleCurrency
      ? selectedCurrency!
      : currencies.length > 1
      ? _combined
      : currencies.firstOrNull ??
            _mainCurrency?.single ??
            const SingleCurrency('INR', 2);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final controller = MainCurrencyScope.maybeOf(context);
    if (!identical(controller, _mainCurrency)) {
      _mainCurrency?.removeListener(_currencyChanged);
      _mainCurrency = controller;
      controller?.addListener(_currencyChanged);
      _reload();
    }
  }

  void _currencyChanged() {
    // Account refreshes also notify the currency controller. Keep the existing
    // cards mounted unless their currency scope really changed; removing them
    // would discard an in-flight amount reveal after native authentication.
    if (_loadedCurrency != currency) {
      summary = null;
      insights = null;
      budget = null;
    }
    _reload();
  }

  // The review card joins the page the moment the waiting messages are read.
  bool _smsShown = false;
  void _smsChanged() {
    final loaded = widget.smsStore?.loaded ?? true;
    if (loaded != _smsShown && mounted) setState(() => _smsShown = loaded);
  }

  @override
  void initState() {
    super.initState();
    stores.addListener(_reload);
    widget.smsStore?.addListener(_smsChanged);
    _reload();
  }

  @override
  void dispose() {
    generation++;
    stores.removeListener(_reload);
    widget.smsStore?.removeListener(_smsChanged);
    _mainCurrency?.removeListener(_currencyChanged);
    super.dispose();
  }

  Future<void> _reload() {
    generation++;
    return _reloadFuture ??= _drainReloads();
  }

  Future<void> _drainReloads() async {
    // Coalesce synchronous notifications, and allow only one query chain in
    // flight. Changes during a query invalidate it and request one fresh pass.
    // RefreshIndicator also waits for that latest pass, not a discarded one.
    await Future<void>.value();
    try {
      while (mounted) {
        final request = generation;
        await _loadSummary(request);
        if (request == generation) break;
      }
    } finally {
      _reloadFuture = null;
    }
  }

  Future<void> _loadSummary(int request) async {
    if (!mounted || request != generation) return;
    if (selectedCurrency is SingleCurrency &&
        !currencies.contains(selectedCurrency)) {
      selectedCurrency = null;
    }
    // With a summary already up the cards stay as they are while it
    // reloads, so only the first load (or a retry) needs a rebuild here.
    if (summary == null || error != null) {
      setState(() {
        loading = true;
        error = null;
      });
    } else {
      loading = true;
    }
    if (widget.accountStore.loading ||
        widget.categoryStore.loading ||
        widget.transactionStore.loading ||
        widget.accountStore.saving ||
        widget.categoryStore.saving ||
        widget.transactionStore.saving ||
        widget.budgetStore.saving) {
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
      final database = widget.transactionStore.repository.database;
      final scope = currency;
      final result = await HomeRepository(database).loadScope(month, scope);
      if (!mounted || request != generation) return;
      final trends = await InsightsRepository(database).loadScope(month, scope);
      if (!mounted || request != generation) return;
      final budgets = scope is CombinedCurrency
          ? null
          : await widget.budgetStore.loadMonth(month, scope.code, scope.digits);
      if (!mounted || request != generation) return;
      setState(() {
        _loadedCurrency = scope;
        summary = result;
        insights = trends;
        budget = budgets;
        loading = false;
      });
    } catch (_) {
      if (!mounted || request != generation) return;
      setState(() {
        error = 'Your home summary could not be loaded.';
        loading = false;
      });
    }
  }

  Future<void> _retry() async {
    await _mainCurrency?.refresh(force: true);
    await Future.wait([
      widget.accountStore.load(),
      widget.categoryStore.load(),
      widget.transactionStore.load(),
    ]);
    await _reload();
  }

  Set<String> _missingCurrencies() {
    final scope = currency;
    final missing = <String>{};
    void check(String code, int digits) {
      if (scope.includes(code, digits) && !scope.hasRateFor(code)) {
        missing.add(code);
      }
    }

    for (final a in widget.accountStore.accounts) {
      check(a.currency, a.digits);
    }
    for (final l in widget.loanStore?.loans ?? []) {
      check(l.terms.currency, l.terms.digits);
    }
    for (final s in widget.recurringPaymentStore?.recurringPayments ?? []) {
      check(s.currency, s.digits);
    }
    for (final p in widget.debtStore?.people ?? []) {
      for (final e in p.entries) {
        check(e.currency, e.digits);
      }
    }
    return missing;
  }

  void _transactions() => widget.onOpenTransactions(month);
  void _changeMonth(DateTime value) {
    setState(() => month = DateTime(value.year, value.month));
    _reload();
  }

  Future<void> _pickMonth() async {
    if (_pickingMonth) return;
    setState(() => _pickingMonth = true);
    final picked = await showMonthPickerPopup(
      context,
      anchorKey: _monthAnchor,
      initialMonth: month,
    );
    if (!mounted) return;
    setState(() => _pickingMonth = false);
    if (picked != null) _changeMonth(picked);
  }

  /// The card [id] stands for, or null when it has nothing to show: what's
  /// due soon only matters while looking at the present, and the month's
  /// charts wait for its summary to load.
  Widget? _card(HomeCardId id, bool viewingPast, CurrencyScope currency) =>
      id == HomeCardId.smsHistory && !(widget.smsStore?.loaded ?? true)
      ? null
      : buildHomeCard(
          id,
          HomeCardContext(
            accountStore: widget.accountStore,
            categoryStore: widget.categoryStore,
            transactionStore: widget.transactionStore,
            loanStore: widget.loanStore,
            recurringPaymentStore: widget.recurringPaymentStore,
            debtStore: widget.debtStore,
            smsStore: widget.smsStore,
            onReviewSms: widget.onReviewSms,
            month: month,
            currency: currency,
            viewingPast: viewingPast,
            summary: error == null ? summary : null,
            insights: error == null ? insights : null,
            budget: budget,
            onOpenTransactions: _transactions,
            onOpenBudgets: () =>
                widget.onOpenBudgets(month, (currency.code, currency.digits)),
          ),
        );

  Widget? _balanceCards() {
    final sms = widget.smsStore;
    if (sms == null) return null;
    return BalanceMismatchCards(
      key: const ValueKey('balance-mismatches'),
      accountStore: widget.accountStore,
      categoryStore: widget.categoryStore,
      transactionStore: widget.transactionStore,
      smsStore: sms,
    );
  }

  @override
  Widget build(BuildContext context) {
    final layout = HomeLayoutScope.maybeOf(context) ?? _defaultLayout;
    final data = error == null ? summary : null;
    // Both walk every account; read them once for the whole frame.
    final singles = currencies;
    final scope = currency;
    final now = DateTime.now();
    final viewingPast = month.isBefore(DateTime(now.year, now.month));
    return StatusBarBlurScope(
      builder: (context, scrollController, topInset) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: RefreshIndicator(
            onRefresh: _retry,
            edgeOffset: topInset,
            child: ListView(
              controller: scrollController,
              padding: EdgeInsets.fromLTRB(
                18,
                topInset + 4,
                18,
                96 + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                HomeHeader(
                  month: month,
                  anchorKey: _monthAnchor,
                  picking: _pickingMonth,
                  onPickMonth: _pickMonth,
                  onOpenTransactions: _transactions,
                  themeMode: widget.themeMode,
                  onChangeThemeMode: widget.onChangeThemeMode,
                ),
                if (singles.length > 1)
                  CurrencyScopeBar(
                    accounts: widget.accountStore.accounts,
                    scope: scope,
                    combined: _combined,
                    singles: singles,
                    onChanged: (value) {
                      selectedCurrency = value;
                      _currencyChanged();
                    },
                  ),
                CurrencyNotice(
                  scope: scope,
                  missing: {
                    ...?summary?.missingCurrencies,
                    ...?insights?.missingCurrencies,
                    ..._missingCurrencies(),
                  },
                ),
                // Balance questions sit under Net savings, or lead the
                // page when that card is turned off.
                if (!layout.visible.contains(HomeCardId.overview))
                  ?_balanceCards(),
                // Every store change reloads the summary; keep the last one
                // up meanwhile rather than tearing the page down to a spinner.
                for (final id in layout.visible) ...[
                  if (_card(id, viewingPast, scope) case final card?)
                    _KeptCard(key: ValueKey(id), child: card),
                  if (id == HomeCardId.overview) ?_balanceCards(),
                ],
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: homeCardGap),
                    child: HomeCard(
                      child: Column(
                        children: [
                          Text(error!),
                          TextButton(
                            onPressed: _retry,
                            child: const Text('Try again'),
                          ),
                        ],
                      ),
                    ),
                  )
                else if (data == null && loading)
                  const Padding(
                    padding: EdgeInsets.only(top: homeCardGap),
                    child: HomeSkeleton(),
                  ),
                if (HomeLayoutScope.maybeOf(context) case final saved?)
                  Padding(
                    padding: const EdgeInsets.only(top: homeCardGap),
                    child: Center(
                      child: TextButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          FeatureRoute<void>(HomeLayoutScreen(layout: saved)),
                        ),
                        icon: const Icon(Icons.swap_vert_rounded, size: 18),
                        label: const Text('Arrange cards'),
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
}

/// Keeps a card built while it is scrolled out of view. Home has a dozen
/// cards at most, and rebuilding one as it scrolls back in (charts measure
/// their labels and replay their entrance) is what made the scroll stutter;
/// it also kept a revealed amount from staying revealed.
class _KeptCard extends StatefulWidget {
  const _KeptCard({super.key, required this.child});
  final Widget child;
  @override
  State<_KeptCard> createState() => _KeptCardState();
}

class _KeptCardState extends State<_KeptCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}
