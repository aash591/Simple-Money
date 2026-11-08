import '../components/transactions/transaction_day_group.dart';
import '../components/transactions/transaction_list_row.dart';

import 'dart:convert';

import 'package:flutter/material.dart';

import '../components/empty_art.dart';
import '../components/app_back_button.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/account.dart';
import '../../domain/category.dart';
import '../../domain/transaction.dart';
import '../../domain/transaction_preview.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import '../../state/transaction_store.dart';
import '../../state/main_currency_controller.dart';
import 'transaction_currency_sheet.dart';
import 'currency_summary_carousel.dart';
import '../components/app_icon.dart';
import '../components/info_guide.dart';
import '../components/common.dart';
import '../components/tab_header.dart';

import '../components/more_popup_button.dart';
import '../components/search_field.dart';
import '../components/private_amount.dart';
import '../components/sheet_scroll_indicator.dart';
import '../components/secondary_header.dart';
import '../components/skeleton.dart';
import '../components/transactions/filter_sheets.dart';
import '../components/transactions/period.dart';
import '../components/transactions/period_pager.dart';
import '../theme/app_theme.dart';
import 'adjust_balance_sheet.dart';
import 'transaction_sheet.dart';
import 'transaction_widgets.dart';
import 'transfer_sheet.dart';

typedef _RangeKind = PeriodKind;

typedef _TransactionFilter = TransactionTypeFilter;

enum _MenuAction {
  allPreview,
  readyPreview,
  range,
  filter,
  category,
  account,
  adjust,
  transfer,
  attention,
}

/// How a period's transactions are laid out: as the days they happened on,
/// or rolled up into the categories they were spent under.
enum _Grouping { date, category }

/// Supplies unsaved rows to the same browsing UI used by the ledger.
class TransactionPreview {
  const TransactionPreview({
    this.transactions = const [],
    this.load,
    this.revision = 0,
    required this.onOpen,
    required this.onRefresh,
    this.title = 'SMS preview',
    this.onUnassigned,
    this.loadUnassigned,
    this.needsAttentionIds = const {},
    this.guide,
  });
  final List<MoneyTransaction> transactions;
  final Future<TransactionPreviewData> Function(TransactionPreviewQuery)? load;
  final int revision;
  final ValueChanged<MoneyTransaction> onOpen;
  final Future<void> Function() onRefresh;
  final String title;
  final Set<int> needsAttentionIds;
  final Future<void> Function(String)? onUnassigned;
  final Future<Map<String, int>> Function()? loadUnassigned;

  /// Opened from an info button in the header.
  final InfoGuide? guide;
}

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({
    super.key,
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    required this.onAddTransaction,
    this.initialMonth,
    this.monthRequest = 0,
    this.parentHandlesBack = false,
    this.preview,
  });
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final VoidCallback onAddTransaction;
  final DateTime? initialMonth;
  final int monthRequest;
  final bool parentHandlesBack;
  final TransactionPreview? preview;

  @override
  TransactionsScreenState createState() => TransactionsScreenState();
}

