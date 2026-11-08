import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../domain/currency_scope.dart';
import '../../../domain/debt.dart';
import '../../../domain/loan.dart';
import '../../../domain/subscription.dart';
import '../../../state/account_store.dart';
import '../../../state/debt_store.dart';
import '../../../state/loan_store.dart';
import '../../../state/subscription_store.dart';
import '../../components/charts/charts.dart';
import '../../components/currency_notice.dart';
import 'home_card.dart';

/// How much of what's in the accounts is already spoken for over the next
/// 30 days — EMIs, renewals and debts you owe — and what's left over.
class CommittedCard extends StatelessWidget {
  const CommittedCard({
    super.key,
    required this.accountStore,
    required this.currency,
    this.loanStore,
    this.subscriptionStore,
    this.debtStore,
    this.now,
  });
  final AccountStore accountStore;
  final LoanStore? loanStore;
  final SubscriptionStore? subscriptionStore;
  final DebtStore? debtStore;
  final CurrencyScope currency;

  /// Stands in for the clock in tests.
  final DateTime? now;

  static const days = 30;

  String _money(num minor) => homeMoney(minor.round(), currency);

  ({int emis, int renewals, int debts}) _due(CurrencyTotals totals) {
    final today = now ?? DateTime.now();
    final horizon = DateTime(today.year, today.month, today.day + days + 1);
    var emis = 0, renewals = 0, debts = 0;
    for (final loan in loanStore?.loans ?? const <Loan>[]) {
      if (loan.closed ||
          !currency.includes(loan.terms.currency, loan.terms.digits)) {
        continue;
      }
      // Anything overdue is still owed, so it counts too.
      var native = 0;
      for (final row in loan.schedule) {
        if (!row.due.isBefore(horizon)) break;
        native += row.amount;
      }
      final converted = totals.convert(
        native,
        loan.terms.currency,
        loan.terms.digits,
      );
      if (converted != null) emis += converted;
    }
    for (final s
        in subscriptionStore?.subscriptions ?? const <Subscription>[]) {
      if (s.paused || !currency.includes(s.currency, s.digits)) continue;
      var native = 0;
      for (
        var due = s.nextDue;
        due.isBefore(horizon);
        due = s.cycle.after(due, s.day)
      ) {
        native += s.amountMinor;
      }
      final converted = totals.convert(native, s.currency, s.digits);
      if (converted != null) renewals += converted;
    }
    for (final person in debtStore?.people ?? const <PersonDebts>[]) {
      final due = person.dueDate;
      if (due == null || !due.isBefore(horizon)) continue;
      for (final balance in person.balances) {
        if (balance.amountMinor >= 0) continue;
        final converted = totals.convert(
          -balance.amountMinor,
          balance.currency,
          balance.digits,
        );
        if (converted != null) debts += converted;
      }
    }
    return (emis: emis, renewals: renewals, debts: debts);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      accountStore,
      ?loanStore,
      ?subscriptionStore,
      ?debtStore,
    ]),
    builder: (context, _) {
      final palette = ChartPalette.of(context);
      final totals = CurrencyTotals(currency);
      for (final account in accountStore.accounts) {
        totals.add(account.balanceMinor, account.currency, account.digits);
      }
      final balance = totals.total;
      final due = _due(totals);
      final committed = due.emis + due.renewals + due.debts;
      final free = balance - committed;
      final parts = [
        ChartEntry(
          label: 'EMIs',
          value: due.emis.toDouble(),
          color: palette.series(0),
        ),
        ChartEntry(
          label: 'Subscriptions',
          value: due.renewals.toDouble(),
          color: palette.series(1),
        ),
        ChartEntry(
          label: 'Debts you owe',
          value: due.debts.toDouble(),
          color: palette.series(4),
        ),
      ].where((e) => e.value > 0).toList();
      final free0 = math.max(0, free);
      final headline = totals.missing.isNotEmpty
          ? 'Partial estimate of upcoming payments and available balance'
          : committed == 0
          ? 'Nothing due in the next $days days.'
          : free < 0
          ? '${_money(committed)} due is ${_money(-free)} more than your '
                'balance'
          : '${_money(committed)} of ${_money(balance)} is already committed';
      final whole = math.max(balance, committed).toDouble();
      return HomeCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HomeChartHeader(title: 'Next $days days', headline: headline),
            CurrencyNotice(scope: currency, missing: totals.missing),
            if (whole > 0) ...[
              _SegmentedBar(
                segments: [
                  for (final part in parts) (part.value / whole, part.color),
                  if (free0 > 0)
                    (free0 / whole, palette.income.withValues(alpha: .35)),
                ],
              ),
              const SizedBox(height: 14),
            ],
            ChartLegend(
              direction: Axis.vertical,
              entries: [
                ...parts,
                ChartEntry(
                  label: free < 0 ? 'Short by' : 'Free to spend',
                  value: free.abs().toDouble(),
                  color: free < 0 ? palette.expense : palette.income,
                ),
              ],
              formatValue: _money,
            ),
          ],
        ),
      );
    },
  );
}

/// One bar split into parts, each as wide as its share.
class _SegmentedBar extends StatelessWidget {
  const _SegmentedBar({required this.segments});
  final List<(double, Color)> segments;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: SizedBox(
      height: 14,
      child: Row(
        children: [
          for (final (i, (share, color)) in segments.indexed)
            if (share > 0)
              Expanded(
                flex: math.max(1, (share * 1000).round()),
                child: Container(
                  margin: EdgeInsets.only(left: i == 0 ? 0 : 2),
                  color: color,
                ),
              ),
        ],
      ),
    ),
  );
}
