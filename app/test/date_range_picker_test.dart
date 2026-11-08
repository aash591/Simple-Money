import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/date_range_picker_sheet.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets(
      'Range sheet picks, restarts and applies a span (${dark ? 'dark' : 'light'})',
      (tester) async {
        tester.view.physicalSize = const Size(390, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        DateTimeRange? result;
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(dark ? Brightness.dark : Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => TextButton(
                  onPressed: () async {
                    result = await showDateRangePickerSheet(
                      context,
                      initialRange: DateTimeRange(
                        start: DateTime(2026, 3, 4),
                        end: DateTime(2026, 3, 9),
                      ),
                    );
                  },
                  child: const Text('Open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        expect(find.text('4 Mar 2026'), findsOneWidget);
        expect(find.text('9 Mar 2026'), findsOneWidget);
        expect(find.text('6 days'), findsOneWidget);

        // Moving the start past the end drops the end.
        await tester.tap(find.text('12'));
        await tester.pumpAndSettle();
        expect(find.text('12 Mar 2026'), findsOneWidget);
        expect(find.text('9 Mar 2026'), findsNothing);

        // A day before the start restarts the range; the next one closes it.
        await tester.tap(find.text('10'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('20'));
        await tester.pumpAndSettle();
        expect(find.text('11 days'), findsOneWidget);

        await tester.tap(find.text('Apply'));
        await tester.pumpAndSettle();
        expect(
          result,
          DateTimeRange(
            start: DateTime(2026, 3, 10),
            end: DateTime(2026, 3, 20),
          ),
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('Range sheet presets and Clear', (tester) async {
    tester.view.physicalSize = const Size(390, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    DateTimeRange? result;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async =>
                  result = await showDateRangePickerSheet(context),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('Tap a day to set the start'), findsOneWidget);

    await tester.tap(find.text('Last 7 days'));
    await tester.pumpAndSettle();
    expect(find.text('7 days'), findsOneWidget);
    await tester.tap(find.text('Clear'));
    await tester.pumpAndSettle();
    expect(find.text('Tap a day to set the start'), findsOneWidget);

    await tester.tap(find.text('Last 7 days'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();
    final today = DateUtils.dateOnly(DateTime.now());
    expect(result?.end, today);
    expect(result?.start, DateTime(today.year, today.month, today.day - 6));
  });
}
