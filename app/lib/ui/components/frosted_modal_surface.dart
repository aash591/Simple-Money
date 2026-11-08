import 'dart:ui';

import 'package:flutter/material.dart';

import '../../data/device_performance.dart';
import 'inner_glow.dart';
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
    this.blurSigma = 40,
    this.shadows = const [],
  });

  final BorderRadius borderRadius;
  final Widget child;
  final double blurSigma;
  final List<BoxShadow> shadows;

  @override
  Widget build(BuildContext context) {
    final content = Material(type: MaterialType.transparency, child: child);
    final reveal = PopupReveal.maybeOf(context);
    if (reveal == null) return _surface(context, 1, content);
    return AnimatedBuilder(
      animation: reveal,
      child: content,
      builder: (context, content) => _surface(context, reveal.value, content!),
    );
  }

  Widget _surface(BuildContext context, double visibility, Widget content) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    // The native blur behind Quick Entry still needs a see-through tint.
    final solid = DevicePerformance.lowEnd && !NativeModalBlur.enabled;
    final tint = dark
        ? const Color(0xff2a2a2a).withValues(alpha: solid ? .97 : .78)
        : Colors.white.withValues(alpha: solid ? .96 : .66);
    Widget surface = CustomPaint(
      foregroundPainter: _GlassRim(borderRadius, dark, visibility),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          // Uniform frost keeps the top just as glassy as the bottom.
          // Opaque cards and controls above it retain their contrast.
          color: tint.withValues(alpha: tint.a * visibility),
        ),
        // Fully opaque, this paints its child directly with no extra layer.
        child: Opacity(opacity: visibility, child: content),
      ),
    );
    if (!solid) {
      // Ramping the blur up with the tint keeps it from snapping on.
      final sigma = blurSigma * visibility;
      surface = BackdropFilter(
        enabled: sigma > .5,
        filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: surface,
      );
    }
    surface = NativeModalBlur(
      radius: borderRadius.topLeft.x,
      child: ClipRRect(borderRadius: borderRadius, child: surface),
    );
    if (shadows.isEmpty) return surface;
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
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
          white(dark ? .075 : .22),
          white(dark ? .015 : .04),
          white(dark ? .09 : .28),
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
