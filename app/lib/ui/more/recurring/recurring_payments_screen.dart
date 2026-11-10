import 'dart:math' as math;

import 'package:intl/intl.dart';
import 'package:flutter/material.dart';

import '../../components/app_back_button.dart';

import '../../theme/app_typography.dart';

import '../../../domain/account.dart';
import '../../../domain/recurring_payment.dart';
import '../../../state/recurring_payment_store.dart';
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
import 'recurring_payment_detail_screen.dart';
import 'recurring_payment_sheet.dart';

/// A currency and its precision: recurring payments only add up within one.
typedef _Currency = (String, int);

class RecurringPaymentsScreen extends StatefulWidget {
  const RecurringPaymentsScreen({super.key, required this.store});
  final RecurringPaymentStore store;

  @override
  State<RecurringPaymentsScreen> createState() =>
      _RecurringPaymentsScreenState();
}

class _RecurringPaymentsScreenState extends State<RecurringPaymentsScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  var _searching = false;

  /// The currency the overview and chart are drawn in, when there's a choice.
  _Currency? _currency;

  RecurringPaymentStore get _store => widget.store;

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

  void _add() => showRecurringPaymentSheet(context, store: _store);

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_searching,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _cancelSearch();
    },
    child: FeaturePage(
      title: 'Recurring payments',
      header: SearchableHeader(
        searching: _searching,
        controller: _search,
        focusNode: _searchFocus,
        fieldKey: const Key('subscription-search'),
        hintText: 'Search recurring payments',
        onChanged: (_) => setState(() {}),
        onCancel: _cancelSearch,
        header: SecondaryHeader(
          title: 'Recurring payments',
          leading: Navigator.of(context).canPop()
              ? const AppBackButton()
              : null,
          actions: [
            AppSearchButton(
              tooltip: 'Search recurring payments',
              onPressed: _openSearch,
            ),
          ],
        ),
      ),
      floatingActionButton: _searching
          ? null
          : AddFab(tooltip: 'Add recurring payment', onPressed: _add),
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
    final all = _store.recurringPayments;
    if (all.isEmpty) {
      return EmptyState(
        icon: Icons.autorenew_rounded,
        title: 'No recurring payments yet.',
        message: 'Track Netflix, rent and more, paid or received. See what it all costs a month.',
        actionLabel: 'Add your first recurring payment',
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
              recurringPayments: inCurrency,
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
                    'All $pausedCount recurring payments are paused.',
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
                query.isEmpty ? 'Your recurring payments' : 'Results',
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
          RecurringPaymentCard(recurringPayment: s, store: _store),
        if (visible.isEmpty)
          const NoResultsState('No matching recurring payments'),
      ],
    );
  }
}

String _money(int minor, _Currency currency) =>
    formatAccountMoney(minor, digits: currency.$2, currency: currency.$1);

/// Paused recurring payments wear a cool slate instead of the card surface, so
/// they read as set aside without needing a section of their own.
Color recurringPausedColor(BuildContext context) =>
    Theme.of(context).brightness == Brightness.dark
    ? const Color(0xff9aa8bd)
    : const Color(0xff5f6f86);

