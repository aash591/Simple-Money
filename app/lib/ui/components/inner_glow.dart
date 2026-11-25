import '../../data/platform_info.dart';

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Paints the soft white glow a wide blurred stroke leaves just inside
/// [shape] once clipped to it: brightest at the edge, fading inward.
///
/// It is built from nested rings, each reaching 2dp deeper from the edge
/// than the last, instead of a [MaskFilter.blur]. A blur is an offscreen pass
/// per shape on every frame, and a sheet full of keypad keys was enough to
/// make it stutter on low-end phones while it moved; plain fills cost next
/// to nothing. [falloff] is the glow's strength in each 2dp band from the
/// edge inward, as a fraction of [opacity], and must not increase.
///
/// Each ring is a rounded rectangle with a hole, which Impeller fills with a
/// stencil pass and a cover pass, on every frame, for every card and disc on
/// screen. So the rings are drawn once into a small image and the image is
/// stretched over the shape as a nine-patch: the glow is the same all the way
/// round, so only its corners need to keep their size.
void paintInnerGlow(
  Canvas canvas,
  RRect shape, {
  required List<double> falloff,
  double opacity = 1,
  Shader? shader,
}) {
  if (shader == null &&
      _GlowCache.enabled &&
      _GlowCache.paint(canvas, shape, falloff, opacity)) {
    return;
  }
  _paintRings(
    canvas,
    shape,
    falloff: falloff,
    opacity: opacity,
    shader: shader,
  );
}

void _paintRings(
  Canvas canvas,
  RRect shape, {
  required List<double> falloff,
  required double opacity,
  Shader? shader,
}) {
  final paint = Paint()..shader = shader;
  // Every ring also covers the bands of the deeper rings inside it, so each
  // only adds what those already leave short of its own band's strength.
  var deeper = 0.0;
  for (var i = falloff.length - 1; i >= 0; i--) {
    final target = opacity * falloff[i];
    paint.color = Colors.white.withValues(
      alpha: (1 - (1 - target) / (1 - deeper)).clamp(0.0, 1.0),
    );
    deeper = target;
    final inner = shape.deflate(2.0 * (i + 1));
    if (inner.width <= 0 || inner.height <= 0) {
      canvas.drawRRect(shape, paint);
    } else {
      canvas.drawDRRect(shape, inner, paint);
    }
  }
}

/// How many device pixels one logical pixel covers on [canvas] right now,
/// rounded up to the next half so a press zoom doesn't make a new image on
/// every frame, and never drawn below the screen's sharpness.
double rasterScaleOf(Canvas canvas) {
  final m = canvas.getTransform();
  final sx = math.sqrt(m[0] * m[0] + m[1] * m[1]);
  final sy = math.sqrt(m[4] * m[4] + m[5] * m[5]);
  final scale = math.max(sx, sy);
  if (!scale.isFinite || scale <= 0) return 1;
  // At rest the canvas is at the screen's own ratio: drawn at exactly that,
  // the image lands pixel for pixel.
  if ((scale - screenRatio).abs() < .001) return screenRatio;
  return ((scale * 2).ceil() / 2).clamp(1.0, 6.0);
}

/// The screen's device pixel ratio.
@visibleForTesting
double get screenRatio =>
    debugScreenRatio ??
    ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio ??
    1;
@visibleForTesting
double? debugScreenRatio;

/// Whether drawings may be kept as images. Widget tests compare plain
/// draws, so they keep drawing everything directly.
bool rasterCachingEnabled = !kIsWeb && !isFlutterTest;

abstract final class _GlowCache {
  static bool get enabled => rasterCachingEnabled;

  static final _images = <String, ui.Image>{};
  static const _limit = 96;

  /// Draws the glow from a cached image; false when [shape] isn't a plain
  /// rounded rectangle and the rings have to be drawn as they are.
  static bool paint(
    Canvas canvas,
    RRect shape,
    List<double> falloff,
    double opacity,
  ) {
    final r = shape.tlRadiusX;
    bool same(double v) => (v - r).abs() < .01;
    if (!same(shape.tlRadiusY) ||
        !same(shape.trRadiusX) ||
        !same(shape.trRadiusY) ||
        !same(shape.blRadiusX) ||
        !same(shape.blRadiusY) ||
        !same(shape.brRadiusX) ||
        !same(shape.brRadiusY) ||
        shape.width <= 0 ||
        shape.height <= 0) {
      return false;
    }
    final scale = rasterScaleOf(canvas);
    // Past this far in from every edge the glow is the same everywhere.
    final corner = math.max(r, 2.0 * falloff.length);
    final nine =
        shape.width >= 2 * corner + 2 && shape.height >= 2 * corner + 2;
    // A nine-patch for anything big enough; small discs get an image of
    // their own size (they come in only a few).
    final width = nine ? 2 * corner + 2 : shape.width;
    final height = nine ? 2 * corner + 2 : shape.height;
    final pw = (width * scale).ceil(), ph = (height * scale).ceil();
    final key = [
      r.toStringAsFixed(2),
      nine ? 'n' : '${width.toStringAsFixed(2)}x${height.toStringAsFixed(2)}',
      opacity.toStringAsFixed(4),
      scale,
      ...falloff,
    ].join(',');
    var image = _images.remove(key);
    if (image == null) {
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder)..scale(scale);
      // A nine-patch's shape fills its image to the last pixel, so the
      // stretched middle has no empty column at its edge.
      final rect = nine
          ? Rect.fromLTWH(0, 0, pw / scale, ph / scale)
          : Rect.fromLTWH(0, 0, width, height);
      _paintRings(
        c,
        RRect.fromRectAndRadius(rect, Radius.circular(r)),
        falloff: falloff,
        opacity: opacity,
      );
      final picture = recorder.endRecording();
      image = picture.toImageSync(pw, ph);
      picture.dispose();
      while (_images.length >= _limit) {
        // A picture already recorded keeps its own hold on the image.
        _images.remove(_images.keys.first)!.dispose();
      }
    }
    _images[key] = image;
    final paint = Paint()..filterQuality = FilterQuality.low;
    if (!nine) {
      canvas.drawImageRect(
        image,
        Rect.fromLTWH(0, 0, width * scale, height * scale),
        shape.outerRect,
        paint,
      );
      return true;
    }
    final inset = corner * scale;
    canvas
      ..save()
      ..translate(shape.left, shape.top)
      ..scale(1 / scale)
      ..drawImageNine(
        image,
        Rect.fromLTRB(inset, inset, pw - inset, ph - inset),
        Rect.fromLTWH(0, 0, shape.width * scale, shape.height * scale),
        paint,
      )
      ..restore();
    return true;
  }
}
