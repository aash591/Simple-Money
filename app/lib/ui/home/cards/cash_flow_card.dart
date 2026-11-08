import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/repositories/insights_repository.dart';
import '../../../domain/currency_scope.dart';
import '../../components/charts/charts.dart';
import 'home_card.dart';

/// Six months of income beside spending, and how much of the income was
/// kept.
class CashFlowCard extends StatelessWidget {
  const CashFlowCard({super.key, required this.flows, required this.currency});
  final List<MonthFlow> flows;
  final CurrencyScope currency;

  String _money(num minor) => homeMoney(minor.round(), currency);

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final active = flows.where((f) => f.income > 0 || f.spent > 0).toList();
    final income = active.fold(0, (sum, f) => sum + f.income);
    final spent = active.fold(0, (sum, f) => sum + f.spent);
    final String headline;
    if (active.isEmpty) {
      headline = 'No income or spending in the last ${flows.length} months.';
    } else if (income <= 0) {
      headline =
          'Spent ${_money(spent / active.length)} a month, with no income '
          'recorded';
    } else {
      final rate = ((income - spent) / income * 100).round();
      final best = active.reduce(
        (a, b) => b.income - b.spent > a.income - a.spent ? b : a,
      );
      headline = rate >= 0
          ? 'You kept $rate% of your income · best month '
                '${DateFormat.MMMM().format(best.month)}'
          : 'You spent ${-rate}% more than you earned';
    }
    return HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeChartHeader(title: 'Money in vs money out', headline: headline),
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
            labels: [for (final f in flows) DateFormat.MMM().format(f.month)],
            formatValue: _money,
            formatAxis: (v) => homeCompactMoney(v, currency),
          ),
        ],
      ),
    );
  }
}
