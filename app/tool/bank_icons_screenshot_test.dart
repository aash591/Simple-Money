// Run explicitly: flutter test tool/bank_icons_screenshot_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/select_icon_screen.dart';

void main() {
  testWidgets('Capture every selectable icon for visual QA', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const captureKey = Key('bank-icon-capture');

    Future<void> capture(String name) async {
      // Image.asset decodes asynchronously and an in-flight decode schedules
      // no frames, so pumpAndSettle alone can hand back a frame where the
      // icons haven't painted yet — which silently produced empty captures.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 220));
      });
      await tester.pumpAndSettle();
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/qa/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    Future<void> openTab(String label) async {
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
    }

    Future<void> scrollBy(double dy) async {
      await tester.drag(find.byType(Scrollable).last, Offset(0, dy));
      await tester.pumpAndSettle();
    }

    /// Walks all three tabs of the picker in one theme.
    Future<void> captureAll(String suffix) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 250));
      });
      for (var page = 1; page <= 3; page++) {
        await capture('category-icons-$page$suffix');
        await scrollBy(-620);
      }

      await openTab('Services');
      await capture('service-icons-1$suffix');
      await scrollBy(-420);
      await capture('service-icons-2$suffix');

      await openTab('Banks');
      for (var page = 1; page <= 12; page++) {
        await capture('bank-icons-$page$suffix');
        await scrollBy(-420);
      }
    }

    await tester.pumpWidget(
      const RepaintBoundary(
        key: captureKey,
        child: MaterialApp(home: SelectIconScreen()),
      ),
    );
    await captureAll('');

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: MaterialApp(
          theme: ThemeData.dark(),
          home: const SelectIconScreen(),
        ),
      ),
    );
    await captureAll('-dark');
  });
}
