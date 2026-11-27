import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/category.dart';
import '../../../domain/transaction.dart';
import '../../../state/account_store.dart';
import '../../../state/category_store.dart';
import '../../../state/transaction_store.dart';
import '../../components/account_tile.dart';
import '../../components/animated_amount.dart';
import '../../components/app_icon.dart';
import '../../components/charts/charts.dart';
import '../../components/common.dart';
import '../../components/feature_page.dart';
import '../../components/glass_surface.dart';
import '../../components/segmented_pill.dart';
import '../../components/transactions/filter_sheets.dart';
import '../../components/transactions/period.dart';
import '../../components/transactions/period_pager.dart';
import '../../transactions/transaction_sheet.dart';
import '../../transactions/transactions_screen.dart';
import 'edit_account_screen.dart';

/// One category's share of the account's money in or out.
class _Slice {
  _Slice(this.id, this.name, this.icon);
  final int id;
  final String name;
  final String? icon;
  int amount = 0, count = 0;
}

/// One account at a glance: its balance, where its money went or came from
/// by category, and the way into its full transaction list.
class AccountOverviewScreen extends StatefulWidget {
  const AccountOverviewScreen({
    super.key,
    required this.accountId,
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
  });
  final int accountId;
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;

  @override
  State<AccountOverviewScreen> createState() => _AccountOverviewScreenState();
}

class _AccountOverviewScreenState extends State<AccountOverviewScreen> {
  /// The time range ribbon is the Transactions screen's own: swipe between
  /// periods, or tap the selected one to pick another kind of range. Always
  /// opens on the current month, whatever was last chosen elsewhere.
  final _period = PeriodController();
  TransactionType tab = TransactionType.expense;

  late final Listenable stores = Listenable.merge([
    widget.accountStore,
    widget.categoryStore,
    widget.transactionStore,
  ]);

  @override
  void dispose() {
    _period.dispose();
    super.dispose();
  }

  /// Slides to this account's transactions over the period on screen. Back
  /// returns here, as the page is pushed on top of this one.
  void _seeTransactions(Account account) => Navigator.of(context).push(
    FeatureRoute<void>(
      // GlassPage paints the theme's background (Aurora, glass or plain);
      // a bare Scaffold would leave it black.
      GlassPage(
        child: Scaffold(
          body: TransactionsScreen(
            initialAccountId: account.id,
            initialPeriod: _period,
            accountStore: widget.accountStore,
            categoryStore: widget.categoryStore,
            transactionStore: widget.transactionStore,
            onAddTransaction: () => showAddTransactionSheet(
              context,
              accountStore: widget.accountStore,
              categoryStore: widget.categoryStore,
              transactionStore: widget.transactionStore,
            ),
          ),
        ),
      ),
    ),
  );

  Account? get _account {
    for (final a in widget.accountStore.allAccounts) {
      if (a.id == widget.accountId) return a;
    }
    return null;
  }

  /// Categories by id, with each subcategory rolled into its parent the way
  /// Home's spending card does.
  List<_Slice> _slices(
    Account account,
    TransactionType type,
    DateTimeRange range,
  ) {
    final byId = {for (final c in widget.categoryStore.categories) c.id: c};
    final slices = <int, _Slice>{};
    for (final t in widget.transactionStore.transactions) {
      final day = DateUtils.dateOnly(t.date);
      if (t.type != type ||
          t.isBalanceAdjustment ||
          t.accountId != account.id ||
          day.isBefore(range.start) ||
          day.isAfter(range.end)) {
        continue;
      }
      Category? category = byId[t.categoryId];
      if (category?.parentId case final parent?) {
        category = byId[parent] ?? category;
      }
      final slice = slices.putIfAbsent(
        category?.id ?? 0,
        () => _Slice(
          category?.id ?? 0,
          category?.name ?? 'Uncategorized',
          category?.icon,
        ),
      );
      slice
        ..amount += t.amountMinor
        ..count += 1;
    }
    return slices.values.toList()..sort((a, b) => b.amount.compareTo(a.amount));
  }

