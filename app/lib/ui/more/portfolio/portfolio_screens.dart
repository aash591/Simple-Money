import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/currency_digits.dart';
import '../../../domain/holding.dart';
import '../../../domain/transaction.dart';
import '../../../state/account_store.dart';
import '../../../state/category_store.dart';
import '../../../state/holding_store.dart';
import '../../../state/transaction_store.dart';
import '../../components/action_buttons.dart';
import '../../components/animated_amount.dart';
import '../../components/account_tile.dart' show AccountLogo;
import '../../components/app_icon.dart';
import '../../components/private_amount.dart';
import '../../components/search_field.dart';
import '../../components/segmented_pill.dart';
import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import '../../components/menu_list.dart';
import '../../components/more_popup_button.dart';
import '../../components/transactions/transaction_day_group.dart';
import '../../components/transactions/transaction_list_row.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/transaction_sheet.dart';
import '../../transactions/transaction_widgets.dart';
import 'add_holding_screen.dart';
import 'portfolio_sheets.dart';
import 'trade_sheet.dart';
import 'broker_money_sheet.dart';
import 'select_place_screen.dart';

String formatUnits(int unitsE6) {
  final text = (unitsE6 / unitScale).toStringAsFixed(4);
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}

/// A price in [currency], which is the account's own unless a holding is
/// quoted in another.
String formatPrice(int priceE4, Account broker, {String? currency}) {
  final code = currency ?? broker.currency;
  final whole = priceE4 % priceScale == 0;
  final text = NumberFormat.decimalPatternDigits(
    locale: code == 'INR' ? 'en_IN' : 'en_US',
    decimalDigits: whole ? 0 : (priceE4 % 100 == 0 ? 2 : 4),
  ).format(priceE4 / priceScale);
  return '${currencyPrefix(code)}$text';
}

/// What is held in [currency], as "$ 710 in USD", or just "CNY 2,000" for a
/// currency with no symbol, where the code is already the prefix.
String _heldIn(int minor, String currency) {
  final text = _moneyIn(minor, currency);
  return text.startsWith(currency) ? text : '$text in $currency';
}

/// An amount in another currency than [broker]'s own.
String _moneyIn(int minor, String currency) => formatAccountMoney(
  minor,
  digits: currencyDigits(currency),
  currency: currency,
);

String _money(int minor, Account broker) =>
    formatAccountMoney(minor, digits: broker.digits, currency: broker.currency);

String _signed(int minor, Account broker) =>
    '${minor > 0 ? '+' : ''}${_money(minor, broker)}';

String _percent(double fraction) =>
    '${fraction > 0 ? '+' : ''}${(fraction * 100).toStringAsFixed(1)}%';

Color _gainColor(BuildContext context, int? gain) {
  final colors = SheetColors.of(context);
  if (gain == null || gain == 0) return colors.muted;
  return gain > 0 ? colors.income : colors.expense;
}

// ---- Portfolio ---------------------------------------------------------------

/// The header button that fetches today's closing prices.
class _RefreshButton extends StatelessWidget {
  const _RefreshButton({required this.store});
  final HoldingStore store;

  @override
  Widget build(BuildContext context) => store.refreshing
      ? const Padding(
          padding: EdgeInsets.symmetric(horizontal: 14),
          child: Center(
            child: SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        )
      : IconButton(
          tooltip: 'Update prices',
          icon: const Icon(Icons.refresh_rounded),
          onPressed: () => refreshPricesWithMessage(context, store),
        );
}

/// Every broker with what it is worth, cash included.
class PortfolioScreen extends StatelessWidget {
  const PortfolioScreen({
    super.key,
    required this.accounts,
    required this.holdings,
    required this.transactions,
    required this.categories,
  });
  final AccountStore accounts;
  final HoldingStore holdings;
  final TransactionStore transactions;
  final CategoryStore categories;

