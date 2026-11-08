import 'dart:ui';

import 'package:flutter/material.dart';

import 'inner_glow.dart';
import '../theme/app_theme.dart' show usesGlass;

/// The app's glass pill button, shared by sheet/alert actions and the number
/// keypad. Neutral by default: a translucent grey body with a light-catching
/// edge, so whatever sits behind it shows through. Pass [color] for the main
/// action, which fills the pill solid in that colour under the same edge.
///
/// Pressing shrinks it slightly and shifts its tint — there is no ink ripple.
/// A null [onPressed] shows it disabled.
class GlassButton extends StatefulWidget {
  const GlassButton({
    super.key,
    required this.child,
    required this.onPressed,
    this.onLongPress,
    this.color,
    this.fill,
    this.foregroundColor,
    this.height = 48,
    this.textStyle,
    this.shadow = false,
    this.blur = 0,
    this.autofocus = false,
    this.busy = false,
  });
  final Widget child;
  final VoidCallback? onPressed;
  final VoidCallback? onLongPress;

  /// A solid fill for the main action, usually the accent.
  final Color? color;

  /// Overrides the neutral translucent body; ignored when [color] is set.
  final Color? fill;
  final Color? foregroundColor;
  final double height;
  final TextStyle? textStyle;

  /// A soft drop shadow outside the pill, for buttons sitting on a plain
  /// surface such as the keypad.
  final bool shadow;

  /// Blurs what shows through a translucent [fill] by this sigma; 0 for
  /// none. Joins the nearest [BackdropGroup], so pills in one group blur in
  /// a single pass.
  final double blur;
  final bool autofocus;

  /// Working on the last tap: keeps the enabled look, so a main action
  /// doesn't fade to grey while it runs, but takes no taps.
  final bool busy;

  /// The neutral body: a light veil in dark mode, near-white in light mode.
  static Color neutralFill(Brightness brightness) =>
      brightness == Brightness.dark
      ? Colors.white.withValues(alpha: .14)
      : Colors.white.withValues(alpha: .82);

  @override
  State<GlassButton> createState() => _GlassButtonState();
}

