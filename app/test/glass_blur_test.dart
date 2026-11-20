import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/state/appearance_controller.dart';
import 'package:simple_money/ui/components/app_back_button.dart';
import 'package:simple_money/ui/components/frosted_modal_surface.dart';
import 'package:simple_money/ui/components/glass_blur.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

/// A disc on the bare page backdrop has nothing to blur, so it must not pay
/// for a backdrop pass; anywhere something can show through, it still blurs.
void main() {
  const header = Key('header'), popup = Key('popup'), loose = Key('loose');

  // Settled, since a change of theme is animated.
  Future<void> pump(
    WidgetTester tester, {
    AppStyle style = AppStyle.aurora,
    String? wallpaper,
    bool black = false,
  }) async {
    await tester.pumpWidget(
      AppearanceScope(
        controller: AppearanceController()..wallpaperPath = wallpaper,
        child: MaterialApp(
          theme: appTheme(Brightness.dark, style: style, black: black),
          home: Column(
            children: [
              const OnPageBackdrop(
                child: Column(
                  children: [
                    GlassDisc(key: header),
                    // A menu opened from the header floats over the page.
                    FrostedModalSurface(
                      borderRadius: BorderRadius.zero,
                      child: GlassDisc(key: popup),
                    ),
                  ],
                ),
              ),
              const GlassDisc(key: loose),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  bool blurs(WidgetTester tester, Key disc) => tester
      .widget<BackdropFilter>(
        find.descendant(
          of: find.byKey(disc),
          matching: find.byType(BackdropFilter),
        ),
      )
      .enabled;

  testWidgets('a header disc on the plain backdrop does not blur', (
    tester,
  ) async {
    for (final style in [AppStyle.aurora, AppStyle.glassy]) {
      await pump(tester, style: style);
      expect(blurs(tester, header), isFalse, reason: '$style');
      // Inside a popup the popup's own frost is all the blur there is.
      expect(blurs(tester, popup), isFalse, reason: '$style');
      expect(blurs(tester, loose), isTrue, reason: '$style');
    }
  });

  testWidgets('over a chosen picture it still frosts', (tester) async {
    await pump(tester, wallpaper: 'picture.jpg');
    expect(blurs(tester, header), isTrue);
    // The picture is only shown behind Aurora, and not on true black.
    await pump(tester, wallpaper: 'picture.jpg', style: AppStyle.glassy);
    expect(blurs(tester, header), isFalse);
    await pump(tester, wallpaper: 'picture.jpg', black: true);
    expect(blurs(tester, header), isFalse);
  });
}
