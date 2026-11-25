import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Which drawn icon a tab uses.
enum NavIconMotion { home, list, bars, dots }

/// A tab icon drawn in code that plays a short animation when its tab gains
/// focus: the door of the house rises, the list's lines draw in, the bars
/// grow, the dots bounce. At rest, and for tabs that start selected, it is
/// still. [active] also fills the shape in, as the Material "selected" icons
/// do.
class NavIconMotionIcon extends StatefulWidget {
  const NavIconMotionIcon({
    super.key,
    required this.motion,
    required this.active,
    required this.color,
    this.size = 24,
  });
  final NavIconMotion motion;
  final bool active;
  final Color color;
  final double size;

  @override
  State<NavIconMotionIcon> createState() => _NavIconMotionIconState();
}

class _NavIconMotionIconState extends State<NavIconMotionIcon>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
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
  Widget build(BuildContext context) => ExcludeSemantics(
    child: RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => CustomPaint(
          size: Size.square(widget.size),
          painter: _NavIconPainter(
            motion: widget.motion,
            t: _controller.value,
            filled: widget.active,
            color: widget.color,
          ),
        ),
      ),
    ),
  );
}

class _NavIconPainter extends CustomPainter {
  const _NavIconPainter({
    required this.motion,
    required this.t,
    required this.filled,
    required this.color,
  });
  final NavIconMotion motion;

  /// 0 to 1 through the animation; 1 is the resting icon.
  final double t;
  final bool filled;
  final Color color;

  static const _stroke = 2.0;

  /// [t] sliced into the part from [begin] to [end], eased.
  double _part(double begin, double end, [Curve curve = Curves.easeOutCubic]) =>
      curve.transform(((t - begin) / (end - begin)).clamp(0.0, 1.0));

  Paint get _line => Paint()
    ..color = color
    ..style = PaintingStyle.stroke
    ..strokeWidth = _stroke
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round;

  Paint get _solid => Paint()..color = color;

  @override
  void paint(Canvas canvas, Size size) {
    // Drawn on a 24-unit grid.
    canvas.scale(size.width / 24);
    switch (motion) {
      case NavIconMotion.home:
        _home(canvas);
      case NavIconMotion.list:
        _list(canvas);
      case NavIconMotion.bars:
        _bars(canvas);
      case NavIconMotion.dots:
        _dots(canvas);
    }
  }

  void _home(Canvas canvas) {
    // A small pop, about the foot of the house.
    final pop = 1 + .1 * math.sin(math.pi * _part(0, .6, Curves.easeOut));
    canvas.translate(12, 20.5);
    canvas.scale(pop);
    canvas.translate(-12, -20.5);
    final doorH = 7 * _part(.1, .7, Curves.easeOutBack);
    final door = RRect.fromLTRBR(
      9.8,
      20.5 - doorH,
      14.2,
      20.5,
      const Radius.circular(1),
    );
    if (filled) {
      final house = Path()
        ..moveTo(12, 3.2)
        ..lineTo(21, 11.2)
        ..lineTo(18.5, 11.2)
        ..lineTo(18.5, 20.5)
        ..lineTo(5.5, 20.5)
        ..lineTo(5.5, 11.2)
        ..lineTo(3, 11.2)
        ..close();
      canvas.saveLayer(const Rect.fromLTWH(0, 0, 24, 24), Paint());
      canvas.drawPath(
        house,
        _solid
          ..strokeWidth = _stroke
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(house, _line);
      canvas.drawRRect(door, Paint()..blendMode = BlendMode.clear);
      canvas.restore();
    } else {
      canvas.drawPath(
        Path()
          ..moveTo(3, 11.2)
          ..lineTo(12, 3.2)
          ..lineTo(21, 11.2),
        _line,
      );
      canvas.drawPath(
        Path()
          ..moveTo(5.5, 9.6)
          ..lineTo(5.5, 20.5)
          ..lineTo(18.5, 20.5)
          ..lineTo(18.5, 9.6),
        _line,
      );
      canvas.drawRRect(door, _line);
    }
  }

  void _list(Canvas canvas) {
    final card = RRect.fromRectAndRadius(
      const Rect.fromLTWH(3.5, 3.5, 17, 17),
      const Radius.circular(4),
    );
    // Each line draws in from the left, one after the other.
    final lines = [
      for (var i = 0; i < 3; i++)
        (
          Offset(7.5, 9 + i * 3.2),
          Offset(
            7.5 + (i == 2 ? 6 : 9) * _part(i * .14, .5 + i * .14),
            9 + i * 3.2,
          ),
        ),
    ];
    if (filled) {
      canvas.saveLayer(const Rect.fromLTWH(0, 0, 24, 24), Paint());
      canvas.drawRRect(card, _solid);
      final clear = Paint()
        ..blendMode = BlendMode.clear
        ..style = PaintingStyle.stroke
        ..strokeWidth = _stroke
        ..strokeCap = StrokeCap.round;
      for (final (a, b) in lines) {
        canvas.drawLine(a, b, clear);
      }
      canvas.restore();
    } else {
      canvas.drawRRect(card, _line);
      for (final (a, b) in lines) {
        canvas.drawLine(a, b, _line);
      }
    }
  }

  void _bars(Canvas canvas) {
    const xs = [6.5, 12.0, 17.5], heights = [8.0, 15.0, 11.0];
    for (var i = 0; i < 3; i++) {
      final h = heights[i] * _part(i * .12, .6 + i * .12, Curves.easeOutBack);
      if (h <= 0) continue;
      canvas.drawRRect(
        RRect.fromLTRBR(
          xs[i] - 1.9,
          20 - h,
          xs[i] + 1.9,
          20,
          const Radius.circular(1.9),
        ),
        _solid,
      );
    }
  }

  void _dots(Canvas canvas) {
    const xs = [5.0, 12.0, 19.0];
    for (var i = 0; i < 3; i++) {
      final hop = math.sin(
        math.pi * _part(i * .12, .5 + i * .12, Curves.linear),
      );
      canvas.drawCircle(Offset(xs[i], 12 - 5 * hop), 2.1, _solid);
    }
  }

  @override
  bool shouldRepaint(_NavIconPainter old) =>
      old.t != t ||
      old.filled != filled ||
      old.color != color ||
      old.motion != motion;
}
