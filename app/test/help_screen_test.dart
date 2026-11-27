import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/more/help/about/about_screen.dart';
import 'package:simple_money/ui/more/help/help_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  Future<void> open(WidgetTester tester, {required String url}) =>
      tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: HelpScreen(communityUrl: url),
        ),
      );

  testWidgets('Help offers the community link when the build has one', (
    tester,
  ) async {
    await open(tester, url: 'https://t.me/+example');
    expect(find.text('Join community'), findsOneWidget);
    expect(find.text('FAQ'), findsOneWidget);
    expect(find.text('Report SMS'), findsNothing);
  });

  testWidgets('without a link there is no community row', (tester) async {
    await open(tester, url: '');
    expect(find.text('Join community'), findsNothing);
    expect(find.text('FAQ'), findsOneWidget);
  });

  testWidgets('About SimpleMoney is inside Help', (tester) async {
    await open(tester, url: '');
    expect(find.text('About SimpleMoney'), findsOneWidget);
    await tester.tap(find.text('About SimpleMoney'));
    await tester.pumpAndSettle();
    expect(find.byType(AboutScreen), findsOneWidget);
  });
}
