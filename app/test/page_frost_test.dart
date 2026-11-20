import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/glass_blur.dart';
import 'package:simple_money/state/appearance_controller.dart';
import 'package:simple_money/ui/components/common.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

/// Glass over a picture draws a ready-frosted copy of it instead of blurring
/// the screen. The copy has to show exactly what the live blur did, and stay
/// pinned to the picture wherever the glass moves.
void main() {
  const screen = Size(360, 640);

  // A picture with hard edges and strong colours, so a copy that is blurred
  // differently or sits in the wrong place can't pass for the real thing.
  Future<ui.Image> picture() {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    const colors = [
      Color(0xffd83a3a),
      Color(0xff2f6fe0),
      Color(0xfff2c230),
      Color(0xff1f9d6b),
      Color(0xff101018),
      Color(0xfff4f4f8),
    ];
    var i = 0;
    for (var y = 0.0; y < screen.height; y += 80) {
      for (var x = 0.0; x < screen.width; x += 90) {
        canvas.drawRect(
          Rect.fromLTWH(x, y, 90, 80),
          Paint()..color = colors[(i++ * 5 + (y ~/ 80)) % colors.length],
        );
      }
    }
    return recorder.endRecording().toImage(
      screen.width.toInt(),
      screen.height.toInt(),
    );
  }

  Widget page(ui.Image backdrop, Rect glass, {required bool copy}) {
    Widget frosted(BuildContext context) => Stack(
      children: [
        Positioned.fill(
          child: copy
              ? CompositedTransformTarget(
                  link: PageFrostHost.maybeOf(context)!.link,
                  child: RawImage(image: backdrop, fit: BoxFit.fill),
                )
              : RawImage(image: backdrop, fit: BoxFit.fill),
        ),
        Positioned.fromRect(
          rect: glass,
          // Layers of its own, as a Home card has while it fades in.
          child: RepaintBoundary(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(24),
              child: const Frosted(
                sigma: FrostImages.cardSigma,
                tileMode: TileMode.mirror,
                onPage: true,
                child: SizedBox.expand(),
              ),
            ),
          ),
        ),
      ],
    );
    return Directionality(
      textDirection: TextDirection.ltr,
      child: copy
          ? PageFrostHost(child: Builder(builder: frosted))
          : Builder(builder: frosted),
    );
  }

  testWidgets('the copy matches the live blur wherever the glass is', (
    tester,
  ) async {
    tester.view
      ..physicalSize = screen
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final backdrop = (await tester.runAsync(picture))!;
    addTearDown(backdrop.dispose);
    final sharp = (await tester.runAsync(() => backdrop.toByteData()))!.buffer
        .asUint8List();
    final boundary = GlobalKey();

    Future<Uint8List> shoot(Rect glass, {required bool copy}) async {
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: page(backdrop, glass, copy: copy),
        ),
      );
      if (copy) {
        final frost = PageFrostHost.maybeOf(
          tester.element(find.byType(Frosted)),
        )!;
        if (frost.images.value == null) {
          frost.show(FrostImages.of(backdrop, screen, 1));
          await tester.pump();
        }
        await tester.pump();
        expect(find.byType(CompositedTransformFollower), findsOneWidget);
        expect(
          tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
          isFalse,
        );
      } else {
        expect(find.byType(CompositedTransformFollower), findsNothing);
      }
      final bytes = await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final data = await image.toByteData();
        image.dispose();
        return data!.buffer.asUint8List();
      });
      return bytes!;
    }

    for (final glass in const [
      Rect.fromLTWH(30, 100, 300, 200),
      // Against the screen's edges, where the blur mirrors the picture.
      Rect.fromLTWH(0, 0, 200, 150),
      Rect.fromLTWH(140, 470, 220, 170),
    ]) {
      final live = await shoot(glass, copy: false);
      final copied = await shoot(glass, copy: true);
      var worst = 0, outside = 0;
      final w = screen.width.toInt();
      for (var i = 0; i < live.length; i++) {
        final d = (live[i] - copied[i]).abs();
        final at = Offset((i ~/ 4 % w) + .5, (i ~/ 4 ~/ w) + .5);
        // The clip's own edge smoothing aside.
        if (glass.deflate(2).contains(at) && !glass.deflate(12).contains(at)) {
          continue;
        }
        if (glass.contains(at)) {
          if (d > worst) worst = d;
        } else if (d > outside) {
          outside = d;
        }
      }
      expect(outside, 0, reason: '$glass');
      // Out of 255, over a picture swinging the full range.
      expect(worst, lessThanOrEqualTo(6), reason: '$glass');
      // And both really are frosted: two sharp pictures would match too.
      for (final shot in [live, copied]) {
        var frosted = 0, inside = 0;
        for (var i = 0; i < shot.length; i += 4) {
          final at = Offset((i ~/ 4 % w) + .5, (i ~/ 4 ~/ w) + .5);
          if (!glass.deflate(12).contains(at)) continue;
          inside++;
          if ((shot[i] - sharp[i]).abs() > 8 ||
              (shot[i + 1] - sharp[i + 1]).abs() > 8 ||
              (shot[i + 2] - sharp[i + 2]).abs() > 8) {
            frosted++;
          }
        }
        expect(frosted / inside, greaterThan(.6), reason: '$glass');
      }
    }
  });

  testWidgets('glass in a menu over the page leaves the blur to the menu', (
    tester,
  ) async {
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: PageFrostHost(
          child: PageFrostHost.none(
            child: const Frosted(
              sigma: FrostImages.cardSigma,
              onPage: true,
              child: SizedBox(),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(CompositedTransformFollower), findsNothing);
    expect(
      tester.widget<BackdropFilter>(find.byType(BackdropFilter)).enabled,
      isFalse,
    );
  });

  testWidgets('a card keeps its own glass over the frosted picture', (
    tester,
  ) async {
    tester.view
      ..physicalSize = screen
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A dark picture: a light card that lost its fill would show it.
    final backdrop = (await tester.runAsync(() {
      final recorder = ui.PictureRecorder();
      Canvas(recorder).drawColor(const Color(0xff101018), BlendMode.src);
      return recorder.endRecording().toImage(
        screen.width.toInt(),
        screen.height.toInt(),
      );
    }))!;
    addTearDown(backdrop.dispose);
    final boundary = GlobalKey();

    Future<int> centre(Brightness brightness) async {
      await tester.pumpWidget(
        AppearanceScope(
          controller: AppearanceController()..wallpaperPath = 'picture.jpg',
          child: MaterialApp(
            theme: appTheme(brightness, style: AppStyle.aurora),
            home: RepaintBoundary(
              key: boundary,
              child: PageFrostHost(
                child: Builder(
                  builder: (context) => Stack(
                    children: [
                      Positioned.fill(
                        child: CompositedTransformTarget(
                          link: PageFrostHost.maybeOf(context)!.link,
                          child: RawImage(image: backdrop, fit: BoxFit.fill),
                        ),
                      ),
                      const Positioned(
                        left: 30,
                        top: 100,
                        width: 300,
                        height: 200,
                        child: MoneyCard(child: SizedBox.expand()),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      PageFrostHost.maybeOf(tester.element(find.byType(Frosted)))!
          .show(FrostImages.of(backdrop, screen, 1));
      await tester.pump();
      await tester.pump();
      expect(find.byType(CompositedTransformFollower), findsOneWidget);
      final bytes = (await tester.runAsync(() async {
        final render =
            boundary.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await render.toImage();
        final data = await image.toByteData();
        image.dispose();
        return data!.buffer.asUint8List();
      }))!;
      // The red channel at the card's middle.
      return bytes[(200 * screen.width.toInt() + 180) * 4];
    }

    // Light Aurora cards are near-white glass, whatever is behind them.
    expect(await centre(Brightness.light), greaterThan(215));
    // Dark ones are a faint veil: lighter than the picture, still dark.
    final dark = await centre(Brightness.dark);
    expect(dark, greaterThan(0x10 + 6));
    expect(dark, lessThan(60));
  });
}
