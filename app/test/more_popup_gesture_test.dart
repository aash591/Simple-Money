import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/more_popup_button.dart';
import 'package:simple_money/ui/components/frosted_modal_surface.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  testWidgets('Menu blurs the page colors behind its dark surface', (
    tester,
  ) async {
    final capture = GlobalKey();
    await tester.pumpWidget(
      RepaintBoundary(
        key: capture,
        child: MaterialApp(
          theme: appTheme(Brightness.dark),
          home: Scaffold(
            body: Stack(
              fit: StackFit.expand,
              children: [
                Row(
                  children: List.generate(
                    40,
                    (index) => Expanded(
                      child: ColoredBox(
                        color: index.isEven ? Colors.red : Colors.blue,
                        child: const SizedBox.expand(),
                      ),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.topRight,
                  child: MorePopupButton<int>(
                    items: const [
                      MorePopupItem(value: 1, label: 'Edit'),
                      MorePopupItem(value: 2, label: 'Settings'),
                    ],
                    onSelected: (_) {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byType(FrostedModalSurface));
    await tester.runAsync(() async {
      final boundary =
          capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final image = await boundary.toImage();
      final bytes = (await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      ))!;
      // Inside the panel, clear of the text and rim: both stripe colors must
      // contribute, proving the backdrop is sampled and softened.
      final x = (rect.left + 10).round();
      final y = rect.center.dy.round();
      final offset = (y * image.width + x) * 4;
      expect(bytes.getUint8(offset), greaterThan(15));
      expect(bytes.getUint8(offset + 2), greaterThan(15));
      image.dispose();
    });
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'Press and slide highlights nearest row and ticks once per change',
    (tester) async {
      final selected = <int>[];
      final haptics = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'HapticFeedback.vibrate') haptics.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                MorePopupButton<int>(
                  items: const [
                    MorePopupItem(value: 1, label: 'Edit'),
                    MorePopupItem(value: 2, label: 'Manage contacts'),
                    MorePopupItem(value: 3, label: 'Settings'),
                  ],
                  onSelected: selected.add,
                ),
              ],
            ),
          ),
        ),
      );

      Color background(String label) => tester
          .widget<ColoredBox>(
            find
                .ancestor(
                  of: find.text(label),
                  matching: find.byType(ColoredBox),
                )
                .first,
          )
          .color;

      final press = await tester.startGesture(
        tester.getCenter(find.byTooltip('More options')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsOneWidget);
      await press.moveTo(tester.getCenter(find.text('Edit')));
      await tester.pump();
      expect(background('Edit'), isNot(Colors.transparent));
      expect(background('Settings'), Colors.transparent);
      expect(haptics.map((call) => call.arguments), [
        'HapticFeedbackType.selectionClick',
      ]);
      await press.moveBy(const Offset(1, 2));
      await tester.pump();
      expect(haptics, hasLength(1));
      await press.moveTo(tester.getCenter(find.text('Settings')));
      await tester.pump();
      expect(background('Edit'), Colors.transparent);
      expect(background('Settings'), isNot(Colors.transparent));
      expect(haptics, hasLength(2));
      await press.up();
      await tester.pumpAndSettle();
      expect(selected, [3]);
      expect(find.text('Edit'), findsNothing);

      // A fresh gesture inside an already open menu can scrub between rows too.
      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      final scrub = await tester.startGesture(
        tester.getCenter(find.text('Edit')),
      );
      await scrub.moveTo(tester.getCenter(find.text('Manage contacts')));
      await scrub.up();
      await tester.pumpAndSettle();
      expect(selected, [3, 2]);

      await tester.tap(find.byTooltip('More options'));
      await tester.pumpAndSettle();
      final cancel = await tester.startGesture(
        tester.getCenter(find.text('Edit')),
      );
      await cancel.moveTo(const Offset(10, 400));
      await tester.pump();
      expect(background('Edit'), Colors.transparent);
      await cancel.up();
      await tester.pumpAndSettle();
      expect(selected, [3, 2]);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Edit'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