class TransactionsScreenState extends State<TransactionsScreen>
    with TickerProviderStateMixin {
  static const _stripAnimationDuration = Duration(milliseconds: 280);
  static const _rangeKindPrefsKey = 'transactions_range_kind';
  static const _customRangeStartPrefsKey = 'transactions_custom_range_start';
  static const _customRangeEndPrefsKey = 'transactions_custom_range_end';

  /// How many of a category group's transactions show before it has to be
  /// expanded. Deep enough to read a category at a glance, short enough that
  /// one busy category can't bury the rest of the breakdown.
  static const _categoryPreviewCount = 10;

  /// The group key standing in for transfers, which have no category to group
  /// by. Negative, so it can never collide with a real category id.
  static const _transfersGroupKey = -1;

  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  /// The period on screen; the [PeriodPager] swipes it.
  final _period = PeriodController();
  _RangeKind get _rangeKind => _period.kind;
  DateTimeRange? get _customRange => _period.customRange;

  /// Period swipes belong to this screen unless its only page is All time.
  bool get allowsTabSwipe => _rangeKind == _RangeKind.all;

  _TransactionFilter _filter = _TransactionFilter.all;
  int? _accountId;
  int? _categoryId;
  _Grouping _grouping = _Grouping.date;

  /// The category groups the user has expanded past [_categoryPreviewCount].
  /// Kept across periods so paging doesn't collapse a category being read.
  final _expandedGroups = <int>{};
  bool _isSearch = false;
  bool _needsAttentionOnly = false;
  bool _readyToSaveOnly = true;
  String _query = '';

  /// Sticky across periods: paging from a month of riyal spending into one
  /// with riyals in it should stay on riyals rather than snapping back.
  /// Dropped when it isn't among a period's currencies, and when the account
  /// filter changes and decides the currency on its own.
  TransactionCurrency? _chosenCurrency;

  /// Per-frame memo for [_currenciesFor], whose scan is O(transactions) and is
  /// otherwise repeated for the balance card and for every live page.
  final _currencyOptions = <DateTimeRange, List<TransactionCurrency>>{};

  /// Per-frame memo for [_currencyFor], which falls back to a second
  /// O(transactions) scan to pick the period's most-used currency.
  final _currencyChoice = <DateTimeRange, TransactionCurrency>{};

  TransactionCurrency _accountCurrency(Account account) =>
      (account.currency, account.digits);
  List<MoneyTransaction> get _transactions =>
      widget.preview?.transactions ?? widget.transactionStore.transactions;
  Future<void> _refresh() =>
      widget.preview?.onRefresh() ?? widget.transactionStore.load();

  List<TransactionCurrency> _currenciesFor(DateTimeRange range) =>
      _currencyOptions[range] ??= _computeCurrenciesFor(range);

  List<TransactionCurrency> _computeCurrenciesFor(DateTimeRange range) {
    final account = _selectedAccount;
    if (account != null) return [_accountCurrency(account)];
    final databaseCurrencies = _previewPeriodData[range]?.currencies.keys
        .toList();
    if (databaseCurrencies != null && databaseCurrencies.isNotEmpty) {
      return databaseCurrencies;
    }
    final used = <TransactionCurrency>{};
    for (final transaction in _periodTransactionsFor(range)) {
      for (final id in [transaction.accountId, transaction.toAccountId]) {
        final account = _accountById(id);
        if (account != null) used.add(_accountCurrency(account));
      }
    }
    // Empty periods still have balances, but no currency choice is needed.
    if (used.isEmpty) {
      final accounts = widget.accountStore.accounts;
      final main = MainCurrencyScope.maybeOf(context);
      final preferred = (main?.code ?? 'INR', main?.digits ?? 2);
      return [
        accounts.isEmpty ||
                accounts.any((a) => _accountCurrency(a) == preferred)
            ? preferred
            : _accountCurrency(accounts.first),
      ];
    }
    return used.toList()..sort((a, b) => a.$1.compareTo(b.$1));
  }

  TransactionCurrency _currencyFor(DateTimeRange range) =>
      _currencyChoice[range] ??= _computeCurrencyFor(range);

  TransactionCurrency _computeCurrencyFor(DateTimeRange range) {
    final options = _currenciesFor(range);
    if (options.contains(_chosenCurrency)) return _chosenCurrency!;
    final main = MainCurrencyScope.maybeOf(context);
    final preferred = (main?.code ?? 'INR', main?.digits ?? 2);
    if (options.contains(preferred)) return preferred;
    final databaseCounts = _previewPeriodData[range]?.currencies;
    if (databaseCounts != null && databaseCounts.isNotEmpty) {
      return options.reduce(
        (a, b) => (databaseCounts[b] ?? 0) > (databaseCounts[a] ?? 0) ? b : a,
      );
    }
    final counts = <TransactionCurrency, int>{};
    for (final transaction in _periodTransactionsFor(range)) {
      final currencies = <TransactionCurrency>{};
      for (final id in [transaction.accountId, transaction.toAccountId]) {
        final account = _accountById(id);
        if (account != null) currencies.add(_accountCurrency(account));
      }
      for (final currency in currencies) {
        counts.update(currency, (n) => n + 1, ifAbsent: () => 1);
      }
    }
    return options.reduce(
      (a, b) => (counts[b] ?? 0) > (counts[a] ?? 0) ? b : a,
    );
  }

  bool _matchesCurrency(
    MoneyTransaction transaction,
    TransactionCurrency currency,
  ) {
    final account = _accountById(transaction.accountId);
    return account != null && _accountCurrency(account) == currency;
  }

  @override
  void initState() {
    super.initState();
    _previewReferenceSignature = _referenceSignature();
    _loadDraftCategories();
    _period.addListener(_onPeriodChanged);
    widget.accountStore.addListener(_onStoreChanged);
    widget.categoryStore.addListener(_onStoreChanged);
    widget.transactionStore.addListener(_onTransactionStoreChanged);
    if (widget.preview != null) {
      _period.select(PeriodKind.month, anchor: widget.initialMonth);
      _grouping = _Grouping.category;
      if (widget.preview!.load != null) _readyToSaveOnly = false;
    } else if (widget.initialMonth != null) {
      _period.select(PeriodKind.month, anchor: widget.initialMonth);
    } else {
      _restoreSavedRange();
    }
  }

  void _onPeriodChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant TransactionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.preview?.revision != oldWidget.preview?.revision) {
      _previewLoads.clear();
      _previewQueryCache.clear();
      _previewPeriodData.clear();
      _previewDateLimits.clear();
    }
    if (widget.monthRequest != oldWidget.monthRequest &&
        widget.initialMonth != null) {
      _filter = _TransactionFilter.all;
      _accountId = null;
      _categoryId = null;
      _grouping = _Grouping.date;
      _expandedGroups.clear();
      _query = '';
      _isSearch = false;
      _searchFocus.unfocus();
      _searchController.clear();
      _period.select(PeriodKind.month, anchor: widget.initialMonth);
    }
  }

  /// Restores the range kind (and custom range, if that was last selected)
  /// the user picked last time, so the screen doesn't always reset to Month.
  Future<void> _restoreSavedRange() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || widget.initialMonth != null) return;
    final savedName = prefs.getString(_rangeKindPrefsKey);
    if (savedName == null) return;
    _RangeKind? saved;
    for (final kind in _RangeKind.values) {
      if (kind.name == savedName) {
        saved = kind;
        break;
      }
    }
    if (saved == null || saved == _rangeKind) return;
    DateTimeRange? customRange;
    if (saved == _RangeKind.custom) {
      final startText = prefs.getString(_customRangeStartPrefsKey);
      final endText = prefs.getString(_customRangeEndPrefsKey);
      if (startText != null && endText != null) {
        customRange = DateTimeRange(
          start: DateTime.parse(startText),
          end: DateTime.parse(endText),
        );
      } else {
        saved = _RangeKind.month;
      }
    }
    _period.select(saved, customRange: customRange);
  }

  Future<void> _saveRangePreference() async {
    if (_isSearch || widget.preview != null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_rangeKindPrefsKey, _rangeKind.name);
    final customRange = _customRange;
    if (_rangeKind == _RangeKind.custom && customRange != null) {
      await prefs.setString(
        _customRangeStartPrefsKey,
        customRange.start.toIso8601String(),
      );
      await prefs.setString(
        _customRangeEndPrefsKey,
        customRange.end.toIso8601String(),
      );
    } else {
      await prefs.remove(_customRangeStartPrefsKey);
      await prefs.remove(_customRangeEndPrefsKey);
    }
  }

  @override
  void dispose() {
    widget.accountStore.removeListener(_onStoreChanged);
    widget.categoryStore.removeListener(_onStoreChanged);
    widget.transactionStore.removeListener(_onTransactionStoreChanged);
    _searchController.dispose();
    _searchFocus.dispose();
    _period
      ..removeListener(_onPeriodChanged)
      ..dispose();
    super.dispose();
  }

  void _onStoreChanged() {
    _loadDraftCategories();
    if (!mounted) return;
    final signature = _referenceSignature();
    if (widget.preview == null || signature != _previewReferenceSignature) {
      _previewLoads.clear();
      _previewQueryCache.clear();
      _previewPeriodData.clear();
    }
    _previewReferenceSignature = signature;
    // The checks below read the stores, so drop last frame's indexes first.
    _accountIndex = null;
    _categoryIndex = null;
    if (_categoryId != null && _categoryById(_categoryId) == null) {
      _categoryId = null;
    }
    if (_accountId != null &&
        !widget.accountStore.accounts.any((a) => a.id == _accountId)) {
      _accountId = null;
    }
    setState(() {});
  }

  void _onTransactionStoreChanged() {
    // Ledger reloads (including foreground sync) do not change the temporary
    // SMS review index. Ignoring them here keeps the preview's SQL page and
    // aggregate results warm while switching apps.
    if (widget.preview != null) return;
    _onStoreChanged();
  }

  String? _previewReferenceSignature;
  String? _referenceSignature() => widget.preview == null
      ? null
      : jsonEncode([
          for (final account in widget.accountStore.allAccounts)
            [
              account.id,
              account.name,
              account.currency,
              account.digits,
              account.type.name,
              account.isArchived,
            ],
          for (final category in widget.categoryStore.categories)
            [category.id, category.name, category.type.name, category.parentId],
        ]);

  Account? get _selectedAccount => _accountById(_accountId);

  /// Indexed for the same reason as [_accountById]: the period totals ask for
  /// every transaction's category to tell debt movements from real spending.
  Category? _categoryById(int? id) => (_categoryIndex ??= {
    for (final category in _displayCategories) category.id: category,
  })[id];

  Map<int, Category>? _categoryIndex;
  List<Category>? _draftCategories;
  List<Category> get _displayCategories => widget.preview != null
      ? (_draftCategories ?? widget.categoryStore.categories)
      : widget.categoryStore.categories;
  Future<void> _loadDraftCategories() async {
    if (widget.preview == null) return;
    final categories = await widget.categoryStore.repository.load(
      includeDrafts: true,
    );
    if (!mounted) return;
    setState(() {
      _draftCategories = categories;
      _categoryIndex = null;
    });
  }

  /// Indexed rather than scanned: the currency totals look an account up once
  /// per transaction, and `accountStore.allAccounts` allocates a fresh
  /// unmodifiable view on every read, so a linear search here copies the list
  /// per lookup. Rebuilt per frame, which is as often as the store can change
  /// under it. Archived accounts are in the index because their transactions
  /// are still listed; the filter strip above is built from the active list.
  Account? _accountById(int? id) => (_accountIndex ??= {
    for (final account in widget.accountStore.allAccounts) account.id: account,
  })[id];

  Map<int, Account>? _accountIndex;

  DateTimeRange get _activeRange => _period.range;

  bool _isInRange(DateTime date, DateTimeRange range) {
    final value = DateTime(date.year, date.month, date.day);
    return !value.isBefore(range.start) && !value.isAfter(range.end);
  }

  bool _inAccountScope(MoneyTransaction transaction) =>
      _accountId == null ||
      transaction.accountId == _accountId ||
      transaction.toAccountId == _accountId;

  bool _matchesFilter(MoneyTransaction transaction) => switch (_filter) {
    _TransactionFilter.all => true,
    _TransactionFilter.expense => transaction.type == TransactionType.expense,
    _TransactionFilter.income => transaction.type == TransactionType.income,
    _TransactionFilter.transfer => transaction.type == TransactionType.transfer,
  };

  bool _matchesQuery(MoneyTransaction transaction) {
    final query = _query.trim().toLowerCase();
    if (query.isEmpty) return true;
    final category = _categoryById(transaction.categoryId);
    final parent = _categoryById(category?.parentId);
    final from = _accountById(transaction.accountId)?.name ?? '';
    final to = _accountById(transaction.toAccountId)?.name ?? '';
    final amount = _formatTransactionAmount(transaction);
    return [
      transaction.title,
      transaction.note,
      category?.name,
      parent?.name,
      from,
      to,
      amount,
      amount.replaceAll(',', ''),
    ].whereType<String>().any((value) => value.toLowerCase().contains(query));
  }

  List<MoneyTransaction> _periodTransactionsFor(DateTimeRange range) =>
      _transactions
          .where(
            (transaction) =>
                _isInRange(transaction.date, range) &&
                _inAccountScope(transaction),
          )
          .toList();

  List<MoneyTransaction> _visibleFrom(List<MoneyTransaction> period) => period
      .where(
        (transaction) =>
            (!_needsAttentionOnly ||
                (widget.preview?.needsAttentionIds.contains(transaction.id) ??
                    false)) &&
            (widget.preview == null ||
                !_readyToSaveOnly ||
                !(widget.preview?.needsAttentionIds.contains(transaction.id) ??
                    false)) &&
            _matchesFilter(transaction) &&
            (_categoryId == null ||
                transaction.categoryId == _categoryId ||
                _categoryById(transaction.categoryId)?.parentId ==
                    _categoryId) &&
            _matchesQuery(transaction),
      )
      .toList();

  int _accountDelta(
    MoneyTransaction transaction,
    TransactionCurrency currency,
  ) {
    if (transaction.type == TransactionType.transfer) {
      bool includes(int? id) {
        final account = _accountById(id);
        return account != null &&
            (_accountId == null || id == _accountId) &&
            _accountCurrency(account) == currency;
      }

      // Each leg moves its own account's figure: across currencies, and when
      // a charge was taken, what arrived is not what was sent.
      return (includes(transaction.accountId) ? -transaction.amountMinor : 0) +
          (includes(transaction.toAccountId) ? transaction.receivedMinor : 0);
    }
    if (!_matchesCurrency(transaction, currency)) return 0;
    if (_accountId == null) {
      return switch (transaction.type) {
        TransactionType.expense => -transaction.amountMinor,
        TransactionType.income => transaction.amountMinor,
        TransactionType.transfer => 0,
      };
    }
    return switch (transaction.type) {
      TransactionType.expense =>
        transaction.accountId == _accountId ? -transaction.amountMinor : 0,
      TransactionType.income =>
        transaction.accountId == _accountId ? transaction.amountMinor : 0,
      // Unreachable: transfers returned above, before the currency check.
      TransactionType.transfer => 0,
    };
  }

  int _currentBalance(TransactionCurrency currency) => _accountId == null
      ? widget.accountStore.accounts
            .where((a) => _accountCurrency(a) == currency)
            .fold(0, (sum, account) => sum + account.balanceMinor)
      : (_selectedAccount?.balanceMinor ?? 0);

  int _endingBalanceFor(DateTimeRange range, TransactionCurrency currency) {
    var balance = _currentBalance(currency);
    for (final transaction in _transactions) {
      final day = DateTime(
        transaction.date.year,
        transaction.date.month,
        transaction.date.day,
      );
      if (day.isAfter(range.end)) {
        balance -= _accountDelta(transaction, currency);
      }
    }
    return balance;
  }

  /// Debts move balances but are neither income nor spending.
  bool _isDebt(MoneyTransaction transaction) =>
      _categoryById(transaction.categoryId)?.isDebtLoan ?? false;

  int _totalOf(
    List<MoneyTransaction> periodTransactions,
    TransactionCurrency currency,
    TransactionType type,
  ) => periodTransactions
      .where(
        (transaction) =>
            transaction.type == type &&
            _matchesCurrency(transaction, currency) &&
            !_isDebt(transaction) &&
            (_accountId == null || transaction.accountId == _accountId),
      )
      .fold(0, (sum, transaction) => sum + transaction.amountMinor);

  int _incomeFrom(
    List<MoneyTransaction> periodTransactions,
    TransactionCurrency currency,
  ) => _totalOf(periodTransactions, currency, TransactionType.income);

  int _expensesFrom(
    List<MoneyTransaction> periodTransactions,
    TransactionCurrency currency,
  ) => _totalOf(periodTransactions, currency, TransactionType.expense);

  String _money(int amount, TransactionCurrency currency) =>
      formatAccountMoney(amount, digits: currency.$2, currency: currency.$1);

  /// A day header's side of the total, or null when there is nothing to show.
  String? _dayTotal(int amount, TransactionCurrency currency) =>
      amount == 0 ? null : _money(amount, currency);

  Future<void> _selectRange() async {
    if (await pickPeriod(context, _period)) _saveRangePreference();
  }

  Future<void> _selectFilter() async {
    final selected = await pickTypeFilter(
      context,
      selected: _filter,
      title: _grouping == _Grouping.category
          ? 'View by transaction'
          : 'Filter by type',
    );
    if (selected != null && mounted) {
      setState(() {
        _filter = selected;
        // Picking a transaction view is how you leave the category breakdown.
        _grouping = _Grouping.date;
      });
    }
  }

  Future<void> _selectAccount() async {
    Map<String, int> unassigned = {};
    try {
      unassigned = await widget.preview?.loadUnassigned?.call() ?? {};
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not load unassigned accounts. Please try again.',
            ),
          ),
        );
    }
    if (!mounted) return;
    final selection = await pickAccountFilter(
      context,
      accounts: widget.accountStore.accounts,
      selected: _accountId,
      unassigned: unassigned,
    );
    if (selection?.unassigned != null && mounted) {
      await widget.preview?.onUnassigned?.call(selection!.unassigned!);
      return;
    }
    if (selection != null && mounted) {
      setState(() {
        _accountId = selection.id;
        // The account decides the currency; any earlier pick is stale.
        _chosenCurrency = null;
      });
    }
  }

  Future<void> _selectCategory() async {
    final selection = await pickCategoryFilter(
      context,
      categories: _displayCategories.toList(),
      selected: _categoryId,
      title: _grouping == _Grouping.category
          ? 'Filter by category'
          : 'View by category',
      startOnIncome: _filter == _TransactionFilter.income,
    );
    if (selection != null && mounted) {
      setState(() {
        _categoryId = selection.$1;
        _grouping = _Grouping.category;
        _expandedGroups.clear();
      });
    }
  }

  Future<void> _onMenuAction(_MenuAction action) async {
    switch (action) {
      case _MenuAction.allPreview:
        setState(() {
          _needsAttentionOnly = false;
          _readyToSaveOnly = false;
        });
        return;
      case _MenuAction.readyPreview:
        setState(() {
          _needsAttentionOnly = false;
          _readyToSaveOnly = true;
        });
        return;
      case _MenuAction.attention:
        setState(() {
          if (widget.preview?.load != null) {
            _needsAttentionOnly = true;
            _readyToSaveOnly = false;
          } else {
            _needsAttentionOnly = !_needsAttentionOnly;
            _readyToSaveOnly = !_needsAttentionOnly;
          }
        });
        return;
      case _MenuAction.range:
        await _selectRange();
      case _MenuAction.filter:
        await _selectFilter();
      case _MenuAction.category:
        await _selectCategory();
      case _MenuAction.account:
        await _selectAccount();
      case _MenuAction.adjust:
        await showAdjustBalanceSheet(
          context,
          accountStore: widget.accountStore,
          transactionStore: widget.transactionStore,
        );
      case _MenuAction.transfer:
        await showTransferSheet(
          context,
          accountStore: widget.accountStore,
          transactionStore: widget.transactionStore,
        );
    }
  }

  Future<void> _openTransaction(MoneyTransaction transaction) async {
    final preview = widget.preview;
    if (preview != null) {
      preview.onOpen(transaction);
      return;
    }
    await showViewTransactionSheet(
      context,
      transaction: transaction,
      accountStore: widget.accountStore,
      categoryStore: widget.categoryStore,
      transactionStore: widget.transactionStore,
    );
  }

  void _openSearch() {
    setState(() => _isSearch = true);
    _searchFocus.requestFocus();
  }

  void _cancelSearch() {
    _searchFocus.unfocus();
    setState(() {
      _isSearch = false;
      _query = '';
      _searchController.clear();
    });
  }

  /// Returns true when back was consumed by the search UI.
  bool handleBack() {
    if (!_isSearch) return false;
    _cancelSearch();
    return true;
  }

  @override
  Widget build(BuildContext context) {
    // Stores and filters hold still for the duration of a frame.
    _currencyOptions.clear();
    _currencyChoice.clear();
    _accountIndex = null;
    _categoryIndex = null;
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 320);
    return PopScope(
      canPop: widget.parentHandlesBack || !_isSearch,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) handleBack();
      },
      child: SafeArea(
        top: widget.preview == null,
        bottom: false,
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: Column(
              children: [
                SearchableHeader(
                  searching: _isSearch,
                  controller: _searchController,
                  focusNode: _searchFocus,
                  fieldKey: const Key('transaction-search'),
                  hintText: 'Search transactions',
                  onChanged: (value) => setState(() => _query = value),
                  onCancel: _cancelSearch,
                  header: Padding(
                    padding: widget.preview != null
                        ? EdgeInsets.zero
                        : const EdgeInsets.fromLTRB(
                            TabHeader.sideMargin,
                            4,
                            TabHeader.sideMargin,
                            0,
                          ),
                    child: _buildHeader(context),
                  ),
                ),
                if (widget.preview == null)
                  AnimatedPadding(
                    duration: duration,
                    curve: Curves.easeInOutCubic,
                    padding: EdgeInsets.fromLTRB(18, _isSearch ? 0 : 4, 18, 0),
                    child: Column(
                      children: [
                        ClipRect(
                          child: AnimatedSize(
                            duration: duration,
                            curve: Curves.easeInOutCubic,
                            alignment: Alignment.topCenter,
                            child: _isSearch
                                ? const SizedBox(width: double.infinity)
                                : widget.preview != null
                                ? const SizedBox.shrink()
                                : _buildBalanceHeader(context),
                          ),
                        ),
                        AnimatedContainer(
                          duration: duration,
                          curve: Curves.easeInOutCubic,
                          height: _isSearch ? 0 : 4,
                        ),
                      ],
                    ),
                  ),
                Expanded(
                  child: PeriodPager(
                    controller: _period,
                    onSelectRange: _selectRange,
                    pageBuilder: _buildPeriodPage,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  final _previewLoads =
      <DateTimeRange, (Object, Future<TransactionPreviewData>)>{};
  final _previewQueryCache = <Object, Future<TransactionPreviewData>>{};
  final _previewPeriodData = <DateTimeRange, TransactionPreviewData>{};
  final _previewDateLimits = <DateTimeRange, int>{};

  Widget _buildPeriodPage(BuildContext context, DateTime anchor) {
    final range = _period.rangeAt(anchor);
    final loader = widget.preview?.load;
    if (loader == null) return _buildPeriodContents(context, range);
    final expanded = _expandedGroups.toList()..sort();
    final limit = _previewDateLimits[range] ?? 50;
    final key = (
      range,
      _query,
      _filter,
      _accountId,
      _categoryId,
      _needsAttentionOnly,
      _readyToSaveOnly,
      _grouping,
      expanded.join(','),
      limit,
      widget.preview!.revision,
    );
    var request = _previewLoads[range];
    if (request == null || request.$1 != key) {
      request = (
        key,
        _previewQueryCache.putIfAbsent(
          key,
          () => loader(
            TransactionPreviewQuery(
              start: range.start,
              end: DateTime(range.end.year, range.end.month, range.end.day + 1),
              ready: _needsAttentionOnly
                  ? false
                  : _readyToSaveOnly
                  ? true
                  : null,
              byCategory: _grouping == _Grouping.category,
              search: _query,
              type: _filter == _TransactionFilter.all ? null : _filter.name,
              accountId: _accountId,
              categoryId: _categoryId,
              expandedGroups: Set.of(_expandedGroups),
              limit: limit,
            ),
          ),
        ),
      );
      // Remember recently used filters without retaining an unbounded inbox.
      while (_previewQueryCache.length > 12) {
        _previewQueryCache.remove(_previewQueryCache.keys.first);
      }
      _previewLoads[range] = request;
      // Keep only neighboring periods, including when browsing years of SMS.
      while (_previewLoads.length > 3) {
        final oldest = _previewLoads.keys.first;
        _previewLoads.remove(oldest);
        _previewPeriodData.remove(oldest);
        _previewDateLimits.remove(oldest);
      }
    }
    return FutureBuilder<TransactionPreviewData>(
      future: request.$2,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return _ErrorState(
            message: 'Could not load bank messages. Please try again.',
            onRetry: () async {
              _previewQueryCache.remove(key);
              setState(() => _previewLoads.remove(range));
            },
          );
        }
        final data = snapshot.data;
        if (data == null) return const SkeletonList();
        _previewPeriodData[range] = data;
        _currencyOptions.remove(range);
        _currencyChoice.remove(range);
        return NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (_grouping == _Grouping.date &&
                notification.depth == 0 &&
                notification.metrics.axis == Axis.vertical &&
                notification.metrics.extentAfter < 400 &&
                snapshot.connectionState == ConnectionState.done &&
                data.transactions.length < data.count &&
                limit == (_previewDateLimits[range] ?? 50)) {
              // Scroll seamlessly through database pages using the same list.
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted && limit == (_previewDateLimits[range] ?? 50)) {
                  setState(() => _previewDateLimits[range] = limit + 50);
                }
              });
            }
            return false;
          },
          child: _buildPeriodContents(context, range, data: data),
        );
      },
    );
  }

  Widget _buildPeriodContents(
    BuildContext context,
    DateTimeRange range, {
    TransactionPreviewData? data,
  }) {
    final periodTransactions =
        data?.transactions ?? _periodTransactionsFor(range);
    final visible = data == null
        ? _visibleFrom(periodTransactions)
        : periodTransactions;
    final currency = _currencyFor(range);
    // The list itself shows the newest transactions first and takes more as
    // it is scrolled, so a wide range such as All time never lays out (or
    // even groups) thousands of rows at once. Totals above it still cover the
    // whole period.
    final signature = (
      _rangeKind,
      _query,
      _filter,
      _accountId,
      _categoryId,
      _grouping,
      _needsAttentionOnly,
      _readyToSaveOnly,
    );
    if (signature != _shownSignature) {
      _shownSignature = signature;
      _shownLimits.clear();
    }
    final shown = _shownLimits[range] ?? _pageSize;
    final paged = data == null && _grouping == _Grouping.date;
    final listed = paged ? _newestFirst(visible, shown) : visible;
    final hasMore = paged && listed.length < visible.length;
    final byDate = _grouping == _Grouping.date
        ? data == null
              ? _groupTransactions(listed)
              : [
                  for (final group in data.groups)
                    _DatedTransactions(
                      group.date!,
                      group.transactions,
                      totals: group.totals[currency],
                    ),
                ]
        : const <_DatedTransactions>[];
    final byCategory = _grouping == _Grouping.category
        ? data == null
              ? _groupByCategory(visible, currency)
              : [
                  for (final group in data.groups)
                    _CategorizedTransactions(
                      key: group.categoryId ?? _transfersGroupKey,
                      category: _categoryById(group.categoryId),
                      transactions: group.transactions,
                      count: group.count,
                      income: group.totals[currency]?.$1 ?? 0,
                      expenses: group.totals[currency]?.$2 ?? 0,
                    ),
                ]
        : const <_CategorizedTransactions>[];
    if (data != null && _grouping == _Grouping.category) {
      byCategory.sort((a, b) {
        if ((a.category == null) != (b.category == null)) {
          return a.category == null ? 1 : -1;
        }
        final amount = b.magnitude.compareTo(a.magnitude);
        return amount != 0 ? amount : a.label.compareTo(b.label);
      });
    }
    if (data != null && _grouping == _Grouping.date) {
      byDate.sort((a, b) => b.date.compareTo(a.date));
    }
    // How many transactions precede each day, to tell how far down the list
    // a day is.
    final starts = <int>[];
    var running = 0;
    for (final group in byDate) {
      starts.add(running);
      running += group.transactions.length;
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: SheetScrollIndicator(
        child: CustomScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          slivers: [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
              sliver: SliverToBoxAdapter(
                child: Column(
                  children: [
                    _buildFlowSummary(
                      context,
                      range,
                      _isSearch ? visible : periodTransactions,
                    ),
                    if (_categoryId != null) ...[
                      const SizedBox(height: 14),
                      _buildCategoryHeader(
                        context,
                        visible,
                        currency,
                        data: data,
                      ),
                    ],
                    const SizedBox(height: 22),
                  ],
                ),
              ),
            ),
            if (widget.preview == null && widget.transactionStore.loading)
              const SliverPadding(
                padding: EdgeInsets.symmetric(horizontal: 18),
                sliver: SliverToBoxAdapter(child: SkeletonCards()),
              )
            else if (widget.preview == null &&
                widget.transactionStore.loadError != null)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _ErrorState(
                  message: widget.transactionStore.loadError!,
                  onRetry: widget.transactionStore.load,
                ),
              )
            else if (visible.isEmpty && widget.preview != null)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(child: Text('No SMS transactions in this view.')),
              )
            else if (visible.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyState(
                  filtered:
                      _query.isNotEmpty ||
                      _filter != _TransactionFilter.all ||
                      _categoryId != null,
                  onAdd: widget.onAddTransaction,
                ),
              )
            else if (_grouping == _Grouping.category)
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: 100 + MediaQuery.paddingOf(context).bottom,
                ),
                sliver: SliverList.builder(
                  itemCount: byCategory.length,
                  itemBuilder: (context, index) =>
                      _buildCategoryGroup(context, byCategory[index], currency),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom: 100 + MediaQuery.paddingOf(context).bottom,
                ),
                sliver: SliverList.builder(
                  itemCount: byDate.length,
                  itemBuilder: (context, index) {
                    // Past the middle of what is loaded, take the next page
                    // before the end is reached.
                    if (hasMore && starts[index] >= shown - _pageSize ~/ 2) {
                      _showMore(range, shown);
                    }
                    return _TransactionGroup(
                      date: byDate[index].date,
                      transactions: byDate[index].transactions,
                      // A day whose only activity was in another currency — or
                      // a day of transfers alone — has nothing to total here,
                      // and a row of zeroes reads as a figure rather than as
                      // an absence.
                      income: _dayTotal(
                        byDate[index].totals?.$1 ??
                            _incomeFrom(byDate[index].transactions, currency),
                        currency,
                      ),
                      expenses: _dayTotal(
                        byDate[index].totals?.$2 ??
                            _expensesFrom(byDate[index].transactions, currency),
                        currency,
                      ),
                      accountById: _accountById,
                      categoryById: _categoryById,
                      formatAmount: _formatTransactionAmount,
                      onOpen: _openTransaction,
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    if (widget.preview != null) {
      return SecondaryHeader(
        title: _needsAttentionOnly
            ? 'Needs attention'
            : _readyToSaveOnly
            ? 'Ready to save transactions'
            : widget.preview!.title,
        leading: Navigator.of(context).canPop() ? const AppBackButton() : null,
        titleStyle: const TextStyle(fontSize: 16),
        actions: [
          if (widget.preview!.guide case final guide? when !_isSearch)
            InfoGuideButton(guide),
          if (!_isSearch)
            AppSearchButton(
              tooltip: 'Search transactions',
              onPressed: _openSearch,
            ),
          _buildOptions(),
        ],
      );
    }
    return TabHeader(
      title: 'Transactions',
      roundActions: true,
      actions: [
        if (!_isSearch)
          AppSearchButton(
            tooltip: 'Search transactions',
            onPressed: _openSearch,
          ),
        _buildOptions(),
      ],
    );
  }

  /// Only the view you are *not* in is offered as a view to switch to; the
  /// one you are already in is what it actually does from here — a filter on
  /// the list in front of you — and is labelled as such.
  Widget _buildOptions() => MorePopupButton<_MenuAction>(
    tooltip: _isSearch ? 'Search options' : 'Transaction options',
    onSelected: _onMenuAction,
    items: [
      if (widget.preview?.load != null) ...[
        if (_readyToSaveOnly || _needsAttentionOnly)
          const MorePopupItem(
            value: _MenuAction.allPreview,
            label: 'All transactions',
          ),
        MorePopupItem(
          value: _needsAttentionOnly
              ? _MenuAction.readyPreview
              : _MenuAction.attention,
          label: _needsAttentionOnly ? 'Ready to save' : 'Needs attention',
        ),
      ] else if (widget.preview != null)
        MorePopupItem(
          value: _MenuAction.attention,
          label: _needsAttentionOnly ? 'Ready to save' : 'Needs attention',
        ),
      MorePopupItem(value: _MenuAction.range, label: 'Select time range'),
      if (_grouping == _Grouping.category) ...[
        MorePopupItem(value: _MenuAction.filter, label: 'View by transaction'),
        MorePopupItem(value: _MenuAction.category, label: 'Filter by category'),
      ] else ...[
        MorePopupItem(value: _MenuAction.category, label: 'View by category'),
        MorePopupItem(value: _MenuAction.filter, label: 'Filter by type'),
      ],
      if (_isSearch || widget.preview != null)
        const MorePopupItem(
          value: _MenuAction.account,
          label: 'Select account',
        ),
      if (!_isSearch && widget.preview == null)
        MorePopupItem(
          value: _MenuAction.adjust,
          label: 'Adjust balance',
          dividerBefore: true,
        ),
      if (!_isSearch && widget.preview == null)
        MorePopupItem(value: _MenuAction.transfer, label: 'Transfer money'),
    ],
  );

  Widget _buildBalanceHeader(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final account = _selectedAccount;
    final currency = _currencyFor(_activeRange);
    final mixed =
        widget.accountStore.accounts.map(_accountCurrency).toSet().length > 1;
    return Container(
      constraints: const BoxConstraints(minHeight: 56),
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account == null
                      ? (mixed ? 'Balance · ${currency.$1}' : 'Total balance')
                      : '${account.name} balance',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                PrivateAmount(
                  height: 40,
                  label: account == null
                      ? (mixed
                            ? 'Balance \u00b7 ${currency.$1}'
                            : 'Total balance')
                      : '${account.name} balance',
                  maskStyle: TextStyle(
                    color: scheme.primary,
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                  ),
                  key: ValueKey((account?.id, currency)),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _money(_currentBalance(currency), currency),
                      style: TextStyle(
                        color: scheme.primary,
                        fontSize: 28,
                        fontWeight: FontWeight.w600,
                        letterSpacing: -0.4,
                      ),
                      maxLines: 1,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 140),
            child: TextButton(
              key: const Key('transaction-account-filter'),
              onPressed: _selectAccount,
              style: TextButton.styleFrom(
                backgroundColor: scheme.surface,
                foregroundColor: scheme.onSurfaceVariant,
                elevation: 1.5,
                shadowColor: Colors.black.withValues(alpha: .16),
                surfaceTintColor: Colors.transparent,
                minimumSize: const Size(48, 34),
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 7,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                tapTargetSize: MaterialTapTargetSize.padded,
                visualDensity: VisualDensity.standard,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  account == null
                      ? const AllAccountsIcon(size: 20)
                      : AppIcon(account.icon, size: 20),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      account?.name ?? 'All accounts',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: scheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFlowSummary(
    BuildContext context,
    DateTimeRange range,
    List<MoneyTransaction> periodTransactions,
  ) {
    final options = _currenciesFor(range);
    if (options.length == 1 || _accountId != null) {
      return _buildCurrencyCard(
        context,
        range,
        periodTransactions,
        _currencyFor(range),
      );
    }
    return CurrencySummaryCarousel(
      key: ValueKey((range, _accountId, options.join(','))),
      selectedIndex: options.indexOf(_currencyFor(range)),
      onChanged: (index) => setState(() => _chosenCurrency = options[index]),
      children: [
        for (var i = 0; i < options.length; i++)
          _buildCurrencyCard(
            context,
            range,
            periodTransactions,
            options[i],
            position: '${i + 1} / ${options.length}',
          ),
      ],
    );
  }

  Widget _buildCurrencyCard(
    BuildContext context,
    DateTimeRange range,
    List<MoneyTransaction> periodTransactions,
    TransactionCurrency currency, {
    String? position,
  }) {
    final mixed = position != null;
    final ending = _endingBalanceFor(range, currency);
    final opening =
        ending -
        periodTransactions.fold<int>(
          0,
          (sum, transaction) => sum + _accountDelta(transaction, currency),
        );
    final databaseTotals = _isSearch
        ? _previewPeriodData[range]?.filteredSummary[currency]
        : _previewPeriodData[range]?.summary[currency];
    final income =
        databaseTotals?.$1 ?? _incomeFrom(periodTransactions, currency);
    final expenses =
        databaseTotals?.$2 ?? _expensesFrom(periodTransactions, currency);
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Column(
        children: [
          if (mixed) ...[
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Summary · ${currency.$1}',
                    style: Theme.of(context).textTheme.titleSmall
                        ?.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  position,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
          ],
          ClipRect(
            child: AnimatedSize(
              duration: _stripAnimationDuration,
              curve: Curves.easeInOutCubic,
              alignment: Alignment.topCenter,
              child: _isSearch || widget.preview != null
                  ? const SizedBox(width: double.infinity)
                  : Column(
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: _BalanceMetric(
                                'Opening balance',
                                _money(opening, currency),
                              ),
                            ),
                            Container(
                              height: 26,
                              width: 1,
                              color: Theme.of(context).dividerColor,
                            ),
                            Expanded(
                              child: _BalanceMetric(
                                'Closing balance',
                                _money(ending, currency),
                                alignEnd: true,
                              ),
                            ),
                          ],
                        ),
                        const Divider(height: 14),
                      ],
                    ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: _FlowMetric(
                  label: 'Money in',
                  value: _money(income, currency),
                  icon: Icons.arrow_downward_rounded,
                  color: green,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _FlowMetric(
                  label: 'Money out',
                  value: _money(expenses, currency),
                  icon: Icons.arrow_upward_rounded,
                  color: coral,
                ),
              ),
            ],
          ),
        ],
      ),
    );
    return MoneyCard(padding: EdgeInsets.zero, child: content);
  }

  String _formatTransactionAmount(MoneyTransaction transaction) {
    final source = _accountById(transaction.accountId);
    if (transaction.type == TransactionType.transfer) {
      final destination = _accountById(transaction.toAccountId);
      final sent = formatTransactionMoney(transaction.amountMinor, source);
      final received = formatTransactionMoney(
        transaction.receivedMinor,
        destination,
      );
      // Filtered to one account, only that account's own leg is its amount.
      if (_accountId != null) {
        return transaction.toAccountId == _accountId
            ? '+ $received'
            : '- $sent';
      }
      // Otherwise show both figures when they differ — across currencies, or
      // when a charge was taken, one number cannot stand for the pair.
      return sent == received ? sent : '$sent → $received';
    }
    final sign = transaction.type == TransactionType.income ? '+ ' : '- ';
    return '$sign${formatTransactionMoney(transaction.amountMinor, source)}';
  }

  /// How many transactions the list takes at first, and with each page after.
  static const _pageSize = 60;

  /// How many transactions each period's list currently shows, until the
  /// filters behind it change ([_shownSignature]).
  final _shownLimits = <DateTimeRange, int>{};
  Object? _shownSignature;

  void _showMore(DateTimeRange range, int shown) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || (_shownLimits[range] ?? _pageSize) != shown) return;
      setState(() => _shownLimits[range] = shown + _pageSize);
    });
  }

  /// The first [limit] of [transactions], newest first — then on to the end of
  /// the last day they reach, so a day's own total never covers only part of it.
  List<MoneyTransaction> _newestFirst(
    List<MoneyTransaction> transactions,
    int limit,
  ) {
    var ordered = transactions;
    var sorted = true;
    for (var i = 1; i < ordered.length && sorted; i++) {
      sorted = ordered[i - 1].date.compareTo(ordered[i].date) >= 0;
    }
    if (!sorted) {
      // Ties keep their order, so rows of one day don't shuffle between builds.
      final indexed = [
        for (var i = 0; i < ordered.length; i++) (i, ordered[i]),
      ];
      indexed.sort((a, b) {
        final byDate = b.$2.date.compareTo(a.$2.date);
        return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
      });
      ordered = [for (final entry in indexed) entry.$2];
    }
    if (ordered.length <= limit) return ordered;
    bool sameDay(DateTime a, DateTime b) =>
        a.year == b.year && a.month == b.month && a.day == b.day;
    var end = limit;
    while (end < ordered.length &&
        sameDay(ordered[end].date, ordered[limit - 1].date)) {
      end++;
    }
    return ordered.sublist(0, end);
  }

  List<_DatedTransactions> _groupTransactions(
    List<MoneyTransaction> transactions,
  ) {
    final groups = <DateTime, List<MoneyTransaction>>{};
    for (final transaction in transactions) {
      final date = DateTime(
        transaction.date.year,
        transaction.date.month,
        transaction.date.day,
      );
      groups.putIfAbsent(date, () => []).add(transaction);
    }
    return groups.entries
        .map((entry) => _DatedTransactions(entry.key, entry.value))
        .toList()
      ..sort((a, b) => b.date.compareTo(a.date));
  }

  /// The period's transactions rolled up by category: into parent categories
  /// while every category is in view, and into the chosen category's own
  /// children once one is picked, so drilling in keeps breaking the spending
  /// down. Transfers belong to no category and collect into a group of their
  /// own at the end.
  List<_CategorizedTransactions> _groupByCategory(
    List<MoneyTransaction> transactions,
    TransactionCurrency currency,
  ) {
    final groups = <int, List<MoneyTransaction>>{};
    for (final transaction in transactions) {
      final category = _categoryById(transaction.categoryId);
      final key = category == null
          ? _transfersGroupKey
          : _categoryId == null
          ? (category.parentId ?? category.id)
          : category.id;
      groups.putIfAbsent(key, () => []).add(transaction);
    }
    final result = <_CategorizedTransactions>[];
    for (final entry in groups.entries) {
      final totals = _categoryTotals(entry.value, currency);
      result.add(
        _CategorizedTransactions(
          key: entry.key,
          category: entry.key == _transfersGroupKey
              ? null
              : _categoryById(entry.key),
          transactions: entry.value..sort((a, b) => b.date.compareTo(a.date)),
          income: totals.$1,
          expenses: totals.$2,
        ),
      );
    }
    // Biggest movement first, so the breakdown reads top-down; the
    // categoryless transfers always trail it.
    result.sort((a, b) {
      if ((a.category == null) != (b.category == null)) {
        return a.category == null ? 1 : -1;
      }
      final byAmount = b.magnitude.compareTo(a.magnitude);
      return byAmount != 0 ? byAmount : a.label.compareTo(b.label);
    });
    return result;
  }

  /// A category group's `(income, expenses)` in [currency]. Unlike the day
  /// headers' totals these keep debt movements in: a Debt/Loan category's
  /// whole point is the money it moved, and a group headed by a blank would
  /// read as a bug.
  (int, int) _categoryTotals(
    List<MoneyTransaction> transactions,
    TransactionCurrency currency,
  ) {
    var income = 0;
    var expenses = 0;
    for (final transaction in transactions) {
      if (!_matchesCurrency(transaction, currency)) continue;
      if (_accountId != null && transaction.accountId != _accountId) continue;
      switch (transaction.type) {
        case TransactionType.income:
          income += transaction.amountMinor;
        case TransactionType.expense:
          expenses += transaction.amountMinor;
        case TransactionType.transfer:
          break;
      }
    }
    return (income, expenses);
  }

  /// Separates the selected filter from the category groups below it.
  Widget _buildCategoryHeader(
    BuildContext context,
    List<MoneyTransaction> visible,
    TransactionCurrency currency, {
    TransactionPreviewData? data,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final category = _categoryById(_categoryId);
    if (category == null) return const SizedBox.shrink();
    final totals =
        data?.categoryTotals[currency] ?? _categoryTotals(visible, currency);
    final count = data?.count ?? visible.length;
    final income = _dayTotal(totals.$1, currency);
    final expenses = _dayTotal(totals.$2, currency);
    return Material(
      color: scheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(color: scheme.primary.withValues(alpha: .16)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 8, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Viewing category',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                Tooltip(
                  message: 'Clear category filter',
                  child: TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(64, 48),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: () => setState(() {
                      _categoryId = null;
                      _expandedGroups.clear();
                    }),
                    child: const Text('Clear'),
                  ),
                ),
              ],
            ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .07),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Center(child: AppIcon(category.icon, size: 28)),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        category.name,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        count == 1 ? '1 transaction' : '$count transactions',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            if (income != null || expenses != null) ...[
              const SizedBox(height: 12),
              const Divider(height: 1),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      'Category total',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        if (income != null)
                          Text(
                            '+ $income',
                            textAlign: TextAlign.end,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: green,
                            ),
                          ),
                        if (expenses != null)
                          Text(
                            '- $expenses',
                            textAlign: TextAlign.end,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: coral,
                            ),
                          ),
                      ],
                    ),
                  ),
                  // The card's own trailing inset is tight, for the Clear
                  // button; this makes up the rest, so the total ends in the
                  // same column as the group totals and amounts below it.
                  const SizedBox(width: 8),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryGroup(
    BuildContext context,
    _CategorizedTransactions group,
    TransactionCurrency currency,
  ) {
    final category = group.category;
    final expanded = _expandedGroups.contains(group.key);
    return _CategoryGroup(
      title: group.label,
      showHeader: _categoryId == null || group.category?.id != _categoryId,
      icon: category == null
          ? Icon(
              Icons.swap_horiz_rounded,
              size: 26,
              color: Theme.of(context).colorScheme.primary,
            )
          : AppIcon(category.icon, size: 28),
      count: group.count ?? group.transactions.length,
      transactions: expanded
          ? group.transactions
          : group.transactions.take(_categoryPreviewCount).toList(),
      income: _dayTotal(group.income, currency),
      expenses: _dayTotal(group.expenses, currency),
      expanded: expanded,
      onToggleExpanded: () => setState(() {
        if (!_expandedGroups.remove(group.key)) _expandedGroups.add(group.key);
      }),
      accountById: _accountById,
      categoryById: _categoryById,
      formatAmount: _formatTransactionAmount,
      onOpen: _openTransaction,
    );
  }
}

