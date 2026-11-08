import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/repositories/insights_repository.dart';
import '../../../domain/currency_scope.dart';
import '../../../domain/debt.dart';
import '../../../domain/loan.dart';
import '../../../state/debt_store.dart';
import '../../../state/loan_store.dart';
import '../../components/charts/charts.dart';
import '../../components/currency_notice.dart';
import 'home_card.dart';
import '../../components/private_amount.dart';

/// What you own less what you owe, month by month: account balances, plus
/// money people owe you, less loans and money you owe people.
class NetWorthCard extends StatelessWidget {
  const NetWorthCard({
    super.key,
    required this.flows,
    required this.balances,
    required this.currency,
    this.loanStore,
    this.debtStore,
  });

  /// The months [balances] closes, oldest first.
  final List<MonthFlow> flows;
  final List<int> balances;
  final CurrencyScope currency;
  final LoanStore? loanStore;
  final DebtStore? debtStore;

  String _money(num minor) =>
      '${minor < 0 ? '−' : ''}${homeMoney(minor.abs().round(), currency)}';

  /// Owed to you and owed by you, each positive, as it stood before [end].
  (int, int) _debtsBefore(DateTime end, CurrencyTotals conversion) {
    var owedToYou = 0, youOwe = 0;
    for (final person in debtStore?.people ?? const <PersonDebts>[]) {
      final groups = <(String, int), int>{};
      for (final e in person.entries.where((e) => e.date.isBefore(end))) {
        final key = (e.currency, e.digits);
        groups[key] = (groups[key] ?? 0) + e.signedMinor;
      }
      for (final entry in groups.entries) {
        final total = conversion.convert(
          entry.value,
          entry.key.$1,
          entry.key.$2,
        );
        if (total == null) continue;
        if (total > 0) owedToYou += total;
        if (total < 0) youOwe -= total;
      }
    }
    return (owedToYou, youOwe);
  }

  /// Loan principal outstanding before [end]. A loan counts from the month
  /// before its first tracked payment, when it was already owed.
  int _loansBefore(DateTime end, CurrencyTotals conversion) {
    var owed = 0;
    for (final loan in loanStore?.loans ?? const <Loan>[]) {
      final terms = loan.terms;
      if (!currency.includes(terms.currency, terms.digits)) continue;
      if (!DateTime(
        terms.firstDue.year,
        terms.firstDue.month - 1,
      ).isBefore(end)) {
        continue;
      }
      final repaid = loan.events
          .where((e) => e.date.isBefore(end))
          .fold(0, (sum, e) => sum + e.principal);
      final converted = conversion.convert(
        math.max(0, terms.openingBalance - repaid),
        terms.currency,
        terms.digits,
      );
      if (converted != null) owed += converted;
    }
    return owed;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([?loanStore, ?debtStore]),
    builder: (context, _) {
      final palette = ChartPalette.of(context);
      final primary = Theme.of(context).colorScheme.primary;
      final conversion = CurrencyTotals(currency);
      final ends = [
        for (final f in flows) DateTime(f.month.year, f.month.month + 1),
      ];
      final worth = [
        for (var i = 0; i < ends.length; i++)
          () {
            final (owedToYou, youOwe) = _debtsBefore(ends[i], conversion);
            return balances[i] +
                owedToYou -
                youOwe -
                _loansBefore(ends[i], conversion);
          }(),
      ];
      final (owedToYou, youOwe) = _debtsBefore(ends.last, conversion);
      final loans = _loansBefore(ends.last, conversion);
      final change = worth.last - worth.first;
      final since = DateFormat.MMMM().format(flows.first.month);
      final headline = change == 0
          ? 'Unchanged since $since'
          : '${change > 0 ? 'Up' : 'Down'} ${_money(change.abs())} since '
                '$since';
      return HomeCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            HomeChartHeader(title: 'Net worth', headline: headline),
            CurrencyNotice(scope: currency, missing: conversion.missing),
            PrivateAmount(
              label: 'Net worth',
              child: Text(
                _money(worth.last),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: worth.last < 0 ? palette.expense : null,
                ),
              ),
            ),
            const SizedBox(height: 12),
            LineChart(
              height: 120,
              filled: true,
              series: [
                ChartSeries(
                  label: 'Net worth',
                  values: worth,
                  color: primary,
                  negativeColor: palette.expense,
                ),
              ],
              labels: [for (final f in flows) DateFormat.MMM().format(f.month)],
              formatValue: _money,
              formatAxis: (v) => homeCompactMoney(v, currency),
            ),
            const SizedBox(height: 14),
            ChartLegend(
              direction: Axis.vertical,
              formatValue: _money,
              entries: [
                ChartEntry(
                  label: 'In your accounts',
                  value: balances.last.toDouble(),
                  color: primary,
                ),
                if (owedToYou > 0)
                  ChartEntry(
                    label: 'Owed to you',
                    value: owedToYou.toDouble(),
                    color: palette.income,
                  ),
                if (loans > 0)
                  ChartEntry(
                    label: 'Loans',
                    value: -loans.toDouble(),
                    color: palette.expense,
                  ),
                if (youOwe > 0)
                  ChartEntry(
                    label: 'You owe people',
                    value: -youOwe.toDouble(),
                    color: palette.series(3),
                  ),
              ],
            ),
          ],
        ),
      );
    },
  );
}
