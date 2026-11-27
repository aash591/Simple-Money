import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'inner_glow.dart' show rasterCachingEnabled, rasterScaleOf;

/// A dashed rounded outline, for a card that invites adding something rather
/// than showing it. Paint it behind the card's content with [CustomPaint].
class DashedOutline extends CustomPainter {
  const DashedOutline(this.color, {this.radius = 22, this.strokeWidth = 1.5});
  final Color color;
  final double radius, strokeWidth;

  @override
  void paint(Canvas canvas, Size size) => paintCached(
    canvas,
    size,
    'outline:${color.toARGB32()}:$radius:$strokeWidth',
    (canvas) => canvas.drawPath(
      dashPath(
        Path()..addRRect(
          RRect.fromRectAndRadius(
            (Offset.zero & size).deflate(1),
            Radius.circular(radius),
          ),
        ),
      ),
      Paint()
        ..color = color
        ..strokeWidth = strokeWidth
        ..style = PaintingStyle.stroke,
    ),
  );

  @override
  bool shouldRepaint(DashedOutline old) =>
      old.color != color ||
      old.radius != radius ||
      old.strokeWidth != strokeWidth;
}

/// [source] cut into dashes [dash] long, every [every], as one path to draw
/// in a single call rather than one per dash.
Path dashPath(Path source, {double dash = 5, double every = 11}) {
  final dashes = Path();
  for (final metric in source.computeMetrics()) {
    for (var start = 0.0; start < metric.length; start += every) {
      dashes.addPath(
        metric.extractPath(start, math.min(start + dash, metric.length)),
        Offset.zero,
      );
    }
  }
  return dashes;
}

/// Draws [draw] for a box of [size] from an image made the first time, and
/// kept for that size, [key] and scale. A dashed outline is dozens of small
/// strokes: drawn afresh, the screen redid all of them on every frame the
/// page scrolled, which made the cards that carry one stutter into view.
/// [overflow] is how far the drawing reaches outside the box.
void paintCached(
  Canvas canvas,
  Size size,
  String key,
  void Function(Canvas canvas) draw, {
  double overflow = 0,
}) {
  if (!rasterCachingEnabled || size.isEmpty) return draw(canvas);
  final scale = rasterScaleOf(canvas);
  final bounds = (Offset.zero & size).inflate(overflow);
  final width = (bounds.width * scale).ceil();
  final height = (bounds.height * scale).ceil();
  final id =
      '$key|${size.width.toStringAsFixed(1)}x'
      '${size.height.toStringAsFixed(1)}|$overflow|$scale';
  var image = _DashCache.images.remove(id);
  if (image == null) {
    final recorder = ui.PictureRecorder();
    draw(
      Canvas(recorder)
        ..scale(scale)
        ..translate(overflow, overflow),
    );
    final picture = recorder.endRecording();
    image = picture.toImageSync(width, height);
    picture.dispose();
    while (_DashCache.images.length >= _DashCache.limit) {
      // A picture already recorded keeps its own hold on the image.
      _DashCache.images.remove(_DashCache.images.keys.first)!.dispose();
    }
  }
  // Most recently used last, so the oldest goes first.
  _DashCache.images[id] = image;
  canvas.drawImageRect(
    image,
    Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
    Rect.fromLTWH(bounds.left, bounds.top, width / scale, height / scale),
    Paint()..filterQuality = FilterQuality.low,
  );
}

abstract final class _DashCache {
  static final images = <String, ui.Image>{};

  /// A card-sized image at screen resolution is a few megabytes; only the
  /// handful on screen at once are worth keeping.
  static const limit = 16;
}
