import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'chart_data.dart';
import 'chart_frame.dart';
import 'chart_legend.dart';
import 'chart_palette.dart';

/// A horizontal marker across the plot: a budget limit, a target, an average.
@immutable
class ChartReferenceLine {
  const ChartReferenceLine({required this.value, this.label, this.color});
  final double value;
  final String? label;
  final Color? color;
}

/// Values over an ordered run of slots — days of a month, months of a year.
/// [cumulative] plots each series' running total instead, which is how a
/// month-to-date cash flow reads.
///
/// Dragging or tapping moves a crosshair and shows every series' value at
/// that slot.
class LineChart extends StatefulWidget {
  const LineChart({
    super.key,
    required this.series,
    this.labels = const [],
    this.cumulative = false,
    this.filled = false,
    this.formatValue,
    this.formatAxis,
    this.height = 160,
    this.divisions = 3,
    this.referenceLines = const [],
    this.showAxis = true,
    this.showLegend = true,
    this.showEndMarkers = true,
    this.onSelect,
  });

  final List<ChartSeries> series;
  final List<String> labels;

  /// Plots running totals. The series still carry per-slot amounts, so the
  /// same data can feed a bar chart without being reshaped.
  final bool cumulative;

  /// Washes the area under each line at 10% — readable for one series, muddy
  /// for several.
  final bool filled;

  final ChartValueFormatter? formatValue;
  final ChartValueFormatter? formatAxis;
  final double height;
  final int divisions;
  final List<ChartReferenceLine> referenceLines;
  final bool showAxis, showLegend, showEndMarkers;
  final ValueChanged<int?>? onSelect;

