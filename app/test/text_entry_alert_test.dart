import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/text_entry_alert.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  Future<void> open(WidgetTester tester, void Function(String?) done) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => done(
                await showTextEntryAlert(
                  context,
                  title: 'This PDF is locked',
                  message: 'Enter its password to read it.',
                  subject: 'hdfc_june.pdf',
                  hintText: 'Password',
                  confirmLabel: 'Open',
                  maxLength: 12,
                  sensitive: true,
                ),
              ),
              child: const Text('Go'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
  }

  testWidgets('names the file, and Open waits for a password', (tester) async {
    String? result = 'untouched';
    await open(tester, (v) => result = v);
    expect(find.text('This PDF is locked'), findsOneWidget);
    expect(find.text('hdfc_june.pdf'), findsOneWidget);

    // Nothing typed: Open does nothing.
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('This PDF is locked'), findsOneWidget);

    await tester.enterText(find.byType(TextField), ' abc123 ');
    await tester.pump();
    expect(find.text('8/12'), findsOneWidget);
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(result, 'abc123');
  });

  testWidgets('clear empties the field; Cancel gives null', (tester) async {
    String? result = 'untouched';
    await open(tester, (v) => result = v);
    await tester.enterText(find.byType(TextField), 'abc');
    await tester.pump();
    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(find.text('3/12'), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
