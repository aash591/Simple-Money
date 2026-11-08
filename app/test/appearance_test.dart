import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/state/appearance_controller.dart';
import 'package:simple_money/ui/more/settings/customization_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';
import 'package:simple_money/ui/theme/sheet_colors.dart';

void main() {
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
            // Cards and controls are lifted off the sheet's frost.
            Color lift(Color color) =>
                Color.alphaBlend(Colors.white.withValues(alpha: .08), color);
            expect(colors.background, darkBackground);
            expect(colors.card, lift(darkSurface));
            expect(colors.control, lift(darkControl));
            expect(colors.primary, CustomizationScreen.colors['Teal']);
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
