import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/inner_glow.dart';

/// The glow drawn from a cached nine-patch has to match the rings it stands
/// in for, pixel for pixel give or take edge smoothing.
void main() {
  Future<Uint8List> draw(
    RRect shape,
    List<double> falloff,
    double opacity,
    double ratio, {
    required bool cached,
  }) async {
    rasterCachingEnabled = cached;
    debugScreenRatio = ratio;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawColor(const Color(0xff202030), BlendMode.src)
      ..scale(ratio);
    paintInnerGlow(canvas, shape, falloff: falloff, opacity: opacity);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      (shape.right * ratio).ceil() + 4,
      (shape.bottom * ratio).ceil() + 4,
    );
    final bytes = await image.toByteData();
    image.dispose();
    picture.dispose();
    return bytes!.buffer.asUint8List();
  }

  tearDown(() {
    rasterCachingEnabled = false;
    debugScreenRatio = null;
  });

  for (final (name, shape, falloff, opacity) in [
    (
      'card',
      RRect.fromLTRBR(3, 5, 303, 125, const Radius.circular(24)),
      const [.6, .35, .15, .05],
      .14,
    ),
    (
      'disc',
      RRect.fromLTRBR(2, 2, 42, 42, const Radius.circular(20)),
      const [.67, .56, .39, .22, .11, .04],
      .6,
    ),
    (
      'pill',
      RRect.fromLTRBR(1, 1, 181, 49, const Radius.circular(24)),
      const [.67, .56, .39, .22, .11, .04],
      .3,
    ),
  ]) {
    for (final ratio in [1.0, 2.75, 3.0]) {
      test('$name at $ratio matches the rings', () async {
        final rings = await draw(shape, falloff, opacity, ratio, cached: false);
        final image = await draw(shape, falloff, opacity, ratio, cached: true);
        expect(image.length, rings.length);
        final width = (shape.right * ratio).ceil() + 4;
        var edge = 0, inside = 0;
        for (var i = 0; i < rings.length; i++) {
          final d = (image[i] - rings[i]).abs();
          final pixel = i ~/ 4;
          final at = Offset(
            (pixel % width + .5) / ratio,
            (pixel ~/ width + .5) / ratio,
          );
          // Physical pixels from the shape's outline.
          final fromEdge = _distance(shape, at).abs() * ratio;
          if (fromEdge <= 1.5) {
            if (d > edge) edge = d;
          } else if (d > inside) {
            inside = d;
          }
        }
        // The glow itself matches. At a ratio that puts the shape between
        // pixels (2.75 here) the image is resampled, which softens each
        // 2dp band's step by under 4%; the outermost pixel may differ a
        // little more, and the rim's own stroke is drawn over that one.
        expect(inside, lessThanOrEqualTo(ratio % 1 == 0 ? 3 : 10));
        expect(edge, lessThanOrEqualTo(32));
      });
    }
  }
}

/// Signed distance from [p] to the outline of [shape] (all corners alike).
double _distance(RRect shape, Offset p) {
  final r = shape.tlRadiusX;
  final c = shape.center;
  final qx = (p.dx - c.dx).abs() - (shape.width / 2 - r);
  final qy = (p.dy - c.dy).abs() - (shape.height / 2 - r);
  final ox = qx > 0 ? qx : 0.0, oy = qy > 0 ? qy : 0.0;
  final outside = Offset(ox, oy).distance;
  final inner = (qx > qy ? qx : qy);
  return outside + (inner < 0 ? inner : 0.0) - r;
}
