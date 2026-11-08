import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/state/appearance_controller.dart';
import 'package:simple_money/ui/components/common.dart';
import 'package:simple_money/ui/components/menu_list.dart';
import 'package:simple_money/ui/more/settings/customization_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('appTheme', () {
    test('black keeps the page black, darkens cards and edges them', () {
      final theme = appTheme(Brightness.dark, black: true);
      expect(theme.scaffoldBackgroundColor, Colors.black);
      expect(theme.colorScheme.surface, blackSurface);
      expect(theme.extension<AppChrome>()!.cardBorder, blackCardBorder);
    });

    test('plain dark and light have no card edge', () {
      expect(
        appTheme(Brightness.dark).extension<AppChrome>()!.cardBorder,
        isNull,
      );
      expect(appTheme(Brightness.dark).colorScheme.surface, darkSurface);
      // Black is a style of dark only.
      final light = appTheme(Brightness.light, black: true);
      expect(light.extension<AppChrome>()!.cardBorder, isNull);
      expect(light.colorScheme.surface, Colors.white);
    });
  });

  group('AppearanceController', () {
    test('black is saved and restored', () async {
      final controller = AppearanceController();
      await controller.setMode(ThemeMode.dark, black: true);
      expect(controller.black, isTrue);

      final restored = AppearanceController();
      await restored.restore();
      expect(restored.value, ThemeMode.dark);
      expect(restored.black, isTrue);
      controller.dispose();
      restored.dispose();
    });

    test('any other mode drops black', () async {
      final controller = AppearanceController();
      await controller.setMode(ThemeMode.dark, black: true);
      await controller.setMode(ThemeMode.light, black: true);
      expect(controller.black, isFalse);
      await controller.setMode(ThemeMode.dark);
      expect(controller.black, isFalse);

      final restored = AppearanceController();
      await restored.restore();
      expect(restored.black, isFalse);
      controller.dispose();
      restored.dispose();
    });

    test('switching dark to black notifies although the mode is the same', () {
      final controller = AppearanceController();
      var notified = 0;
      controller.addListener(() => notified++);
      controller.setMode(ThemeMode.dark);
      expect(notified, 1);
      controller.setMode(ThemeMode.dark, black: true);
      expect(notified, 2);
      controller.dispose();
    });
  });

  testWidgets('a card in the black theme has a hairline edge', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark, black: true),
        home: const Scaffold(body: MoneyCard(child: Text('card'))),
      ),
    );
    final box = tester.widget<DecoratedBox>(
      find
          .descendant(
            of: find.byType(MoneyCard),
            matching: find.byType(DecoratedBox),
          )
          .first,
    );
    expect((box.decoration as BoxDecoration).border, isNotNull);
  });

  testWidgets('Customization lists Black and picking it selects only it', (
    tester,
  ) async {
    final controller = AppearanceController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      ValueListenableBuilder<ThemeMode>(
        valueListenable: controller,
        builder: (context, mode, _) => MaterialApp(
          theme: appTheme(Brightness.light),
          darkTheme: appTheme(Brightness.dark, black: controller.black),
          themeMode: mode,
          builder: (context, child) =>
              AppearanceScope(controller: controller, child: child!),
          home: const CustomizationScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Black'), findsOneWidget);

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(controller.black, isFalse);

    await tester.tap(find.text('Black'));
    await tester.pumpAndSettle();
    expect(controller.value, ThemeMode.dark);
    expect(controller.black, isTrue);
    final context = tester.element(find.byType(CustomizationScreen));
    expect(Theme.of(context).colorScheme.surface, blackSurface);
    // One tick only: Black is selected, and plain Dark is not.
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
    final blackRow = find.ancestor(
      of: find.text('Black'),
      matching: find.byType(MenuRow),
    );
    expect(
      find.descendant(
        of: blackRow,
        matching: find.byIcon(Icons.check_circle_rounded),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Dark'));
    await tester.pumpAndSettle();
    expect(controller.black, isFalse);
    expect(
      Theme.of(tester.element(find.byType(CustomizationScreen)))
          .colorScheme
          .surface,
      darkSurface,
    );
  });
}
