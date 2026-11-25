import 'data/community/community_fixes.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'data/rates/exchange_rates.dart';
import 'state/main_currency_controller.dart';

import 'ui/theme/app_motion.dart';
import 'ui/home/home_screen.dart';
import 'ui/quick_entry_screen.dart';
import 'ui/sms/sms_notification_screen.dart';
import 'state/appearance_controller.dart';
import 'ui/theme/app_theme.dart';
import 'data/db/app_database.dart';
import 'data/repositories/account_repository.dart';
import 'data/repositories/budget_repository.dart';
import 'data/repositories/category_repository.dart';
import 'data/repositories/debt_repository.dart';
import 'data/repositories/transaction_repository.dart';
import 'state/account_store.dart';
import 'state/budget_store.dart';
import 'state/category_store.dart';
import 'state/debt_store.dart';
import 'data/prices/price_service.dart';
import 'state/holding_store.dart';
import 'state/loan_store.dart';
import 'state/recurring_payment_store.dart';
import 'data/repositories/holding_repository.dart';
import 'data/repositories/loan_repository.dart';
import 'data/repositories/recurring_payment_repository.dart';
import 'state/transaction_store.dart';
import 'state/sync_controller.dart';
import 'state/security_controller.dart';
import 'state/home_layout.dart';
import 'state/ad_gate.dart';
import 'state/pro_controller.dart';
import 'state/upi_settings.dart';
import 'ui/components/app_lock_gate.dart';
import 'ui/components/glass_blur.dart' show ScreenAnchor;

import 'dart:async' show unawaited;

import 'data/daily_reminders.dart';
import 'ui/components/empty_art.dart' show EmptyArtWarmup;
import 'data/backup/sync_repository.dart';
import 'ui/components/feature_page.dart';
import 'ui/welcome/onboarding_screen.dart';

class SimpleMoneyApp extends StatefulWidget {
  const SimpleMoneyApp({
    super.key,
    this.accountStore,
    this.categoryStore,
    this.transactionStore,
    this.budgetStore,
    this.mainCurrencyController,
    this.onboarding = false,
  });
  final AccountStore? accountStore;
  final CategoryStore? categoryStore;
  final TransactionStore? transactionStore;
  final BudgetStore? budgetStore;
  final MainCurrencyController? mainCurrencyController;

  /// Opens on the first-open setup instead of Home.
  final bool onboarding;
  @override
  State<SimpleMoneyApp> createState() => _SimpleMoneyAppState();
}

