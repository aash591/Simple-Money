import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/state/review_prompt.dart';
import 'package:simple_money/ui/components/review_prompt_alert.dart';
import 'package:simple_money/ui/more/settings/help/report_issue_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  final review = ReviewPrompt.instance;
  var today = DateTime(2026, 1, 1, 10);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    review.now = () => today;
    // A week in, on the fourth day used, with ten transactions added.
    for (final day in [0, 2, 5, 8]) {
      today = DateTime(2026, 1, 1 + day, 10);
      await review.restore();
      for (var i = 0; i < 3; i++) {
        await review.noteSave();
      }
    }
  });

  tearDown(() => review.now = DateTime.now);

  Future<void> open(WidgetTester tester, {required int savesBefore}) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  maybeAskForReview(context, savesBefore: savesBefore),
              child: const Text('saved'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('saved'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
  }

  testWidgets('after a save it shows the star rating sheet', (tester) async {
    await open(tester, savesBefore: review.saves - 1);
    expect(find.text('Rate SimpleMoney'), findsOneWidget);
    expect(find.bySemanticsLabel('5 stars'), findsOneWidget);
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(find.text('Rate SimpleMoney'), findsNothing);
    expect(review.due, isFalse, reason: 'put off');
  });

  testWidgets('a sheet closed without saving never asks', (tester) async {
    await open(tester, savesBefore: review.saves);
    expect(find.text('Rate SimpleMoney'), findsNothing);
  });

  testWidgets('a low rating opens feedback and ends the asking', (
    tester,
  ) async {
    await open(tester, savesBefore: review.saves - 1);
    await tester.tap(find.bySemanticsLabel('2 stars'));
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    expect(find.byType(ReportIssueScreen), findsOneWidget);
    today = today.add(const Duration(days: 400));
    expect(review.due, isFalse);
  });
}
