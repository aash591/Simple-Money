import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/cached_shadow.dart';
import 'package:simple_money/ui/components/glass_surface.dart';
import 'package:simple_money/ui/components/inner_glow.dart';

/// A card's shadows drawn from cached images have to match the blurs they
/// stand in for.
void main() {
  const margin = 70.0;

  Future<Uint8List> draw(
    Size card,
    List<BoxShadow> shadows,
    double ratio, {
    required bool cached,
    Color page = const Color(0xff808890),
  }) async {
    // Tests draw shadows unblurred unless told otherwise.
    debugDisableShadows = false;
    rasterCachingEnabled = cached;
    debugScreenRatio = ratio;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..drawColor(page, BlendMode.src)
      ..scale(ratio)
      ..translate(margin, margin);
    BoxShadowPainter(
      radius: BorderRadius.circular(22),
      shadows: shadows,
    ).paint(canvas, card);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      ((card.width + 2 * margin) * ratio).ceil(),
      ((card.height + 2 * margin) * ratio).ceil(),
    );
    final bytes = await image.toByteData();
    image.dispose();
    picture.dispose();
    return bytes!.buffer.asUint8List();
  }

  tearDown(() {
    debugDisableShadows = true;
    rasterCachingEnabled = false;
    debugScreenRatio = null;
  });

  // Ten times a card's own shadow strength, so a mismatch can't hide in
  // rounding: the real ones darken the page by only a few levels in all.
  List<BoxShadow> strong(Brightness brightness) => [
    for (final shadow in glassCardShadows(brightness))
      shadow.copyWith(
        color: shadow.color.withValues(
          alpha: (shadow.color.a * 10).clamp(0, 1),
        ),
      ),
  ];

  for (final (name, card) in [
    // Long both ways: every side stretches.
    ('tall card', const Size(324, 260)),
    // Too short for the wide shadow to have a middle from top to bottom.
    ('one-row card', const Size(324, 72)),
    ('small tile', const Size(96, 64)),
  ]) {
    for (final ratio in [1.0, 2.75, 3.0]) {
      test('$name at $ratio matches the blurs', () async {
        for (final brightness in Brightness.values) {
          final shadows = strong(brightness);
          final blurs = await draw(card, shadows, ratio, cached: false);
          final images = await draw(card, shadows, ratio, cached: true);
          expect(images.length, blurs.length);
          var worst = 0;
          for (var i = 0; i < blurs.length; i++) {
            final d = (images[i] - blurs[i]).abs();
            if (d > worst) worst = d;
          }
          // Out of 255, at ten times the real strength.
          expect(worst, lessThanOrEqualTo(4), reason: '$brightness');
        }
      });
    }
  }

  test('real shadows match to the last level', () async {
    for (final brightness in Brightness.values) {
      final shadows = glassCardShadows(brightness);
      const card = Size(324, 260);
      final page = brightness == Brightness.dark
          ? const Color(0xff0b1020)
          : const Color(0xfff6f7fa);
      final blurs = await draw(card, shadows, 3, cached: false, page: page);
      final images = await draw(card, shadows, 3, cached: true, page: page);
      var worst = 0;
      for (var i = 0; i < blurs.length; i++) {
        final d = (images[i] - blurs[i]).abs();
        if (d > worst) worst = d;
      }
      expect(worst, lessThanOrEqualTo(1), reason: '$brightness');
    }
  });

  test('uneven corners are drawn as they are', () async {
    rasterCachingEnabled = true;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    // Must not throw, and falls back to the plain blur.
    paintBoxShadow(
      canvas,
      const Rect.fromLTWH(0, 0, 200, 120),
      const BorderRadius.vertical(top: Radius.circular(30)),
      const BoxShadow(color: Color(0x40000000), blurRadius: 12),
    );
    recorder.endRecording().dispose();
  });
}
