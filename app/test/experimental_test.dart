import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/notification_access_platform.dart';
import 'package:simple_money/ui/more/settings/experimental/experimental_screen.dart';
import 'package:simple_money/ui/more/settings/settings_screen.dart';

void main() {
  testWidgets('Settings opens Experimental, which holds notifications', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('EXPERIMENTAL'), findsOneWidget);
    await tester.tap(find.text('Experimental features'));
    await tester.pumpAndSettle();
    expect(find.byType(ExperimentalScreen), findsOneWidget);
    expect(find.textContaining('Early features'), findsWidgets);
    expect(find.text('NOTIFICATIONS'), findsOneWidget);
    expect(find.text('Transactions from notifications'), findsOneWidget);
    expect(tester.takeException(), isNull);
  }, skip: !NotificationAccessPlatform.available);

  // Run with --dart-define=PLAY_BUILD=true, as `build app:play` builds.
  testWidgets('the Play build has no Experimental section at all', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    await tester.pumpAndSettle();
    expect(find.text('EXPERIMENTAL'), findsNothing);
    expect(find.text('Experimental features'), findsNothing);
    expect(ExperimentalScreen.offered(), isFalse);
  }, skip: NotificationAccessPlatform.available);
}
