import 'dart:ui';

import 'package:flutter/material.dart';

import 'glass_button.dart';
import 'search_field.dart';

/// A round glass disc holding a thin, drawn glyph, as in the system's own
/// settings and phone apps: the back button, and the search and more
/// buttons at the end of a header. It is made like [SearchField], so it sits
/// beside one as a match: the same height, the same blurred translucent body
/// and rim, and no drop shadow. It takes a [tapSize] square, so discs side by
/// side keep a small gap without any spacing from the caller.
///
/// Pressing shrinks it a little instead of an ink ripple.
class GlassCircleButton extends StatefulWidget {
  const GlassCircleButton({
    super.key,
    required this.label,
    required this.glyph,
    required this.onPressed,
    this.showTooltip = true,
  });

  /// Read out, and shown as a tooltip on long press unless [showTooltip] is
  /// off (a press-and-drag menu uses the long press itself).
  final String label;
  final CustomPainter glyph;
  final VoidCallback? onPressed;
  final bool showTooltip;

  static const size = SearchField.height;
  static const tapSize = 48.0;

  /// Between the edge of the tap square and the disc. A header that lines a
  /// disc up with the page margin sets the square this far past it.
  static const edgeInset = (tapSize - size) / 2;

  @override
  State<GlassCircleButton> createState() => _GlassCircleButtonState();
}

class _GlassCircleButtonState extends State<GlassCircleButton> {
  bool _pressed = false;

  void _press(bool value) {
    if (widget.onPressed != null && _pressed != value) {
      setState(() => _pressed = value);
    }
  }

  /// [SearchField]'s glass, in a circle. A press dims it a touch.
  Widget _disc(
    ThemeData theme, {
    required bool pressed,
    required Widget child,
  }) {
    final dark = theme.brightness == Brightness.dark;
    final radius = BorderRadius.circular(GlassCircleButton.size / 2);
    final body = Color.alphaBlend(
      pressed
          ? (dark ? Colors.white : Colors.black).withValues(
              alpha: dark ? .1 : .06,
            )
          : Colors.transparent,
      SearchField.fill(context),
    );
    return Container(
      width: GlassCircleButton.size,
      height: GlassCircleButton.size,
      decoration: BoxDecoration(borderRadius: radius),
      foregroundDecoration: GlassRim(dark: dark, solid: false, radius: radius),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter.grouped(
          filter: ImageFilter.blur(
            sigmaX: SearchField.blurSigma,
            sigmaY: SearchField.blurSigma,
          ),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            decoration: BoxDecoration(
              // The same faint sheen over the top half as the search field.
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color.alphaBlend(
                    Colors.white.withValues(alpha: dark ? .04 : .3),
                    body,
                  ),
                  body,
                ],
                stops: const [0, .5],
              ),
            ),
            child: child,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final pressed = _pressed && !MediaQuery.disableAnimationsOf(context);
    final button = Semantics(
      button: true,
      enabled: widget.onPressed != null,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => _press(true),
        onTapCancel: () => _press(false),
        onTapUp: (_) => _press(false),
        onTap: widget.onPressed,
        child: SizedBox.square(
          dimension: GlassCircleButton.tapSize,
          child: Center(
            child: AnimatedScale(
              scale: pressed ? .9 : 1,
              duration: const Duration(milliseconds: 120),
              curve: Curves.easeOutCubic,
              child: _disc(
                theme,
                pressed: pressed,
                child: Opacity(
                  opacity: widget.onPressed == null ? .4 : 1,
                  child: CustomPaint(painter: widget.glyph),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Tooltip(
      message: widget.label,
      // Kept, but never shown on its own, when long press means something
      // else.
      triggerMode: widget.showTooltip ? null : TooltipTriggerMode.manual,
      child: button,
    );
  }
}

/// The app's back button. [close] draws an × instead, for the first step of
/// a flow, where going back means leaving it.
///
/// Like [BackButton], a null [onPressed] pops the current route.
class AppBackButton extends StatelessWidget {
  const AppBackButton({super.key, this.onPressed, this.close = false});
  final VoidCallback? onPressed;
  final bool close;

  @override
  Widget build(BuildContext context) {
    final localizations = MaterialLocalizations.of(context);
    return GlassCircleButton(
      label: close
          ? localizations.closeButtonTooltip
          : localizations.backButtonTooltip,
      glyph: _Glyph(
        close ? _GlyphKind.close : _GlyphKind.back,
        Theme.of(context).colorScheme.onSurface,
      ),
      onPressed: onPressed ?? () => Navigator.maybePop(context),
    );
  }
}

/// A header's search button: a thin magnifying glass in a glass disc.
class AppSearchButton extends StatelessWidget {
  const AppSearchButton({
    super.key,
    required this.onPressed,
    this.tooltip = 'Search',
  });
  final VoidCallback? onPressed;
  final String tooltip;

  @override
  Widget build(BuildContext context) => GlassCircleButton(
    label: tooltip,
    glyph: _Glyph(_GlyphKind.search, Theme.of(context).colorScheme.onSurface),
    onPressed: onPressed,
  );
}

/// Three stacked dots, for a header's more-options button.
CustomPainter moreGlyph(Color color) => _Glyph(_GlyphKind.more, color);

enum _GlyphKind { back, close, search, more }

/// Light-weight strokes, centred in the disc.
class _Glyph extends CustomPainter {
  const _Glyph(this.kind, this.color);
  final _GlyphKind kind;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    switch (kind) {
      case _GlyphKind.back:
        // 15 wide: the shaft spans it, the head reaches 5 back and 5 out.
        final tip = c + const Offset(-7.5, 0);
        canvas
          ..drawLine(tip, c + const Offset(7.5, 0), stroke)
          ..drawPath(
            Path()
              ..moveTo(tip.dx + 5, tip.dy - 5)
              ..lineTo(tip.dx, tip.dy)
              ..lineTo(tip.dx + 5, tip.dy + 5),
            stroke,
          );
      case _GlyphKind.close:
        const r = 4.5;
        canvas
          ..drawLine(c + const Offset(-r, -r), c + const Offset(r, r), stroke)
          ..drawLine(c + const Offset(r, -r), c + const Offset(-r, r), stroke);
      case _GlyphKind.search:
        // The lens sits up and left so lens and handle together are centred.
        final lens = c + const Offset(-1.5, -1.5);
        const radius = 5.2;
        const toRim = radius * .7071;
        canvas
          ..drawCircle(lens, radius, stroke)
          ..drawLine(
            lens + const Offset(toRim, toRim),
            c + const Offset(6.8, 6.8),
            stroke,
          );
      case _GlyphKind.more:
        final dot = Paint()..color = color;
        for (final dy in const [-5.0, 0.0, 5.0]) {
          canvas.drawCircle(c + Offset(0, dy), 1.5, dot);
        }
    }
  }

  @override
  bool shouldRepaint(_Glyph oldDelegate) =>
      kind != oldDelegate.kind || color != oldDelegate.color;
}
