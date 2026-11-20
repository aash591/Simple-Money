import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/glass_blur.dart';

/// A sheet's frozen frost has to look just like the live blur it stands in
/// for, at a phone's pixel density too, not only at one pixel a point.
void main() {
  const logical = Size(120, 200);

  for (final ratio in [1.0, 3.0]) {
    testWidgets('the frozen copy matches the live blur at ${ratio}x', (
      tester,
    ) async {
      tester.view
        ..physicalSize = logical * ratio
        ..devicePixelRatio = ratio;
      addTearDown(tester.view.reset);
      // Hard stripes, so any difference in blur strength shows.
      final screen = (await tester.runAsync(() {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..scale(ratio);
        for (var y = 0.0; y < logical.height; y += 20) {
          canvas.drawRect(
            Rect.fromLTWH(0, y, logical.width, 10),
            Paint()..color = const Color(0xffffffff),
          );
          canvas.drawRect(
            Rect.fromLTWH(0, y + 10, logical.width, 10),
            Paint()..color = const Color(0xff000000),
          );
        }
        return recorder.endRecording().toImage(
          (logical.width * ratio).round(),
          (logical.height * ratio).round(),
        );
      }))!;
      addTearDown(screen.dispose);
      final copy = blurredCopyExact(screen, ratio, 6);
      addTearDown(copy.dispose);

      final boundary = GlobalKey();
      Future<Uint8List> shoot(Widget child) async {
        await tester.pumpWidget(RepaintBoundary(key: boundary, child: child));
        return (await tester.runAsync(() async {
          final render =
              boundary.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await render.toImage(pixelRatio: 1);
          final data = await image.toByteData();
          image.dispose();
          return data!.buffer.asUint8List();
        }))!;
      }

      final live = await shoot(
        Stack(
          textDirection: TextDirection.ltr,
          children: [
            Positioned.fill(
              child: RawImage(image: screen, fit: BoxFit.fill),
            ),
            Positioned.fill(
              child: BackdropFilter(
                filter: ui.ImageFilter.blur(sigmaX: 6, sigmaY: 6),
                child: const SizedBox.expand(),
              ),
            ),
          ],
        ),
      );
      final frozen = await shoot(RawImage(image: copy, fit: BoxFit.fill));

      // The stripes' contrast in the middle of the picture: a weaker blur
      // leaves more of it.
      int contrast(Uint8List px) {
        final w = logical.width.toInt();
        var lo = 255, hi = 0;
        for (var y = 60; y < 140; y++) {
          final v = px[(y * w + w ~/ 2) * 4];
          if (v < lo) lo = v;
          if (v > hi) hi = v;
        }
        return hi - lo;
      }

      expect((contrast(live) - contrast(frozen)).abs(), lessThan(12));
    });
  }
}
