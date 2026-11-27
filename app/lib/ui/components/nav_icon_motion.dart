import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Which tab glyph a [NavIconMotionIcon] draws.
enum NavIconMotion { home, transactions, budgets, more }

/// A bottom-bar icon drawn in Flutter on a 24-unit grid with rounded strokes.
/// It shows an outline when [filled] is false and a solid shape when true,
/// and plays a short eased animation whenever [active] turns on. At rest, and
/// for tabs that start selected, it is still.
class NavIconMotionIcon extends StatefulWidget {
  const NavIconMotionIcon({
    super.key,
    required this.motion,
    required this.active,
    required this.color,
    this.filled,
    this.size = 24,
  });

  final NavIconMotion motion;
  final bool active;

  /// Solid when true, outline when false. Defaults to [active].
  final bool? filled;
  final Color color;
  final double size;

  @override
  State<NavIconMotionIcon> createState() => _NavIconMotionIconState();
}

class _NavIconMotionIconState extends State<NavIconMotionIcon>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 760),
    value: 1,
  );

  @override
  void didUpdateWidget(NavIconMotionIcon old) {
    super.didUpdateWidget(old);
    if (widget.active && !old.active) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _controller.value = 1;
      } else {
        _controller.forward(from: 0);
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      // Only the parts inside the glyph move; the icon itself keeps its size
      // and place.
      builder: (context, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: _NavGlyphPainter(
          motion: widget.motion,
          filled: widget.filled ?? widget.active,
          color: widget.color,
          t: _controller.value,
        ),
      ),
    );
  }
}

class _NavGlyphPainter extends CustomPainter {
  _NavGlyphPainter({
    required this.motion,
    required this.filled,
    required this.color,
    required this.t,
  });

  final NavIconMotion motion;
  final bool filled;
  final Color color;

  /// Raw animation time, 0 → 1; 1 is the resting icon.
  final double t;

  static const _stroke = 1.8;
  static const _box = Rect.fromLTWH(0, 0, 24, 24);

  double _ease(
    double begin,
    double end, [
    Curve curve = Curves.easeInOutCubic,
  ]) => Interval(begin, end, curve: curve).transform(t);

  Paint get _line => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = _stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Paint get _solid => Paint()
    ..color = color
    ..style = PaintingStyle.fill;

  static final _cut = Paint()..blendMode = BlendMode.clear;

