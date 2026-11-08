import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'chart_data.dart';
import 'chart_palette.dart';

/// The scaffolding every plotted chart sits in: value ticks down the left,
/// recessive gridlines behind the marks, and slot labels underneath, thinned
/// until they stop colliding.
///
/// [plot] is painted into the area right of the ticks and is handed exactly
/// the same [bounds], so a painter maps a value to a y with
/// `rect.bottom - bounds.fraction(value) * rect.height` and lands on the grid.
class ChartFrame extends StatelessWidget {
  const ChartFrame({
    super.key,
    required this.bounds,
    required this.height,
    required this.plot,
    this.formatValue,
    this.labels = const [],
  });

  final ChartBounds bounds;
  final double height;
  final Widget plot;

  /// Null hides the value axis — right for a chart whose marks are directly
  /// labelled, and for anything small.
  final ChartValueFormatter? formatValue;

  /// One label per slot. They are dropped at a fixed interval when they
  /// cannot all fit, never overlapped or rotated.
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final style = chartLabelStyle(context);
    final scaler = MediaQuery.textScalerOf(context);
    final format = formatValue;
    final ticks = format == null
        ? const <String>[]
        : bounds.ticks.map(format).toList();
    final gutter = ticks.isEmpty
        ? 0.0
        : ticks
                  .map((t) => measureChartText(t, style, scaler).width)
                  .reduce(math.max) +
              8;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: height,
          child: Stack(
            children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _GridPainter(
                    bounds: bounds,
                    ticks: ticks,
                    gutter: gutter,
                    grid: palette.grid,
                    style: style,
                    scaler: scaler,
                  ),
                ),
              ),
              Positioned.fill(left: gutter, child: plot),
            ],
          ),
        ),
        if (labels.isNotEmpty) ...[
          const SizedBox(height: 6),
          Padding(
            padding: EdgeInsets.only(left: gutter),
            child: _SlotLabels(labels: labels, style: style, scaler: scaler),
          ),
        ],
      ],
    );
  }
}

/// Axis text, tick text and tooltip text all wear this — a text token, never
/// the series colour, which is illegible at label sizes in half the palette.
TextStyle chartLabelStyle(BuildContext context) =>
    (Theme.of(context).textTheme.bodySmall ?? const TextStyle()).copyWith(
      fontSize: 11,
      color: ChartPalette.of(context).label,
    );

Size measureChartText(String text, TextStyle style, TextScaler scaler) =>
    (TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: TextDirection.ltr,
      textScaler: scaler,
      maxLines: 1,
    )..layout()).size;

