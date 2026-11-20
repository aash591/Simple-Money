import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/holding.dart';
import '../../../state/account_store.dart';
import '../../../state/holding_store.dart';
import '../../../state/transaction_store.dart';
import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import '../../components/menu_list.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/transfer_sheet.dart';
import 'add_broker_screen.dart';
import 'portfolio_sheets.dart';

String formatUnits(int unitsE6) {
  final text = (unitsE6 / unitScale).toStringAsFixed(4);
  return text.replaceFirst(RegExp(r'\.?0+$'), '');
}

String formatPrice(int priceE4, Account broker) {
  final whole = priceE4 % priceScale == 0;
  final text = NumberFormat.decimalPatternDigits(
    locale: broker.currency == 'INR' ? 'en_IN' : 'en_US',
    decimalDigits: whole ? 0 : (priceE4 % 100 == 0 ? 2 : 4),
  ).format(priceE4 / priceScale);
  return '${currencyPrefix(broker.currency)}$text';
}

String _money(int minor, Account broker) => formatAccountMoney(
  minor,
  digits: broker.digits,
  currency: broker.currency,
);

String _signed(int minor, Account broker) =>
    '${minor > 0 ? '+' : ''}${_money(minor, broker)}';

String _percent(double fraction) =>
    '${fraction > 0 ? '+' : ''}${(fraction * 100).toStringAsFixed(1)}%';

Color _gainColor(BuildContext context, int? gain) {
  final colors = SheetColors.of(context);
  if (gain == null || gain == 0) return colors.muted;
  return gain > 0 ? colors.income : colors.expense;
}