/// Forecast actual renewal charges, so annual bills show up in their due month.
class _ChartCard extends StatefulWidget {
  const _ChartCard({
    super.key,
    required this.recurringPayments,
    required this.currency,
    required this.paused,
  });
  final List<RecurringPayment> recurringPayments;
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
    final theme = Theme.of(context);
    final now = dateOnly(DateTime.now());
    final all = widget.recurringPayments;
    final hasOut = all.any((s) => !s.incoming);
    final hasIn = all.any((s) => s.incoming);
    List<int> totals(bool incoming) => upcomingRenewals(
      all,
      6,
      now: now,
      includeOverdue: false,
      incoming: incoming,
    );
    final pay = totals(false), get = totals(true);
    final selected = _selected ?? 0;
    final months = [
      for (var i = 0; i < 6; i++) DateTime(now.year, now.month + i),
    ];
    int overdue(bool incoming) => all
        .where((s) => s.incoming == incoming && s.nextDue.isBefore(now))
        .fold(0, (sum, s) => sum + s.amountMinor);
    final currency = widget.currency;
    final title = hasOut && hasIn
        ? 'Money in and out'
        : hasIn
        ? 'Expected by month'
        : 'Payments by month';
    Widget figure(String label, int minor, Color color) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              const SizedBox(width: 6),
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(_money(minor, currency), style: AppTypography.amount),
          ),
        ],
      ),
    );
    return MoneyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            'Next 6 months · ${currency.$1}',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 18),
          Text(
            DateFormat('MMMM yyyy').format(months[selected]),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (hasOut) figure('To pay', pay[selected], colors.expense),
              if (hasOut && hasIn) const SizedBox(width: 16),
              if (hasIn) figure('To get', get[selected], colors.income),
            ],
          ),
          const SizedBox(height: 18),
          BarChart(
            height: 160,
            showLegend: false,
            series: [
              if (hasOut)
                ChartSeries(
                  label: 'To pay',
                  values: pay,
                  color: colors.expense,
                  valueColors: [
                    for (var i = 0; i < 6; i++)
                      i == selected
                          ? colors.expense
                          : colors.expense.withValues(alpha: .35),
                  ],
                ),
              if (hasIn)
                ChartSeries(
                  label: 'To get',
                  values: get,
                  color: colors.income,
                  valueColors: [
                    for (var i = 0; i < 6; i++)
                      i == selected
                          ? colors.income
                          : colors.income.withValues(alpha: .35),
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
          if (overdue(false) > 0) ...[
            const SizedBox(height: 10),
            Text(
              '${_money(overdue(false), currency)} already overdue · separate from this forecast',
              style: theme.textTheme.bodySmall?.copyWith(color: colors.expense),
            ),
          ],
          if (overdue(true) > 0) ...[
            const SizedBox(height: 10),
            Text(
              '${_money(overdue(true), currency)} still to receive · separate from this forecast',
              style: theme.textTheme.bodySmall?.copyWith(color: colors.income),
            ),
          ],
        ],
      ),
    );
  }
}

/// What [recurringPayments] charge (or pay in) in each of the next [months] calendar months,
/// this one first. A renewal that's already overdue is still owed, so it
/// counts once towards this month.
@visibleForTesting
List<int> upcomingRenewals(
  List<RecurringPayment> recurringPayments,
  int months, {
  required DateTime now,
  bool includeOverdue = true,

  /// Money coming in instead of money going out.
  bool incoming = false,
}) {
  if (months <= 0) return [];
  final today = dateOnly(now);
  final end = DateTime(now.year, now.month + months);
  final totals = List.filled(months, 0);
  for (final s in recurringPayments.where(
    (s) => !s.paused && s.incoming == incoming,
  )) {
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

/// One recurring payment in the list. The same [ReminderCard] Home shows, so a
/// renewal reads identically in both places.
class RecurringPaymentCard extends StatelessWidget {
  const RecurringPaymentCard({
    super.key,
    required this.recurringPayment,
    required this.store,
  });
  final RecurringPayment recurringPayment;
  final RecurringPaymentStore store;

  @override
  Widget build(BuildContext context) {
    final s = recurringPayment;
    return ReminderCard(
      icon: s.icon,
      title: s.name,
      subtitle: s.cycle.label,
      amount:
          '${s.incoming ? '+' : ''}${formatAccountMoney(s.amountMinor, digits: s.digits, currency: s.currency)}',
      actionLabel: s.incoming ? 'Mark received' : 'Mark paid',
      due: s.paused ? null : s.nextDue,
      // Paused is not an achievement, so it stays muted rather than green.
      status: s.paused ? (label: 'Paused', done: false) : null,
      onTap: () => Navigator.push(
        context,
        FeatureRoute<void>(
          RecurringPaymentDetailScreen(store: store, id: s.id),
        ),
      ),
      onMarkPaid: store.saving
          ? null
          : () => showMarkPaidSheet(context, store: store, recurringPayment: s),
    );
  }
}
