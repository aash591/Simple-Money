import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/device_performance.dart';
import 'package:simple_money/ui/components/frosted_modal_surface.dart';
import 'package:simple_money/ui/components/glass_blur.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

/// On a low-end phone an Aurora sheet doesn't blur, and isn't a flat accent
/// tint either: like a Home card, it shows the page's own backdrop under the
/// card glass, lined up with the screen.
void main() {
  const screen = Size(360, 640);
  tearDown(() => DevicePerformance.lowEnd = false);

  testWidgets('shows the page backdrop, not the accent', (tester) async {
    tester.view
      ..physicalSize = screen
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    DevicePerformance.lowEnd = true;
    // A backdrop red at the top half and blue at the bottom, so a copy that
    // isn't lined up with the screen would show the wrong colour.
    final backdrop = (await tester.runAsync(() {
      final recorder = ui.PictureRecorder();
      Canvas(recorder)
        ..drawRect(
          const Rect.fromLTWH(0, 0, 360, 320),
          Paint()..color = const Color(0xffe03030),
        )
        ..drawRect(
          const Rect.fromLTWH(0, 320, 360, 320),
          Paint()..color = const Color(0xff3050e0),
        );
      return recorder.endRecording().toImage(360, 640);
    }))!;
    ShownBackdrop.show(backdrop, screen);
    final boundary = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          theme: appTheme(Brightness.dark, style: AppStyle.aurora),
          builder: (context, child) => ScreenAnchor(child: child!),
          home: const Scaffold(
            backgroundColor: Colors.black,
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                height: 400,
                child: FrostedModalSurface(
                  borderRadius: BorderRadius.all(Radius.circular(30)),
                  shadows: [],
                  child: SizedBox.expand(),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ShownBackdropFill), findsOneWidget);

    final bytes = (await tester.runAsync(() async {
      final render =
          boundary.currentContext!.findRenderObject()! as RenderRepaintBoundary;
      final image = await render.toImage();
      final data = await image.toByteData();
      image.dispose();
      return data!.buffer.asUint8List();
    }))!;
    int red(int x, int y) => bytes[(y * 360 + x) * 4];
    int blue(int x, int y) => bytes[(y * 360 + x) * 4 + 2];
    // The sheet starts at 240: red above the screen's middle, blue below.
    expect(red(180, 280), greaterThan(180));
    expect(blue(180, 280), lessThan(110));
    expect(blue(180, 500), greaterThan(180));
    expect(red(180, 500), lessThan(110));
  });

  testWidgets('other styles keep their tint', (tester) async {
    DevicePerformance.lowEnd = true;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light, style: AppStyle.glassy),
        home: const FrostedModalSurface(
          borderRadius: BorderRadius.zero,
          child: SizedBox.expand(),
        ),
      ),
    );
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.byType(ShownBackdropFill), findsNothing);
  });
}
