import 'package:flutter/material.dart';

/// A dashed rounded outline, for a card that invites adding something rather
/// than showing it. Paint it behind the card's content with [CustomPaint].
class DashedOutline extends CustomPainter {
  const DashedOutline(this.color, {this.radius = 22, this.strokeWidth = 1.5});
  final Color color;
  final double radius, strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final path = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          (Offset.zero & size).deflate(1),
          Radius.circular(radius),
        ),
      );
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;
    for (final metric in path.computeMetrics()) {
      for (double offset = 0; offset < metric.length; offset += 11) {
        canvas.drawPath(metric.extractPath(offset, offset + 5), paint);
      }
    }
  }

  @override
  bool shouldRepaint(DashedOutline old) =>
      old.color != color ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth;
}