  void _edit(Account account) => Navigator.of(context).push(
    FeatureRoute<void>(
      EditAccountScreen(
        store: widget.accountStore,
        account: account,
        transactionStore: widget.transactionStore,
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: stores,
    builder: (context, _) {
      final account = _account;
      if (account == null) {
        return const FeaturePage(
          title: 'Account',
          child: Center(child: Text('This account no longer exists.')),
        );
      }
      String money(int minor) => formatAccountMoney(
        minor,
        digits: account.digits,
        currency: account.currency,
      );
      return FeaturePage(
        title: 'Account summary',
        actions: [
          IconButton(
            tooltip: 'Edit account',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _edit(account),
          ),
        ],
        // The account card scrolls away with the page; the period ribbon, which
        // heads the body, stops just under the header and stays there.
        child: Stack(
          children: [
            Positioned.fill(
              child: NestedScrollView(
                headerSliverBuilder: (context, _) => [
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(18, 12, 18, 8),
                      child: AccountTile(
                        account: account,
                        width: null,
                        dense: true,
                      ),
                    ),
                  ),
                ],
                body: PeriodPager(
                  controller: _period,
                  onSelectRange: () => pickPeriod(context, _period),
                  pageBuilder: (context, anchor) =>
                      _page(context, account, _period.rangeAt(anchor), money),
                ),
              ),
            ),
            // Stays at the bottom while the page scrolls; the page fades out
            // under it rather than ending in a hard edge.
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Theme.of(context).scaffoldBackgroundColor
                          .withValues(alpha: 0),
                      Theme.of(context).scaffoldBackgroundColor,
                    ],
                    stops: const [0, .45],
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(18, 24, 18, 6),
                  child: FilledButton.icon(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(50),
                      shape: const StadiumBorder(),
                    ),
                    onPressed: () => _seeTransactions(account),
                    icon: const Icon(Icons.receipt_long_outlined, size: 20),
                    label: const Text('See all transactions'),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );

  /// What happened in [range]: totals, then the category breakdown.
  Widget _page(
    BuildContext context,
    Account account,
    DateTimeRange range,
    String Function(int) money,
  ) {
    final expenses = _slices(account, TransactionType.expense, range);
    final incomes = _slices(account, TransactionType.income, range);
    final shown = tab == TransactionType.expense ? expenses : incomes;
    int total(List<_Slice> s) => s.fold(0, (sum, x) => sum + x.amount);
    final palette = ChartPalette.of(context);
    final when = _period.kind == PeriodKind.all ? 'yet' : 'in this period';
    return LayoutBuilder(
      builder: (context, box) => ListView(
        padding: EdgeInsets.fromLTRB(18, 8, 18, 96),
        children: [
          Row(
            children: [
              Expanded(
                child: _Figure(
                  label: 'Spent',
                  icon: Icons.south_east_rounded,
                  color: palette.expense,
                  value: total(expenses),
                  money: money,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _Figure(
                  label: 'Received',
                  icon: Icons.north_east_rounded,
                  color: palette.income,
                  value: total(incomes),
                  money: money,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // A bare account's card fills the page down to the button, so it
          // isn't a small card floating above empty space; one with a chart
          // is as tall as its chart.
          ConstrainedBox(
            constraints: BoxConstraints(
              minHeight: total(shown) <= 0
                  ? math.max(0, box.maxHeight - 208)
                  : 0,
            ),
            child: MoneyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SegmentedPill<TransactionType>(
                    segments: [
                      PillSegment(
                        TransactionType.expense,
                        'Expense',
                        icon: Icons.south_east_rounded,
                        tone: palette.expense,
                      ),
                      PillSegment(
                        TransactionType.income,
                        'Income',
                        icon: Icons.north_east_rounded,
                        tone: palette.income,
                      ),
                    ],
                    value: tab,
                    onChanged: (value) => setState(() => tab = value),
                  ),
                  const SizedBox(height: 16),
                  _Breakdown(
                    key: ValueKey((tab, range)),
                    slices: shown,
                    total: total(shown),
                    money: money,
                    noun: tab == TransactionType.expense
                        ? 'spending'
                        : 'income',
                    empty: tab == TransactionType.expense
                        ? 'Nothing spent from this account $when.'
                        : 'Nothing received in this account $when.',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({
    required this.label,
    required this.icon,
    required this.color,
    required this.value,
    required this.money,
  });
  final String label;
  final int value;
  final String Function(int) money;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MoneyCard(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          // Spent and received are shown plainly; the balance is what's private.
          SizedBox(
            height: 28,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Semantics(
                label: '$label ${money(value)}',
                excludeSemantics: true,
                child: AnimatedAmount(
                  value: value,
                  format: money,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The donut and its ranked category rows.
class _Breakdown extends StatelessWidget {
  const _Breakdown({
    super.key,
    required this.slices,
    required this.total,
    required this.money,
    required this.noun,
    required this.empty,
  });
  final List<_Slice> slices;
  final int total;
  final String Function(int) money;
  final String noun, empty;

  /// The biggest few keep their own hue; the tail folds into one grey slice.
  static const _named = 5;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (slices.isEmpty || total <= 0) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 28),
        child: Text(
          empty,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    final palette = ChartPalette.of(context);
    final rest = slices.skip(_named);
    final entries = [
      for (final (i, s) in slices.take(_named).indexed)
        ChartEntry(
          label: s.name,
          value: s.amount + .0,
          color: palette.series(i),
        ),
      if (rest.isNotEmpty)
        ChartEntry(
          label: 'Others',
          value: rest.fold(0.0, (sum, s) => sum + s.amount),
          color: palette.other,
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        CalloutDonutChart(
          slices: entries,
          centerLabel: money(total),
          centerCaption: noun == 'spending' ? 'spent' : 'received',
          formatValue: (v) => money(v.round()),
          badgeBuilder: (context, i) => i < _named
              ? AppIcon(slices[i].icon)
              : Icon(
                  Icons.more_horiz_rounded,
                  size: 18,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
        ),
        const SizedBox(height: 8),
        for (final (i, s) in slices.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: palette.series(i).withValues(alpha: .14),
                  ),
                  child: s.icon == null
                      ? Icon(
                          Icons.label_outline_rounded,
                          size: 20,
                          color: palette.series(i),
                        )
                      : AppIcon(s.icon),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Text(
                        '${(s.amount * 100 / total).round()}% of $noun',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      money(s.amount),
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      '${s.count} ${s.count == 1 ? 'transaction' : 'transactions'}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ],
            ),
          ),
      ],
    );
  }
}
