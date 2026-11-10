import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'private_amount.dart';

/// A money amount whose digits roll like an odometer. Currency symbols, signs
/// and separators stay still; each digit reel turns on its own.
///
/// The motion is meant to be quiet: a long, soft deceleration with no
/// overshoot, the digits at the right (the ones that change most) finishing
/// first, and the reel fading out at its top and bottom edge so digits dissolve
/// rather than being cut off. A rising value rolls up and a falling one rolls
/// down. Nothing moves for reduced motion, or when the value hasn't changed.
///
/// Reusable anywhere an amount is shown: pass the minor-unit [value] and a
/// [format] that turns it into text. Place inside PrivateAmount when the value
/// needs privacy protection.
class AnimatedAmount extends StatefulWidget {
  const AnimatedAmount({
    super.key,
    required this.value,
    required this.format,
    this.style,
    this.rollOnlyOnReveal = false,
  });

  final int value;
  final String Function(int) format;
  final TextStyle? style;

  /// Roll only when the eye was just pressed to show amounts. Switching
  /// account or period, a refresh and the like change the digits without
  /// any motion.
  final bool rollOnlyOnReveal;

  /// The curve every reel decelerates along: quick off the mark, then a long
  /// gentle settle (an ease-out-quint).
  static const curve = Cubic(0.22, 1, 0.36, 1);

  @override
  State<AnimatedAmount> createState() => _AnimatedAmountState();
}

class _AnimatedAmountState extends State<AnimatedAmount> {
  /// Which way the last change went: 1 up, -1 down.
  int _direction = 1;
  late final bool _rollOnMount =
      !widget.rollOnlyOnReveal || PrivateAmount.justRevealed;

  @override
  void didUpdateWidget(AnimatedAmount oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.value != oldWidget.value) {
      _direction = widget.value > oldWidget.value ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final formatted = widget.format(widget.value);
    if (MediaQuery.disableAnimationsOf(context)) {
      return Text(formatted, style: widget.style, maxLines: 1);
    }
    final textStyle = DefaultTextStyle.of(context).style
        .merge(widget.style)
        .copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final scaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    var width = 0.0, height = 0.0;
    for (var digit = 0; digit < 10; digit++) {
      final painter = TextPainter(
        text: TextSpan(text: '$digit', style: textStyle),
        textDirection: direction,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      width = math.max(width, painter.width);
      height = math.max(height, painter.height);
      painter.dispose();
    }
    final characters = formatted.characters.toList();
    var place = characters.where((c) => int.tryParse(c) != null).length;
    return Semantics(
      label: formatted,
      child: ExcludeSemantics(
        // Its own layer: while the digits roll, only they repaint, not the
        // card (and its charts) around them.
        child: RepaintBoundary(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final character in characters)
                if (int.tryParse(character) case final digit?)
                  _DigitReel(
                    // Keep decimal places aligned when the number
                    // grows/shrinks.
                    key: ValueKey(--place),
                    digit: digit,
                    place: place,
                    rollsUp: _direction > 0,
                    roll: _rollOnMount,
                    rollOnChange: !widget.rollOnlyOnReveal,
                    width: width,
                    height: height,
                    style: textStyle,
                  )
                else
                  Text(character, style: textStyle, maxLines: 1),
            ],
          ),
        ),
      ),
    );
  }
}

class _DigitReel extends StatefulWidget {
  const _DigitReel({
    super.key,
    required this.digit,
    required this.place,
    required this.rollsUp,
    required this.roll,
    required this.rollOnChange,
    required this.width,
    required this.height,
    required this.style,
  });
  final int digit, place;
  final bool rollsUp;

  /// Whether to roll into place when first shown, and when the digit changes.
  final bool roll, rollOnChange;
  final double width, height;
  final TextStyle style;

  @override
  State<_DigitReel> createState() => _DigitReelState();
}

class _DigitReelState extends State<_DigitReel>
    with SingleTickerProviderStateMixin {
  // Ones finish first and each place further left takes a little longer, so
  // the number settles from the right like a real counter.
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 820 + math.min(widget.place, 6) * 70),
  );
  late double _from = widget.roll
      ? widget.digit - 3.0
      : widget.digit.toDouble();
  late double _to = widget.digit.toDouble();

  double get _position =>
      _from + (_to - _from) * AnimatedAmount.curve.transform(_controller.value);

  @override
  void initState() {
    super.initState();
    if (widget.roll) {
      _controller.forward();
    } else {
      _controller.value = 1;
    }
  }

  @override
  void didUpdateWidget(_DigitReel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.digit == widget.digit) return;
    if (!widget.rollOnChange) {
      _from = _to = widget.digit.toDouble();
      _controller.value = 1;
      return;
    }
    // Continue from the visible position if data updates mid-roll, then turn
    // the way the value moved: up to the next matching digit, or down to the
    // previous one.
    _from = _position;
    final base = _from.floorToDouble();
    final turn = (widget.digit - base.toInt()) % 10;
    if (widget.rollsUp) {
      _to = base + turn;
      if (_to <= _from) _to += 10;
    } else {
      _to = base + turn - 10;
      if (_to >= _from) _to -= 10;
    }
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// Fades the reel out over its top and bottom edge.
  static final _edge = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: const [
      Color(0x00000000),
      Color(0xFF000000),
      Color(0xFF000000),
      Color(0x00000000),
    ],
    stops: const [0, .22, .78, 1],
  );

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    height: widget.height,
    child: AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final position = _position;
        final current = position.floor();
        final fraction = position - current;
        Widget digit(int number, double offset) => Positioned(
          top: offset * widget.height,
          left: 0,
          right: 0,
          child: Text(
            '${number % 10}',
            style: widget.style,
            textAlign: TextAlign.center,
            maxLines: 1,
          ),
        );
        final reel = Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            digit(current, -fraction),
            if (fraction > 0) digit(current + 1, 1 - fraction),
          ],
        );
        // At rest the digit is plain text, so a settled number is never
        // dimmed by the mask; it only applies while the reel is turning.
        if (_controller.isCompleted) return reel;
        return ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (bounds) => _edge.createShader(bounds),
          child: reel,
        );
      },
    ),
  );
}
