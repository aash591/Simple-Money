import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/ui/components/segmented_pill.dart';
import 'package:simple_money/ui/more/categories/categories_screen.dart';

void main() {
  testWidgets('Category search restores the selected tab on cancel and back', (
    tester,
  ) async {
    final db = AppDatabase(NativeDatabase.memory());
    final store = CategoryStore(CategoryRepository(db));
    await tester.runAsync(store.load);
    await tester.pumpWidget(MaterialApp(home: CategoriesScreen(store: store)));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    await tester.tap(find.text('Income'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Search categories'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).focusNode!.hasFocus,
      isTrue,
    );
    expect(find.byType(SegmentedPillTabBar), findsNothing);
    expect(find.byTooltip('Add category'), findsNothing);
    await tester.enterText(find.byType(TextField), 'salary');
    await tester.pumpAndSettle();
    expect(find.text('Salary'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'no matching category');
    await tester.pumpAndSettle();
    expect(find.text('No categories found'), findsOneWidget);
    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    expect(find.text('Salary'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(
      tester
          .widget<SegmentedPillTabBar>(find.byType(SegmentedPillTabBar))
          .controller!
          .index,
      1,
    );
    expect(find.byTooltip('Add category'), findsOneWidget);
    await tester.tap(find.byTooltip('Search categories'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(find.text('Categories'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
    await tester.runAsync(db.close);
  });
}
