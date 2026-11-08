import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/adaptive_sheet.dart';
import 'package:simple_money/ui/components/choice_list_sheet.dart';
import 'package:simple_money/ui/components/sheet_scroll_indicator.dart';
import 'package:simple_money/ui/transactions/transaction_widgets.dart';

void main() {
  testWidgets('Entry body opens at the bottom with a persistent scrollbar', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 400,
            child: SheetPage(
              startAtBottom: true,
              header: const SizedBox(height: 48),
              actions: const SizedBox(height: 52, child: Text('Continue')),
              body: Column(
                children: [
                  const Text('Summary'),
                  const SizedBox(height: 700),
                  TextButton(onPressed: () {}, child: const Text('Last key')),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Last key').hitTestable(), findsOneWidget);
    expect(find.text('Summary').hitTestable(), findsNothing);
    expect(
      tester.getBottomLeft(find.text('Last key')).dy,
      lessThan(tester.getTopLeft(find.text('Continue')).dy),
    );
    expect(find.byType(SheetScrollIndicator), findsOneWidget);
    // The summary remains reachable, and reading it doesn't snap back down.
    await tester.drag(find.byType(SingleChildScrollView), const Offset(0, 900));
    await tester.pumpAndSettle();
    expect(find.text('Summary').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Scrolled category stays in place while sliding to subcategories',
    (tester) async {
      var subcategory = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => SizedBox(
                height: 500,
                child: StepSlider(
                  stepKey: subcategory,
                  forward: true,
                  child: ChoicePickerPage<int>(
                    header: SheetHeader(
                      subcategory ? 'Subcategories' : 'Categories',
                    ),
                    fillHeight: true,
                    selected: null,
                    searchHint: subcategory
                        ? 'Search subcategories'
                        : 'Search categories',
                    items: [
                      for (var i = 0; i < (subcategory ? 2 : 30); i++)
                        ChoiceItem(
                          value: i,
                          icon: const Icon(Icons.category),
                          label: subcategory ? 'Subcategory $i' : 'Category $i',
                          chevron: true,
                        ),
                    ],
                    onSelected: (_) => setState(() => subcategory = true),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final list = find.byType(SingleChildScrollView);
      expect(find.byType(SheetScrollIndicator), findsOneWidget);
      await tester.drag(list, const Offset(0, -2000));
      await tester.pumpAndSettle();
      final row = find.text('Category 29');
      await tester.ensureVisible(row);
      await tester.pumpAndSettle();
      final scrollState = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final offset = scrollState.position.pixels;
      final y = tester.getTopLeft(row).dy;
      expect(offset, greaterThan(0));
      await tester.tap(row);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(scrollState.mounted, isTrue);
      expect(scrollState.position.pixels, offset);
      expect(tester.getTopLeft(row).dy, closeTo(y, 0.01));
      await tester.pumpAndSettle();
      expect(find.text('Category 29'), findsNothing);
      expect(find.text('Subcategory 0'), findsOneWidget);
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .pixels,
        0,
      );
    },
  );
}
