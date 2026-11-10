import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/animated_amount.dart';
import 'package:simple_money/ui/components/private_amount.dart';

void main() {
  Widget amounts() => const MaterialApp(
    home: Scaffold(
      body: Column(
        children: [
          PrivateAmount(label: 'First', child: Text('₹111')),
          PrivateAmount(label: 'Second', child: Text('₹222')),
        ],
      ),
    ),
  );

  testWidgets('revealing one amount reveals every amount, until hidden', (
    tester,
  ) async {
    await tester.pumpWidget(amounts());
    expect(find.text('₹111'), findsNothing);
    expect(find.text('₹222'), findsNothing);
    await tester.tap(find.byTooltip('Show first'));
    await tester.pumpAndSettle();
    expect(find.text('₹111'), findsOneWidget);
    expect(find.text('₹222'), findsOneWidget);
    // Hiding one hides them all again.
    await tester.tap(find.byTooltip('Hide second'));
    await tester.pumpAndSettle();
    expect(find.text('₹111'), findsNothing);
    expect(find.text('₹222'), findsNothing);
  });

  testWidgets('a reveal stays across screens, and ends when the app leaves', (
    tester,
  ) async {
    await tester.pumpWidget(amounts());
    await tester.tap(find.byTooltip('Show first'));
    await tester.pumpAndSettle();
    // Another amount appearing later (a new screen) comes up revealed.
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              PrivateAmount(label: 'First', child: Text('₹111')),
              PrivateAmount(label: 'Second', child: Text('₹222')),
              PrivateAmount(label: 'Third', child: Text('₹333')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('₹333'), findsOneWidget);
    // Leaving the foreground hides everything.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('₹333'), findsNothing);
    expect(find.text('₹111'), findsNothing);
  });

  testWidgets('a reveal-only amount rolls when revealed, not when it changes', (
    tester,
  ) async {
    var value = 123;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return PrivateAmount(
                label: 'Balance',
                child: AnimatedAmount(
                  rollOnlyOnReveal: true,
                  value: value,
                  format: (v) => '$v',
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('Show balance'));
    await tester.pump();
    await tester.pump();
    // Revealed just now: the reels are turning.
    expect(tester.hasRunningAnimations, isTrue);
    await tester.pumpAndSettle();
    // A new value after that changes at once, with no motion.
    update(() => value = 456);
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse);
  });
}
