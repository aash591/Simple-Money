import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Independent vertical digit reels. Currency, signs and separators stay still.
/// Place inside PrivateAmount when the value needs privacy protection.
class AnimatedAmount extends StatelessWidget {
  const AnimatedAmount({
    super.key,
    required this.value,
    required this.format,
    this.style,
  });

  final int value;
  final String Function(int) format;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final formatted = format(value);
    if (MediaQuery.disableAnimationsOf(context)) {
      return Text(formatted, style: style, maxLines: 1);
    }
    final textStyle = DefaultTextStyle.of(context).style
        .merge(style)
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
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final character in characters)
              if (int.tryParse(character) case final digit?)
                _DigitReel(
                  // Keep decimal places aligned when the number grows/shrinks.
                  key: ValueKey(--place),
                  digit: digit,
                  place: place,
                  width: width,
                  height: height,
                  style: textStyle,
                )
              else
                Text(character, style: textStyle, maxLines: 1),
          ],
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
    required this.width,
    required this.height,
    required this.style,
  });
  final int digit, place;
  final double width, height;
  final TextStyle style;

  @override
  State<_DigitReel> createState() => _DigitReelState();
}

class _DigitReelState extends State<_DigitReel>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 520 + math.min(widget.place, 6) * 24),
  );
  late double _from = widget.digit - 3.0;
  late double _to = widget.digit.toDouble();

  double get _position =>
      _from + (_to - _from) * Curves.easeOutCubic.transform(_controller.value);

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void didUpdateWidget(_DigitReel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.digit == widget.digit) return;
    // Continue from the visible position if data updates mid-roll.
    _from = _position;
    _to = _from.floorToDouble() + (widget.digit - _from.floor() % 10) % 10;
    if (_to < _from) _to += 10;
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    width: widget.width,
    height: widget.height,
    child: ClipRect(
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
          return Stack(
            children: [
              digit(current, -fraction),
              if (fraction > 0) digit(current + 1, 1 - fraction),
            ],
          );
        },
      ),
    ),
  );
}
