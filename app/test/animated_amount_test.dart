import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/animated_amount.dart';
import 'package:simple_money/ui/components/private_amount.dart';

Widget host(int value, {bool reduced = false, bool private = false}) {
  Widget amount = AnimatedAmount(value: value, format: (n) => 'INR $n');
  if (private) amount = PrivateAmount(label: 'Savings', child: amount);
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reduced),
      child: Scaffold(body: amount),
    ),
  );
}

void main() {
  String displayed(WidgetTester tester) => tester
      .widgetList<Text>(
        find.descendant(
          of: find.byType(AnimatedAmount),
          matching: find.byType(Text),
        ),
      )
      .map((text) => text.data ?? '')
      .join();

  testWidgets('Digits roll vertically while the currency stays still', (
    tester,
  ) async {
    await tester.pumpWidget(host(1500));
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('INR 1500'), findsOneWidget);
    semantics.dispose();
    final currencyPosition = tester.getTopLeft(find.text('I'));
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.getTopLeft(find.text('I')), currencyPosition);
    expect(
      tester
          .widgetList<Positioned>(find.byType(Positioned))
          .any((position) => (position.top ?? 0) < 0),
      isTrue,
    );
    await tester.pumpAndSettle();
    expect(displayed(tester), 'INR 1500');
    await tester.pumpWidget(host(-725));
    await tester.pumpAndSettle();
    expect(displayed(tester), 'INR -725');
  });

  testWidgets(
    'Rapid updates settle exactly and unchanged values do not roll again',
    (tester) async {
      await tester.pumpWidget(host(999));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(host(1001));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(host(42));
      await tester.pumpAndSettle();
      expect(displayed(tester), 'INR 42');
      await tester.pumpWidget(host(42));
      await tester.pump(const Duration(milliseconds: 100));
      expect(displayed(tester), 'INR 42');
    },
  );

  testWidgets('Reduced motion shows the final value immediately', (
    tester,
  ) async {
    await tester.pumpWidget(host(1500, reduced: true));
    expect(find.text('INR 1500'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AnimatedAmount),
        matching: find.byType(AnimatedBuilder),
      ),
      findsNothing,
    );
  });

  testWidgets('Hidden balances do not build or announce their counter', (
    tester,
  ) async {
    await tester.pumpWidget(host(1500, private: true));
    expect(find.byType(AnimatedAmount), findsNothing);
    await tester.tap(find.byTooltip('Show savings'));
    await tester.pumpAndSettle();
    expect(displayed(tester), 'INR 1500');
    await tester.tap(find.byTooltip('Hide savings'));
    await tester.pumpAndSettle();
    expect(find.byType(AnimatedAmount), findsNothing);
  });
}
