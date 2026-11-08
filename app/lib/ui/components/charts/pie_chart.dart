import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'chart_data.dart';
import 'chart_palette.dart';

/// Parts of one whole. [thickness] is the ring's width; pass 0 for a solid
/// pie. A donut is the better default — the hole holds the total, which is
/// the number people actually read.
///
/// Zero and negative values are skipped, and no data draws a quiet track ring
/// rather than an empty hole, so the card keeps its shape while loading.
class PieChart extends StatelessWidget {
  const PieChart({
    super.key,
    required this.slices,
    this.size = 144,
    this.thickness = 20,
    this.centerLabel,
    this.centerCaption,
    this.center,
    this.selectedIndex,
    this.onSelect,
    this.formatValue,
  });

  final List<ChartEntry> slices;
  final double size, thickness;

  /// The total, or whatever one number the ring is about. Ignored when
  /// [center] is given.
  final String? centerLabel;
  final String? centerCaption;
  final Widget? center;

  /// Draws the rest back, so a selection made in a legend shows in the ring.
  final int? selectedIndex;
  final ValueChanged<int?>? onSelect;

  /// Only used to describe the chart to a screen reader.
  final ChartValueFormatter? formatValue;

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final format = formatValue;
    final total = slices.fold<double>(
      0,
      (sum, s) => sum + math.max(0, s.value),
    );
    final inner = center != null
        ? center!
        : centerLabel == null
        ? const SizedBox.shrink()
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  centerLabel!,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              if (centerCaption != null)
                Text(
                  centerCaption!,
                  style: Theme.of(context).textTheme.bodySmall,
                  textAlign: TextAlign.center,
                ),
            ],
          );
    return Semantics(
      label: [
        ?centerLabel,
        for (final slice in slices)
          '${slice.label}: ${format == null ? '${(slice.value / (total == 0 ? 1 : total) * 100).round()}%' : format(slice.value)}',
      ].join(', '),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: onSelect == null
            ? null
            : (details) => onSelect!(_sliceAt(details.localPosition, total)),
        child: SizedBox.square(
          dimension: size,
          child: CustomPaint(
            painter: _PiePainter(
              slices: slices,
              thickness: thickness,
              selected: selectedIndex,
              track: palette.track,
            ),
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(thickness + 12),
                child: inner,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The slice under a tap, or null for a tap in the hole or outside the
  /// ring — which reads as "clear the selection".
  int? _sliceAt(Offset position, double total) {
    final radius = size / 2;
    final offset = position - Offset(radius, radius);
    final distance = offset.distance;
    if (distance > radius || (thickness > 0 && distance < radius - thickness)) {
      return null;
    }
    if (total <= 0) return null;
    var angle = math.atan2(offset.dy, offset.dx) + math.pi / 2;
    if (angle < 0) angle += math.pi * 2;
    var start = 0.0;
    for (var i = 0; i < slices.length; i++) {
      if (slices[i].value <= 0) continue;
      start += slices[i].value / total * math.pi * 2;
      if (angle <= start) return i;
    }
    return null;
  }
}

class _PiePainter extends CustomPainter {
  _PiePainter({
    required this.slices,
    required this.thickness,
    required this.selected,
    required this.track,
  });
  final List<ChartEntry> slices;
  final double thickness;
  final int? selected;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final radius = size.shortestSide / 2;
    final solid = thickness <= 0;
    // A ring is stroked down its middle; a pie is a filled arc from the edge.
    final width = solid ? radius : thickness;
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: radius - width / 2,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = width;
    canvas.drawArc(rect, 0, math.pi * 2, false, paint..color = track);
    final total = slices.fold<double>(
      0,
      (sum, s) => sum + math.max(0, s.value),
    );
    if (total <= 0) return;
    // The 2px separator is the surface showing through, measured where the
    // eye reads the boundary: the middle of the ring.
    final gap = 2 / rect.width * 2;
    var start = -math.pi / 2;
    for (var i = 0; i < slices.length; i++) {
      final slice = slices[i];
      if (slice.value <= 0) continue;
      final sweep = slice.value / total * math.pi * 2;
      final dimmed = selected != null && selected != i;
      canvas.drawArc(
        selected == i ? rect.inflate(1.5) : rect,
        start,
        math.max(0, sweep - math.min(gap, sweep * .12)),
        false,
        paint
          ..color = dimmed ? slice.color.withValues(alpha: .3) : slice.color
          ..strokeWidth = selected == i ? width + 3 : width,
      );
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(_PiePainter old) =>
      old.selected != selected ||
      old.thickness != thickness ||
      old.track != track ||
      !listEquals(old.slices, slices);
}
