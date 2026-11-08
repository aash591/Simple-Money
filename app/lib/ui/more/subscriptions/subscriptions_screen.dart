import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:flutter/material.dart';

import '../../components/app_back_button.dart';

import '../../theme/app_typography.dart';

import '../../../domain/account.dart';
import '../../../domain/subscription.dart';
import '../../../state/subscription_store.dart';
import '../../components/common.dart';
import '../../components/charts/charts.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import '../../components/reminder_card.dart';
import '../../components/search_field.dart';
import '../../components/secondary_header.dart';
import '../../components/skeleton.dart';
import '../../theme/sheet_colors.dart';
import 'mark_paid_sheet.dart';
import 'subscription_detail_screen.dart';
import 'subscription_sheet.dart';

/// A currency and its precision: subscriptions only add up within one.
typedef _Currency = (String, int);

class SubscriptionsScreen extends StatefulWidget {
  const SubscriptionsScreen({super.key, required this.store});
  final SubscriptionStore store;

  @override
  State<SubscriptionsScreen> createState() => _SubscriptionsScreenState();
}

class _SubscriptionsScreenState extends State<SubscriptionsScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  var _searching = false;

  /// The currency the overview and chart are drawn in, when there's a choice.
  _Currency? _currency;

  SubscriptionStore get _store => widget.store;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searching = true);
    _searchFocus.requestFocus();
  }

  void _cancelSearch() {
    _searchFocus.unfocus();
    setState(() {
      _searching = false;
      _search.clear();
    });
  }

  void _add() => showSubscriptionSheet(context, store: _store);

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_searching,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _cancelSearch();
    },
    child: FeaturePage(
      title: 'Subscriptions',
      header: SearchableHeader(
        searching: _searching,
        controller: _search,
        focusNode: _searchFocus,
        fieldKey: const Key('subscription-search'),
        hintText: 'Search subscriptions',
        onChanged: (_) => setState(() {}),
        onCancel: _cancelSearch,
        header: SecondaryHeader(
          title: 'Subscriptions',
          leading: Navigator.of(context).canPop()
              ? const AppBackButton()
              : null,
          actions: [
            AppSearchButton(
              tooltip: 'Search subscriptions',
              onPressed: _openSearch,
            ),
          ],
        ),
      ),
      floatingActionButton: _searching
          ? null
          : AddFab(tooltip: 'Add subscription', onPressed: _add),
      child: ListenableBuilder(
        listenable: _store,
        builder: (context, _) => _body(context),
      ),
    ),
  );

  Widget _body(BuildContext context) {
    if (_store.loading) return const SkeletonList();
    if (_store.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_store.error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _store.load,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    final all = _store.subscriptions;
    if (all.isEmpty) {
      return EmptyState(
        icon: Icons.autorenew_rounded,
        title: 'No subscriptions yet.',
        message:
            'Track Netflix, the gym and more. See what it all costs a month.',
        actionLabel: 'Add your first subscription',
        onAction: _add,
      );
    }
    final theme = Theme.of(context);
    final query = _search.text.trim().toLowerCase();
    // One list: what renews soonest first, paused ones after it by name.
    final visible =
        all.where((s) => s.name.toLowerCase().contains(query)).toList()
          ..sort((a, b) {
            if (a.paused != b.paused) return a.paused ? 1 : -1;
            if (a.paused) {
              return a.name.toLowerCase().compareTo(b.name.toLowerCase());
            }
            return a.nextDue.compareTo(b.nextDue);
          });

    final active = all.where((s) => !s.paused).toList();
    final spend = <_Currency, int>{};
    for (final s in active) {
      final key = (s.currency, s.digits);
      spend[key] = (spend[key] ?? 0) + s.monthlyAmount;
    }
    // The biggest spend leads until the user picks another.
    final currencies = spend.keys.toList()
      ..sort((a, b) => spend[b]!.compareTo(spend[a]!));
    final currency = currencies.contains(_currency)
        ? _currency
        : currencies.firstOrNull;
    final inCurrency = [
      for (final s in active)
        if ((s.currency, s.digits) == currency) s,
    ];
    final pausedCount = all.length - active.length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 100),
      children: [
        if (query.isEmpty) ...[
          if (currencies.length > 1) ...[
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in currencies)
                  ChoiceChip(
                    label: Text(option.$1),
                    selected: option == currency,
                    onSelected: (_) => setState(() => _currency = option),
                  ),
              ],
            ),
            const SizedBox(height: 12),
          ],
          if (currency != null)
            _ChartCard(
              key: ValueKey(currency),
              subscriptions: inCurrency,
              currency: currency,
              paused: pausedCount,
            )
          else
            MoneyCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Nothing active', style: theme.textTheme.titleMedium),
                  const SizedBox(height: 6),
                  Text(
                    'All $pausedCount subscriptions are paused.',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          const SizedBox(height: 26),
        ],
        Row(
          children: [
            Expanded(
              child: Text(
                query.isEmpty ? 'Your subscriptions' : 'Results',
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Text(
              '${visible.length}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: SheetColors.of(context).muted,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        for (final s in visible)
          SubscriptionCard(subscription: s, store: _store),
        if (visible.isEmpty) const NoResultsState('No matching subscriptions'),
      ],
    );
  }
}

String _money(int minor, _Currency currency) =>
    formatAccountMoney(minor, digits: currency.$2, currency: currency.$1);

/// Paused subscriptions wear a cool slate instead of the card surface, so
/// they read as set aside without needing a section of their own.
Color subscriptionPausedColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff9aa8bd)
    : const Color(0xff5f6f86);

