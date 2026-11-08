import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'chart_data.dart';
import 'chart_palette.dart';

/// Horizontal bars, one per entry, longest first: the form for "which of
/// these is biggest" — spending by category, balances by account.
///
/// It is a separate widget from [BarChart] on purpose. Rotating columns is
/// not the whole job: names need room to sit and to ellipsize, and each row
/// wants to be tappable, which plain widgets do better than a painter.
class RankedBarChart extends StatelessWidget {
  const RankedBarChart({
    super.key,
    required this.entries,
    this.formatValue,
    this.showShare = false,
    this.barHeight = 8,
    this.maxValue,
    this.onTap,
  });

  final List<ChartEntry> entries;
  final ChartValueFormatter? formatValue;

  /// Shows each entry's percentage of the total next to its value.
  final bool showShare;
  final double barHeight;

  /// What a full-width bar means. Defaults to the largest entry, so the top
  /// bar always fills — pass a total or a budget to scale against that
  /// instead, and the bars become comparable across cards.
  final double? maxValue;

  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    final palette = ChartPalette.of(context);
    final total = entries.fold<double>(0, (sum, e) => sum + e.value.abs());
    final max =
        maxValue ??
        entries.fold<double>(0, (n, e) => math.max(n, e.value.abs()));
    final format = formatValue;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < entries.length; i++)
          InkWell(
            onTap: onTap == null ? null : () => onTap!(i),
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: Text(
                          entries[i].label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13),
                        ),
                      ),
                      if (showShare && total > 0) ...[
                        const SizedBox(width: 8),
                        Text(
                          '${(entries[i].value.abs() / total * 100).round()}%',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      if (format != null) ...[
                        const SizedBox(width: 10),
                        Flexible(
                          flex: 2,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(
                              format(entries[i].value),
                              maxLines: 1,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(barHeight),
                    child: Stack(
                      children: [
                        Container(height: barHeight, color: palette.track),
                        FractionallySizedBox(
                          widthFactor: max <= 0
                              ? 0
                              : (entries[i].value.abs() / max).clamp(0.0, 1.0),
                          child: Container(
                            height: barHeight,
                            color: entries[i].color,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
