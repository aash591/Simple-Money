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
void paintInnerGlow(
  Canvas canvas,
  RRect shape, {
  required List<double> falloff,
  double opacity = 1,
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