/// One figure with its small label, for the summary cards.
class _Stat extends StatelessWidget {
  const _Stat(this.label, this.value, {this.color});
  final String label, value;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: text.bodySmall),
        const SizedBox(height: 3),
        Text(
          value,
          style: text.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
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
  });
  final AccountStore accounts;
  final HoldingStore holdings;
  final TransactionStore transactions;

  Future<void> _addBroker(BuildContext context) async {
    final id = await Navigator.of(context).push(
      FeatureRoute<int>(AddBrokerScreen(accounts: accounts)),
    );
    if (id != null && context.mounted) {
      await Navigator.of(context).push(
        FeatureRoute<void>(
          BrokerScreen(
            brokerId: id,
            accounts: accounts,
            holdings: holdings,
            transactions: transactions,
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
        actions: [
          if (holdings.prices != null) _RefreshButton(store: holdings),
          IconButton(
            tooltip: 'Add broker',
            icon: const Icon(Icons.add_rounded),
            onPressed: () => _addBroker(context),
          ),
        ],
        child: brokers.isEmpty
            ? EmptyState(
                icon: Icons.show_chart_rounded,
                title: 'No brokers yet',
                message:
                    'Add a broker or investing app, then the stocks and funds you hold there.',
                actionLabel: 'Add broker',
                onAction: () => _addBroker(context),
              )
            : ListView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
                children: [
                  for (final currency in {for (final b in brokers) b.currency})
                    _CurrencySummary(
                      brokers: [
                        for (final b in brokers)
                          if (b.currency == currency) b,
                      ],
                      holdings: holdings,
                    ),
                  const SizedBox(height: 8),
                  MenuGroup(
                    label: 'Brokers',
                    children: [
                      for (final b in brokers)
                        MenuRow(
                          icon: Icons.show_chart_rounded,
                          title: b.name,
                          subtitle:
                              'Cash ${_money(b.balanceMinor, b)} · '
                              '${holdings.holdingsOf(b.id).length} holdings',
                          trailing: Text(
                            _money(holdings.totalValueMinor(b), b),
                            style: text.titleSmall,
                          ),
                          onTap: () => Navigator.of(context).push(
                            FeatureRoute<void>(
                              BrokerScreen(
                                brokerId: b.id,
                                accounts: accounts,
                                holdings: holdings,
                                transactions: transactions,
                              ),
                            ),
                          ),
                        ),
                    ],
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
    for (final b in brokers) {
      value += holdings.holdingsValueMinor(b);
      cost += holdings.holdingsCostMinor(b);
      cash += b.balanceMinor;
    }
    final gain = value - cost;
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: MoneyCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Portfolio value · ${first.currency}', style: text.bodySmall),
            const SizedBox(height: 6),
            Text(
              _money(value + cash, first),
              style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Expanded(child: _Stat('Invested', _money(cost, first))),
                Expanded(
                  child: _Stat(
                    'Gain',
                    cost > 0
                        ? '${_signed(gain, first)} (${_percent(gain / cost)})'
                        : '—',
                    color: _gainColor(context, gain),
                  ),
                ),
                Expanded(child: _Stat('Cash', _money(cash, first))),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---- One broker --------------------------------------------------------------

class BrokerScreen extends StatelessWidget {
  const BrokerScreen({
    super.key,
    required this.brokerId,
    required this.accounts,
    required this.holdings,
    required this.transactions,
  });
  final int brokerId;
  final AccountStore accounts;
  final HoldingStore holdings;
  final TransactionStore transactions;

  Future<void> _addHolding(BuildContext context, Account broker) async {
    final id = await showAddHoldingSheet(
      context,
      store: holdings,
      broker: broker,
    );
    final holding = id == null ? null : holdings.byId(id);
    if (holding != null && context.mounted) {
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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([accounts, holdings]),
    builder: (context, _) {
      final broker = accounts.byId(brokerId);
      if (broker == null) return const SizedBox.shrink();
      final list = holdings.holdingsOf(broker.id);
      final value = holdings.holdingsValueMinor(broker);
      final cost = holdings.holdingsCostMinor(broker);
      final gain = value - cost;
      final text = Theme.of(context).textTheme;
      return FeaturePage(
        title: broker.name,
        actions: [
          if (holdings.prices != null) _RefreshButton(store: holdings),
          IconButton(
            tooltip: 'Delete broker',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => _delete(context, broker),
          ),
        ],
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
          children: [
            MoneyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Total value', style: text.bodySmall),
                  const SizedBox(height: 6),
                  Text(
                    _money(holdings.totalValueMinor(broker), broker),
                    style: text.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _Stat('Cash', _money(broker.balanceMinor, broker)),
                      ),
                      Expanded(child: _Stat('Invested', _money(cost, broker))),
                      Expanded(
                        child: _Stat(
                          'Gain',
                          cost > 0
                              ? '${_signed(gain, broker)} (${_percent(gain / cost)})'
                              : '—',
                          color: _gainColor(context, gain),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.south_west_rounded, size: 18),
                    label: const Text('Deposit'),
                    onPressed: () => showTransferSheet(
                      context,
                      accountStore: accounts,
                      transactionStore: transactions,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.north_east_rounded, size: 18),
                    label: const Text('Withdraw'),
                    onPressed: () => showTransferSheet(
                      context,
                      accountStore: accounts,
                      transactionStore: transactions,
                      initialFromAccountId: broker.id,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            if (list.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 24),
                child: Text(
                  'Nothing held here yet.',
                  textAlign: TextAlign.center,
                  style: text.bodyMedium,
                ),
              )
            else
              MenuGroup(
                label: 'Holdings',
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
            const SizedBox(height: 16),
            FilledButton.icon(
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
              ),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add stock or fund'),
              onPressed: () => _addHolding(context, broker),
            ),
          ],
        ),
      );
    },
  );
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
    final value = position.valueMinor(holding.lastPriceE4, broker.digits);
    final gain = position.gainMinor(holding.lastPriceE4, broker.digits);
    final fraction = position.gainFraction(holding.lastPriceE4, broker.digits);
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
            _money(value ?? position.costMinor, broker),
            style: text.titleSmall,
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
      final value = position.valueMinor(price, broker.digits);
      final gain = position.gainMinor(price, broker.digits);
      final fraction = position.gainFraction(price, broker.digits);
      final average = position.averagePriceE4(broker.digits);
      final trades = holdings.tradesOf(holding.id);
      final text = Theme.of(context).textTheme;
      final held = !position.isEmpty;
      return FeaturePage(
        title: holding.name,
        actions: [
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline_rounded),
            onPressed: () => _deleteHolding(context, holding, broker),
          ),
        ],
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 12, 18, 32),
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
                  if (gain != null && fraction != null)
                    Text(
                      '${_signed(gain, broker)} (${_percent(fraction)})',
                      style: text.bodyMedium?.copyWith(
                        color: _gainColor(context, gain),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: _Stat('Units', formatUnits(position.unitsE6)),
                      ),
                      Expanded(
                        child: _Stat(
                          'Average cost',
                          average == null ? '—' : formatPrice(average, broker),
                        ),
                      ),
                      Expanded(
                        child: _Stat(
                          holding.priceDate == null
                              ? 'Price'
                              : 'Price · ${DateFormat('d MMM').format(holding.priceDate!)}',
                          price == null ? '—' : formatPrice(price, broker),
                        ),
                      ),
                    ],
                  ),
                  if (position.realizedMinor != 0 ||
                      position.dividendsMinor != 0) ...[
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _Stat(
                            'Booked profit',
                            _signed(position.realizedMinor, broker),
                            color: _gainColor(context, position.realizedMinor),
                          ),
                        ),
                        Expanded(
                          child: _Stat(
                            'Dividends',
                            _money(position.dividendsMinor, broker),
                          ),
                        ),
                        const Spacer(),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                for (final type in TradeType.values) ...[
                  if (type != TradeType.buy) const SizedBox(width: 10),
                  Expanded(
                    child: (type == TradeType.buy
                        ? FilledButton.new
                        : OutlinedButton.new)(
                      onPressed: type == TradeType.sell && !held
                          ? null
                          : () => showTradeSheet(
                              context,
                              store: holdings,
                              accounts: accounts,
                              holding: holding,
                              type: type,
                            ),
                      child: Text(type.label),
                    ),
                  ),
                ],
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (holdings.prices != null)
                  TextButton(
                    onPressed: holdings.refreshing
                        ? null
                        : () => refreshPricesWithMessage(context, holdings),
                    child: Text(
                      holdings.refreshing ? 'Updating…' : 'Update prices',
                    ),
                  ),
                TextButton(
                  onPressed: () => showPriceSheet(
                    context,
                    store: holdings,
                    holding: holding,
                    broker: broker,
                  ),
                  child: const Text('Set price by hand'),
                ),
              ],
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
                                '${formatPrice(t.priceE4, broker)}',
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
      );
    },
  );
}
