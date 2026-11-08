import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/budget_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/domain/budget.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/state/appearance_controller.dart';
import 'package:simple_money/state/budget_store.dart';
import 'package:simple_money/state/category_store.dart';
import 'package:simple_money/state/pro_controller.dart';
import 'package:simple_money/ui/budgets/set_budget_screen.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/ui/components/number_keypad.dart';
import 'package:simple_money/ui/more/settings/customization_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  final pro = ProController.instance;
  setUp(() => ProController.enforceLimits = true);
  tearDown(() {
    pro.subscribed = false;
    ProController.enforceLimits = true;
  });

  group('Budgets without Pro', () {
    late AppDatabase db;
    late BudgetStore budgets;
    late CategoryStore categories;
    setUp(() async {
      db = AppDatabase(NativeDatabase.memory());
      budgets = BudgetStore(BudgetRepository(db));
      categories = CategoryStore(CategoryRepository(db));
      await categories.load();
    });
    tearDown(() => db.close());

    Future<void> addOne(WidgetTester tester, int existing) async {
      tester.view.physicalSize = const Size(430, 932);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final expense = categories.categories
          .where((c) => c.type == CategoryType.expense && c.parentId == null)
          .first;
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          home: SetBudgetScreen(
            budgetStore: budgets,
            categoryStore: categories,
            month: DateTime(2026, 11),
            currency: 'INR',
            digits: 2,
            budgets: BudgetMonth(
              budgets: [
                for (var i = 0; i < existing; i++)
                  BudgetLine(
                    id: i + 100,
                    categoryIds: [-i],
                    limit: 1,
                    spent: 0,
                  ),
              ],
            ),
            initialCategoryIds: {expense.id},
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final digit in '500'.split('')) {
        await tester.tap(
          find.descendant(
            of: find.byType(NumberKeypad),
            matching: find.text(digit),
          ),
        );
      }
      await tester.pump();
      await tester.tap(find.widgetWithText(GlassButton, 'Set budget'));
      await tester.pumpAndSettle();
    }

    testWidgets('the first budget is free', (tester) async {
      await addOne(tester, 0);
      expect(find.textContaining('short ad'), findsNothing);
      expect(find.textContaining('free limit'), findsNothing);
    });

    testWidgets('the next ones take a short ad, saying how many are left', (
      tester,
    ) async {
      await addOne(tester, 1);
      expect(find.text('Watch a short ad to add this budget'), findsOneWidget);
      expect(find.textContaining('Budget 2 of 7'), findsOneWidget);
      expect(find.text('Get Pro instead'), findsOneWidget);
      await tester.tap(find.text('Watch ad'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 200)),
      );
      await tester.pumpAndSettle();
      final saved = (await tester.runAsync(
        () => budgets.loadMonth(DateTime(2026, 11), 'INR', 2),
      ))!;
      expect(saved.budgets, hasLength(1));
    });

    testWidgets('past seven, Pro is needed', (tester) async {
      await addOne(tester, 7);
      expect(find.text('7 budgets is the free limit'), findsOneWidget);
      expect(find.text('See Pro'), findsOneWidget);
    });

    testWidgets('with the limits off, everyone adds freely', (tester) async {
      ProController.enforceLimits = false;
      await addOne(tester, 9);
      expect(find.textContaining('short ad'), findsNothing);
      expect(find.textContaining('free limit'), findsNothing);
    });

    testWidgets('Pro adds as many as it likes, with no ad', (tester) async {
      pro.subscribed = true;
      await addOne(tester, 9);
      expect(find.textContaining('short ad'), findsNothing);
      expect(find.textContaining('free limit'), findsNothing);
    });
  });

  group('Accent colors', () {
    Future<AppearanceController> open(WidgetTester tester) async {
      tester.view.physicalSize = const Size(430, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final settings = AppearanceController();
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.light),
          builder: (context, child) =>
              AppearanceScope(controller: settings, child: child!),
          home: const CustomizationScreen(),
        ),
      );
      await tester.pumpAndSettle();
      return settings;
    }

    testWidgets('the first row is free, the second row and picker are Pro', (
      tester,
    ) async {
      final settings = await open(tester);
      expect(find.byIcon(Icons.lock_rounded), findsNWidgets(4));
      await tester.tap(find.byTooltip('Pink'));
      await tester.pumpAndSettle();
      // A free color asks first, so nothing waits on an ad out of sight.
      expect(find.text('Watch a short ad to switch color'), findsOneWidget);
      expect(find.text('Get Pro instead'), findsOneWidget);
      expect(settings.accentColor, isNot(CustomizationScreen.colors['Pink']));
      await tester.tap(find.text('Watch ad'));
      await tester.pumpAndSettle();
      expect(settings.accentColor, CustomizationScreen.colors['Pink']);
      await tester.tap(find.byTooltip('Teal'));
      await tester.pumpAndSettle();
      expect(find.text('A Pro color'), findsOneWidget);
      expect(settings.accentColor, CustomizationScreen.colors['Pink']);
    });

    testWidgets('with the limits off, every color is open', (tester) async {
      ProController.enforceLimits = false;
      await open(tester);
      expect(find.byIcon(Icons.lock_rounded), findsNothing);
      await tester.tap(find.byTooltip('Teal'));
      await tester.pumpAndSettle();
      expect(find.text('A Pro color'), findsNothing);
    });

    testWidgets('with Pro the picker offers any readable shade', (
      tester,
    ) async {
      pro.subscribed = true;
      final settings = await open(tester);
      expect(find.byIcon(Icons.lock_rounded), findsNothing);
      await tester.tap(find.byTooltip('Your own color'));
      await tester.pumpAndSettle();
      expect(find.text('Use this color'), findsOneWidget);
      await tester.tap(find.text('Use this color'));
      await tester.pumpAndSettle();
      final hsl = HSLColor.fromColor(settings.accentColor);
      // Never black, white or grey.
      expect(hsl.saturation, greaterThan(.6));
      expect(hsl.lightness, inInclusiveRange(.34, .54));
    });
  });
}
