import '../../data/community/community_fixes.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../data/repositories/sms_import_repository.dart';
import '../../state/sms_import_store.dart';
import '../sms/sms_review_flow.dart';
import 'home_dashboard.dart';
import '../../data/repositories/upi_repository.dart';
import '../../state/upi_settings.dart';
import '../upi/upi_payment_flow.dart';
import '../components/accent_glow.dart';
import '../components/adaptive_sheet.dart';
import '../budgets/budgets_screen.dart';
import '../components/common.dart';
import '../components/liquid_glass_nav_bar.dart';
import '../../state/account_store.dart';
import '../../state/budget_store.dart';
import '../../state/sync_controller.dart';
import '../../state/category_store.dart';
import '../../state/debt_store.dart';
import '../../state/loan_store.dart';
import '../../state/subscription_store.dart';
import '../../state/transaction_store.dart';
import '../../data/agent/ai_session.dart';
import '../more/more_screen.dart';
import '../transactions/transaction_sheet.dart';
import '../transactions/transactions_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.themeMode,
    required this.onChangeThemeMode,
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    required this.budgetStore,
    required this.debtStore,
    this.loanStore,
    this.subscriptionStore,
    this.syncController,
    this.community,
  });
  final ValueListenable<ThemeMode> themeMode;
  final ValueChanged<ThemeMode> onChangeThemeMode;
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final BudgetStore budgetStore;
  final DebtStore debtStore;
  final LoanStore? loanStore;
  final SubscriptionStore? subscriptionStore;
  final SyncController? syncController;

  /// Shared fixes from other users; null in tests and launcher sheets.
  final CommunitySync? community;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final SmsImportStore _sms = SmsImportStore(
    SmsImportRepository(widget.transactionStore.repository.database),
  );
  // Lives as long as the dashboard, so a session outlasts its screen.
  late final AiSessionController _ai = AiSessionController(
    database: widget.transactionStore.repository.database,
  )..load();
  // Refresh local inbox data after ledger reloads, including an app data wipe.
  Future<void> _reloadSmsQueue() async {
    try {
      await _sms.reload();
    } catch (_) {}
  }

  bool _smsOpen = false;
  Future<void> _openSms(PendingSmsImport sms) async {
    if (_smsOpen || _upiOpen) return;
    _smsOpen = true;
    try {
      await showAdaptiveSheet<void>(
        context,
        entrance: SheetEntrance.fadeRise,
        dismissible: false,
        topClearance: 62,
        builder: (_) => SmsReviewFlow(
          sms: sms,
          store: _sms,
          accounts: widget.accountStore,
          categories: widget.categoryStore,
          transactions: widget.transactionStore,
        ),
      );
    } finally {
      _smsOpen = false;
    }
  }

  bool _upiOpen = false;
  bool _checkingUpi = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // A scan adds accounts and saves transactions on its own.
    _sms.onLedgerChanged = () {
      widget.accountStore.load();
      widget.categoryStore.load();
      widget.transactionStore.load();
      widget.budgetStore.reload();
    };
    _sms.initialize();
    widget.transactionStore.addListener(_reloadSmsQueue);
    WidgetsBinding.instance.addPostFrameCallback((_) => _reviewUpi());
    unawaited(_syncCommunity());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _reviewUpi();
      _sms.scan(automatic: true);
      unawaited(_syncCommunity());
    }
  }

  /// Sends fixes waiting to be shared, and about once a day fetches the ones
  /// others shared. New SMS formats mean the inbox is read again.
  Future<void> _syncCommunity() async {
    final community = widget.community;
    if (community == null) return;
    await community.flush();
    if (await community.refresh() && mounted) await _sms.rulesChanged();
  }

  Future<void> _reviewUpi() async {
    if (!mounted ||
        _upiOpen ||
        _smsOpen ||
        _checkingUpi ||
        ModalRoute.of(context)?.isCurrent != true) {
      return;
    }
    _checkingUpi = true;
    try {
      final pending = await UpiRepository(
        widget.transactionStore.repository.database,
      ).load();
      if (mounted &&
          pending.isNotEmpty &&
          ModalRoute.of(context)?.isCurrent == true) {
        await _openUpi(review: true);
      }
    } catch (_) {
      // The scanner also exposes the persistent queue for a later retry.
    } finally {
      _checkingUpi = false;
    }
  }

  Future<void> _openUpi({bool review = false}) async {
    if (_upiOpen || _smsOpen) return;
    _upiOpen = true;
    try {
      await showAdaptiveSheet<void>(
        context,
        dismissible: false,
        topClearance: 62,
        builder: (sheetContext) => UpiPaymentFlow(
          reviewPending: review,
          accountStore: widget.accountStore,
          categoryStore: widget.categoryStore,
          transactionStore: widget.transactionStore,
          onBack: () => Navigator.pop(sheetContext),
          onClose: () => Navigator.pop(sheetContext),
        ),
      );
    } finally {
      _upiOpen = false;
    }
  }

  int selectedTab = 0;
  // Mount a tab only when first shown, then retain its scroll/selection state.
  // Offstage still builds and lays out children, so eagerly mounting all tabs
  // makes Home pay for ledger filtering and budget queries it cannot display.
  final _visitedTabs = <int>{0};
  DateTime? transactionMonth;
  int transactionRequest = 0;
  DateTime? budgetMonth;
  (String, int)? budgetCurrency;
  int budgetRequest = 0;
  int? _slidingFromTab;

  /// Later tabs enter from the right; earlier tabs enter from the left.
  int _slideDirection = 1;
  double _tabDragDistance = 0;
  bool _tabDragAllowed = false;
  int? _dragTarget;

  /// Ticks when the drag changes which pages slide, or which way. Only the
  /// tab body listens: a setState here would rebuild every tab — the
  /// Transactions tab filters the whole ledger as it builds — on each frame
  /// of the drag.
  final _tabMotion = ValueNotifier<int>(0);
  late final _tabListenable = Listenable.merge([_historySlide, _tabMotion]);
  final _budgets = GlobalKey<BudgetsScreenState>();
  final _transactions = GlobalKey<TransactionsScreenState>();
  late final _historySlide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 320),
    value: 1,
  );

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _historySlide.dispose();
    _tabMotion.dispose();
    widget.transactionStore.removeListener(_reloadSmsQueue);
    _sms.dispose();
    _ai.dispose();
    super.dispose();
  }

  void _openTransactions(DateTime month) {
    setState(() {
      transactionMonth = month;
      transactionRequest++;
    });
    _selectTab(1);
  }

  void _openBudgets(DateTime month, (String, int) currency) {
    setState(() {
      budgetMonth = month;
      budgetCurrency = currency;
      budgetRequest++;
    });
    _selectTab(2);
  }

  void _selectTab(int index) {
    if (_dragTarget != null) return;
    if (index == selectedTab || index < 0 || index > 3) return;
    setState(() {
      _slidingFromTab = selectedTab;
      _slideDirection = index > selectedTab ? 1 : -1;
      selectedTab = index;
    });
    if (MediaQuery.disableAnimationsOf(context)) {
      _historySlide.value = 1;
    } else {
      _historySlide.value = 0;
      _historySlide.animateTo(1, curve: Curves.easeInOutCubic);
    }
  }

  void _startTabDrag(DragStartDetails details) {
    _tabDragDistance = 0;
    _tabDragAllowed =
        !_historySlide.isAnimating &&
        (selectedTab != 1 ||
            (_transactions.currentState?.allowsTabSwipe ?? false));
  }

  void _endTabDrag(DragEndDetails details) {
    if (!_tabDragAllowed) return;
    final velocity = details.primaryVelocity ?? 0;
    final commit = velocity.abs() >= 400
        ? velocity.sign == -_slideDirection
        : _historySlide.value >= .2;
    _settleTabDrag(commit);
  }

  void _updateTabDrag(DragUpdateDetails details) {
    if (!_tabDragAllowed) return;
    _tabDragDistance += details.primaryDelta ?? 0;
    final direction = _tabDragDistance < 0 ? 1 : -1;
    final target = selectedTab + direction;
    final dragTarget = target >= 0 && target <= 3 ? target : null;
    if (direction != _slideDirection ||
        dragTarget != _dragTarget ||
        _slidingFromTab != selectedTab) {
      _slideDirection = direction;
      _slidingFromTab = selectedTab;
      _dragTarget = dragTarget;
      _tabMotion.value++;
    }
    _historySlide.value = _dragTarget == null
        ? 0
        : (_tabDragDistance.abs() / context.size!.width).clamp(0.0, 1.0);
  }

  Future<void> _settleTabDrag(bool commit) async {
    _tabDragAllowed = false;
    final target = _dragTarget;
    if (target == null) return;
    await _historySlide.animateTo(
      commit ? 1 : 0,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
    );
    if (!mounted) return;
    setState(() {
      if (commit) selectedTab = target;
      _dragTarget = null;
      _slidingFromTab = null;
    });
  }

  Widget _tabBody(List<Widget> pages) => AnimatedBuilder(
    animation: _tabListenable,
    builder: (context, _) {
      final sliding = _historySlide.isAnimating || _dragTarget != null;
      final progress = _historySlide.value;
      final visibleTab = _dragTarget ?? selectedTab;
      final previousTab = _slidingFromTab;
      _visitedTabs.add(visibleTab);
      return ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            for (var i = 0; i < pages.length; i++)
              Offstage(
                offstage: i != visibleTab && !(sliding && i == previousTab),
                child: TickerMode(
                  enabled: i == visibleTab || (sliding && i == previousTab),
                  child: ExcludeSemantics(
                    excluding: i != selectedTab,
                    child: IgnorePointer(
                      ignoring: i != selectedTab || sliding,
                      child: FractionalTranslation(
                        translation: Offset(
                          sliding
                              ? _slideDirection *
                                    (i == previousTab
                                        ? -progress
                                        : i == visibleTab
                                        ? 1 - progress
                                        : 0)
                              : 0,
                          0,
                        ),
                        // Its own layer, so sliding a page moves pixels already
                        // painted instead of repainting it on every frame —
                        // and scrolling one page doesn't repaint the others.
                        child: RepaintBoundary(
                          child: _visitedTabs.contains(i)
                              ? pages[i]
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    },
  );

  Future<void> _openMoneyEntry() => showAddTransactionSheet(
    context,
    accountStore: widget.accountStore,
    categoryStore: widget.categoryStore,
    transactionStore: widget.transactionStore,
  );

  void _backToHome() => _selectTab(0);

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Off Home, back returns to it instead of closing the app; on Home,
      // back behaves normally.
      canPop: selectedTab == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // A blocked pop never reaches the route's local history, so anything
        // open on top of a tab (the ⋮ menu) has to be dismissed from here.
        if (ModalRoute.of(context)?.willHandlePopInternally ?? false) {
          Navigator.of(context).pop();
          return;
        }
        if (selectedTab == 1 &&
            (_transactions.currentState?.handleBack() ?? false)) {
          return;
        }
        if (selectedTab != 0) _backToHome();
      },
      child: _scaffold(),
    );
  }

  Widget _scaffold() {
    return Scaffold(
      // The tab bar is glass: the tabs have to run underneath it.
      extendBody: true,
      body: AccentGlowScope(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragStart: _startTabDrag,
          onHorizontalDragUpdate: _updateTabDrag,
          onHorizontalDragEnd: _endTabDrag,
          onHorizontalDragCancel: () => _settleTabDrag(false),
          child: _tabBody([
            HomeDashboard(
              smsStore: _sms,
              onReviewSms: _openSms,
              loanStore: widget.loanStore,
              subscriptionStore: widget.subscriptionStore,
              debtStore: widget.debtStore,
              accountStore: widget.accountStore,
              categoryStore: widget.categoryStore,
              transactionStore: widget.transactionStore,
              budgetStore: widget.budgetStore,
              themeMode: widget.themeMode,
              onChangeThemeMode: widget.onChangeThemeMode,
              onOpenTransactions: _openTransactions,
              onOpenBudgets: _openBudgets,
            ),
            TransactionsScreen(
              key: _transactions,
              parentHandlesBack: true,
              initialMonth: transactionMonth,
              monthRequest: transactionRequest,
              accountStore: widget.accountStore,
              categoryStore: widget.categoryStore,
              transactionStore: widget.transactionStore,
              onAddTransaction: _openMoneyEntry,
            ),
            BudgetsScreen(
              key: _budgets,
              initialMonth: budgetMonth,
              initialCurrency: budgetCurrency,
              monthRequest: budgetRequest,
              accountStore: widget.accountStore,
              categoryStore: widget.categoryStore,
              transactionStore: widget.transactionStore,
              budgetStore: widget.budgetStore,
            ),
            MoreScreen(
              syncController: widget.syncController,
              store: widget.accountStore,
              categoryStore: widget.categoryStore,
              transactionStore: widget.transactionStore,
              debtStore: widget.debtStore,
              loanStore: widget.loanStore,
              subscriptionStore: widget.subscriptionStore,
              // Approved suggestions can touch the ledger and the SMS queue,
              // which reloads itself when the transactions do.
              onLedgerChanged: _sms.onLedgerChanged,
              onRulesChanged: _sms.rulesChanged,
              smsStore: _sms,
              aiSession: _ai,
              community: widget.community,
            ),
          ]),
        ),
      ),
      floatingActionButton: switch (selectedTab) {
        0 => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (UpiSettingsScope.maybeOf(context)?.enabled ?? false) ...[
              FloatingActionButton.small(
                heroTag: 'upi_scan',
                tooltip: 'Scan QR',
                onPressed: () => _openUpi(),
                child: const Icon(Icons.qr_code_scanner),
              ),
              const SizedBox(height: 12),
            ],
            AddFab(onPressed: _openMoneyEntry, tooltip: 'Add transaction'),
          ],
        ),
        1 => AddFab(onPressed: _openMoneyEntry, tooltip: 'Add transaction'),
        2 => AddFab(
          onPressed: () => _budgets.currentState?.addBudget(),
          tooltip: 'Add budget',
        ),
        _ => null,
      },
      // Hidden while a sheet is open: the bar's white glass sits right behind
      // the sheet's frost and shows through as a white band. At zero opacity
      // it isn't painted either, so its glass costs nothing meanwhile.
      bottomNavigationBar: ValueListenableBuilder<int>(
        valueListenable: AdaptiveSheetRoute.open,
        builder: (context, sheets, child) => IgnorePointer(
          ignoring: sheets > 0,
          child: AnimatedOpacity(
            opacity: sheets > 0 ? 0 : 1,
            duration: const Duration(milliseconds: 180),
            child: child,
          ),
        ),
        child: LiquidGlassNavBar(
          selectedIndex: selectedTab,
          onDestinationSelected: _selectTab,
          destinations: [
            const LiquidGlassDestination(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home_rounded,
              label: 'Home',
            ),
            LiquidGlassDestination(
              icon: Theme.of(context).brightness == Brightness.light
                  ? Icons.format_list_bulleted_rounded
                  : Icons.receipt_long_outlined,
              selectedIcon: Theme.of(context).brightness == Brightness.light
                  ? Icons.format_list_bulleted_rounded
                  : Icons.receipt_long_rounded,
              label: 'Transactions',
            ),
            const LiquidGlassDestination(
              icon: Icons.bar_chart_rounded,
              selectedIcon: Icons.bar_chart_rounded,
              label: 'Budgets',
            ),
            const LiquidGlassDestination(
              icon: Icons.more_horiz_rounded,
              selectedIcon: Icons.more_horiz_rounded,
              label: 'More',
            ),
          ],
        ),
      ),
    );
  }
}