class _BalanceMetric extends StatelessWidget {
  const _BalanceMetric(this.label, this.value, {this.alignEnd = false});
  final String label;
  final String value;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: alignEnd
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(fontSize: 11, height: 1),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    ],
  );
}

class _FlowMetric extends StatelessWidget {
  const _FlowMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(13),
    ),
    child: Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(fontSize: 10, height: 1),
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _DatedTransactions {
  const _DatedTransactions(this.date, this.transactions, {this.totals});
  final (int, int)? totals;
  final DateTime date;
  final List<MoneyTransaction> transactions;
}

class _CategorizedTransactions {
  const _CategorizedTransactions({
    required this.key,
    required this.category,
    required this.transactions,
    required this.income,
    required this.expenses,
    this.count,
  });
  final int? count;

  /// The grouped category's id, or `_transfersGroupKey` for the transfers
  /// that have no category to group by.
  final int key;
  final Category? category;

  /// Newest first, so a truncated group previews the latest activity.
  final List<MoneyTransaction> transactions;
  final int income;
  final int expenses;

  String get label => category?.name ?? 'Transfers';

  /// How much the category moved either way — what the groups are ranked on.
  int get magnitude => income + expenses;
}

/// One category's transactions within the selected period, headed by the
/// category's own total. A long group previews its most recent transactions
/// and expands in place.
class _CategoryGroup extends StatelessWidget {
  const _CategoryGroup({
    required this.title,
    required this.showHeader,
    required this.icon,
    required this.count,
    required this.transactions,
    required this.income,
    required this.expenses,
    required this.expanded,
    required this.onToggleExpanded,
    required this.accountById,
    required this.categoryById,
    required this.formatAmount,
    required this.onOpen,
  });
  final String title;
  final bool showHeader;
  final Widget icon;

