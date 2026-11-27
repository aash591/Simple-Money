import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/feature_page.dart';
import 'package:simple_money/ui/components/page_motion.dart';

void main() {
  // The page underneath takes touches at once while the page above goes
  // back: nothing invisible left on screen swallows the first tap or swipe.
  for (final waitMs in [0, 120, 300, 2000]) {
    testWidgets('tap opens a page $waitMs ms after going back', (tester) async {
      final nav = GlobalKey<NavigatorState>();
      var opened = 0;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: nav,
          theme: ThemeData(
            pageTransitionsTheme: PageTransitionsTheme(
              builders: {
                for (final p in TargetPlatform.values)
                  p: const PageMotionTransitionsBuilder(),
              },
            ),
          ),
          home: FeaturePage(
            title: 'Home',
            child: Builder(
              builder: (context) => ListTile(
                title: const Text('Open'),
                onTap: () {
                  opened++;
                  Navigator.of(context).push(
                    FeatureRoute<void>(
                      const FeaturePage(title: 'Details', child: SizedBox()),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      nav.currentState!.pop();
      await tester.pump();
      await tester.pump(Duration(milliseconds: waitMs));
      await tester.tap(find.text('Open'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(opened, 2, reason: 'first tap after back was lost');
    });
  }
}
