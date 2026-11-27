import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/liquid_glass_nav_bar.dart';
import 'package:simple_money/ui/components/nav_icon_motion.dart';

void main() {
  for (final motion in NavIconMotion.values) {
    testWidgets('$motion paints at rest and plays when it gains focus', (
      tester,
    ) async {
      Widget icon({required bool active}) => MaterialApp(
        home: Center(
          child: NavIconMotionIcon(
            motion: motion,
            active: active,
            color: Colors.purple,
          ),
        ),
      );
      await tester.pumpWidget(icon(active: false));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(icon(active: true));
      // Mid-animation and settled both paint without trouble.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump(const Duration(milliseconds: 400));
      expect(tester.takeException(), isNull);
      expect(find.byType(NavIconMotionIcon), findsOneWidget);
    });
  }

  testWidgets('switching tabs in LiquidGlassNavBar activates the target icon', (
    tester,
  ) async {
    Widget buildBar(int selectedIndex) => MaterialApp(
      home: Scaffold(
        bottomNavigationBar: LiquidGlassNavBar(
          selectedIndex: selectedIndex,
          onDestinationSelected: (_) {},
          destinations: const [
            LiquidGlassDestination(
              icon: Icons.home_outlined,
              selectedIcon: Icons.home_rounded,
              label: 'Home',
              motion: NavIconMotion.home,
            ),
            LiquidGlassDestination(
              icon: Icons.receipt_long_outlined,
              selectedIcon: Icons.receipt_long_rounded,
              label: 'Transactions',
              motion: NavIconMotion.transactions,
            ),
            LiquidGlassDestination(
              icon: Icons.pie_chart_outline_rounded,
              selectedIcon: Icons.pie_chart_rounded,
              label: 'Budgets',
              motion: NavIconMotion.budgets,
            ),
            LiquidGlassDestination(
              icon: Icons.more_horiz_rounded,
              selectedIcon: Icons.more_horiz_rounded,
              label: 'More',
              motion: NavIconMotion.more,
            ),
          ],
        ),
      ),
    );

    await tester.pumpWidget(buildBar(0));
    await tester.pumpAndSettle();

    await tester.pumpWidget(buildBar(2));
    final budgetIcons = tester
        .widgetList<NavIconMotionIcon>(find.byType(NavIconMotionIcon))
        .where((w) => w.motion == NavIconMotion.budgets);
    expect(budgetIcons.every((w) => w.active), isTrue);

    await tester.pump(const Duration(milliseconds: 150));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('tapping a tab plays the icon motion through press release', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: StatefulBuilder(
          builder: (context, setState) => Scaffold(
            bottomNavigationBar: LiquidGlassNavBar(
              selectedIndex: selected,
              onDestinationSelected: (i) => setState(() => selected = i),
              destinations: const [
                LiquidGlassDestination(
                  icon: Icons.home_outlined,
                  selectedIcon: Icons.home_rounded,
                  label: 'Home',
                  motion: NavIconMotion.home,
                ),
                LiquidGlassDestination(
                  icon: Icons.receipt_long_outlined,
                  selectedIcon: Icons.receipt_long_rounded,
                  label: 'Transactions',
                  motion: NavIconMotion.transactions,
                ),
                LiquidGlassDestination(
                  icon: Icons.pie_chart_outline_rounded,
                  selectedIcon: Icons.pie_chart_rounded,
                  label: 'Budgets',
                  motion: NavIconMotion.budgets,
                ),
                LiquidGlassDestination(
                  icon: Icons.more_horiz_rounded,
                  selectedIcon: Icons.more_horiz_rounded,
                  label: 'More',
                  motion: NavIconMotion.more,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Budgets'));
    await tester.pump(const Duration(milliseconds: 120));
    expect(selected, 2);
    // Only the glyph's parts move: the icon keeps its size and place.
    expect(
      find.descendant(
        of: find.byType(NavIconMotionIcon),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );

    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
