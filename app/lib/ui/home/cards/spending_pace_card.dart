import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/budget.dart';
import '../../../domain/currency_scope.dart';
import '../../components/charts/charts.dart';
import 'home_card.dart';

/// The month's running spend against the month before, so overspending
/// shows while there's still time to act on it.
class SpendingPaceCard extends StatelessWidget {
  const SpendingPaceCard({
    super.key,
    required this.month,
    required this.daily,
    required this.previousDaily,
    required this.budget,
    required this.currency,
    this.now,
  });
  final DateTime month;
  final List<int> daily, previousDaily;
  final BudgetLine? budget;
  final CurrencyScope currency;

  /// Stands in for the clock in tests.
  final DateTime? now;

  String _money(num minor) => homeMoney(minor.round(), currency);

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    final today = now ?? DateTime.now();
    final running = month.year == today.year && month.month == today.month;
    // A running month is only plotted up to today; the rest hasn't happened.
    final days = running ? today.day.clamp(1, daily.length) : daily.length;
    final spent = daily.take(days).fold(0, (sum, v) => sum + v);
    final before = previousDaily
        .take(days.clamp(0, previousDaily.length))
        .fold(0, (sum, v) => sum + v);
    final previousName = DateFormat.MMM().format(
      DateTime(month.year, month.month - 1),
    );
    final budget = this.budget;
    final String headline;
    if (spent == 0 && before == 0) {
      headline = 'Nothing spent yet this month or last by this point.';
    } else if (running) {
      final projected = (spent / days * daily.length).round();
      final gap = spent - before;
      final pace = gap == 0
          ? 'Level with $previousName'
          : '${_money(gap.abs())} ${gap > 0 ? 'more' : 'less'} than '
                '$previousName by day $days';
      headline = budget != null && projected > budget.limit
          ? '$pace · on track for ${_money(projected)}, over budget'
          : '$pace · on track for ${_money(projected)}';
    } else {
      final gap = spent - before;
      headline = gap == 0
          ? 'Same as $previousName'
          : '${_money(gap.abs())} ${gap > 0 ? 'more' : 'less'} than '
                '$previousName';
    }
    return HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeChartHeader(title: 'Spending pace', headline: headline),
          LineChart(
            height: 150,
            cumulative: true,
            series: [
              ChartSeries(
                label: DateFormat.MMM().format(month),
                values: daily.take(days).toList(),
                color: primary,
              ),
              ChartSeries(
                label: previousName,
                values: previousDaily,
                color: palette.other.withValues(alpha: .55),
                dashed: true,
              ),
            ],
            labels: [
              for (var d = 1; d <= math.max(days, previousDaily.length); d++)
                '$d',
            ],
            referenceLines: [
              if (budget != null)
                ChartReferenceLine(
                  value: budget.limit.toDouble(),
                  label: 'Budget',
                  color: palette.expense,
                ),
            ],
            formatValue: _money,
            formatAxis: (v) => homeCompactMoney(v, currency),
          ),
        ],
      ),
    );
  }
}
