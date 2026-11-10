import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/repositories/insights_repository.dart';
import '../../../domain/currency_scope.dart';
import '../../components/charts/charts.dart';
import '../../components/common.dart';
import '../../components/empty_chart_preview.dart';
import 'home_card.dart';

/// Six months of income beside spending.
class CashFlowCard extends StatelessWidget {
  const CashFlowCard({super.key, required this.flows, required this.currency});
  final List<MonthFlow> flows;
  final CurrencyScope currency;

  String _money(num minor) => homeMoney(minor.round(), currency);

  /// Sample months for the preview: a little money in, a little out.
  static const _sampleIn = [38.0, 44.0, 36.0, 52.0, 41.0, 48.0];
  static const _sampleOut = [30.0, 33.0, 38.0, 29.0, 35.0, 31.0];

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final labels = [for (final f in flows) DateFormat.MMM().format(f.month)];
    final empty = flows.every((f) => f.income == 0 && f.spent == 0);
    return HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SectionTitle('Money in vs money out'),
          const SizedBox(height: 14),
          if (empty)
            EmptyChartPreview(
              title: 'No money in or out yet.',
              message:
                  'Your income and spending for the last six months will show '
                  'up here.',
              sample: BarChart(
                height: 150,
                maxBarThickness: 14,
                series: [
                  ChartSeries(
                    label: 'Money in',
                    values: _sampleIn.take(flows.length).toList(),
                    color: palette.income,
                  ),
                  ChartSeries(
                    label: 'Money out',
                    values: _sampleOut.take(flows.length).toList(),
                    color: palette.expense,
                  ),
                ],
                labels: labels,
                formatValue: (v) => '',
                formatAxis: (v) => '',
              ),
            )
          else
            BarChart(
              height: 150,
              maxBarThickness: 14,
              series: [
                ChartSeries(
                  label: 'Money in',
                  values: [for (final f in flows) f.income],
                  color: palette.income,
                ),
                ChartSeries(
                  label: 'Money out',
                  values: [for (final f in flows) f.spent],
                  color: palette.expense,
                ),
              ],
              labels: labels,
              formatValue: _money,
              formatAxis: (v) => homeCompactMoney(v, currency),
            ),
        ],
      ),
    );
  }
}
