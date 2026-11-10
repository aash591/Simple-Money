import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'chart_data.dart';
import 'chart_frame.dart';
import 'chart_legend.dart';
import 'chart_palette.dart';

/// Grouped puts one bar per series side by side in each slot — for comparing
/// series against each other. Stacked adds them into one column — for a total
/// that is made of parts.
enum BarLayout { grouped, stacked }

/// Columns over slots: months, days, categories — whatever the screen is
/// comparing. Values may be negative, in which case the baseline moves and
/// [ChartSeries.negativeColor] gives the two directions their own colours.
///
/// Tapping a slot selects it and shows its readout; tapping it again clears.
class BarChart extends StatefulWidget {
  const BarChart({
    super.key,
    required this.series,
    this.labels = const [],
    this.layout = BarLayout.grouped,
    this.formatValue,
    this.formatAxis,
    this.height = 180,
    this.divisions = 3,
    this.maxBarThickness = 28,
    this.showAxis = true,
    this.showLegend = true,
    this.onSelect,
  });

  final List<ChartSeries> series;

  /// One label per slot, shown under the plot and as the tooltip's title.
  final List<String> labels;
  final BarLayout layout;

  /// Formats the tooltip's values; [formatAxis] falls back to it for ticks,
  /// which is usually right — pass a shorter formatter when axis ticks would
  /// crowd (`1.2k` against `₹1,234.00`).
  final ChartValueFormatter? formatValue;
  final ChartValueFormatter? formatAxis;
  final double height;
  final int divisions;
  final double maxBarThickness;
  final bool showAxis, showLegend;

  /// Fires with the tapped slot, or null when the selection is cleared.
  final ValueChanged<int?>? onSelect;

  @override
  State<BarChart> createState() => _BarChartState();
}

class _BarChartState extends State<BarChart> {
  int? _selected;

  int get _slots =>
      widget.series.fold(0, (n, s) => math.max(n, s.values.length));

  /// What the axis has to cover: each bar in a grouped chart, each column's
  /// running total in a stacked one.
  Iterable<double> get _extent {
    if (widget.layout == BarLayout.grouped) {
      return widget.series.expand((s) => s.values);
    }
    return [
      for (var i = 0; i < _slots; i++) ...[
        _sum(i, positive: true),
        _sum(i, positive: false),
      ],
    ];
  }

  double _sum(int slot, {required bool positive}) =>
      widget.series.fold(0, (total, series) {
        if (slot >= series.values.length) return total;
        final value = series.values[slot];
        return value.isNegative == !positive ? total + value : total;
      });

  void _select(int? slot) {
    if (slot == _selected) slot = null;
    setState(() => _selected = slot);
    widget.onSelect?.call(slot);
  }

