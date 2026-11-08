import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/date_picker_sheet.dart';
import 'package:simple_money/ui/components/month_picker_popup.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'Calendar dropdown selects year/month and dismisses (${dark ? 'dark' : 'light'})',
      (tester) async {
        tester.view.physicalSize = const Size(390, 700);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        if (const bool.fromEnvironment('CAPTURE_CALENDAR')) {
          debugDisableShadows = false;
          addTearDown(() => debugDisableShadows = true);
          await tester.runAsync(() async {
            for (final family in ['Roboto', 'Ahem']) {
              await (FontLoader(family)..addFont(
                    File('C:/Windows/Fonts/segoeui.ttf')
                        .readAsBytes()
                        .then((bytes) => ByteData.sublistView(bytes)),
                  ))
                  .load();
            }
            await (FontLoader('MaterialIcons')
                  ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf')))
                .load();
          });
        }
        final anchor = GlobalKey();
        final capture = GlobalKey();
        DateTime? result;
        await tester.pumpWidget(
          RepaintBoundary(
            key: capture,
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: appTheme(dark ? Brightness.dark : Brightness.light),
              home: Scaffold(
                body: Builder(
                  builder: (context) => Padding(
                    padding: const EdgeInsets.fromLTRB(24, 90, 24, 0),
                    child: TextButton(
                      key: anchor,
                      onPressed: () async {
                        result = await showMonthPickerPopup(
                          context,
                          anchorKey: anchor,
                          initialMonth: DateTime(2026, 3),
                        );
                      },
                      child: const Text('March 2026'),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        Future<void> captureImage(String name) async {
          if (!const bool.fromEnvironment('CAPTURE_CALENDAR')) return;
          await tester.runAsync(() async {
            final boundary =
                capture.currentContext!.findRenderObject()
                    as RenderRepaintBoundary;
            final image = await boundary.toImage(pixelRatio: 2);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            final file = File('build/qa/$name.png');
            await file.parent.create(recursive: true);
            await file.writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }

        await tester.tap(find.text('March 2026'));
        await tester.pumpAndSettle();
        final popup = find.byKey(const Key('month-picker-popup'));
        expect(
          tester.getTopLeft(popup).dy,
          greaterThan(tester.getBottomLeft(find.byKey(anchor)).dy),
        );
        expect(find.text('Jan'), findsOneWidget);
        expect(find.text('Dec'), findsOneWidget);
        final monthGridSize = tester.getSize(
          find.byKey(const Key('month-grid')),
        );
        await captureImage('calendar-months-${dark ? 'dark' : 'light'}');
        final monthPopupRect = tester.getRect(popup);
        await tester.tap(find.text('2026'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        expect(tester.getRect(popup), monthPopupRect);
        await tester.pumpAndSettle();
        expect(tester.getRect(popup), monthPopupRect);
        expect(find.text('2027'), findsOneWidget);
        await captureImage('calendar-years-${dark ? 'dark' : 'light'}');
        final pager = find.byKey(const Key('year-grid-pager'));
        final previousArrow = find.byTooltip('Previous years');
        final nextArrow = find.byTooltip('Next years');
        expect(previousArrow, findsNothing);
        expect(nextArrow, findsNothing);
        expect(tester.getSize(pager), monthGridSize);
        expect(find.text('2017 - 2028'), findsNothing);
        // A month picker has no Today shortcut; only day pickers do.
        expect(find.text('Today'), findsNothing);

        await tester.drag(pager, const Offset(-220, 0));
        await tester.pumpAndSettle();
        expect(find.text('2029'), findsOneWidget);
        await tester.drag(pager, const Offset(220, 0));
        await tester.pumpAndSettle();
        expect(find.text('2017'), findsOneWidget);

        await tester.tap(find.text('2027'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Feb'));
        await tester.pumpAndSettle();
        expect(result, DateTime(2027, 2));
        expect(popup, findsNothing);
        await tester.tap(find.text('March 2026'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('Next year'), findsNothing);
        expect(find.byTooltip('Previous year'), findsNothing);
        await tester.tapAt(const Offset(370, 620));
        await tester.pumpAndSettle();
        expect(result, isNull);
        expect(popup, findsNothing);
        tester.view.physicalSize = const Size(320, 480);
        tester.platformDispatcher.textScaleFactorTestValue = 1.6;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        await tester.pumpAndSettle();
        await tester.tap(find.text('March 2026'));
        await tester.pumpAndSettle();
        expect(tester.getRect(popup).right, lessThanOrEqualTo(308));
        expect(tester.getRect(popup).bottom, lessThanOrEqualTo(468));
        expect(tester.takeException(), isNull);
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        debugDisableShadows = true;
      },
    );
  }

  testWidgets(
    'Shared day calendar handles year, month and leap-day selection',
    (tester) async {
      DateTime? result;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CalendarPicker(
              initialDate: DateTime(2026, 3, 16),
              onChanged: (date) => result = date,
            ),
          ),
        ),
      );
      await tester.tap(find.text('2026'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('2024'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Feb'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('29'));
      await tester.pumpAndSettle();
      expect(result, DateTime(2024, 2, 29));
      final pager = find.byKey(const Key('day-grid-pager'));
      await tester.drag(pager, const Offset(-600, 0));
      await tester.pumpAndSettle();
      expect(find.text('March'), findsOneWidget);
      await tester.drag(pager, const Offset(600, 0));
      await tester.pumpAndSettle();
      expect(find.text('February'), findsOneWidget);
      expect(find.byTooltip('Next month'), findsNothing);
      expect(find.byTooltip('Previous month'), findsNothing);
      await tester.drag(pager, const Offset(-600, 0));
      await tester.pumpAndSettle();
      await tester.tap(find.text('31'));
      expect(result, DateTime(2024, 3, 31));
      await tester.tap(find.text('2024'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Today'));
      expect(result, DateUtils.dateOnly(DateTime.now()));
      expect(tester.takeException(), isNull);
    },
  );
}
