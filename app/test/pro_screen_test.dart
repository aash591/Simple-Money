import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/state/pro_controller.dart';
import 'package:simple_money/ui/more/pro/pro_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  final pro = ProController.instance;

  Future<void> open(WidgetTester tester) async {
    // Tall enough to build every perk and plan without scrolling.
    tester.view.physicalSize = const Size(400, 1500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: appTheme(Brightness.light), home: const ProScreen()),
    );
    await tester.pump();
  }

  tearDown(() {
    pro.subscribed = false;
    pro.ownsLifetime = false;
  });

  testWidgets('a supporter sees what they have, and how to manage it', (
    tester,
  ) async {
    pro.subscribed = true;
    await open(tester);
    expect(find.text('You’re a supporter'), findsOneWidget);
    expect(find.text('AI assistant'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_rounded), findsNWidgets(4));
    expect(find.text('Manage subscription'), findsOneWidget);
    expect(find.text('Restore purchases'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('while the AI is free, the offer says so', (tester) async {
    await open(tester);
    expect(find.text('Free for now'), findsOneWidget);
  });

  testWidgets('once the AI needs Pro, the note is gone', (tester) async {
    ProController.aiNeedsPro = true;
    addTearDown(() => ProController.aiNeedsPro = false);
    await open(tester);
    expect(find.text('Free for now'), findsNothing);
  });

  testWidgets('a lifetime supporter has nothing to manage', (tester) async {
    pro.ownsLifetime = true;
    await open(tester);
    expect(find.text('You’re a lifetime supporter'), findsOneWidget);
    expect(find.text('Manage subscription'), findsNothing);
  });

  testWidgets('the offer leads with the AI assistant, not ads', (tester) async {
    await open(tester);
    expect(find.text('SimpleMoney'), findsOneWidget);
    expect(find.text('PRO'), findsOneWidget);
    expect(find.textContaining('skip the ads'), findsNothing);
    expect(find.text('AI assistant'), findsOneWidget);
    // Free reads as complete; Pro as the nicer one.
    expect(find.text('Free is complete. Pro is nicer.'), findsOneWidget);
    expect(
      find.text('Track spending, accounts, loans and debts'),
      findsOneWidget,
    );
    expect(find.text('Unlimited'), findsOneWidget);
    expect(
      find.text('Google Play isn’t available on this device.'),
      findsOneWidget,
    );
    expect(find.text('Continue'), findsNothing);
    expect(find.text('Restore purchases'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a small phone gets a shorter hero, with nothing cut off', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(theme: appTheme(Brightness.dark), home: const ProScreen()),
    );
    await tester.pump();
    expect(find.text('SimpleMoney'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
