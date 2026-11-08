import 'package:flutter/material.dart';

import 'surface_style.dart';
import 'app_typography.dart';

const accent = Color(0xff8055e8);
const green = Color(0xff16b97c);
const coral = Color(0xffff6575);

/// Something waits on the user: not an error, not done.
const orange = Color(0xffff9f0a);

/// Dark mode's page, card and control colours.
const darkBackground = Color(0xff000000);
const darkSurface = Color(0xff292929);
const darkControl = Color(0xff282828);

/// The black theme keeps cards nearly as dark as the page, so a hairline
/// edge ([AppChrome.cardBorder]) is what sets them apart.
const blackSurface = Color(0xff0e0e0e);
const blackControl = Color(0xff181818);
const blackCardBorder = Color(0x18ffffff);

/// Chrome that only some themes have.
@immutable
class AppChrome extends ThemeExtension<AppChrome> {
  const AppChrome({this.cardBorder});

  /// A hairline around every card; none in the other themes.
  final Color? cardBorder;

  @override
  AppChrome copyWith({Color? cardBorder}) =>
      AppChrome(cardBorder: cardBorder ?? this.cardBorder);

  @override
  AppChrome lerp(AppChrome? other, double t) =>
      AppChrome(cardBorder: Color.lerp(cardBorder, other?.cardBorder, t));
}

/// [black] only applies to [Brightness.dark]: the dark theme with true-black
/// cards, easy on an OLED screen.
ThemeData appTheme(
  Brightness brightness, {
  Color accentColor = accent,
  bool black = false,
}) {
  final accent = accentColor;
  final dark = brightness == Brightness.dark;
  final surface = dark && black ? blackSurface : darkSurface;
  final control = dark && black ? blackControl : darkControl;
  final scheme = ColorScheme.fromSeed(seedColor: accent, brightness: brightness)
      .copyWith(
        primary: accent,
        onPrimary:
            ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
            ? Colors.white
            : Colors.black,
        surface: dark ? surface : Colors.white,
        surfaceContainerLowest: dark ? darkBackground : Colors.white,
        surfaceContainerLow: dark ? surface : Colors.white,
        surfaceContainer: dark ? surface : Colors.white,
        surfaceContainerHigh: dark ? control : Colors.white,
        surfaceContainerHighest: dark ? control : Colors.white,
        surfaceTint: Colors.transparent,
        onSurface: dark ? const Color(0xfff2f4fa) : const Color(0xff141c30),
        onSurfaceVariant: dark
            ? const Color(0xffa1abc0)
            : const Color(0xff616d82),
      );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    extensions: [AppChrome(cardBorder: dark && black ? blackCardBorder : null)],
    scrollbarTheme: const ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(2),
      radius: Radius.circular(1),
      thumbVisibility: WidgetStatePropertyAll(false),
      trackVisibility: WidgetStatePropertyAll(false),
    ),
    scaffoldBackgroundColor: dark ? darkBackground : lightPageBackground,
    appBarTheme: AppBarTheme(
      backgroundColor: dark ? darkBackground : lightPageBackground,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
    ),
    cardTheme: CardThemeData(
      color: scheme.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(appCardRadius),
      ),
    ),
    textTheme: TextTheme(
      headlineLarge: AppTypography.amount.copyWith(color: scheme.onSurface),
      headlineSmall: AppTypography.amount.copyWith(
        fontSize: 32,
        color: scheme.onSurface,
      ),
      headlineMedium: AppTypography.pageTitle.copyWith(color: scheme.onSurface),
      titleLarge: AppTypography.pageTitle.copyWith(
        fontSize: 24,
        color: scheme.onSurface,
      ),
      titleMedium: AppTypography.sectionTitle.copyWith(color: scheme.onSurface),
      titleSmall: AppTypography.body.copyWith(
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      bodyLarge: AppTypography.body.copyWith(color: scheme.onSurface),
      bodyMedium: AppTypography.body.copyWith(color: scheme.onSurface),
      bodySmall: AppTypography.caption.copyWith(color: scheme.onSurfaceVariant),
      labelLarge: AppTypography.button.copyWith(color: scheme.onSurface),
      labelMedium: AppTypography.caption.copyWith(
        fontWeight: FontWeight.w500,
        color: scheme.onSurface,
      ),
      labelSmall: AppTypography.caption.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    listTileTheme: ListTileThemeData(
      minVerticalPadding: 12,
      horizontalTitleGap: 12,
      titleTextStyle: AppTypography.body.copyWith(
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
      subtitleTextStyle: AppTypography.caption.copyWith(
        color: scheme.onSurfaceVariant,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: false,
      fillColor: dark ? control : const Color(0xfff2f5fa),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
      contentPadding: const EdgeInsets.all(16),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 52),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        textStyle: AppTypography.button,
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: scheme.surface,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(30)),
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.onSurface.withValues(alpha: .06),
      space: 24,
    ),
  );
}