/// Forecast actual renewal charges, so annual bills show up in their due month.
class _ChartCard extends StatefulWidget {
  const _ChartCard({
    super.key,
    required this.subscriptions,
    required this.currency,
    required this.paused,
  });
  final List<Subscription> subscriptions;
  final _Currency currency;
  final int paused;
  @override
  State<_ChartCard> createState() => _ChartCardState();
}

class _ChartCardState extends State<_ChartCard> {
  int? _selected;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final now = dateOnly(DateTime.now());
    final totals = upcomingRenewals(
      widget.subscriptions,
      6,
      now: now,
      includeOverdue: false,
    );
    final peak = totals.reduce(math.max);
    final peakIndex = totals.indexOf(peak);
    final selected = _selected ?? peakIndex;
    final months = [
      for (var i = 0; i < 6; i++) DateTime(now.year, now.month + i),
    ];
    final overdue = widget.subscriptions
        .where((s) => s.nextDue.isBefore(now))
        .fold(0, (sum, s) => sum + s.amountMinor);
    final even = totals.every((amount) => amount == peak);
    final currency = widget.currency;
    return MoneyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Plan for upcoming bills',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            'Next 6 months · ${currency.$1}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          Text(
            _selected != null
                ? DateFormat('MMMM yyyy').format(months[selected])
                : even
                ? 'Expected each month'
                : 'Highest bill month · ${DateFormat('MMM yyyy').format(months[selected])}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              _money(totals[selected], currency),
              style: AppTypography.amount,
            ),
          ),
          const SizedBox(height: 18),
          BarChart(
            height: 160,
            showLegend: false,
            series: [
              ChartSeries(
                label: 'Scheduled bills',
                values: totals,
                color: colors.primary,
                valueColors: [
                  for (var i = 0; i < 6; i++)
                    i == selected
                        ? colors.primary
                        : colors.primary.withValues(alpha: .35),
                ],
              ),
            ],
            labels: [
              for (final month in months) DateFormat('MMM').format(month),
            ],
            formatValue: (value) => _money(value.round(), currency),
            formatAxis: (value) => NumberFormat.compact().format(
              value / math.pow(10, currency.$2),
            ),
            onSelect: (index) => setState(() => _selected = index),
          ),
          const SizedBox(height: 12),
          Text(
            'Tap a month for its total. This month counts only bills from today.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (overdue > 0) ...[
            const SizedBox(height: 10),
            Text(
              '${_money(overdue, currency)} already overdue · separate from this forecast',
              style: Theme.of(context).textTheme.bodySmall
                  ?.copyWith(color: colors.expense),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            'Based on current prices and renewal dates. Paused plans excluded.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

/// What [subscriptions] charge in each of the next [months] calendar months,
/// this one first. A renewal that's already overdue is still owed, so it
/// counts once towards this month.
@visibleForTesting
List<int> upcomingRenewals(
  List<Subscription> subscriptions,
  int months, {
  required DateTime now,
  bool includeOverdue = true,
}) {
  if (months <= 0) return [];
  final today = dateOnly(now);
  final end = DateTime(now.year, now.month + months);
  final totals = List.filled(months, 0);
  for (final s in subscriptions.where((s) => !s.paused)) {
    var due = s.nextDue;
    if (due.isBefore(today)) {
      if (includeOverdue) totals[0] += s.amountMinor;
      while (due.isBefore(today)) {
        due = s.cycle.after(due, s.day);
      }
    }
    while (due.isBefore(end)) {
      totals[(due.year - now.year) * 12 + due.month - now.month] +=
          s.amountMinor;
      due = s.cycle.after(due, s.day);
    }
  }
  return totals;
}

/// One subscription in the list. The same [ReminderCard] Home shows, so a
/// renewal reads identically in both places.
class SubscriptionCard extends StatelessWidget {
  const SubscriptionCard({
    super.key,
    required this.subscription,
    required this.store,
  });
  final Subscription subscription;
  final SubscriptionStore store;

  @override
  Widget build(BuildContext context) {
    final s = subscription;
    final account = store.accountStore.byId(s.accountId);
    return ReminderCard(
      icon: s.icon,
      title: s.name,
      subtitle: '${s.cycle.label} · ${account?.name ?? 'No account'}',
      amount: formatAccountMoney(
        s.amountMinor,
        digits: s.digits,
        currency: s.currency,
      ),
      per: s.cycle.per,
      due: s.paused ? null : s.nextDue,
      // Paused is not an achievement, so it stays muted rather than green.
      status: s.paused ? (label: 'Paused', done: false) : null,
      onTap: () => Navigator.push(
        context,
        FeatureRoute<void>(SubscriptionDetailScreen(store: store, id: s.id)),
      ),
      onMarkPaid: store.saving
          ? null
          : () => showMarkPaidSheet(context, store: store, subscription: s),
    );
  }
}
