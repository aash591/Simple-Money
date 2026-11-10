import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/state/appearance_controller.dart';
import 'package:simple_money/ui/more/settings/customization_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/theme/sheet_colors.dart';
import 'package:simple_money/ui/components/menu_list.dart';

void main() {
  test('Aurora selection persists without replacing the accent', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppearanceController();
    await settings.setAccent(const Color(0xff008580));
    await settings.setStyle(AppStyle.aurora);
    final restored = AppearanceController();
    await restored.restore();
    expect(restored.style, AppStyle.aurora);
    expect(restored.accentColor, const Color(0xff008580));
    settings.dispose();
    restored.dispose();
  });

  testWidgets('Menu glyphs follow accent changes in every style', (
    tester,
  ) async {
    for (final style in AppStyle.values) {
      for (final accentColor in [
        const Color(0xff8055e8),
        const Color(0xff008580),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            theme: appTheme(
              Brightness.light,
              accentColor: accentColor,
              style: style,
            ),
            home: const Scaffold(
              body: Column(
                children: [
                  MenuIconTile(Icons.settings_outlined),
                  MenuIconTile(Icons.delete_outline, tint: coral),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.widget<Icon>(find.byIcon(Icons.settings_outlined)).color,
          accentColor,
        );
        expect(
          tester.widget<Icon>(find.byIcon(Icons.delete_outline)).color,
          coral,
        );
      }
    }
  });

  test('Style persists independently of brightness and accent', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = AppearanceController();
    await settings.setStyle(AppStyle.simple);
    await settings.setMode(ThemeMode.dark);
    await settings.setAccent(Colors.blue);
    final restored = AppearanceController();
    await restored.restore();
    expect(restored.style, AppStyle.simple);
    expect(restored.value, ThemeMode.dark);
    expect(restored.accentColor.toARGB32(), Colors.blue.toARGB32());
    await restored.setMode(ThemeMode.light);
    expect(restored.style, AppStyle.simple);
    settings.dispose();
    restored.dispose();
  });

  test('Invalid saved settings fall back to system and purple', () async {
    SharedPreferences.setMockInitialValues({
      'theme_mode': 'unknown',
      'accent_color': 0,
    });
    final settings = AppearanceController();
    await settings.restore();
    expect(settings.value, ThemeMode.system);
    expect(settings.accentColor, accent);
    settings.dispose();
  });

  testWidgets('Dark colors and accents reach bottom sheets', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(
          Brightness.dark,
          accentColor: CustomizationScreen.colors['Teal']!,
        ),
        home: Builder(
          builder: (context) {
            final colors = SheetColors.of(context);
            // Cards and controls are see-through washes over the sheet's frost.
            expect(colors.background, darkBackground);
            expect(colors.card, Colors.white.withValues(alpha: .08));
            expect(colors.control, Colors.white.withValues(alpha: .09));
            // Lifted just enough to read on the sheet, but still the same hue.
            final teal = HSLColor.fromColor(
              CustomizationScreen.colors['Teal']!,
            );
            final shown = HSLColor.fromColor(colors.primary);
            expect((shown.hue - teal.hue).abs(), lessThan(8));
            return const SizedBox();
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  });

  testWidgets('Customization fits a narrow phone with large text', (
    tester,
  ) async {
    tester.view.reset();
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = AppearanceController();
    addTearDown(settings.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: AppearanceScope(controller: settings, child: child!),
        ),
        home: const CustomizationScreen(),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