class _SlotLabels extends StatelessWidget {
  const _SlotLabels({
    required this.labels,
    required this.style,
    required this.scaler,
  });
  final List<String> labels;
  final TextStyle style;
  final TextScaler scaler;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final widest = labels
          .map((l) => measureChartText(l, style, scaler).width)
          .fold(0.0, math.max);
      final height = measureChartText('0', style, scaler).height;
      final step = math.max(
        1,
        (labels.length * (widest + 10) / math.max(1, constraints.maxWidth))
            .ceil(),
      );
      return Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              // A kept label may be wider than its slot; thinning left the
              // neighbouring slots blank, so it centres over them unclipped.
              child: SizedBox(
                height: height,
                child: OverflowBox(
                  maxWidth: double.infinity,
                  child: Text(
                    i % step == 0 ? labels[i] : '',
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    softWrap: false,
                    style: style,
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}

class _GridPainter extends CustomPainter {
  _GridPainter({
    required this.bounds,
    required this.ticks,
    required this.gutter,
    required this.grid,
    required this.style,
    required this.scaler,
  });
  final ChartBounds bounds;
  final List<String> ticks;
  final double gutter;
  final Color grid;
  final TextStyle style;
  final TextScaler scaler;

  @override
  void paint(Canvas canvas, Size size) {
    final line = Paint()..color = grid;
    for (var i = 0; i <= bounds.divisions; i++) {
      final y = size.height * (1 - i / bounds.divisions);
      canvas.drawLine(Offset(gutter, y), Offset(size.width, y), line);
      if (i >= ticks.length) continue;
      final painter = TextPainter(
        text: TextSpan(text: ticks[i], style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      painter.paint(
        canvas,
        Offset(gutter - 8 - painter.width, y - painter.height / 2),
      );
    }
    // The baseline only earns extra ink when there is something below it.
    if (bounds.min < 0) {
      final y = size.height * (1 - bounds.baseline);
      canvas.drawLine(
        Offset(gutter, y),
        Offset(size.width, y),
        Paint()
          ..color = grid
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(_GridPainter old) =>
      old.bounds != bounds ||
      old.gutter != gutter ||
      old.grid != grid ||
      !listEquals(old.ticks, ticks);
}

/// One line of a tooltip: the series' colour as a dot, its name, its value.
@immutable
class ChartTooltipRow {
  const ChartTooltipRow({
    required this.color,
    required this.label,
    required this.value,
  });
  final Color color;
  final String label, value;
}

/// Draws the readout for the selected slot, nudged to stay inside [plot] so
/// it never hangs off the edge of the card. Shared by the bar and line charts
/// so a tap reads the same in both.
void paintChartTooltip(
  Canvas canvas, {
  required Rect plot,
  required Offset anchor,
  required List<ChartTooltipRow> rows,
  required ChartPalette palette,
  required TextStyle style,
  required TextScaler scaler,
  String? title,
}) {
  if (rows.isEmpty) return;
  const padding = 8.0, dot = 7.0, gap = 6.0, columnGap = 14.0;
  TextPainter paint(String text, {bool strong = false}) => TextPainter(
    text: TextSpan(
      text: text,
      style: strong ? style.copyWith(fontWeight: FontWeight.w600) : style,
    ),
    textDirection: TextDirection.ltr,
    textScaler: scaler,
    maxLines: 1,
  )..layout();

  final heading = title == null ? null : paint(title, strong: true);
  final labels = [for (final row in rows) paint(row.label)];
  final values = [for (final row in rows) paint(row.value, strong: true)];
  final lineHeight = [
    dot,
    for (var i = 0; i < rows.length; i++)
      math.max(labels[i].height, values[i].height),
  ].fold(0.0, math.max);
  final width =
      padding * 2 +
      [
        if (heading != null) heading.width,
        for (var i = 0; i < rows.length; i++)
          dot + gap + labels[i].width + columnGap + values[i].width,
      ].fold(0.0, math.max);
  final height =
      padding * 2 +
      (heading == null ? 0.0 : heading.height + 4) +
      lineHeight * rows.length +
      4 * (rows.length - 1);

  final left = math.min(
    math.max(anchor.dx - width / 2, plot.left),
    math.max(plot.left, plot.right - width),
  );
  var top = anchor.dy - height - 10;
  if (top < plot.top) top = math.min(anchor.dy + 12, plot.bottom - height);
  final rect = RRect.fromRectAndRadius(
    Rect.fromLTWH(left, top, width, height),
    const Radius.circular(10),
  );
  canvas.drawRRect(rect, Paint()..color = palette.surface);
  canvas.drawRRect(
    rect,
    Paint()
      ..color = palette.grid
      ..style = PaintingStyle.stroke,
  );

  var y = top + padding;
  if (heading != null) {
    heading.paint(canvas, Offset(left + padding, y));
    y += heading.height + 4;
  }
  for (var i = 0; i < rows.length; i++) {
    final center = y + lineHeight / 2;
    canvas.drawCircle(
      Offset(left + padding + dot / 2, center),
      dot / 2,
      Paint()..color = rows[i].color,
    );
    labels[i].paint(
      canvas,
      Offset(left + padding + dot + gap, center - labels[i].height / 2),
    );
    values[i].paint(
      canvas,
      Offset(
        left + width - padding - values[i].width,
        center - values[i].height / 2,
      ),
    );
    y += lineHeight + 4;
  }
}