  /// Fills [shape] and rounds its edges with a stroke of the same colour, so
  /// the solid version is exactly as large as the outline one.
  void _fillRounded(Canvas canvas, Path shape) {
    canvas
      ..drawPath(shape, _solid)
      ..drawPath(shape, _line);
  }

  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    switch (motion) {
      case NavIconMotion.home:
        _home(canvas);
      case NavIconMotion.transactions:
        _transactions(canvas);
      case NavIconMotion.budgets:
        _budgets(canvas);
      case NavIconMotion.more:
        _more(canvas);
    }
  }

  void _home(Canvas canvas) {
    final house = Path()
      ..moveTo(10.6, 4.9)
      ..quadraticBezierTo(12, 3.8, 13.4, 4.9)
      ..lineTo(19.2, 9.4)
      ..quadraticBezierTo(20, 10, 20, 11)
      ..lineTo(20, 18)
      ..arcToPoint(const Offset(17.6, 20.4), radius: const Radius.circular(2.4))
      ..lineTo(6.4, 20.4)
      ..arcToPoint(const Offset(4, 18), radius: const Radius.circular(2.4))
      ..lineTo(4, 11)
      ..quadraticBezierTo(4, 10, 4.8, 9.4)
      ..close();
    // The door rises into place.
    final drop = 5 * (1 - _ease(0.05, 0.9, Curves.easeOutCubic));
    if (filled) {
      canvas.saveLayer(_box.inflate(2), Paint());
      _fillRounded(canvas, house);
      canvas
        ..drawRRect(
          RRect.fromLTRBAndCorners(
            9.9,
            14.9 + drop,
            14.1,
            23,
            topLeft: const Radius.circular(2.1),
            topRight: const Radius.circular(2.1),
          ),
          _cut,
        )
        ..restore();
    } else {
      canvas
        ..drawPath(house, _line)
        ..save()
        ..clipRect(const Rect.fromLTRB(0, 0, 24, 20.4))
        ..drawPath(
          Path()
            ..moveTo(9.8, 20.4 + drop)
            ..lineTo(9.8, 16.8 + drop)
            ..arcToPoint(
              Offset(14.2, 16.8 + drop),
              radius: const Radius.circular(2.2),
            )
            ..lineTo(14.2, 20.4 + drop),
          _line,
        )
        ..restore();
    }
  }

  void _transactions(Canvas canvas) {
    // A bulleted list whose lines draw out one row after another.
    final paint = _line..strokeWidth = filled ? 2.5 : _stroke;
    final dotRadius = filled ? 1.6 : 1.3;
    for (var i = 0; i < 3; i++) {
      final y = 6.0 + 6 * i;
      final delay = i * 0.16;
      final line = _ease(delay, delay + 0.68);
      canvas
        ..drawCircle(Offset(4.6, y), dotRadius, _solid)
        ..drawLine(Offset(9, y), Offset(9 + 11 * line, y), paint);
    }
  }

  void _budgets(Canvas canvas) {
    // A pie with one slice that sweeps open from twelve o'clock.
    const center = Offset(12, 12);
    const radius = 8.2;
    final open = _ease(0, 0.9);
    final sweep = math.pi / 2 * open;
    const start = -math.pi / 2;
    Path wedge(double r) => Path()
      ..moveTo(center.dx, center.dy)
      ..arcTo(Rect.fromCircle(center: center, radius: r), start, sweep, false)
      ..close();

    if (!filled) {
      canvas.drawCircle(center, radius, _line);
      if (sweep > 0) {
        final end = center + Offset.fromDirection(start + sweep, radius);
        canvas.drawPath(
          Path()
            ..moveTo(center.dx, center.dy - radius)
            ..lineTo(center.dx, center.dy)
            ..lineTo(end.dx, end.dy),
          _line,
        );
      }
      return;
    }

    // Solid: the pie with the slice cut out, and the slice lifted slightly
    // away in a lighter tone.
    final outer = radius + _stroke / 2;
    canvas
      ..saveLayer(_box.inflate(2), Paint())
      ..drawCircle(center, outer, _solid);
    if (sweep > 0) {
      final cutout = wedge(outer + 1);
      canvas
        ..drawPath(cutout, _cut)
        ..drawPath(
          cutout,
          Paint()
            ..blendMode = BlendMode.clear
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2
            ..strokeJoin = StrokeJoin.round,
        );
    }
    canvas.restore();
    if (sweep > 0) {
      final lift = Offset.fromDirection(start + sweep / 2, 1.1);
      canvas
        ..save()
        ..translate(lift.dx, lift.dy)
        ..drawPath(wedge(outer), _solid..color = color.withValues(alpha: .5))
        ..restore();
    }
  }

  void _more(Canvas canvas) {
    // Four tiles that fade up one after another, clockwise.
    const tiles = [
      Offset(4, 4),
      Offset(13.6, 4),
      Offset(13.6, 13.6),
      Offset(4, 13.6),
    ];
    for (var i = 0; i < tiles.length; i++) {
      final shown = _ease(i * 0.14, i * 0.14 + 0.58);
      final tint = color.withValues(alpha: color.a * (0.25 + 0.75 * shown));
      final tile = RRect.fromRectAndRadius(
        tiles[i] & const Size.square(6.4),
        const Radius.circular(2.2),
      );
      if (filled) canvas.drawRRect(tile, _solid..color = tint);
      canvas.drawRRect(tile, _line..color = tint);
    }
  }

  @override
  bool shouldRepaint(_NavGlyphPainter old) =>
      old.t != t ||
      old.filled != filled ||
      old.color != color ||
      old.motion != motion;
}
