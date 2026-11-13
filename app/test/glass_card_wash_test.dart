import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/glass_surface.dart';

/// The sheen draws only its visible top part; it must look exactly as the
/// full-card gradient it replaced.
void main() {
  Future<Uint8List> capture(WidgetTester tester, Widget card) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.light),
        home: Center(
          child: RepaintBoundary(
            key: key,
            child: ColoredBox(
              color: const Color(0xff334455),
              child: Padding(padding: const EdgeInsets.all(4), child: card),
            ),
          ),
        ),
      ),
    );
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    return (await tester.runAsync(() async {
      final image = await boundary.toImage(pixelRatio: 2.75);
      final bytes = await image.toByteData();
      image.dispose();
      return bytes!.buffer.asUint8List();
    }))!;
  }

  for (final (width, height) in [(300.0, 140.0), (200.0, 52.0), (90, 30)]) {
    testWidgets('a $width×$height card matches the full gradient', (
      tester,
    ) async {
      const radius = BorderRadius.all(Radius.circular(24));
      final size = Size(width.toDouble(), height.toDouble());
      final before = await capture(
        tester,
        SizedBox.fromSize(
          size: size,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: radius,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: .12),
                  Colors.white.withValues(alpha: 0),
                ],
                stops: const [0, .4],
              ),
            ),
          ),
        ),
      );
      final after = await capture(
        tester,
        SizedBox.fromSize(
          size: size,
          child: const GlassCardWash(radius: radius, child: SizedBox.expand()),
        ),
      );
      expect(after.length, before.length);
      var worst = 0;
      for (var i = 0; i < before.length; i++) {
        final d = (after[i] - before[i]).abs();
        if (d > worst) worst = d;
      }
      expect(worst, lessThanOrEqualTo(1));
    });
  }
}
