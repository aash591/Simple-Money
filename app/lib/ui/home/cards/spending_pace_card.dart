import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/budget.dart';
import '../../../domain/currency_scope.dart';
import '../../components/animated_amount.dart';
import '../../components/charts/charts.dart';
import '../../components/empty_chart_preview.dart';
import 'home_card.dart';
import '../../theme/app_theme.dart' show usesAurora;

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
    final monthName = DateFormat.MMM().format(month);
    final gap = spent - before;
    final hasData = spent != 0 || before != 0;

    final theme = Theme.of(context);
    // Nothing spent this month or last: show the chart as it will look.
    if (!hasData) {
      final length = math.max(daily.length, 1);
      final lastMonth = [for (var i = 0; i < length; i++) 80 + (i * 37) % 90];
      final thisMonth = [for (var i = 0; i < days; i++) 60 + (i * 53) % 100];
      return HomeCard(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            EmptyChartPreview(
              title: 'No spending yet.',
              message:
                  'Once you add expenses, this month will be drawn against '
                  'last month here.',
              sample: LineChart(
                height: 150,
                cumulative: true,
                filled: usesAurora(context),
                series: [
                  ChartSeries(
                    label: monthName,
                    values: thisMonth,
                    color: primary,
                  ),
                  ChartSeries(
                    label: previousName,
                    values: lastMonth,
                    color: palette.other.withValues(alpha: .55),
                    dashed: true,
                  ),
                ],
                labels: [for (var d = 1; d <= length; d++) '$d'],
                formatValue: (v) => '',
                formatAxis: (v) => '',
              ),
            ),
          ],
        ),
      );
    }
    final (chip, chipColor) = !hasData
        ? (null, null)
        : gap == 0
        ? ('Same as $previousName', theme.colorScheme.onSurfaceVariant)
        : gap > 0
        ? ('${_money(gap)} more', palette.expense)
        : ('${_money(-gap)} less', palette.income);
    final amountStyle = theme.textTheme.headlineMedium?.copyWith(
      fontWeight: FontWeight.w700,
      letterSpacing: -.5,
    );

    return HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  '$monthName vs $previousName',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              if (chip != null && chipColor != null)
                Flexible(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: chipColor.withValues(alpha: .14),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      chip,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: chipColor,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Semantics(
              label: _money(spent),
              excludeSemantics: true,
              child: AnimatedAmount(
                value: spent,
                format: _money,
                style: amountStyle,
              ),
            ),
          ),
          const SizedBox(height: 18),
          LineChart(
            height: 150,
            cumulative: true,
            filled: usesAurora(context),
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
