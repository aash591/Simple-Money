import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/repositories/home_repository.dart';
import 'package:simple_money/domain/currency_scope.dart';
import 'package:simple_money/ui/home/cards/overview_card.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

HomeSummary summary(int income, int spent) => HomeSummary(
  income: income,
  spent: spent,
  previousSpent: 0,
  dailyIncome: const [],
  dailyExpenses: const [],
  categories: const [],
  recent: const [],
);

Future<void> show(WidgetTester tester, HomeSummary data) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: appTheme(Brightness.light),
      home: Scaffold(
        body: SingleChildScrollView(
          child: OverviewCard(
            data: data,
            budget: null,
            currency: const SingleCurrency('INR', 2),
            onOpenTransactions: () {},
            onOpenBudgets: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('savings show the share of income kept', (tester) async {
    await show(tester, summary(300000, 120000));
    expect(find.text('Net savings'), findsOneWidget);
    expect(find.text("Spent 40% of this month's income"), findsOneWidget);
    expect(find.text('Money in'), findsOneWidget);
    expect(find.text('Money out'), findsOneWidget);
    expect(find.text('Nothing recorded yet.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the bar draws both what went out and what is left', (
    tester,
  ) async {
    await show(tester, summary(500, 100));
    Finder segment(Color color) => find.byWidgetPredicate(
      (w) =>
          w is DecoratedBox &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).color == color,
    );
    final out = tester.getSize(segment(coral));
    final left = tester.getSize(segment(green));
    expect(out.height, 6);
    expect(left.height, 6);
    // A fifth went out, so the red part is a quarter of the green.
    expect(out.width / left.width, closeTo(.25, .02));
  });

  testWidgets('spending past income says so, calmly', (tester) async {
    await show(tester, summary(100000, 150000));
    expect(find.text("Spent 150% of this month's income"), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('spending with no income recorded is named as that', (
    tester,
  ) async {
    await show(tester, summary(0, 50000));
    expect(find.text('No income recorded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an empty month shows a preview instead of zeros', (
    tester,
  ) async {
    await show(tester, summary(0, 0));
    expect(find.text('Net savings'), findsOneWidget);
    expect(find.text('Nothing recorded yet.'), findsOneWidget);
    expect(find.textContaining('of this month'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
