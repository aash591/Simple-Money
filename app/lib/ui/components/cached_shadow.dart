import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';

import 'inner_glow.dart' show rasterCachingEnabled, rasterScaleOf;

/// Paints [shadows] around a rounded rectangle exactly where a
/// [BoxDecoration] with the same [radius] would, from cached images.
///
/// A blurred shadow is a per-pixel blur shader over the whole card and a
/// wide margin around it, redone for every card on every frame of a scroll
/// (Impeller keeps no raster cache). The blur is the same all the way round,
/// so it is drawn once into a small image and stretched over the shape as a
/// nine-patch: a textured quad costs a fraction of the shader.
class BoxShadowPainter extends CustomPainter {
  const BoxShadowPainter({required this.radius, required this.shadows});
  final BorderRadius radius;
  final List<BoxShadow> shadows;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    for (final shadow in shadows) {
      paintBoxShadow(canvas, rect, radius, shadow);
    }
  }

  @override
  bool shouldRepaint(BoxShadowPainter old) =>
      radius != old.radius || !listEquals(shadows, old.shadows);
}

/// One [shadow] of a box at [rect], as [BoxDecoration] paints it.
void paintBoxShadow(
  Canvas canvas,
  Rect rect,
  BorderRadius radius,
  BoxShadow shadow,
) {
  final shape = radius.toRRect(
    rect.shift(shadow.offset).inflate(shadow.spreadRadius),
  );
  if (rasterCachingEnabled && _ShadowCache.paint(canvas, shape, shadow)) {
    return;
  }
  canvas.drawRRect(shape, shadow.toPaint());
}

abstract final class _ShadowCache {
  static final _images = <String, ui.Image>{};
  static const _limit = 32;

  /// Draws the shadow from a cached image; false when it has to be drawn
  /// as it is (an uneven radius, or a blur style that cuts the shape out).
  static bool paint(Canvas canvas, RRect shape, BoxShadow shadow) {
    final sigma = shadow.blurSigma;
    if (shadow.blurStyle != BlurStyle.normal ||
        sigma <= 0 ||
        shape.width <= 0 ||
        shape.height <= 0) {
      return false;
    }
    final r = shape.tlRadiusX;
    bool same(double v) => (v - r).abs() < .01;
    if (!same(shape.tlRadiusY) ||
        !same(shape.trRadiusX) ||
        !same(shape.trRadiusY) ||
        !same(shape.blRadiusX) ||
        !same(shape.blRadiusY) ||
        !same(shape.brRadiusX) ||
        !same(shape.brRadiusY)) {
      return false;
    }
    // Past three sigmas a blur has under a thousandth of its strength left:
    // that far outside the shape nothing is drawn, and that far in from the
    // corners the shadow no longer changes along an edge.
    final reach = (3 * sigma).ceilToDouble();
    final corner = r + reach;
    // A wide blur has no detail finer than a logical pixel, so its image is
    // kept at that size; a tight one is kept as sharp as the screen.
    final scale = sigma >= 6 ? 1.0 : rasterScaleOf(canvas);
    // Each axis stretches its middle when the shape is long enough to have
    // one; a shorter side gets an image of its own length.
    final stretchX = shape.width >= 2 * corner + 2;
    final stretchY = shape.height >= 2 * corner + 2;
    final width = stretchX ? 2 * corner + 2 : shape.width;
    final height = stretchY ? 2 * corner + 2 : shape.height;
    final key = [
      r.toStringAsFixed(2),
      sigma.toStringAsFixed(3),
      // The image holds the shadow at full strength and is faded as it is
      // drawn: a faint shadow kept in eight bits would fall off in a
      // handful of visible steps.
      shadow.color.withValues(alpha: 1).toARGB32(),
      scale,
      stretchX ? 'n' : width.toStringAsFixed(1),
      stretchY ? 'n' : height.toStringAsFixed(1),
    ].join(',');
    var image = _images.remove(key);
    if (image == null) {
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..scale(scale)
        ..translate(reach, reach)
        ..drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(0, 0, width, height),
            Radius.circular(r),
          ),
          shadow.toPaint()..color = shadow.color.withValues(alpha: 1),
        );
      final picture = recorder.endRecording();
      image = picture.toImageSync(
        ((width + 2 * reach) * scale).ceil(),
        ((height + 2 * reach) * scale).ceil(),
      );
      picture.dispose();
      while (_images.length >= _limit) {
        // A picture already recorded keeps its own hold on the image.
        _images.remove(_images.keys.first)!.dispose();
      }
    }
    _images[key] = image;

    // Where the image and the screen are cut, along one axis: the two ends
    // keep their size and the middle (if any) stretches between them.
    List<(double, double)> cuts(
      bool stretch,
      double length,
      double from,
      double to,
    ) => stretch
        ? [
            (0, from - reach),
            (reach + corner, from + corner),
            (reach + corner + 2, to - corner),
            (length + 2 * reach, to + reach),
          ]
        : [(0, from - reach), (length + 2 * reach, to + reach)];
    final xs = cuts(stretchX, width, shape.left, shape.right);
    final ys = cuts(stretchY, height, shape.top, shape.bottom);
    final paint = Paint()
      ..color = Color.fromRGBO(0, 0, 0, shadow.color.a)
      ..filterQuality = FilterQuality.low
      ..isAntiAlias = false;
    for (var j = 0; j < ys.length - 1; j++) {
      for (var i = 0; i < xs.length - 1; i++) {
        final dst = Rect.fromLTRB(
          xs[i].$2,
          ys[j].$2,
          xs[i + 1].$2,
          ys[j + 1].$2,
        );
        if (dst.width <= 0 || dst.height <= 0) continue;
        canvas.drawImageRect(
          image,
          Rect.fromLTRB(
            xs[i].$1 * scale,
            ys[j].$1 * scale,
            xs[i + 1].$1 * scale,
            ys[j + 1].$1 * scale,
          ),
          dst,
          paint,
        );
      }
    }
    return true;
  }
}