class _SimpleMoneyAppState extends State<SimpleMoneyApp>
    with WidgetsBindingObserver {
  late final _smsRoute = Uri.parse(
    WidgetsBinding.instance.platformDispatcher.defaultRouteName,
  ).pathSegments;
  bool get _isSmsNotification =>
      _smsRoute.length == 3 && _smsRoute.first == 'sms';
  late final String? _quickAction =
      switch (WidgetsBinding.instance.platformDispatcher.defaultRouteName) {
        '/quick/upi' => 'upi',
        '/quick/income' => 'income',
        '/quick/expense' => 'expense',
        _ => null,
      };
  // A notifier rather than plain state: HomeScreen is built once by
  // onGenerateRoute, so it must listen to see theme changes.
  // Restored as it is made: preloaded in main, so the first frame already
  // shows the saved look.
  final _themeMode = AppearanceController()..restoreNow();
  final _security = SecurityController();
  final _upiSettings = UpiSettings();
  final _homeLayout = HomeLayout();
  final _rateClient = http.Client();
  late final _mainCurrency =
      widget.mainCurrencyController ??
      MainCurrencyController(
        _accounts,
        ExchangeRates(_accounts.repository.database, _rateClient),
      );
  late final SyncController? _sync = _database == null
      ? null
      : (SyncController(SyncRepository(_database))..onRestored = _reloadLedger);
  late final AppDatabase? _database = widget.accountStore == null
      ? AppDatabase()
      : null;
  late final AccountStore _accounts =
      widget.accountStore ?? AccountStore(AccountRepository(_database!));
  late final CategoryStore _categories =
      widget.categoryStore ?? CategoryStore(CategoryRepository(_database!));
  late final TransactionStore _transactions =
      widget.transactionStore ??
      TransactionStore(TransactionRepository(_database!), _accounts);
  late final BudgetStore _budgets =
      widget.budgetStore ??
      BudgetStore(
        BudgetRepository(_database ?? _transactions.repository.database),
      );
  late final DebtStore _debts = DebtStore(
    DebtRepository(_database ?? _transactions.repository.database),
    accountStore: _accounts,
    categoryStore: _categories,
    transactionStore: _transactions,
  );
  late final LoanStore _loans = LoanStore(
    LoanRepository(_database ?? _transactions.repository.database),
    accountStore: _accounts,
    categoryStore: _categories,
    transactionStore: _transactions,
  );
  late final HoldingStore _holdings = HoldingStore(
    HoldingRepository(_database ?? _transactions.repository.database),
    accountStore: _accounts,
    // Tests that inject their own stores never reach the network.
    prices: widget.accountStore == null ? PriceService(_rateClient) : null,
  );
  late final RecurringPaymentStore _recurringPayments = RecurringPaymentStore(
    RecurringPaymentRepository(_database ?? _transactions.repository.database),
    accountStore: _accounts,
    categoryStore: _categories,
    transactionStore: _transactions,
  );
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Holdings priced in other currencies are valued by the same daily rates
    // as everything else, and ask for them to be kept.
    _holdings.converter = _mainCurrency.convertBetween;
    _mainCurrency.extraCurrencies = () => _holdings.foreignCurrencies;
    var asked = <String>{};
    _holdings.addListener(() {
      // Only when a new currency turns up, so a rate refresh (which redraws
      // holdings) can never ask for another.
      final now = _holdings.foreignCurrencies;
      if (now.difference(asked).isEmpty) return;
      asked = now;
      _mainCurrency.refresh();
    });
    _mainCurrency.addListener(_holdings.ratesChanged);
    const MethodChannel('simple_money/sms_changes')
        .setMethodCallHandler((call) async {
          if (call.method == 'changed' && mounted) _reloadLedger();
        });
    if (_accounts.loading) {
      _accounts.load(initializeDefault: widget.accountStore == null);
    }
    if (_categories.loading) _categories.load();
    if (_transactions.loading) _transactions.load();
    _debts.load();
    _loans.load();
    _loadHoldings();
    _recurringPayments.load();
    _startSync();
    _upiSettings.restore();
    _homeLayout.restore();
    _mainCurrency.start();
    _startPro();
    if (widget.accountStore == null) {
      DailyReminders.instance.restore().then((_) => _syncDailyReminders());
      _transactions.addListener(_syncDailyReminders);
    }
  }

  /// Keeps the 8 pm / 10 pm nudges in line with whether today already has a
  /// transaction.
  void _syncDailyReminders() {
    // Not while the first-run setup is open: scheduling asks for the
    // notification permission, and the setup's SMS step does that itself.
    if (_setupPending || _transactions.loading) return;
    final now = DateTime.now();
    final added = _transactions.transactions.any(
      (t) =>
          t.date.year == now.year &&
          t.date.month == now.month &&
          t.date.day == now.day,
    );
    unawaited(DailyReminders.instance.reschedule(addedToday: added));
  }

  /// Billing and ads belong to the main app only, not the launcher sheets or
  /// SMS popups, and not tests (which inject their stores).
  bool get _monetized =>
      widget.accountStore == null &&
      _quickAction == null &&
      !_isSmsNotification;

  Future<void> _startPro() async {
    if (!_monetized) return;
    await ProController.instance.start();
    await AdGate.instance.prepare();
  }

  final _navigator = GlobalKey<NavigatorState>();

  Future<void> _startSync() async {
    // Launcher sheets and SMS popups are short-lived; the main app syncs when
    // it next resumes, and the work would only slow the sheet's opening.
    if (_isSmsNotification || _quickAction != null) return;
    await _sync?.start();
  }

  /// The setup is the first screen, before Home is built, so nothing slides
  /// in over a dashboard that has just drawn. Only the main app shows it.
  bool get _showOnboarding =>
      widget.onboarding &&
      _database != null &&
      _quickAction == null &&
      !_isSmsNotification;

  /// True from launch until the first-run setup is finished.
  late bool _setupPending = _showOnboarding;

  /// The setup may have added accounts, transactions and balances.
  void _finishOnboarding() {
    _setupPending = false;
    _syncDailyReminders();
    _reloadLedger();
    _navigator.currentState?.pushReplacement(_homeRoute());
  }

  Route<void> _homeRoute() => FeatureRoute<void>(
    HomeScreen(
      accountStore: _accounts,
      categoryStore: _categories,
      transactionStore: _transactions,
      budgetStore: _budgets,
      debtStore: _debts,
      loanStore: _loans,
      recurringPaymentStore: _recurringPayments,
      syncController: _sync,
      themeMode: _themeMode,
      onChangeThemeMode: _changeThemeMode,
      community: _community,
    ),
  );

  /// Shared fixes, for the main app only: not tests, which inject stores.
  late final CommunitySync? _community = _database == null
      ? null
      : CommunitySync(_database);

  /// A restore replaced the whole database under the stores.
  void _reloadLedger() {
    _accounts.load();
    _categories.load();
    _transactions.load();
    _budgets.reload();
    _debts.load();
    _loans.load();
    _loadHoldings();
    _recurringPayments.load();
  }

  /// Holdings, then today's closing prices if they haven't been fetched yet.
  Future<void> _loadHoldings() async {
    await _holdings.load();
    if (mounted) await _holdings.refreshPrices();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // A launcher sheet uses a separate engine and may have changed the ledger.
    if (state == AppLifecycleState.resumed && _quickAction == null) {
      _reloadLedger();
      _themeMode.expirePreviews();
      if (_monetized) ProController.instance.refresh();
    }
  }

  Future<void> _changeThemeMode(ThemeMode next) => _themeMode.setMode(next);

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    const MethodChannel('simple_money/sms_changes').setMethodCallHandler(null);
    _transactions.removeListener(_syncDailyReminders);
    _sync?.dispose();
    _themeMode.dispose();
    _security.dispose();
    _upiSettings.dispose();
    _homeLayout.dispose();
    if (widget.mainCurrencyController == null) _mainCurrency.dispose();
    _rateClient.close();
    if (widget.accountStore == null) _accounts.dispose();
    if (widget.categoryStore == null) _categories.dispose();
    if (widget.transactionStore == null) _transactions.dispose();
    if (widget.budgetStore == null) _budgets.dispose();
    _debts.dispose();
    _loans.dispose();
    _holdings.dispose();
    _recurringPayments.dispose();
    if (widget.accountStore == null) _database?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ThemeMode>(
    valueListenable: _themeMode,
    builder: (context, mode, _) => MaterialApp(
      navigatorKey: _navigator,
      title: 'SimpleMoney',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const _AppScrollBehavior(),
      onGenerateInitialRoutes: _showOnboarding
          ? (_) => [
              PageRouteBuilder<void>(
                pageBuilder: (context, animation, secondaryAnimation) =>
                    OnboardingScreen(
                      database: _database!,
                      sync: _sync,
                      community: _community,
                      onDone: _finishOnboarding,
                    ),
              ),
            ]
          : _quickAction == null && !_isSmsNotification
          ? null
          : (_) => [
              PageRouteBuilder<void>(
                opaque: false,
                pageBuilder: (context, animation, secondaryAnimation) =>
                    _isSmsNotification
                    ? SmsNotificationScreen(
                        database:
                            _database ?? _transactions.repository.database,
                        id: _smsRoute[1],
                        field: _smsRoute[2],
                      )
                    : QuickEntryScreen(
                        action: _quickAction!,
                        accounts: _accounts,
                        categories: _categories,
                        transactions: _transactions,
                      ),
              ),
            ],
      theme: appTheme(
        Brightness.light,
        accentColor: _themeMode.accentColor,
        style: _themeMode.style,
      ),
      darkTheme: appTheme(
        Brightness.dark,
        accentColor: _themeMode.accentColor,
        black: _themeMode.black,
        style: _themeMode.style,
      ),
      themeMode: mode,
      // Where popups line up the page backdrop they show on low-end phones.
      builder: (context, child) => ScreenAnchor(
        child: AppearanceScope(
          controller: _themeMode,
          child: UpiSettingsScope(
            settings: _upiSettings,
            child: HomeLayoutScope(
              layout: _homeLayout,
              child: MainCurrencyScope(
                controller: _mainCurrency,
                child: LoanStoreScope(
                  store: _loans,
                  child: DebtStoreScope(
                    store: _debts,
                    child: HoldingStoreScope(
                      store: _holdings,
                      child: AppLockGate(
                        controller: _security,
                        child: EmptyArtWarmup(child: child!),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
      onGenerateRoute: (_) => _homeRoute(),
    ),
  );
}

/// Lists end with no overscroll glow: its tinted patch darkened the glass
/// cards and the picture behind them at the top and bottom. Instead a list
/// runs softly past its end and springs back.
class _AppScrollBehavior extends MaterialScrollBehavior {
  const _AppScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => switch (getPlatform(
    context,
  )) {
    // Already bounce, with their own fling.
    TargetPlatform.iOS ||
    TargetPlatform.macOS => super.getScrollPhysics(context),
    _ => const ElasticScrollPhysics(parent: RangeMaintainingScrollPhysics()),
  };

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => child;
}
