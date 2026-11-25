import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
      await tester.pump(const Duration(milliseconds: 600));
      expect(tester.takeException(), isNull);
      expect(find.byType(NavIconMotionIcon), findsOneWidget);
    });
  }
}