  @override
  State<LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<LineChart> {
  int? _selected;

  List<ChartSeries> get _plotted => [
    for (final s in widget.series)
      if (!widget.cumulative)
        s
      else
        ChartSeries(
          label: s.label,
          values: _runningTotal(s.values),
          color: s.color,
          negativeColor: s.negativeColor,
          dashed: s.dashed,
        ),
  ];

  static List<double> _runningTotal(List<double> values) {
    var sum = 0.0;
    return [for (final value in values) sum += value];
  }

  void _select(int? slot) {
    if (slot == _selected) return;
    setState(() => _selected = slot);
    widget.onSelect?.call(slot);
  }

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final series = _plotted;
    final slots = series.fold(0, (n, s) => math.max(n, s.values.length));
    final bounds = ChartBounds.of([
      ...series.expand((s) => s.values),
      ...widget.referenceLines.map((r) => r.value),
    ], divisions: widget.divisions);
    final plot = LayoutBuilder(
      builder: (context, constraints) {
        void pick(Offset position) {
          if (slots == 0) return;
          _select(
            ((position.dx / constraints.maxWidth) * slots).floor().clamp(
              0,
              slots - 1,
            ),
          );
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => pick(d.localPosition),
          onTapUp: (_) => _select(null),
          onTapCancel: () => _select(null),
          onHorizontalDragStart: (d) => pick(d.localPosition),
          onHorizontalDragUpdate: (d) => pick(d.localPosition),
          onHorizontalDragEnd: (_) => _select(null),
          child: CustomPaint(
            painter: _LinePainter(
              series: series,
              slots: slots,
              bounds: bounds,
              filled: widget.filled,
              showEndMarkers: widget.showEndMarkers,
              referenceLines: widget.referenceLines,
              palette: palette,
              selected: _selected,
              labels: widget.labels,
              formatValue: widget.formatValue,
              style: chartLabelStyle(context),
              scaler: MediaQuery.textScalerOf(context),
            ),
          ),
        );
      },
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.showLegend && widget.series.length > 1) ...[
          ChartLegend.ofSeries(series),
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

class _LinePainter extends CustomPainter {
  _LinePainter({
    required this.series,
    required this.slots,
    required this.bounds,
    required this.filled,
    required this.showEndMarkers,
    required this.referenceLines,
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
  final bool filled, showEndMarkers;
  final List<ChartReferenceLine> referenceLines;
  final ChartPalette palette;
  final int? selected;
  final List<String> labels;
  final ChartValueFormatter? formatValue;
  final TextStyle style;
  final TextScaler scaler;

  @override
  void paint(Canvas canvas, Size size) {
    if (slots == 0 || size.width <= 0) return;
    final plot = Offset.zero & size;
    double x(int slot) => size.width * (slot + .5) / slots;
    double y(double value) => size.height * (1 - bounds.fraction(value));

    for (final reference in referenceLines) {
      final at = y(reference.value);
      _dashed(
        canvas,
        Path()
          ..moveTo(0, at)
          ..lineTo(size.width, at),
        Paint()
          ..color = (reference.color ?? palette.label).withValues(alpha: .7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );
      final label = reference.label;
      if (label == null) continue;
      final painter = TextPainter(
        text: TextSpan(text: label, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      painter.paint(
        canvas,
        Offset(size.width - painter.width, at - painter.height - 2),
      );
    }

    for (final s in series) {
      if (s.values.isEmpty) continue;
      final path = Path();
      for (var i = 0; i < s.values.length; i++) {
        final point = Offset(x(i), y(s.values[i]));
        if (i == 0) {
          path.moveTo(point.dx, point.dy);
        } else {
          path.lineTo(point.dx, point.dy);
        }
      }
      if (filled && !s.dashed) {
        final base = y(math.max(bounds.min, 0));
        canvas.drawPath(
          Path.from(path)
            ..lineTo(x(s.values.length - 1), base)
            ..lineTo(x(0), base)
            ..close(),
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                s.color.withValues(alpha: .23),
                s.color.withValues(alpha: .015),
              ],
            ).createShader(Offset.zero & size),
        );
      }
      final stroke = Paint()
        ..color = s.color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round;
      if (s.dashed) {
        _dashed(canvas, path, stroke);
      } else {
        canvas.drawPath(path, stroke);
      }
      if (showEndMarkers && s.values.length > 1) {
        _marker(
          canvas,
          Offset(x(s.values.length - 1), y(s.values.last)),
          s.color,
        );
      }
    }

    final format = formatValue;
    final slot = selected;
    if (slot == null) return;
    canvas.drawLine(
      Offset(x(slot), 0),
      Offset(x(slot), size.height),
      Paint()..color = palette.label.withValues(alpha: .35),
    );
    var top = size.height;
    for (final s in series) {
      if (slot >= s.values.length) continue;
      final at = Offset(x(slot), y(s.values[slot]));
      _marker(canvas, at, s.color);
      top = math.min(top, at.dy);
    }
    if (format == null) return;
    paintChartTooltip(
      canvas,
      plot: plot,
      anchor: Offset(x(slot), top),
      palette: palette,
      style: style,
      scaler: scaler,
      title: slot < labels.length ? labels[slot] : null,
      rows: [
        for (final s in series)
          if (slot < s.values.length)
            ChartTooltipRow(
              color: s.color,
              label: s.label,
              value: format(s.values[slot]),
            ),
      ],
    );
  }

  /// A dot wears a ring in the surface colour so it stays legible where lines
  /// cross or markers overlap.
  void _marker(Canvas canvas, Offset at, Color color) {
    canvas.drawCircle(at, 6, Paint()..color = palette.surface);
    canvas.drawCircle(at, 4.5, Paint()..color = color);
  }

  void _dashed(Canvas canvas, Path path, Paint paint) {
    for (final metric in path.computeMetrics()) {
      for (var start = 0.0; start < metric.length; start += 9) {
        canvas.drawPath(
          metric.extractPath(start, math.min(start + 5, metric.length)),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_LinePainter old) =>
      old.selected != selected ||
      old.bounds != bounds ||
      old.filled != filled ||
      old.slots != slots ||
      old.palette.surface != palette.surface ||
      old.referenceLines.length != referenceLines.length ||
      !listEquals(old.series, series) ||
      !listEquals(old.labels, labels);
}
