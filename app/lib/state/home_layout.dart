import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Every section Home can show, in the order a fresh install shows them.
enum HomeCardId {
  overview,
  upcomingEmis,
  upcomingPayments,
  upcomingDebts,
  smsHistory,
  spendingPace,
  committed,
  spending,
  cashFlow,
  accounts,
  netWorth,
  loanPayoff,
  debts,
  recentTransactions,
}

extension HomeCardInfo on HomeCardId {
  String get label => switch (this) {
    HomeCardId.upcomingEmis => 'Upcoming EMIs',
    HomeCardId.upcomingPayments => 'Upcoming payments',
    HomeCardId.upcomingDebts => 'Upcoming debts',
    HomeCardId.overview => 'Month overview',
    HomeCardId.smsHistory => 'Needs your review',
    HomeCardId.spendingPace => 'Spending pace',
    HomeCardId.committed => 'Coming up',
    HomeCardId.spending => 'Top expense categories',
    HomeCardId.cashFlow => 'Money in vs money out',
    HomeCardId.accounts => 'Accounts',
    HomeCardId.netWorth => 'Net worth',
    HomeCardId.loanPayoff => 'Loan payoff',
    HomeCardId.debts => 'Debts',
    HomeCardId.recentTransactions => 'Recent transactions',
  };

  String get description => switch (this) {
    HomeCardId.upcomingEmis => 'Loan payments due this week',
    HomeCardId.upcomingPayments =>
      'Rent, subscriptions and bills due this week',
    HomeCardId.upcomingDebts => 'Money due to or from people this week',
    HomeCardId.overview => 'Net savings, income, spent and budget left',
    HomeCardId.smsHistory => 'Bank messages waiting for a category or account',
    HomeCardId.spendingPace => 'This month against last, day by day',
    HomeCardId.committed => 'Payments to make and money to get, next 30 days',
    HomeCardId.spending => 'Where the month’s money went',
    HomeCardId.cashFlow => 'Six months of money in and out',
    HomeCardId.accounts => 'Your first few balances',
    HomeCardId.netWorth => 'What you own minus what you owe',
    HomeCardId.loanPayoff => 'Balance left and when you’ll be debt-free',
    HomeCardId.debts => 'What people owe you and what you owe',
    HomeCardId.recentTransactions => 'The month’s latest entries',
  };

  IconData get icon => switch (this) {
    HomeCardId.upcomingEmis => Icons.account_balance_outlined,
    HomeCardId.upcomingPayments => Icons.autorenew_rounded,
    HomeCardId.upcomingDebts => Icons.handshake_outlined,
    HomeCardId.overview => Icons.savings_outlined,
    HomeCardId.smsHistory => Icons.sms_outlined,
    HomeCardId.spendingPace => Icons.show_chart_rounded,
    HomeCardId.committed => Icons.lock_clock_outlined,
    HomeCardId.spending => Icons.donut_large_rounded,
    HomeCardId.cashFlow => Icons.bar_chart_rounded,
    HomeCardId.accounts => Icons.account_balance_wallet_outlined,
    HomeCardId.netWorth => Icons.trending_up_rounded,
    HomeCardId.loanPayoff => Icons.flag_outlined,
    HomeCardId.debts => Icons.handshake_outlined,
    HomeCardId.recentTransactions => Icons.receipt_long_outlined,
  };

  bool get isChart => switch (this) {
    HomeCardId.spendingPace ||
    HomeCardId.committed ||
    HomeCardId.spending ||
    HomeCardId.cashFlow ||
    HomeCardId.netWorth ||
    HomeCardId.debts ||
    HomeCardId.loanPayoff => true,
    _ => false,
  };
}

/// Which Home cards show, and in what order. Saved on the device only — it's
/// a preference about this screen, not part of the ledger a backup carries.
class HomeLayout extends ChangeNotifier {
  static const orderKey = 'home_card_order';
  static const hiddenKey = 'home_card_hidden';

  List<HomeCardId> _order = HomeCardId.values;
  Set<HomeCardId> _hidden = {};
  bool _disposed = false;
  int _revision = 0;

  /// Every card, shown or not, in Home's order.
  List<HomeCardId> get order => List.unmodifiable(_order);
  bool isVisible(HomeCardId id) => !_hidden.contains(id);
  List<HomeCardId> get visible => [
    for (final id in _order)
      if (!_hidden.contains(id)) id,
  ];
  bool get isDefault =>
      _hidden.isEmpty &&
      _order.indexed.every((e) => e.$2 == HomeCardId.values[e.$1]);

  Future<void> restore() async {
    final revision = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || revision != _revision) return;
      _order = _merge(prefs.getStringList(orderKey));
      _hidden = {...?prefs.getStringList(hiddenKey)?.map(_byName).nonNulls};
      notifyListeners();
    } catch (_) {
      // Keep the default layout.
    }
  }

  void setVisible(HomeCardId id, bool visible) {
    if (visible == isVisible(id)) return;
    _hidden = visible ? ({..._hidden}..remove(id)) : {..._hidden, id};
    _changed();
  }

  /// [newIndex] is where the card ends up, counted after it was removed.
  void move(int oldIndex, int newIndex) {
    if (oldIndex == newIndex) return;
    final order = [..._order];
    order.insert(newIndex, order.removeAt(oldIndex));
    _order = order;
    _changed();
  }

  void reset() {
    _order = HomeCardId.values;
    _hidden = {};
    _changed();
  }

  void _changed() {
    _revision++;
    notifyListeners();
    _save();
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(orderKey, [for (final id in _order) id.name]);
      await prefs.setStringList(hiddenKey, [for (final id in _hidden) id.name]);
    } catch (_) {
      // The layout still applies for this session.
    }
  }

  static HomeCardId? _byName(String name) =>
      HomeCardId.values.where((id) => id.name == name).firstOrNull;

  /// The saved order, with cards it doesn't know dropped and cards added
  /// since slotted in after the card they follow by default.
  static List<HomeCardId> _merge(List<String>? saved) {
    if (saved == null) return HomeCardId.values;
    final order = <HomeCardId>[
      ...{...saved.map(_byName).nonNulls},
    ];
    for (final id in HomeCardId.values) {
      if (order.contains(id)) continue;
      final before = HomeCardId.values
          .take(id.index)
          .lastWhere(order.contains, orElse: () => id);
      order.insert(before == id ? 0 : order.indexOf(before) + 1, id);
    }
    return order;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class HomeLayoutScope extends InheritedNotifier<HomeLayout> {
  const HomeLayoutScope({
    super.key,
    required HomeLayout layout,
    required super.child,
  }) : super(notifier: layout);

  static HomeLayout? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<HomeLayoutScope>()?.notifier;
}
