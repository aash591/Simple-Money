import 'package:flutter/material.dart';

import '../../data/device_performance.dart';
import 'cached_shadow.dart';
import 'glass_blur.dart';
import 'glass_surface.dart' show glassCardFill;
import 'inner_glow.dart';
import '../../state/appearance_controller.dart' show AppearanceScope;
import '../theme/app_theme.dart' show auroraDarkPage, usesAurora, usesGlass;
import '../theme/sheet_colors.dart';
import 'native_modal_blur.dart';
import 'popup_zoom.dart';

/// A clipped blur with a translucent tint and a light-catching glass rim.
///
/// Inside a [PopupZoom] it fades in with the popup: the blur strength, tint,
/// rim, [shadows] and content all follow [PopupReveal]. On low-end phones the
/// blur is replaced by a near-opaque tint, which costs nothing to animate.
class FrostedModalSurface extends StatelessWidget {
  const FrostedModalSurface({
    super.key,
    required this.borderRadius,
    required this.child,
    this.blurSigma = 28,
    this.shadows,
  });

  final BorderRadius borderRadius;
  final Widget child;
  final double blurSigma;

  /// The surface's drop shadow; null gives the soft, wide one iOS sheets
  /// have, so the surface lifts off the page behind it.
  final List<BoxShadow>? shadows;

  /// How much black lies under dark glass, from 0 to 1. A little, so the
  /// sheet reads a touch darker while keeping its sheen (56-74% dulled it).
  static const darkUnderlay = 0.25;

  static List<BoxShadow> _defaultShadows(bool dark) => [
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? .5 : .24),
      blurRadius: 44,
      spreadRadius: -4,
      offset: const Offset(0, -8),
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? .3 : .12),
      blurRadius: 10,
      offset: const Offset(0, -1),
    ),
  ];

  @override
  Widget build(BuildContext context) {
    // A menu opened from a page's header is not on the page backdrop itself.
    final content = GlassBlur(
      enabled: true,
      child: PageFrostHost.none(
        child: Material(type: MaterialType.transparency, child: child),
      ),
    );
    final reveal = PopupReveal.maybeOf(context);
    if (reveal == null) return _surface(context, 1, content);
    return AnimatedBuilder(
      animation: reveal,
      child: content,
      builder: (context, content) => _surface(context, reveal.value, content!),
    );
  }

  Widget _surface(BuildContext context, double visibility, Widget content) {
    final shadows =
        this.shadows ??
        _defaultShadows(Theme.of(context).brightness == Brightness.dark);
    final surface = _paint(context, visibility, content);
    if (shadows.isEmpty) return surface;
    // From cached images, as the cards' are: two wide blurs under a sheet
    // were redrawn on every frame of it sliding in.
    return CustomPaint(
      painter: BoxShadowPainter(
        radius: borderRadius,
        shadows: [
          for (final shadow in shadows)
            shadow.copyWith(
              color: shadow.color.withValues(
                alpha: shadow.color.a * visibility,
              ),
            ),
        ],
      ),
      child: surface,
    );
  }

  Widget _paint(BuildContext context, double visibility, Widget content) {
    if (!usesGlass(context)) {
      return Opacity(
        opacity: visibility,
        child: ClipRRect(
          borderRadius: borderRadius,
          child: ColoredBox(
            color: Theme.of(context).brightness == Brightness.dark
                ? Theme.of(context).colorScheme.surface
                : SheetColors.lightSheetBase(context),
            child: content,
          ),
        ),
      );
    }
    final dark = Theme.of(context).brightness == Brightness.dark;
    // The native blur behind Quick Entry still needs a see-through tint.
    final solid = DevicePerformance.lowEnd && !NativeModalBlur.enabled;
    if (solid && usesAurora(context)) {
      return ValueListenableBuilder<Object?>(
        valueListenable: ShownBackdrop.image,
        builder: (context, shown, _) => shown == null
            ? _painted(context, visibility, content, solid: true, dark: dark)
            : _onBackdrop(context, visibility, content, dark: dark),
      );
    }
    return _painted(context, visibility, content, solid: solid, dark: dark);
  }

  /// Low-end Aurora: no blur, but not a flat colour either. Like a Home
  /// card, the surface is the page's own backdrop (the glow, or the picture
  /// already frosted) under the card's glass, drawn from the image the page
  /// keeps and pinned to the screen as the surface moves.
  Widget _onBackdrop(
    BuildContext context,
    double visibility,
    Widget content, {
    required bool dark,
  }) {
    final fill = glassCardFill(context) as LinearGradient;
    return ClipRRect(
      borderRadius: borderRadius,
      child: CustomPaint(
        foregroundPainter: _GlassRim(borderRadius, dark, visibility),
        child: Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(child: ShownBackdropFill(opacity: visibility)),
            DecoratedBox(
              decoration: BoxDecoration(gradient: fill.scale(visibility)),
              child: Opacity(opacity: visibility, child: content),
            ),
          ],
        ),
      ),
    );
  }

  Widget _painted(
    BuildContext context,
    double visibility,
    Widget content, {
    required bool solid,
    required bool dark,
  }) {
    // The frost is made from the theme itself: the page's own base colour
    // with a wash of the accent, so a menu, alert or sheet reads as part of
    // the same glass as the cards. Over a chosen picture it lets more of the
    // picture's colour through.
    final scheme = Theme.of(context).colorScheme;
    final picture = AppearanceScope.maybeOf(context)?.wallpaperPath != null;
    final tint = dark
        ? Color.alphaBlend(
            scheme.primary.withValues(alpha: usesAurora(context) ? .16 : .10),
            usesAurora(context) ? auroraDarkPage : const Color(0xff1e1e20),
          ).withValues(alpha: solid ? .97 : (picture ? .56 : .72))
        : Color.alphaBlend(
            scheme.primary.withValues(alpha: .06),
            Colors.white,
          ).withValues(alpha: solid ? .96 : (picture ? .58 : .7));
    final Color base;
    if (solid) {
      base = (dark ? tint : SheetColors.lightSheetBase(context)).withValues(
        alpha: (dark ? tint.a : .96) * visibility,
      );
    } else if (!dark) {
      base = SheetColors.lightSheetBase(context)
          .withValues(alpha: (picture ? .72 : .84) * visibility);
    } else {
      // Dark glass is the frost and the glass fill alone: a flat dark layer
      // under it (tried at 56-74% black) dulled the sheen and the lit edge
      // that make it read as glass. [darkUnderlay] dials one in.
      base = Colors.black.withValues(alpha: darkUnderlay * visibility);
    }
    Widget surface = CustomPaint(
      foregroundPainter: _GlassRim(borderRadius, dark, visibility),
      child: ColoredBox(
        color: base,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: solid || !dark
                ? null
                : (glassCardFill(context) as LinearGradient).scale(
                    .55 * visibility,
                  ),
          ),
          // Fully opaque, this paints its child directly with no extra layer.
          child: Opacity(opacity: visibility, child: content),
        ),
      ),
    );
    // Over the launcher (Quick Entry, SMS popup) Flutter has nothing behind
    // the sheet to blur; Android's own blur does it, so skip a costly no-op.
    if (!solid && !NativeModalBlur.enabled) {
      // Ramping the blur up with the tint keeps it from snapping on.
      surface = ScreenFrost(
        sigma: blurSigma,
        visibility: visibility,
        child: surface,
      );
    }
    surface = NativeModalBlur(
      radius: borderRadius.topLeft.x,
      child: ClipRRect(borderRadius: borderRadius, child: surface),
    );
    return surface;
  }
}

