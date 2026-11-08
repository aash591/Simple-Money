import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../data/repositories/home_repository.dart';
import '../../../domain/currency_scope.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/app_icon.dart';
import '../../components/charts/charts.dart';
import '../../components/common.dart';
import 'home_card.dart';

/// The month's spending by category as a pie, with the full ranking a tap
/// away.
class SpendingCard extends StatelessWidget {
  const SpendingCard({
    super.key,
    required this.data,
    required this.month,
    required this.currency,
  });
  final HomeSummary data;
  final DateTime month;
  final CurrencyScope currency;

  String _amount(double value) => homeMoney(value.round(), currency);

  /// The five biggest categories keep a hue of their own; the tail folds into
  /// one grey "Others", so no two categories ever share a colour. The query
  /// already returns them biggest first, so index i here is category i.
  static const _named = 5;

  List<ChartEntry> _segments(BuildContext context) {
    final palette = ChartPalette.of(context);
    final rest = data.categories.skip(_named);
    return [
      for (final (i, c) in data.categories.take(_named).indexed)
        ChartEntry(
          label: c.name,
          value: c.amount + .0,
          color: palette.series(i),
        ),
      if (rest.isNotEmpty)
        ChartEntry(
          label: 'Others',
          value: rest.fold(0.0, (sum, c) => sum + c.amount),
          color: palette.other,
        ),
    ];
  }

  Widget _badge(BuildContext context, int index) => index < _named
      ? AppIcon(data.categories[index].icon)
      : Icon(
          Icons.more_horiz_rounded,
          size: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        );

  void _details(BuildContext context) => showAdaptiveSheet<void>(
    context,
    builder: (context) => SheetPage(
      header: SheetHeader('${DateFormat.MMMM().format(month)} spending'),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('${homeMoney(data.spent, currency)} total'),
          const SizedBox(height: 8),
          // Every category is listed, biggest first; past the palette's hues
          // they wear the neutral grey rather than repeating a colour.
          RankedBarChart(
            entries: [
              for (var i = 0; i < data.categories.length; i++)
                ChartEntry(
                  label: data.categories[i].name,
                  value: data.categories[i].amount + .0,
                  color: ChartPalette.of(context).series(i),
                ),
            ],
            formatValue: _amount,
            showShare: true,
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => HomeCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SectionTitle(
          'Top expense categories',
          action: data.spent > 0 ? 'See all' : null,
          onTap: data.spent > 0 ? () => _details(context) : null,
        ),
        const SizedBox(height: 14),
        if (data.spent == 0)
          const Text('No spending this month.')
        else
          CalloutDonutChart(
            slices: _segments(context),
            centerLabel: homeMoney(data.spent, currency),
            centerCaption: 'spent',
            formatValue: _amount,
            badgeBuilder: _badge,
          ),
      ],
    ),
  );
}
