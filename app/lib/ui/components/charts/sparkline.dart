import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// A trend with no axes, small enough to sit inside a list row or a stat
/// tile. It says "rising" or "falling", never "how much" — anything that
/// needs a value read off it wants a [LineChart] instead.
class Sparkline extends StatelessWidget {
  const Sparkline({
    super.key,
    required this.values,
    required this.color,
    this.filled = true,
    this.height = 28,
    this.width,
  });

  final List<num> values;
  final Color color;
  final bool filled;
  final double height;
  final double? width;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: width,
    child: CustomPaint(
      painter: _SparklinePainter(
        [for (final value in values) value.toDouble()],
        color,
        filled,
      ),
    ),
  );
}

class _SparklinePainter extends CustomPainter {
  _SparklinePainter(this.values, this.color, this.filled);
  final List<double> values;
  final Color color;
  final bool filled;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2 || size.width <= 0) return;
    final low = values.reduce(math.min), high = values.reduce(math.max);
    final span = high - low == 0 ? 1 : high - low;
    // Inset by the stroke so the extremes are not clipped in half.
    final top = 1.5, bottom = size.height - 1.5;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = size.width * i / (values.length - 1);
      final y = bottom - (values[i] - low) / span * (bottom - top);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    if (filled) {
      canvas.drawPath(
        Path.from(path)
          ..lineTo(size.width, size.height)
          ..lineTo(0, size.height)
          ..close(),
        Paint()..color = color.withValues(alpha: .1),
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_SparklinePainter old) =>
      old.color != color ||
      old.filled != filled ||
      !listEquals(old.values, values);
}