  Future<void> _addBroker(BuildContext context) async {
    final id = await Navigator.of(context)
        .push(FeatureRoute<int>(SelectPlaceScreen(accounts: accounts)));
    if (id != null && context.mounted) {
      await Navigator.of(context).push(
        FeatureRoute<void>(
          BrokerScreen(
            brokerId: id,
            accounts: accounts,
            holdings: holdings,
            transactions: transactions,
            categories: categories,
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([accounts, holdings]),
    builder: (context, _) {
      final brokers = accounts.accounts.where((a) => a.isBroker).toList();
      final text = Theme.of(context).textTheme;
      return FeaturePage(
        title: 'Portfolio',
        actions: [if (holdings.prices != null) _RefreshButton(store: holdings)],
        // With no brokers the empty state already carries the add button.
        floatingActionButton: brokers.isEmpty
            ? null
            : AddFab(
                tooltip: 'Add investment account',
                onPressed: () => _addBroker(context),
              ),
        child: brokers.isEmpty
            ? EmptyState(
                icon: Icons.show_chart_rounded,
                title: 'Track your investments',
                message: 'Add the broker or app where you invest, then record what you hold there, like stocks, ETFs and funds.',
                actionLabel: 'Add investment account',
                onAction: () => _addBroker(context),
              )
            : ListView(
                // Room at the bottom so the add button never covers a broker.
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 96),
                children: [
                  for (final currency in {for (final b in brokers) b.currency})
                    _CurrencySummary(
                      brokers: [
                        for (final b in brokers)
                          if (b.currency == currency) b,
                      ],
                      holdings: holdings,
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 10),
                    child: Text('Accounts', style: text.titleSmall),
                  ),
                  for (final b in brokers)
                    _BrokerTile(
                      broker: b,
                      holdings: holdings,
                      onTap: () => Navigator.of(context).push(
                        FeatureRoute<void>(
                          BrokerScreen(
                            brokerId: b.id,
                            accounts: accounts,
                            holdings: holdings,
                            transactions: transactions,
                            categories: categories,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
      );
    },
  );
}

class _CurrencySummary extends StatelessWidget {
  const _CurrencySummary({required this.brokers, required this.holdings});
  final List<Account> brokers;
  final HoldingStore holdings;

  @override
  Widget build(BuildContext context) {
    final first = brokers.first;
    var value = 0, cost = 0, cash = 0;
    final foreign = <String, ({int own, int? converted})>{};
    for (final b in brokers) {
      value += holdings.holdingsValueMinor(b);
      cost += holdings.holdingsCostMinor(b);
      cash += b.balanceMinor;
      for (final MapEntry(key: code, value: part)
          in holdings.foreignTotals(b).entries) {
        final before = foreign[code];
        foreign[code] = (
          own: (before?.own ?? 0) + part.own,
          converted: before == null
              ? part.converted
              : (before.converted == null || part.converted == null)
              ? null
              : before.converted! + part.converted!,
        );
      }
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: _BrokerCard(
        title: 'Portfolio value',
        broker: first,
        total: value,
        value: value,
        cost: cost,
        funds: cash,
        foreign: foreign,
      ),
    );
  }
}

/// One investment account in the list, drawn like an account card: its logo
/// in a disc, name and kind across the top, what its holdings are worth big
/// underneath, then the gain and the cash beside it.
class _BrokerTile extends StatelessWidget {
  const _BrokerTile({
    required this.broker,
    required this.holdings,
    required this.onTap,
  });
  final Account broker;
  final HoldingStore holdings;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final dark = theme.brightness == Brightness.dark;
    final text = theme.textTheme;
    final value = holdings.holdingsValueMinor(broker);
    final cost = holdings.holdingsCostMinor(broker);
    final gain = value - cost;
    final count = holdings.holdingsOf(broker.id).length;
    const radius = BorderRadius.all(Radius.circular(22));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Ink(
        decoration: BoxDecoration(
          borderRadius: radius,
          border: Border.all(color: scheme.onSurface.withValues(alpha: .06)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              scheme.primary.withValues(alpha: dark ? .16 : .10),
              scheme.onSurface.withValues(alpha: dark ? .05 : .025),
            ],
          ),
        ),
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    broker.icon == null
                        ? Container(
                            width: 42,
                            height: 42,
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: .12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              broker.place?.icon ?? Icons.show_chart_rounded,
                              color: scheme.primary,
                              size: 22,
                            ),
                          )
                        : AccountLogo(broker.icon),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            broker.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: text.titleMedium,
                          ),
                          Text(
                            '${broker.place?.tag ?? 'Account'} · '
                            '$count ${count == 1 ? 'holding' : 'holdings'}',
                            style: text.bodySmall,
                          ),
                        ],
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    _money(value, broker),
                    style: text.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.5,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (cost > 0)
                      Flexible(
                        child: Text(
                          '${_signed(gain, broker)} (${_percent(gain / cost)})',
                          overflow: TextOverflow.ellipsis,
                          style: text.bodySmall?.copyWith(
                            color: _gainColor(context, gain),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    if (cost > 0) const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        'Funds ${_money(broker.balanceMinor, broker)}',
                        overflow: TextOverflow.ellipsis,
                        style: text.bodySmall,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---- One broker --------------------------------------------------------------

/// One broker: its value and, on two tabs, what it holds and the money moved
/// in and out. The add button follows the tab.
class BrokerScreen extends StatefulWidget {
  const BrokerScreen({
    super.key,
    required this.brokerId,
    required this.accounts,
    required this.holdings,
    required this.transactions,
    required this.categories,
  });
  final int brokerId;
  final AccountStore accounts;
  final HoldingStore holdings;
  final TransactionStore transactions;
  final CategoryStore categories;

  @override
  State<BrokerScreen> createState() => _BrokerScreenState();
}

class _BrokerScreenState extends State<BrokerScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() => setState(() {}));
  final _search = TextEditingController();

  @override
  void dispose() {
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _BrokerView(
    tabs: _tabs,
    search: _search,
    onSearch: (_) => setState(() {}),
    brokerId: widget.brokerId,
    accounts: widget.accounts,
    holdings: widget.holdings,
    transactions: widget.transactions,
    categories: widget.categories,
  );
}

class _BrokerView extends StatelessWidget {
  const _BrokerView({
    required this.tabs,
    required this.search,
    required this.onSearch,
    required this.brokerId,
    required this.accounts,
    required this.holdings,
    required this.transactions,
    required this.categories,
  });
  final TabController tabs;
  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final int brokerId;
  final AccountStore accounts;
  final HoldingStore holdings;
  final TransactionStore transactions;
  final CategoryStore categories;

  Future<void> _addTransfer(BuildContext context, Account broker) =>
      showBrokerMoneySheet(
        context,
        accounts: accounts,
        transactions: transactions,
        broker: broker,
      );

  Future<void> _addHolding(BuildContext context, Account broker) async {
    final added = await Navigator.of(context).push(
      FeatureRoute<AddedHolding>(
        AddHoldingScreen(store: holdings, broker: broker),
      ),
    );
    final holding = added == null ? null : holdings.byId(added.id);
    // Only when the person asked to record what they already own of it.
    if (holding != null && added!.addPurchase && context.mounted) {
      await showTradeSheet(
        context,
        store: holdings,
        accounts: accounts,
        holding: holding,
        type: TradeType.buy,
      );
    }
  }

  Future<void> _delete(BuildContext context, Account broker) async {
    final ok = await showConfirmationAlert(
      context,
      title: 'Delete ${broker.name}?',
      message:
          'Its holdings and trades are removed too, and so are its transfers. '
          'This can’t be undone.',
    );
    if (!ok || !context.mounted) return;
    await accounts.delete(broker.id);
    await holdings.load();
    if (context.mounted) Navigator.of(context).pop();
  }

  /// Every ledger entry that touches this broker (deposits, withdrawals and
  /// anything else posted to it), newest first.
  List<MoneyTransaction> _entriesOf(Account broker) =>
      [
        for (final t in transactions.transactions)
          if (t.accountId == broker.id || t.toAccountId == broker.id) t,
      ]..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        return byDate != 0 ? byDate : b.id.compareTo(a.id);
      });

  /// An entry's amount in the currency it was in on this broker's side: what
  /// arrived for money paid in, what left for anything else.
  String _entryAmount(MoneyTransaction t, Account broker) {
    final paidIn = t.toAccountId == broker.id;
    final account = paidIn ? broker : accounts.byId(t.accountId);
    return formatTransactionMoney(
      paidIn ? t.receivedMinor : t.amountMinor,
      account,
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([accounts, holdings, transactions]),
    builder: (context, _) {
      final broker = accounts.byId(brokerId);
      if (broker == null) return const SizedBox.shrink();
      final query = search.text.trim().toLowerCase();
      bool matches(Iterable<String?> texts) =>
          query.isEmpty ||
          texts.any((t) => t != null && t.toLowerCase().contains(query));
      final entries = [
        for (final t in _entriesOf(broker))
          if (matches([
            t.title,
            t.note,
            accounts.byId(t.accountId)?.name,
            accounts.byId(t.toAccountId)?.name,
            _entryAmount(t, broker),
          ]))
            t,
      ];
      final list = [
        for (final h in holdings.holdingsOf(broker.id))
          if (matches([h.name, h.symbol])) h,
      ];
      final value = holdings.holdingsValueMinor(broker);
      final cost = holdings.holdingsCostMinor(broker);
      final searching = query.isNotEmpty;
      final holdingsTab = tabs.index == 0;
      final textScaler = MediaQuery.textScalerOf(context);
      return FeaturePage(
        title: broker.name,
        titleIcon: broker.icon == null ? null : AppIcon(broker.icon, size: 32),
        floatingActionButton: AddFab(
          tooltip: holdingsTab ? 'Add holding' : 'Add deposit or withdrawal',
          onPressed: () => holdingsTab
              ? _addHolding(context, broker)
              : _addTransfer(context, broker),
        ),
        actions: [
          if (holdings.prices != null) _RefreshButton(store: holdings),
          MorePopupButton<String>(
            fitContent: true,
            items: const [
              MorePopupItem(value: 'delete', label: 'Delete account'),
            ],
            onSelected: (action) {
              if (action == 'delete') _delete(context, broker);
            },
          ),
        ],
        // The summary scrolls away; the tabs and search stay under the header.
        child: NestedScrollView(
          headerSliverBuilder: (context, _) => [
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
              sliver: SliverToBoxAdapter(
                child: _BrokerCard(
                  broker: broker,
                  total: value,
                  value: value,
                  cost: cost,
                  foreign: holdings.foreignTotals(broker),
                ),
              ),
            ),
            SliverOverlapAbsorber(
              handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
              sliver: SliverPersistentHeader(
                pinned: true,
                delegate: _BrokerTabsHeader(
                  controller: tabs,
                  search: search,
                  onSearch: onSearch,
                  hint: holdingsTab ? 'Search holdings' : 'Search transfers',
                  background: Theme.of(context).scaffoldBackgroundColor,
                  textScaler: textScaler,
                ),
              ),
            ),
          ],
          body: TabBarView(
            controller: tabs,
            children: [
              _TabList(
                name: 'holdings',
                empty: searching
                    ? 'No holdings match.'
                    : 'No holdings yet. Tap + to add one.',
                child: list.isEmpty
                    ? null
                    : MenuGroup(
                        children: [
                          for (final h in list)
                            _HoldingRow(
                              holding: h,
                              broker: broker,
                              store: holdings,
                              onTap: () => Navigator.of(context).push(
                                FeatureRoute<void>(
                                  HoldingScreen(
                                    holdingId: h.id,
                                    accounts: accounts,
                                    holdings: holdings,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
              ),
              _TabList(
                name: 'transfers',
                empty: searching
                    ? 'No transfers match.'
                    : 'No deposits or withdrawals yet.',
                child: entries.isEmpty
                    ? null
                    : Column(
                        children: [
                          for (final (day, items) in groupByDay(
                            entries,
                            (t) => t.date,
                          ))
                            TransactionDayGroup(
                              date: day,
                              padding: const EdgeInsets.only(bottom: 22),
                              rows: [
                                for (final t in items)
                                  _entryRow(context, t, broker),
                              ],
                            ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      );
    },
  );

  Widget _entryRow(BuildContext context, MoneyTransaction t, Account broker) {
    final scheme = Theme.of(context).colorScheme;
    final byId = {for (final c in categories.categories) c.id: c};
    final category = byId[t.categoryId];
    // Money in and money out each get their own arrow, the same two the
    // Deposit and Withdraw buttons carry, rather than the transfer swap.
    final Widget? arrow = t.type != TransactionType.transfer
        ? null
        : Icon(
            t.toAccountId == broker.id
                ? Icons.south_west_rounded
                : Icons.north_east_rounded,
            color: scheme.primary,
            size: 28,
          );
    return TransactionListRow(
      transaction: t,
      account: accounts.byId(t.accountId),
      toAccount: accounts.byId(t.toAccountId),
      category: category,
      parentCategory: byId[category?.parentId],
      formattedAmount: _entryAmount(t, broker),
      icon: arrow,
      onTap: () => showViewTransactionSheet(
        context,
        transaction: t,
        accountStore: accounts,
        categoryStore: categories,
        transactionStore: transactions,
      ),
    );
  }
}

class _HoldingRow extends StatelessWidget {
  const _HoldingRow({
    required this.holding,
    required this.broker,
    required this.store,
    required this.onTap,
  });
  final Holding holding;
  final Account broker;
  final HoldingStore store;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final position = store.positionFor(holding);
    final value = store.valueMinor(holding, broker);
    final gain = value == null ? null : value - position.costMinor;
    final fraction = gain == null || position.costMinor <= 0
        ? null
        : gain / position.costMinor;
    // A holding quoted in another currency shows that first, then what it
    // comes to here.
    final code = holding.currencyIn(broker.currency);
    final own = code == broker.currency
        ? null
        : store.valueInOwnCurrency(holding, broker);
    final text = Theme.of(context).textTheme;
    return MenuRow(
      icon: holding.kind == HoldingKind.fund
          ? Icons.pie_chart_rounded
          : Icons.candlestick_chart_rounded,
      title: holding.name,
      subtitle: position.isEmpty
          ? 'Sold out'
          : '${formatUnits(position.unitsE6)} units'
                '${holding.lastPriceE4 == null ? ' · no price yet' : ''}',
      onTap: onTap,
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            own != null
                ? _moneyIn(own, code)
                : _money(value ?? position.costMinor, broker),
            style: text.titleSmall,
          ),
          if (own != null)
            Text(
              value == null ? 'no rate yet' : '≈ ${_money(value, broker)}',
              style: text.bodySmall,
            ),
          if (gain != null && fraction != null)
            Text(
              _percent(fraction),
              style: text.bodySmall?.copyWith(color: _gainColor(context, gain)),
            ),
        ],
      ),
    );
  }
}

// ---- One holding -------------------------------------------------------------

class HoldingScreen extends StatelessWidget {
  const HoldingScreen({
    super.key,
    required this.holdingId,
    required this.accounts,
    required this.holdings,
  });
  final int holdingId;
  final AccountStore accounts;
  final HoldingStore holdings;

  Future<void> _deleteHolding(
    BuildContext context,
    Holding holding,
    Account broker,
  ) async {
    final ok = await showConfirmationAlert(
      context,
      title: 'Delete ${holding.name}?',
      message:
          'Its trades are removed and their cash goes back to where it came '
          'from. This can’t be undone.',
    );
    if (!ok || !context.mounted) return;
    await holdings.deleteHolding(holding);
    if (context.mounted) Navigator.of(context).pop();
  }

  Future<void> _deleteTrade(BuildContext context, HoldingTrade trade) async {
    final ok = await showConfirmationAlert(
      context,
      title: 'Delete this ${trade.type.label.toLowerCase()}?',
      message: 'Its cash goes back to where it came from.',
    );
    if (!ok || !context.mounted) return;
    try {
      await holdings.deleteTrade(trade);
    } on ArgumentError catch (e) {
      if (context.mounted) {
        await showConfirmationAlert(
          context,
          title: 'Can’t delete this',
          message: '${e.message}',
          confirmLabel: 'OK',
          showCancel: false,
          destructive: false,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([accounts, holdings]),
    builder: (context, _) {
      final holding = holdings.byId(holdingId);
      final broker = holding == null ? null : accounts.byId(holding.accountId);
      if (holding == null || broker == null) return const SizedBox.shrink();
      final position = holdings.positionFor(holding);
      final price = holding.lastPriceE4;
      final value = holdings.valueMinor(holding, broker);
      final gain = value == null ? null : value - position.costMinor;
      final fraction = gain == null || position.costMinor <= 0
          ? null
          : gain / position.costMinor;
      final code = holding.currencyIn(broker.currency);
      final foreign = code != broker.currency;
      final own = foreign ? holdings.valueInOwnCurrency(holding, broker) : null;
      final average = position.averagePriceE4(broker.digits);
      final trades = holdings.tradesOf(holding.id);
      final text = Theme.of(context).textTheme;
      final held = !position.isEmpty;
      return FeaturePage(
        title: holding.name,
        actions: [
          MorePopupButton<String>(
            fitContent: true,
            items: [
              if (holdings.prices != null)
                const MorePopupItem(value: 'update', label: 'Update prices'),
              const MorePopupItem(value: 'price', label: 'Set price by hand'),
              const MorePopupItem(
                value: 'delete',
                label: 'Delete holding',
                dividerBefore: true,
              ),
            ],
            onSelected: (action) {
              switch (action) {
                case 'update':
                  if (!holdings.refreshing) {
                    refreshPricesWithMessage(context, holdings);
                  }
                case 'price':
                  showPriceSheet(
                    context,
                    store: holdings,
                    holding: holding,
                    broker: broker,
                  );
                case 'delete':
                  _deleteHolding(context, holding, broker);
              }
            },
          ),
        ],
        child: Column(
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                children: [
                  MoneyCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${holding.kind.label}'
                          '${holding.symbol == null ? '' : ' · ${holding.symbol}'}'
                          '${holding.exchange == null ? '' : ' · ${holding.exchange}'}',
                          style: text.bodySmall,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          value == null ? '—' : _money(value, broker),
                          style: text.headlineMedium?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        if (own != null)
                          Text(
                            '${_heldIn(own, code)}'
                            '${value == null ? ' · no rate yet' : ''}',
                            style: text.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        if (gain != null && fraction != null)
                          Text(
                            '${_signed(gain, broker)} (${_percent(fraction)})',
                            style: text.bodyMedium?.copyWith(
                              color: _gainColor(context, gain),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        const SizedBox(height: 12),
                        _StatRow('Units', formatUnits(position.unitsE6)),
                        _StatRow(
                          'Average cost',
                          average == null
                              ? '—'
                              : formatPrice(
                                  (average / 100).round() * 100,
                                  broker,
                                ),
                        ),
                        _StatRow(
                          holding.priceDate == null
                              ? 'Unit price'
                              : 'Unit price · ${DateFormat('d MMM').format(holding.priceDate!)}',
                          price == null
                              ? '—'
                              : formatPrice(price, broker, currency: code),
                        ),
                        if (position.realizedMinor != 0)
                          _StatRow(
                            'Booked profit',
                            _signed(position.realizedMinor, broker),
                            color: _gainColor(context, position.realizedMinor),
                          ),
                        if (position.dividendsMinor != 0)
                          _StatRow(
                            'Dividends',
                            _money(position.dividendsMinor, broker),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 8),
                  if (trades.isNotEmpty)
                    MenuGroup(
                      label: 'History · tap one to delete it',
                      children: [
                        for (final t in trades)
                          MenuRow(
                            icon: switch (t.type) {
                              TradeType.buy => Icons.add_shopping_cart_rounded,
                              TradeType.sell => Icons.sell_rounded,
                              TradeType.dividend => Icons.payments_rounded,
                            },
                            title: t.type == TradeType.dividend
                                ? 'Dividend'
                                : '${t.type.label} ${formatUnits(t.unitsE6)} @ '
                                      '${formatPrice(t.priceE4, broker, currency: code)}',
                            subtitle:
                                '${DateFormat('d MMM y').format(t.date)}'
                                '${t.feesMinor > 0 ? ' · fees ${_money(t.feesMinor, broker)}' : ''}',
                            trailing: Text(
                              _signed(t.cashEffectMinor, broker),
                              style: text.titleSmall?.copyWith(
                                color: _gainColor(context, t.cashEffectMinor),
                              ),
                            ),
                            onTap: () => _deleteTrade(context, t),
                          ),
                      ],
                    ),
                ],
              ),
            ),
            // Always in reach, at the bottom.
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                child: Row(
                  children: [
                    for (final type in TradeType.values) ...[
                      if (type != TradeType.buy) const SizedBox(width: 12),
                      Expanded(
                        child: PillButton(
                          label: type.label,
                          primary: type == TradeType.buy,
                          onPressed: type == TradeType.sell && !held
                              ? null
                              : () => showTradeSheet(
                                  context,
                                  store: holdings,
                                  accounts: accounts,
                                  holding: holding,
                                  type: type,
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
    },
  );
}

/// A broker's summary, laid out like the accounts total: the figure large
/// under its title, the currency beside it, and the parts underneath.
class _BrokerCard extends StatelessWidget {
  const _BrokerCard({
    this.title = 'Total value',
    this.funds,
    required this.broker,
    required this.total,
    required this.value,
    required this.cost,
    required this.foreign,
  });
  final Account broker;
  final int total, value, cost;
  final String title;

  /// The cash held; the account's own balance when null.
  final int? funds;

  /// What is held in each other currency: in it, and in the account's.
  final Map<String, ({int own, int? converted})> foreign;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final gain = value - cost;
    final bigStyle = text.headlineLarge?.copyWith(
      fontSize: 32,
      fontWeight: FontWeight.w700,
    );
    return MoneyCard(
      padding: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(child: Text(title, style: text.titleSmall)),
                const SizedBox(width: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: .08),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    broker.currency,
                    style: text.labelMedium?.copyWith(color: scheme.primary),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            PrivateAmount(
              label: title,
              height: 52,
              maskStyle: bigStyle,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: AnimatedAmount(
                  value: total,
                  format: (minor) => _money(minor, broker),
                  style: bigStyle,
                ),
              ),
            ),
            for (final MapEntry(key: code, value: part) in foreign.entries) ...[
              const SizedBox(height: 6),
              Text(
                part.converted == null
                    ? '${_heldIn(part.own, code)} · no rate yet, '
                          'counted at cost'
                    : '${_heldIn(part.own, code)} '
                          '≈ ${_money(part.converted!, broker)}',
                style: text.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
            ],
            const SizedBox(height: 16),
            Divider(height: 1, color: scheme.outlineVariant),
            const SizedBox(height: 14),
            _StatRow('Funds', _money(funds ?? broker.balanceMinor, broker)),
            _StatRow('Invested', _money(cost, broker)),
            _StatRow(
              'Gain',
              cost > 0
                  ? '${_signed(gain, broker)} (${_percent(gain / cost)})'
                  : '—',
              color: _gainColor(context, gain),
            ),
          ],
        ),
      ),
    );
  }
}

/// One labelled figure on its own line: the label at the start, the figure
/// at the end.
class _StatRow extends StatelessWidget {
  const _StatRow(this.label, this.value, {this.color});
  final String label, value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Text(label, style: text.bodyMedium),
          const SizedBox(width: 12),
          Expanded(
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerRight,
              child: Text(
                value,
                style: text.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Holdings / Transfers and a search field, pinned under the page header
/// while the lists scroll beneath. The tabs also switch by swiping sideways.
class _BrokerTabsHeader extends SliverPersistentHeaderDelegate {
  _BrokerTabsHeader({
    required this.controller,
    required this.search,
    required this.onSearch,
    required this.hint,
    required this.background,
    required this.textScaler,
  });
  final TabController controller;
  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final String hint;
  final Color background;
  final TextScaler textScaler;

  @override
  double get minExtent => textScaler.scale(18) + 34 + SearchField.height + 12;
  @override
  double get maxExtent => minExtent;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlaps) =>
      SizedBox(
        height: maxExtent,
        child: ColoredBox(
          color: background,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 4),
            child: Column(
              children: [
                SegmentedPillTabBar(
                  controller: controller,
                  labels: const ['Holdings', 'Transfers'],
                ),
                const SizedBox(height: 10),
                SearchField(
                  controller: search,
                  onChanged: onSearch,
                  hintText: hint,
                ),
              ],
            ),
          ),
        ),
      );

  @override
  bool shouldRebuild(_BrokerTabsHeader old) =>
      old.controller != controller ||
      old.search != search ||
      old.hint != hint ||
      old.background != background ||
      old.textScaler != textScaler;
}

/// One tab's list, under the pinned header. A null [child] says [empty].
class _TabList extends StatelessWidget {
  const _TabList({
    required this.name,
    required this.empty,
    required this.child,
  });
  final String name, empty;
  final Widget? child;

  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: PageStorageKey(name),
    slivers: [
      SliverOverlapInjector(
        handle: NestedScrollView.sliverOverlapAbsorberHandleFor(context),
      ),
      SliverPadding(
        // Room at the bottom so the add button never covers the last row.
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 96),
        sliver: SliverToBoxAdapter(
          child:
              child ??
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 28),
                child: Text(
                  empty,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
        ),
      ),
    ],
  );
}
