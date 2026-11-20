import 'dart:async';
import 'dart:math' as math;

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
import '../components/animated_amount.dart';
import '../components/app_icon.dart';
import '../components/info_guide.dart';
import '../components/app_toast.dart';
import '../components/choice_list_sheet.dart';
import '../components/common.dart';
import '../components/confirmation_alert.dart';
import '../components/transactions/review_pickers.dart';
import '../components/tab_header.dart';

import '../components/more_popup_button.dart';
import '../components/row_transition.dart';
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

part 'transaction_groups.dart';

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
  select,
  selectAll,
  deleteSelected,
  categorizeSelected,
  moveSelected,
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
    this.initialAccountId,
    this.initialPeriod,
    this.parentHandlesBack = false,
    this.preview,
    this.onSync,
  });

  /// Pulling the list down runs this first (Sync now), so it shows what
  /// the other phones changed too.
  final Future<void> Function()? onSync;
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final VoidCallback onAddTransaction;
  final DateTime? initialMonth;
  final int monthRequest;

  /// An account to filter to, as an account's page asks for when it opens
  /// this screen on top of itself.
  final int? initialAccountId;

  /// The period to open on with [initialAccountId]: its kind, range and
  /// place in it are copied, so the list covers what the page was showing.
  /// All time when null.
  final PeriodController? initialPeriod;
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

  /// The ids ticked in select mode; null when the list is not being selected.
  Set<int>? _selection;

  void _toggleSelected(MoneyTransaction transaction) => setState(() {
    final picked = _selection ??= {};
    if (!picked.remove(transaction.id)) picked.add(transaction.id);
  });
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

  /// The ledger's transactions as last shown, by id, to tell which rows
  /// are new and which were deleted when it reloads (see [RowTransition]).
  Map<int, MoneyTransaction>? _lastShown;

  /// When each new transaction arrived: built soon after, its row unfolds.
  final _arrived = <int, DateTime>{};

  /// Deleted transactions, still drawn while their rows fold away.
  final _leaving = <int, MoneyTransaction>{};
  List<MoneyTransaction>? _withLeaving;

  bool _isNew(int id) {
    final at = _arrived[id];
    return at != null &&
        DateTime.now().difference(at) < const Duration(seconds: 2);
  }

  /// Notes which transactions the reload added and which it removed. The
  /// first load animates nothing.
  void _trackChanges() {
    final store = widget.transactionStore;
    if (store.loading) return;
    final now = {for (final t in store.transactions) t.id: t};
    final before = _lastShown;
    _lastShown = now;
    _withLeaving = null;
    _leaving.removeWhere((id, _) => now.containsKey(id));
    if (before == null) return;
    final time = DateTime.now();
    _arrived.removeWhere(
      (_, at) => time.difference(at) > const Duration(seconds: 5),
    );
    for (final id in now.keys) {
      if (!before.containsKey(id)) _arrived[id] = time;
    }
    final gone = [
      for (final MapEntry(:key, :value) in before.entries)
        if (!now.containsKey(key)) (key, value),
    ];
    if (gone.isEmpty) return;
    for (final (id, transaction) in gone) {
      _leaving[id] = transaction;
    }
    Timer(RowTransition.duration + const Duration(milliseconds: 40), () {
      if (!mounted) return;
      for (final (id, _) in gone) {
        _leaving.remove(id);
      }
      _withLeaving = null;
      _onStoreChanged();
    });
  }

  List<MoneyTransaction> get _transactions {
    final current =
        widget.preview?.transactions ?? widget.transactionStore.transactions;
    if (_leaving.isEmpty || widget.preview != null) return current;
    // Kept in the ledger's order (newest first), so a leaving row folds
    // away where it was.
    return _withLeaving ??= [...current, ..._leaving.values]
      ..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        return byDate != 0 ? byDate : b.id.compareTo(a.id);
      });
  }

  Future<void> _refresh() async {
    if (widget.preview case final preview?) return preview.onRefresh();
    await widget.onSync?.call();
    await widget.transactionStore.load();
  }

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
    } else if (widget.initialAccountId != null) {
      _accountId = widget.initialAccountId;
      final from = widget.initialPeriod;
      if (from == null) {
        _period.select(PeriodKind.all);
      } else {
        _period.select(
          from.kind,
          customRange: from.customRange,
          anchor: from.anchor,
        );
      }
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
    if (!mounted ||
        widget.initialMonth != null ||
        widget.initialAccountId != null) {
      return;
    }
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
    _settle.dispose();
    _fold.dispose();
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
    _trackChanges();
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
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Could not load unassigned accounts. Please try again.',
            ),
          ),
        );
      }
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
      case _MenuAction.select:
        setState(() => _selection = _selection == null ? {} : null);
        return;
      case _MenuAction.selectAll:
        _selectAll();
        return;
      case _MenuAction.deleteSelected:
        await _deleteSelected();
        return;
      case _MenuAction.categorizeSelected:
        await _categorizeSelected();
        return;
      case _MenuAction.moveSelected:
        await _moveSelected();
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

  /// The ticked transactions, as they are now in the store.
  List<MoneyTransaction> get _picked => [
    for (final t in widget.transactionStore.transactions)
      if (_selection?.contains(t.id) ?? false) t,
  ];

  /// What the list in front of you shows: the period, account and filters.
  List<MoneyTransaction> get _shown =>
      _visibleFrom(_periodTransactionsFor(_activeRange));

  bool get _allSelected {
    final shown = _shown;
    final picked = _selection;
    return picked != null &&
        shown.isNotEmpty &&
        shown.every((t) => picked.contains(t.id));
  }

  void _selectAll() => setState(() {
    final shown = _shown;
    _selection = _allSelected ? <int>{} : {for (final t in shown) t.id};
  });

  Future<void> _deleteSelected() async {
    final picked = _picked;
    if (picked.isEmpty) {
      showAppToast(context, 'Select transactions first');
      return;
    }
    final n = picked.length;
    final ok = await showDeleteConfirmation(
      context,
      title: 'Delete $n ${n == 1 ? 'transaction' : 'transactions'}?',
      message: 'Their effect on your account balances is reversed.',
    );
    if (!ok || !mounted) return;
    var failed = 0;
    for (final t in picked) {
      try {
        await widget.transactionStore.deleteTransaction(t.id);
      } catch (_) {
        failed++;
      }
    }
    _finishBatch(done: n - failed, failed: failed, verb: 'deleted');
  }

  Future<void> _categorizeSelected() async {
    final picked = _picked.where((t) => t.type != TransactionType.transfer);
    if (picked.isEmpty) {
      showAppToast(context, 'Select expenses or income first');
      return;
    }
    final types = picked.map((t) => t.type).toSet();
    if (types.length > 1) {
      showAppToast(context, 'Select only expenses or only income');
      return;
    }
    final pick = await showReviewCategoryPicker(
      context,
      title: 'Change category',
      categories: widget.categoryStore.categories,
      store: widget.categoryStore,
      type: types.single == TransactionType.income
          ? CategoryType.income
          : CategoryType.expense,
      selected: null,
    );
    final id = pick?.categoryId;
    if (id == null || !mounted) return;
    var failed = 0;
    for (final t in picked) {
      try {
        await widget.transactionStore.updateExpenseOrIncome(
          id: t.id,
          type: t.type,
          amountMinor: t.amountMinor,
          accountId: t.accountId,
          categoryId: id,
          title: t.title,
          note: t.note,
          date: t.date,
        );
      } catch (_) {
        failed++;
      }
    }
    _finishBatch(done: picked.length - failed, failed: failed, verb: 'updated');
  }

  Future<void> _moveSelected() async {
    final picked = _picked.where((t) => t.type != TransactionType.transfer);
    if (picked.isEmpty) {
      showAppToast(context, 'Select expenses or income first');
      return;
    }
    final accounts = widget.accountStore;
    final currencies = {
      for (final t in picked) accounts.byId(t.accountId)?.currency,
    };
    if (currencies.length > 1) {
      showAppToast(context, 'Select transactions in one currency');
      return;
    }
    final currency = currencies.single;
    final id = await showReviewAccountPicker(
      context,
      title: 'Change account',
      heading: 'Move to',
      selected: null,
      items: [
        for (final a in accounts.accounts)
          if (a.currency == currency)
            ChoiceItem(
              value: a.id,
              icon: AppIcon(a.icon, size: 28),
              label: a.name,
              subtitle: formatTransactionMoney(a.balanceMinor, a),
              chevron: true,
            ),
      ],
      onAdd: (_) async => null,
    );
    if (id == null || !mounted) return;
    var failed = 0;
    for (final t in picked) {
      try {
        await widget.transactionStore.updateExpenseOrIncome(
          id: t.id,
          type: t.type,
          amountMinor: t.amountMinor,
          accountId: id,
          categoryId: t.categoryId ?? 0,
          title: t.title,
          note: t.note,
          date: t.date,
        );
      } catch (_) {
        failed++;
      }
    }
    _finishBatch(done: picked.length - failed, failed: failed, verb: 'moved');
  }

  void _finishBatch({
    required int done,
    required int failed,
    required String verb,
  }) {
    if (!mounted) return;
    setState(() => _selection = null);
    showAppToast(
      context,
      failed == 0
          ? '$done ${done == 1 ? 'transaction' : 'transactions'} $verb'
          : '$done $verb, $failed could not be changed',
    );
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
    if (_selection != null) {
      setState(() => _selection = null);
      return true;
    }
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
      canPop: _selection == null && (widget.parentHandlesBack || !_isSearch),
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
                // The card sits above the pager, but the pager is always laid
                // out at the full height below it and only moved as the card
                // folds. Its lists never change size mid-drag, so scrolling
                // stays smooth: a fold costs a repaint, not a relayout of the
                // list (which used to fight the finger and stutter).
                Expanded(
                  child: ClipRect(
                    child: CustomMultiChildLayout(
                      delegate: _CardOverList(),
                      children: [
                        LayoutId(
                          id: _CardOverList.list,
                          child: NotificationListener<ScrollNotification>(
                            onNotification: _onListScroll,
                            child: PeriodPager(
                              controller: _period,
                              onSelectRange: _selectRange,
                              pageBuilder: _buildPeriodPage,
                            ),
                          ),
                        ),
                        if (widget.preview == null)
                          LayoutId(
                            id: _CardOverList.card,
                            child: AnimatedPadding(
                              duration: duration,
                              curve: Curves.easeInOutCubic,
                              padding: EdgeInsets.fromLTRB(
                                18,
                                _isSearch ? 0 : 4,
                                18,
                                0,
                              ),
                              child: Column(
                                children: [
                                  // Opening search still slides the card away on a
                                  // timer; its own shrinking follows the scroll
                                  // directly, with no easing in between.
                                  TweenAnimationBuilder<double>(
                                    duration: duration,
                                    curve: Curves.easeInOutCubic,
                                    tween: Tween(end: _isSearch ? 0.0 : 1.0),
                                    // Folded away completely, the card leaves
                                    // the tree, so screen readers don't read
                                    // out a balance nobody can see.
                                    builder: (context, open, child) => open == 0
                                        ? const SizedBox(width: double.infinity)
                                        : ClipRect(
                                            child: Align(
                                              alignment: Alignment.topCenter,
                                              heightFactor: open,
                                              child: child,
                                            ),
                                          ),
                                    child: _buildBalanceHeader(context),
                                  ),
                                  AnimatedContainer(
                                    duration: duration,
                                    curve: Curves.easeInOutCubic,
                                    height: _isSearch ? 0 : 4,
                                  ),
                                ],
                              ),
                            ),
                          ),
                      ],
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

  /// How far the balance card is folded, from 0 (open) to 1 (folded).
  ///
  /// While a finger is on the list it drives the fold directly: dragging up
  /// folds, dragging down unfolds, in step with the movement and whether or
  /// not the list has anything to scroll. When the list comes to rest, the
  /// card settles to whichever end is nearer, so it is never left half way.
  /// Nothing else moves it: swiping to another period keeps it as it was.
  final _fold = ValueNotifier<double>(0);
  static const _foldDistance = 56.0;

  /// The pager runs this far past the bottom while the card is open, so
  /// the lists end with that much more room.
  double get _cardRoom => widget.preview == null ? 120 : 0;

  late final _settle = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  )..addListener(_settleTick);
  double _settleFrom = 0, _settleTo = 0;
  double _lastPixels = 0;

  void _settleTick() => _fold.value =
      _settleFrom +
      (_settleTo - _settleFrom) * Curves.easeOutCubic.transform(_settle.value);

  void _foldBy(double pixels) {
    final next = (_fold.value + pixels / _foldDistance).clamp(0.0, 1.0);
    if (next != _fold.value) _fold.value = next;
  }

  bool _onListScroll(ScrollNotification n) {
    // The list sits inside the horizontal pager, so it arrives one scrollable
    // deep; only vertical scrolling counts.
    if (n.depth > 1 || n.metrics.axis != Axis.vertical) return false;
    switch (n) {
      case ScrollStartNotification():
        _settle.stop();
        _lastPixels = n.metrics.pixels;
      case ScrollUpdateNotification():
        // Dragging past an end still folds (a short list is always there),
        // but the list springing back from it on its own doesn't unfold.
        final m = n.metrics;
        final bouncing =
            n.dragDetails == null &&
            (m.outOfRange ||
                _lastPixels < m.minScrollExtent ||
                _lastPixels > m.maxScrollExtent);
        if (!bouncing) _foldBy(m.pixels - _lastPixels);
        _lastPixels = m.pixels;
      case OverscrollNotification():
        // Past an end of the list, which is where a short list always is.
        _foldBy(n.overscroll);
      case ScrollEndNotification():
        final value = _fold.value;
        if (value > 0 && value < 1) {
          _settleFrom = value;
          _settleTo = value >= .5 ? 1 : 0;
          _settle.forward(from: 0);
        }
      default:
    }
    return false;
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
          // Always draggable, so a page with little in it still folds and
          // unfolds the balance card.
          physics: const AlwaysScrollableScrollPhysics(),
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
                ),
              )
            else if (_grouping == _Grouping.category)
              SliverPadding(
                padding: EdgeInsets.only(
                  bottom:
                      100 + _cardRoom + MediaQuery.paddingOf(context).bottom,
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
                  bottom:
                      100 + _cardRoom + MediaQuery.paddingOf(context).bottom,
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
                      selection: _selection,
                      onToggle: widget.preview == null ? _toggleSelected : null,
                      entering: _isNew,
                      leaving: _leaving.keys.toSet(),
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
        centered: true,
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
      // A tab has nothing to go back to; a page opened from an account does.
      leading: !widget.parentHandlesBack && Navigator.of(context).canPop()
          ? const AppBackButton()
          : null,
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
    items: _selection != null
        ? [
            MorePopupItem(
              value: _MenuAction.selectAll,
              label: _allSelected ? 'Deselect all' : 'Select all',
            ),
            MorePopupItem(
              value: _MenuAction.categorizeSelected,
              label: 'Change category',
            ),
            MorePopupItem(
              value: _MenuAction.moveSelected,
              label: 'Change account',
            ),
            MorePopupItem(
              value: _MenuAction.deleteSelected,
              label: 'Delete',
              dividerBefore: true,
            ),
            MorePopupItem(
              value: _MenuAction.select,
              label: 'Cancel selection',
              dividerBefore: true,
            ),
          ]
        : [
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
                label: _needsAttentionOnly
                    ? 'Ready to save'
                    : 'Needs attention',
              ),
            ] else if (widget.preview != null)
              MorePopupItem(
                value: _MenuAction.attention,
                label: _needsAttentionOnly
                    ? 'Ready to save'
                    : 'Needs attention',
              ),
            if (widget.preview == null)
              MorePopupItem(
                value: _MenuAction.select,
                label: _selection == null ? 'Select' : 'Cancel selection',
              ),
            MorePopupItem(value: _MenuAction.range, label: 'Select time range'),
            if (_grouping == _Grouping.category) ...[
              MorePopupItem(
                value: _MenuAction.filter,
                label: 'View by transaction',
              ),
              MorePopupItem(
                value: _MenuAction.category,
                label: 'Filter by category',
              ),
            ] else ...[
              MorePopupItem(
                value: _MenuAction.category,
                label: 'View by category',
              ),
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
              MorePopupItem(
                value: _MenuAction.transfer,
                label: 'Transfer money',
              ),
          ],
  );

  /// One surface for the account being looked at: its icon, name and last
  /// digits, and the balance. Tapping it opens the account selector.
  Widget _buildBalanceHeader(BuildContext context) =>
      ValueListenableBuilder<double>(
        valueListenable: _fold,
        builder: (context, fold, _) => _balanceCard(context, fold),
      );

  /// Text sizes for the card, measured once per text and style rather than on
  /// every frame of a fold.
  final _measured = <(String, TextStyle, double), Size>{};

  Size _measure(BuildContext context, String text, TextStyle style) {
    final scale = MediaQuery.textScalerOf(context).scale(1);
    if (_measured.length > 24) _measured.clear();
    return _measured.putIfAbsent((text, style, scale), () {
      final painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        maxLines: 1,
      )..layout();
      final size = painter.size;
      painter.dispose();
      return size;
    });
  }

  /// [fold] runs from 0 (full card) to 1 (folded). Open, the name, detail
  /// and balance stack. Folded, they share one row: the name gives way (and
  /// is cut off) so the balance always shows in full. When even that leaves
  /// the name too little room, the balance stays on a second row instead.
  ///
  /// The balance is laid out once at its full size and only scaled while it
  /// folds, so a fold costs a repaint, not a fresh layout of every digit.
  Widget _balanceCard(BuildContext context, double fold) {
    double lerp(double open, double folded) => open + (folded - open) * fold;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final account = _selectedAccount;
    final currency = _currencyFor(_activeRange);
    final mixed =
        widget.accountStore.accounts.map(_accountCurrency).toSet().length > 1;
    final title = account?.name ?? 'All accounts';
    final detail = account == null
        ? (mixed ? 'Balance · ${currency.$1}' : 'Total balance')
        : [
            if (account.lastDigits != null) '•••• ${account.lastDigits}',
            if (mixed || account.currency != currency.$1) currency.$1,
          ].join('  ·  ');
    final label = account == null
        ? (mixed ? 'Balance · ${currency.$1}' : 'Total balance')
        : '${account.name} balance';
    final balance = _currentBalance(currency);
    final titleStyle = theme.textTheme.titleSmall!.copyWith(
      fontWeight: FontWeight.w600,
    );
    final detailStyle = theme.textTheme.bodySmall!;
    final amountStyle = theme.textTheme.bodyMedium!.copyWith(
      fontSize: 28,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
      color: scheme.onSurface,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    // The eye that hides the balance sits beside it, inside the same block.
    const eye = 30.0, foldedScale = 22 / 28;
    final titleH = _measure(context, 'Ag', titleStyle).height;
    final detailH = detail.isEmpty
        ? 0.0
        : _measure(context, 'Ag', detailStyle).height;
    final text = _measure(context, _money(balance, currency), amountStyle);
    // The balance block at full size: digits plus the eye.
    final blockW = text.width + eye, blockH = text.height;
    final iconSize = lerp(40, 28);
    final gap = lerp(14, 10);
    final padLeft = lerp(16, 14);
    final padV = lerp(14, 8);
    const chevron = 20.0, chevronGap = 4.0;
    return Padding(
      padding: EdgeInsets.only(bottom: lerp(4, 0)),
      child: MoneyCard(
        padding: EdgeInsets.zero,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const Key('transaction-account-filter'),
            onTap: _selectAccount,
            child: LayoutBuilder(
              builder: (context, box) {
                final textLeft = iconSize + gap;
                final avail =
                    box.maxWidth -
                    padLeft -
                    12 -
                    textLeft -
                    chevron -
                    chevronGap;
                // Row mode: the name keeps at least a little room beside the
                // balance. Otherwise the balance stays under the name.
                const nameMin = 72.0, between = 10.0;
                final foldedW = blockW * foldedScale;
                final rowMode = foldedW + between + nameMin <= avail;
                // Two phases, so it never looks half-way between two
                // layouts: first the detail line closes up, then the balance
                // slides across onto the name's row.
                final f1 = (fold / .5).clamp(0.0, 1.0);
                final f2 = ((fold - .5) / .5).clamp(0.0, 1.0);
                // Shrunk with the fold, and further only if it would not fit.
                final scale = math.min(lerp(1, foldedScale), avail / blockW);
                final amountW = blockW * scale, amountH = blockH * scale;
                final foldedRowH = math.max(titleH, blockH * foldedScale);
                final gapV = lerp(6, 2);
                final stackedY = titleH + detailH * (1 - f1) + gapV;
                final stackH = stackedY + amountH;
                final textH = rowMode
                    ? stackH + (foldedRowH - stackH) * f2
                    : stackH;
                final amountX = rowMode ? (avail - amountW) * f2 : 0.0;
                final amountY = rowMode
                    ? stackedY + ((foldedRowH - amountH) / 2 - stackedY) * f2
                    : stackedY;
                final titleW = rowMode
                    ? avail - (foldedW + between) * f2
                    : avail;
                final titleY = rowMode ? (foldedRowH - titleH) / 2 * f2 : 0.0;
                final height = math.max(iconSize, textH);
                final top = (height - textH) / 2;
                return Padding(
                  padding: EdgeInsets.fromLTRB(padLeft, padV, 12, padV),
                  child: SizedBox(
                    height: height,
                    child: Stack(
                      clipBehavior: Clip.none,
                      children: [
                        Positioned(
                          left: 0,
                          top: (height - iconSize) / 2,
                          child: account == null
                              ? AllAccountsIcon(size: iconSize)
                              : AppIcon(account.icon, size: iconSize),
                        ),
                        Positioned(
                          left: textLeft,
                          top: top + titleY,
                          width: titleW,
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: titleStyle,
                          ),
                        ),
                        if (detail.isNotEmpty && f1 < 1)
                          Positioned(
                            left: textLeft,
                            top: top + titleH,
                            width: avail,
                            child: Opacity(
                              opacity: 1 - f1,
                              child: Text(
                                detail,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: detailStyle,
                              ),
                            ),
                          ),
                        Positioned(
                          left: textLeft + amountX,
                          top: top + amountY,
                          width: amountW,
                          height: amountH,
                          // Laid out once at full size, then only scaled.
                          child: FittedBox(
                            alignment: Alignment.centerLeft,
                            child: SizedBox(
                              width: blockW,
                              height: blockH,
                              child: PrivateAmount(
                                height: blockH,
                                label: label,
                                maskStyle: amountStyle,
                                key: ValueKey((account?.id, currency)),
                                child: AnimatedAmount(
                                  // Rolls only when the eye reveals it.
                                  rollOnlyOnReveal: true,
                                  value: balance,
                                  format: (minor) => _money(minor, currency),
                                  style: amountStyle,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          top: (height - chevron) / 2,
                          child: Icon(
                            Icons.unfold_more_rounded,
                            size: chevron,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ),
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
      selection: _selection,
      onToggle: widget.preview == null ? _toggleSelected : null,
      entering: _isNew,
      leaving: _leaving.keys.toSet(),
    );
  }
}

/// Lays the balance card at the top and the pager right under it, at the
/// full height of the space whatever the card's size. Only the pager's
/// position follows the card, so its lists are never resized by a fold.
class _CardOverList extends MultiChildLayoutDelegate {
  _CardOverList();

  static const card = 'card', list = 'list';

  @override
  void performLayout(Size size) {
    var top = 0.0;
    if (hasChild(card)) {
      top = layoutChild(
        card,
        BoxConstraints(minWidth: size.width, maxWidth: size.width),
      ).height;
      positionChild(card, Offset.zero);
    }
    layoutChild(list, BoxConstraints.tight(size));
    positionChild(list, Offset(0, top));
  }

  @override
  bool shouldRelayout(_CardOverList oldDelegate) => false;
}