class _GlassButtonState extends State<GlassButton>
    with SingleTickerProviderStateMixin {
  bool _pressed = false;
  late final AnimationController _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 100),
  );
  late final _pressCurve = CurvedAnimation(
    parent: _press,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  bool get _enabled => widget.onPressed != null && !widget.busy;

  /// Drawn as enabled: tappable, or [GlassButton.busy] with its action.
  bool get _active => _enabled || widget.busy;

  Future<void> _pressDown() async {
    if (!_enabled || MediaQuery.disableAnimationsOf(context)) return;
    _pressed = true;
    try {
      await _press.forward().orCancel;
      // The tap may have closed this button's screen meanwhile.
      if (mounted && !_pressed) _release();
    } on TickerCanceled {
      // Another press or disposal interrupted this animation.
    }
  }

  void _release() {
    _pressed = false;
    if (!mounted) return;
    // Finish the shrink even for taps that begin and end between frames.
    if (_press.isCompleted) {
      _press.animateBack(0, duration: const Duration(milliseconds: 200));
    }
  }

  @override
  void dispose() {
    _pressCurve.dispose();
    _press.dispose();
    super.dispose();
  }

  Widget _blurred(BorderRadius radius, Widget body) =>
      widget.blur == 0 || !usesGlass(context)
      ? body
      : ClipRRect(
          borderRadius: radius,
          child: BackdropFilter.grouped(
            filter: ImageFilter.blur(sigmaX: widget.blur, sigmaY: widget.blur),
            child: body,
          ),
        );

  @override
  Widget build(BuildContext context) {
    final glass = usesGlass(context);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final brightness = Theme.of(context).brightness;
    final dark = brightness == Brightness.dark;
    final radius = BorderRadius.circular(widget.height / 2);
    // A disabled main action falls back to the neutral glass.
    final solid = widget.color != null && _active;
    final baseFill = solid
        ? widget.color!
        : glass
        ? widget.fill ?? GlassButton.neutralFill(brightness)
        : Color.alphaBlend(
            onSurface.withValues(alpha: .07),
            Theme.of(context).colorScheme.surface,
          );
    // Pressed: neutral glass brightens in dark mode and dims in light mode;
    // a solid fill always deepens a little.
    final pressedTint = !solid && dark
        ? Colors.white.withValues(alpha: .12)
        : Colors.black.withValues(alpha: solid ? .14 : .07);
    final foreground = !_active
        ? onSurface.withValues(alpha: .35)
        : widget.foregroundColor ?? (solid ? Colors.white : onSurface);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    return Listener(
      onPointerDown: (_) => _pressDown(),
      onPointerUp: (_) => _release(),
      onPointerCancel: (_) => _release(),
      child: AnimatedBuilder(
        animation: _pressCurve,
        builder: (context, child) {
          final t = reduceMotion ? 0.0 : _pressCurve.value;
          final fill = Color.alphaBlend(
            pressedTint.withValues(alpha: pressedTint.a * t),
            baseFill,
          );
          return Transform.scale(
            scale: 1 - .05 * t,
            child: Container(
              height: widget.height,
              decoration: widget.shadow && glass
                  ? BoxDecoration(
                      borderRadius: radius,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: (dark ? .25 : .08) * (1 - .6 * t),
                          ),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                          // Outer-only under a translucent body, so it never
                          // shows through. An opaque body hides it anyway, and
                          // a normal shadow is drawn without a blur pass —
                          // which matters across a whole keypad of keys.
                          blurStyle: baseFill.a == 1
                              ? BlurStyle.normal
                              : BlurStyle.outer,
                        ),
                      ],
                    )
                  : null,
              foregroundDecoration: !glass
                  ? null
                  : GlassRim(dark: dark, solid: solid, radius: radius),
              // No clip unless blurring: the rounded fill already gives the
              // shape, and a clip per key adds up across a full keypad.
              child: Material(
                type: MaterialType.transparency,
                child: _blurred(
                  radius,
                  DecoratedBox(
                    // A faint sheen over the top half of the body.
                    decoration: BoxDecoration(
                      borderRadius: radius,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Color.alphaBlend(
                            Colors.white.withValues(
                              alpha: !glass
                                  ? 0
                                  : solid
                                  ? .04
                                  : (dark ? .02 : .08),
                            ),
                            fill,
                          ),
                          fill,
                        ],
                        stops: const [0, .5],
                      ),
                    ),
                    child: child,
                  ),
                ),
              ),
            ),
          );
        },
        child: InkWell(
          autofocus: widget.autofocus,
          splashFactory: NoSplash.splashFactory,
          overlayColor: const WidgetStatePropertyAll(Colors.transparent),
          enableFeedback: false,
          onTap: _enabled ? widget.onPressed : null,
          onLongPress: _enabled ? widget.onLongPress : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Center(
              child: IconTheme.merge(
                data: IconThemeData(color: foreground, size: 22),
                child: DefaultTextStyle.merge(
                  style: (widget.textStyle ?? const TextStyle()).copyWith(
                    color: foreground,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  child: widget.child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The glass edge: a soft inner glow just inside the whole rim plus a
/// hairline that is a little brighter along the top than the sides and
/// bottom. Brighter on a solid fill so it still reads against the colour.
/// Shared with other glass pills, such as the search field, as a
/// foreground decoration.
class GlassRim extends Decoration {
  const GlassRim({
    required this.dark,
    required this.solid,
    required this.radius,
  });
  final bool dark;
  final bool solid;
  final BorderRadius radius;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _GlassRimPainter(this);
}

class _GlassRimPainter extends BoxPainter {
  _GlassRimPainter(this.rim);
  final GlassRim rim;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    final shape = rim.radius.toRRect(rect);
    final (glow, top, middle, bottom) = rim.solid
        ? (.015, .12, .03, .05)
        : rim.dark
        ? (.05, .16, .06, .04)
        : (.08, .6, .18, .22);
    // The falloff of an 8dp stroke blurred by sigma 4, clipped to the pill.
    paintInnerGlow(
      canvas,
      shape,
      opacity: glow,
      falloff: const [.67, .56, .39, .22, .11, .04],
    );
    canvas.drawRRect(
      rim.radius.toRRect(rect.deflate(.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: top),
            Colors.white.withValues(alpha: middle),
            Colors.white.withValues(alpha: bottom),
          ],
          stops: const [0, .5, 1],
        ).createShader(rect),
    );
  }
}