  @override
  void didUpdateWidget(BarChart old) {
    super.didUpdateWidget(old);
    if (_selected != null && _selected! >= _slots) _selected = null;
  }

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final bounds = ChartBounds.of(_extent, divisions: widget.divisions);
    final plot = LayoutBuilder(
      builder: (context, constraints) => GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: _slots == 0
            ? null
            : (details) => _select(
                (details.localPosition.dx / (constraints.maxWidth / _slots))
                    .floor()
                    .clamp(0, _slots - 1),
              ),
        // Its own layer: a tap repaints the plot, not the whole card.
        child: RepaintBoundary(
          child: CustomPaint(
            painter: _BarPainter(
              series: widget.series,
              slots: _slots,
              bounds: bounds,
              layout: widget.layout,
              maxBarThickness: widget.maxBarThickness,
              palette: palette,
              selected: _selected,
              labels: widget.labels,
              formatValue: widget.formatValue,
              style: chartLabelStyle(context),
              scaler: MediaQuery.textScalerOf(context),
            ),
          ),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // One series needs no legend: the card's title already names it.
        if (widget.showLegend && widget.series.length > 1) ...[
          ChartLegend.ofSeries(widget.series),
          const SizedBox(height: 12),
        ],
        ChartFrame(
          bounds: bounds,
          height: widget.height,
          labels: widget.labels,
          formatValue: widget.showAxis
              ? widget.formatAxis ?? widget.formatValue
              : null,
          plot: plot,
        ),
      ],
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter({
    required this.series,
    required this.slots,
    required this.bounds,
    required this.layout,
    required this.maxBarThickness,
    required this.palette,
    required this.selected,
    required this.labels,
    required this.formatValue,
    required this.style,
    required this.scaler,
  });

  final List<ChartSeries> series;
  final int slots;
  final ChartBounds bounds;
  final BarLayout layout;
  final double maxBarThickness;
  final ChartPalette palette;
  final int? selected;
  final List<String> labels;
  final ChartValueFormatter? formatValue;
  final TextStyle style;
  final TextScaler scaler;

  /// The 2px of surface that separates touching marks — the gap does the
  /// separating, never a stroke around the bar.
  static const gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (slots == 0 || size.width <= 0) return;
    final plot = Offset.zero & size;
    final band = size.width / slots;
    final baseline = size.height * (1 - bounds.baseline);
    var tooltipAnchor = Offset.zero;

    for (var slot = 0; slot < slots; slot++) {
      final left = band * slot;
      final dimmed = selected != null && selected != slot;
      var top = baseline, bottom = baseline;
      if (layout == BarLayout.stacked) {
        final width = math.min(maxBarThickness, band * .6);
        final x = left + (band - width) / 2;
        final stack = [
          for (final s in series)
            if (slot < s.values.length && s.values[slot] != 0) s,
        ];
        // Only the column's far end is rounded; the joins inside a stack stay
        // square and are separated by the gap.
        final lastUp = stack.lastIndexWhere((s) => s.values[slot] > 0);
        final lastDown = stack.lastIndexWhere((s) => s.values[slot] < 0);
        for (var i = 0; i < stack.length; i++) {
          final value = stack[i].values[slot];
          final length = _length(value, size.height);
          final rect = value > 0
              ? Rect.fromLTRB(x, top - length, x + width, top)
              : Rect.fromLTRB(x, bottom, x + width, bottom + length);
          _bar(
            canvas,
            rect,
            stack[i].colorAt(slot),
            dimmed,
            up: value > 0,
            rounded: i == (value > 0 ? lastUp : lastDown),
          );
          if (value > 0) {
            top = rect.top + gap;
          } else {
            bottom = rect.bottom - gap;
          }
        }
      } else {
        final count = series.length;
        final inner = band * .72;
        final width = math.min(
          maxBarThickness,
          math.max(2.0, (inner - gap * (count - 1)) / count),
        );
        var x = left + (band - (width * count + gap * (count - 1))) / 2;
        for (final s in series) {
          final value = slot < s.values.length ? s.values[slot] : 0.0;
          if (value != 0) {
            final length = _length(value, size.height);
            final rect = value > 0
                ? Rect.fromLTRB(x, baseline - length, x + width, baseline)
                : Rect.fromLTRB(x, baseline, x + width, baseline + length);
            _bar(canvas, rect, s.colorAt(slot), dimmed, up: value > 0);
            top = math.min(top, rect.top);
            bottom = math.max(bottom, rect.bottom);
          }
          x += width + gap;
        }
      }
      if (slot == selected) {
        tooltipAnchor = Offset(left + band / 2, math.min(top, baseline));
      }
    }

    final format = formatValue;
    if (selected == null || format == null) return;
    paintChartTooltip(
      canvas,
      plot: plot,
      anchor: tooltipAnchor,
      palette: palette,
      style: style,
      scaler: scaler,
      title: selected! < labels.length ? labels[selected!] : null,
      rows: [
        for (final s in series)
          if (selected! < s.values.length && s.values[selected!] != 0)
            ChartTooltipRow(
              color: s.colorAt(selected!),
              label: s.label,
              value: format(s.values[selected!]),
            ),
      ],
    );
  }

  /// A value too small to see still gets 2px, so "almost nothing" never reads
  /// as "nothing at all".
  double _length(double value, double height) =>
      math.max(2, (value.abs() / bounds.span) * height);

  void _bar(
    Canvas canvas,
    Rect rect,
    Color color,
    bool dimmed, {
    required bool up,
    bool rounded = true,
  }) {
    final radius = rounded
        ? Radius.circular(math.min(8, rect.width / 2))
        : Radius.zero;
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        rect,
        topLeft: up ? radius : Radius.zero,
        topRight: up ? radius : Radius.zero,
        bottomLeft: up ? Radius.zero : radius,
        bottomRight: up ? Radius.zero : radius,
      ),
      Paint()..color = dimmed ? color.withValues(alpha: .3) : color,
    );
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.selected != selected ||
      old.bounds != bounds ||
      old.layout != layout ||
      old.slots != slots ||
      old.palette.surface != palette.surface ||
      !listEquals(old.series, series) ||
      !listEquals(old.labels, labels);
}
