import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/device_performance.dart';
import 'package:simple_money/ui/components/liquid_glass_nav_bar.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

/// On a low-end phone the tab bar is the same bar, with the same pill and
/// press droplet, only nothing behind it is filtered.
void main() {
  tearDown(() => DevicePerformance.lowEnd = false);

  Future<void> pump(WidgetTester tester) => tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.dark, style: AppStyle.aurora),
      home: Scaffold(
        extendBody: true,
        body: const SizedBox.expand(),
        bottomNavigationBar: LiquidGlassNavBar(
          selectedIndex: 0,
          onDestinationSelected: (_) {},
          destinations: [
            for (final label in ['Home', 'History', 'Budgets', 'More'])
              LiquidGlassDestination(
                icon: Icons.circle_outlined,
                selectedIcon: Icons.circle,
                label: label,
              ),
          ],
        ),
      ),
    ),
  );

  testWidgets('a low-end phone draws the bar without any filter', (
    tester,
  ) async {
    DevicePerformance.lowEnd = true;
    await pump(tester);
    expect(find.byType(BackdropFilter), findsNothing);
    final rims = find.byWidgetPredicate(
      (w) => w.runtimeType.toString() == '_LensRim',
    );
    expect(rims, findsOneWidget);

    // A press still raises the droplet, drawn rather than filtered.
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('Budgets')),
    );
    // The tap is claimed a moment after the touch, then the pill rises.
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump(const Duration(milliseconds: 120));
    addTearDown(gesture.removePointer);
    expect(rims, findsNWidgets(2));
    expect(find.byType(BackdropFilter), findsNothing);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(rims, findsOneWidget);
  });

  testWidgets('other phones keep the glass', (tester) async {
    await pump(tester);
    expect(find.byType(BackdropFilter), findsWidgets);
  });
}