class _GlassRim extends CustomPainter {
  const _GlassRim(this.radius, this.dark, this.opacity);
  final BorderRadius radius;
  final bool dark;
  final double opacity;

  @override
  void paint(Canvas canvas, Size size) {
    if (opacity <= 0) return;
    final rect = Offset.zero & size;
    final outline = radius.toRRect(rect).deflate(.5);
    Color white(double alpha) =>
        Colors.white.withValues(alpha: alpha * opacity);
    // A wide, faint reflection hugs the inside of the clipped edge. It adds
    // depth without putting another tint over the blurred center. The
    // falloff is that of a 7dp stroke blurred by sigma 5, clipped.
    paintInnerGlow(
      canvas,
      radius.toRRect(rect),
      falloff: const [.51, .46, .37, .25, .15, .08, .04],
      shader: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          white(dark ? .04 : .22),
          white(dark ? .01 : .04),
          white(dark ? .05 : .28),
        ],
        stops: const [0, .5, 1],
      ).createShader(rect),
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          white(dark ? .20 : .72),
          white(dark ? .04 : .12),
          white(dark ? .06 : .18),
          white(dark ? .24 : .52),
        ],
        stops: const [0, .35, .65, 1],
      ).createShader(rect);
    canvas.drawRRect(outline, paint);
  }

  @override
  bool shouldRepaint(_GlassRim oldDelegate) =>
      radius != oldDelegate.radius ||
      dark != oldDelegate.dark ||
      opacity != oldDelegate.opacity;
}
