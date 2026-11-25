import 'package:flutter/material.dart';

import 'legible_color.dart';
import 'surface_style.dart';
import 'app_typography.dart';

enum AppStyle { glassy, simple, aurora }

bool usesAurora(BuildContext context) =>
    Theme.of(context).extension<AppChrome>()?.style == AppStyle.aurora;

bool usesGlass(BuildContext context) =>
    Theme.of(context).extension<AppChrome>()?.style != AppStyle.simple;

/// Ink: the app is neutral, and the primary action is black (white on dark).
const accent = Color(0xff18181b);
const green = Color(0xff2f9e6e);
const coral = Color(0xffe5484d);

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

/// Aurora's dark page: a deep navy the accent pools glow over.
const auroraDarkPage = Color(0xff0b1020);

/// Chrome that only some themes have.
@immutable
class AppChrome extends ThemeExtension<AppChrome> {
  const AppChrome({
    this.cardBorder,
    this.style = AppStyle.glassy,
    this.pageTop,
  });
  final AppStyle style;

  /// A hairline around every card; none in the other themes.
  final Color? cardBorder;

  /// The page backdrop's colour along the top edge, so the status bar scrim
  /// blends into the page instead of laying a grey band over it.
  final Color? pageTop;

  @override
  AppChrome copyWith({Color? cardBorder, AppStyle? style, Color? pageTop}) =>
      AppChrome(
        cardBorder: cardBorder ?? this.cardBorder,
        style: style ?? this.style,
        pageTop: pageTop ?? this.pageTop,
      );

  @override
  AppChrome lerp(AppChrome? other, double t) => AppChrome(
    cardBorder: Color.lerp(cardBorder, other?.cardBorder, t),
    style: t < .5 ? style : other?.style ?? style,
    pageTop: Color.lerp(pageTop, other?.pageTop, t),
  );
}

/// [black] only applies to [Brightness.dark]: the dark theme with true-black
/// cards, easy on an OLED screen.
ThemeData appTheme(
  Brightness brightness, {
  Color accentColor = accent,
  bool black = false,
  AppStyle style = AppStyle.glassy,
}) {
  final dark = brightness == Brightness.dark;
  // A near-black accent would vanish on a dark page, so it flips to white.
  final accent = dark && accentColor.computeLuminance() < .05
      ? const Color(0xfff2f2f4)
      : accentColor;
  final simple = style == AppStyle.simple;
  // Aurora's dark surfaces lean navy with a breath of the accent, so sheets,
  // pills and discs belong to the same page as the glowing backdrop instead
  // of sitting on it as neutral charcoal.
  final aurora = style == AppStyle.aurora && dark && !black;
  final surface = dark && black
      ? blackSurface
      : simple
      ? const Color(0xff1c1c1e)
      : aurora
      ? Color.alphaBlend(accent.withValues(alpha: .06), const Color(0xff161b2b))
      : darkSurface;
  final control = dark && black
      ? blackControl
      : aurora
      ? Color.alphaBlend(accent.withValues(alpha: .08), const Color(0xff20263a))
      : darkControl;
  final scaffold = simple
      ? (dark
            ? (black ? Colors.black : const Color(0xff111214))
            : const Color(0xfff2f2f7))
      : (dark ? darkBackground : lightPageBackground);
  final pageTop = switch (style) {
    AppStyle.simple => scaffold,
    AppStyle.aurora =>
      dark
          ? (black
                ? Colors.black
                : Color.alphaBlend(
                    accent.withValues(alpha: .14),
                    auroraDarkPage,
                  ))
          : const Color(0xfff6f7fa),
    AppStyle.glassy =>
      dark
          ? (black ? Colors.black : const Color(0xff131315))
          : const Color(0xfff6f5f3),
  };
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
        onSurface: dark ? const Color(0xfff2f2f4) : const Color(0xff1c1c1f),
        onSurfaceVariant: dark
            ? (aurora ? const Color(0xffa1a6bb) : const Color(0xff9a9aa2))
            : const Color(0xff686870),
      );
  return ThemeData(
    useMaterial3: true,
    fontFamily: AppTypography.fontFamily,
    colorScheme: scheme,
    brightness: brightness,
    extensions: [
      AppChrome(
        cardBorder: dark && black ? blackCardBorder : null,
        style: style,
        pageTop: pageTop,
      ),
    ],
    scrollbarTheme: const ScrollbarThemeData(
      thickness: WidgetStatePropertyAll(2),
      radius: Radius.circular(1),
      thumbVisibility: WidgetStatePropertyAll(false),
      trackVisibility: WidgetStatePropertyAll(false),
    ),
    // Text buttons are drawn in the accent; on dark it is lifted until it
    // reads, whatever colour was picked.
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: dark
            ? legibleOn(accent, const Color(0xff1b1b22))
            : accent,
      ),
    ),
    scaffoldBackgroundColor: scaffold,
    appBarTheme: AppBarTheme(
      backgroundColor: scaffold,
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
      // A selected row's text and icon are the accent; on dark it is lifted
      // until it reads on glass, whatever colour was picked.
      selectedColor: dark ? legibleOn(accent, const Color(0xff1b1b22)) : accent,
      minVerticalPadding: 12,
      horizontalTitleGap: 12,
      titleTextStyle: AppTypography.body.copyWith(
        fontWeight: FontWeight.w500,
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
