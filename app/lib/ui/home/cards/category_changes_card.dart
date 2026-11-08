import 'package:flutter/material.dart';

import '../../../data/repositories/insights_repository.dart';
import '../../../domain/currency_scope.dart';
import '../../components/charts/charts.dart';
import 'home_card.dart';

/// The categories that moved most against their usual — the average of the
/// months before — so what's different about this month stands out.
class CategoryChangesCard extends StatelessWidget {
  const CategoryChangesCard({
    super.key,
    required this.changes,
    required this.comparedMonths,
    required this.currency,
  });
  final List<CategoryChange> changes;
  final int comparedMonths;
  final CurrencyScope currency;

  static const _shown = 5;

  String _signed(double minor) =>
      '${minor < 0 ? '−' : '+'}${homeMoney(minor.abs().round(), currency)}';

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final moved = changes
        .where((c) => c.current != c.average)
        .take(_shown)
        .toList();
    final String headline;
    if (comparedMonths == 0) {
      headline = 'Needs a month of spending before this one to compare with.';
    } else if (moved.isEmpty) {
      headline = 'Spending is in line with your usual.';
    } else {
      String part(CategoryChange c) =>
          '${c.name} ${_signed((c.current - c.average).toDouble())}';
      headline =
          'Against your $comparedMonths-month average: '
          '${moved.take(2).map(part).join(', ')}';
    }
    return HomeCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeChartHeader(title: 'What changed', headline: headline),
          if (comparedMonths > 0)
            RankedBarChart(
              entries: [
                for (final c in moved)
                  ChartEntry(
                    label: c.name,
                    value: (c.current - c.average).toDouble(),
                    color: c.current > c.average
                        ? palette.expense
                        : palette.income,
                  ),
              ],
              formatValue: _signed,
            ),
        ],
      ),
    );
  }
}