  /// Everything the group holds, which [transactions] shows only the most
  /// recent of until the group is expanded.
  final int count;
  final List<MoneyTransaction> transactions;

  /// The group's formatted totals in the selected currency, or null for a
  /// side that is zero — most categories move money only one way, and a zero
  /// reads as a figure rather than as an absence.
  final String? income;
  final String? expenses;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final Account? Function(int?) accountById;
  final Category? Function(int?) categoryById;
  final String Function(MoneyTransaction) formatAmount;
  final ValueChanged<MoneyTransaction> onOpen;

  Widget _headerTotal(String amount, Color color) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerRight,
    child: Text(
      amount,
      maxLines: 1,
      textAlign: TextAlign.end,
      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Inset to match the rows' own trailing padding, so the group's total
    // sits in the same column as the amounts it adds up.
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 14),
      child: Row(
        children: [
          SizedBox.square(dimension: 30, child: Center(child: icon)),
          const SizedBox(width: 12),
          // Tight, so the row has no slack left to strand on its right: a
          // merely flexible title would take only the width it needs and
          // leave the rest between the total and the edge.
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  count == 1 ? '1 transaction' : '$count transactions',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Keep totals in a bounded column so labels retain room on phones.
          if (income != null || expenses != null)
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (income != null) _headerTotal('+ $income', green),
                  if (expenses != null) _headerTotal('- $expenses', coral),
                ],
              ),
            ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeader) header,
          MoneyCard(
            padding: EdgeInsets.zero,
            // Transparent Material so the rows' ripples paint above the
            // card's own color rather than under it.
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  // Grows and shrinks from the top, so the rows past the
                  // preview unroll rather than appearing all at once.
                  AnimatedSize(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 280),
                    curve: Curves.easeInOutCubic,
                    alignment: Alignment.topCenter,
                    child: Column(
                      children: [
                        for (
                          var index = 0;
                          index < transactions.length;
                          index++
                        ) ...[
                          TransactionListRow(
                            transaction: transactions[index],
                            account: accountById(transactions[index].accountId),
                            toAccount: accountById(
                              transactions[index].toAccountId,
                            ),
                            category: categoryById(
                              transactions[index].categoryId,
                            ),
                            parentCategory: categoryById(
                              categoryById(transactions[index].categoryId)
                                  ?.parentId,
                            ),
                            formattedAmount: formatAmount(transactions[index]),
                            onTap: () => onOpen(transactions[index]),
                            // A category group spans the whole period, so the
                            // day is what places a row, not the hour.
                            showDate: true,
                          ),
                          if (index < transactions.length - 1)
                            const Divider(height: 1),
                        ],
                      ],
                    ),
                  ),
                  if (expanded || transactions.length < count) ...[
                    const Divider(height: 1),
                    InkWell(
                      onTap: onToggleExpanded,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              expanded ? 'Show less' : 'Show all $count',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: scheme.primary,
                              ),
                            ),
                            const SizedBox(width: 3),
                            Icon(
                              expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 18,
                              color: scheme.primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransactionGroup extends StatelessWidget {
  const _TransactionGroup({
    required this.date,
    required this.transactions,
    required this.income,
    required this.expenses,
    required this.accountById,
    required this.categoryById,
    required this.formatAmount,
    required this.onOpen,
  });
  final DateTime date;
  final List<MoneyTransaction> transactions;

  /// The day's formatted income/expense totals in the selected currency, or
  /// null for a side that is zero — a day may have moved money only in another
  /// currency, or only between accounts.
  final String? income;
  final String? expenses;
  final Account? Function(int?) accountById;
  final Category? Function(int?) categoryById;
  final String Function(MoneyTransaction) formatAmount;
  final ValueChanged<MoneyTransaction> onOpen;

  @override
  Widget build(BuildContext context) => TransactionDayGroup(
    date: date,
    income: income,
    expenses: expenses,
    rows: [
      for (final transaction in transactions)
        TransactionListRow(
          transaction: transaction,
          account: accountById(transaction.accountId),
          toAccount: accountById(transaction.toAccountId),
          category: categoryById(transaction.categoryId),
          parentCategory: categoryById(
            categoryById(transaction.categoryId)?.parentId,
          ),
          formattedAmount: formatAmount(transaction),
          onTap: () => onOpen(transaction),
        ),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filtered, required this.onAdd});
  final bool filtered;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 4, 28, 96),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GlassLens(
          size: 104,
          child: EmptyArtwork(
            filtered ? EmptyArt.search : EmptyArt.transfer,
            size: 56,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          filtered
              ? 'No matching transactions'
              : 'No transactions in this period',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 7),
        Text(
          filtered
              ? 'Try another search or transaction filter.'
              : 'Your expenses, income, and transfers will appear here.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
        ),
        if (!filtered) ...[
          const SizedBox(height: 18),
          FilledButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add_rounded),
            label: const Text('Add transaction'),
          ),
        ],
      ],
    ),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(28),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.cloud_off_outlined,
          size: 42,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 14),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 14),
        OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}
