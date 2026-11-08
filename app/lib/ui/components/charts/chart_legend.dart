import 'package:flutter/material.dart';

import 'chart_data.dart';

/// The identity channel every multi-series chart ships with, so a reader never
/// has to match colours by memory. Horizontal reads as a key above a plot;
/// vertical reads as the breakdown beside a pie, with values and shares.
class ChartLegend extends StatelessWidget {
  const ChartLegend({
    super.key,
    required this.entries,
    this.direction = Axis.horizontal,
    this.formatValue,
    this.showShare = false,
    this.selectedIndex,
    this.onTap,
  });

  /// The same legend built from what a plotted chart was given — each series'
  /// name, colour and total.
  ChartLegend.ofSeries(
    List<ChartSeries> series, {
    super.key,
    this.direction = Axis.horizontal,
    this.formatValue,
    this.showShare = false,
    this.selectedIndex,
    this.onTap,
  }) : entries = [
         for (final s in series)
           ChartEntry(label: s.label, value: s.total, color: s.color),
       ];

  final List<ChartEntry> entries;
  final Axis direction;

  /// Null shows names only — the right call above a plot that already has a
  /// value axis.
  final ChartValueFormatter? formatValue;

  /// Adds each entry's percentage of the total, for a composition chart where
  /// the share is the point.
  final bool showShare;

  final int? selectedIndex;
  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) return const SizedBox.shrink();
    if (direction == Axis.horizontal) {
      return Wrap(
        spacing: 16,
        runSpacing: 6,
        children: [for (var i = 0; i < entries.length; i++) _key(context, i)],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (var i = 0; i < entries.length; i++) _row(context, i)],
    );
  }

  Widget _key(BuildContext context, int index) {
    final entry = entries[index];
    final format = formatValue;
    return _tappable(
      index,
      Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _Swatch(entry.color, dimmed: _dimmed(index)),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              entry.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: _labelStyle(context, index),
            ),
          ),
          if (format != null) ...[
            const SizedBox(width: 6),
            Text(
              format(entry.value),
              style: _labelStyle(
                context,
                index,
              )?.copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ],
      ),
    );
  }

  Widget _row(BuildContext context, int index) {
    final entry = entries[index];
    final format = formatValue;
    final total = entries.fold<double>(0, (sum, e) => sum + e.value.abs());
    return _tappable(
      index,
      Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            _Swatch(entry.color, dimmed: _dimmed(index)),
            const SizedBox(width: 8),
            Expanded(
              flex: 3,
              child: Text(
                entry.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _labelStyle(context, index),
              ),
            ),
            if (showShare && total > 0) ...[
              const SizedBox(width: 8),
              Text(
                '${(entry.value.abs() / total * 100).round()}%',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
            if (format != null) ...[
              const SizedBox(width: 10),
              // An amount shrinks to fit rather than ellipsizing: half a
              // number is worse than a small one, and long currency strings
              // at large text sizes would otherwise overflow the row.
              Flexible(
                flex: 2,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    format(entry.value),
                    maxLines: 1,
                    style: _labelStyle(
                      context,
                      index,
                    )?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  bool _dimmed(int index) => selectedIndex != null && selectedIndex != index;

  TextStyle? _labelStyle(BuildContext context, int index) {
    final style = Theme.of(context).textTheme.bodyMedium
        ?.copyWith(fontSize: 12);
    return _dimmed(index)
        ? style?.copyWith(color: style.color?.withValues(alpha: .45))
        : style;
  }

  Widget _tappable(int index, Widget child) => onTap == null
      ? child
      : InkWell(
          onTap: () => onTap!(index),
          borderRadius: BorderRadius.circular(8),
          child: child,
        );
}

class _Swatch extends StatelessWidget {
  const _Swatch(this.color, {required this.dimmed});
  final Color color;
  final bool dimmed;
  @override
  Widget build(BuildContext context) => Container(
    width: 8,
    height: 8,
    decoration: BoxDecoration(
      color: dimmed ? color.withValues(alpha: .35) : color,
      shape: BoxShape.circle,
    ),
  );
}
