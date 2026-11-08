import 'package:flutter/material.dart';

import 'app_theme.dart';
import 'surface_style.dart';

/// The calm, low-contrast palette every bottom sheet is drawn in (see
/// FLUTTER_GUIDE.md §2 "Bottom popup"). Light values follow the design brief;
/// dark values reuse the app's existing dark surfaces so a sheet never looks
/// pasted in.
@immutable
class SheetColors {
  const SheetColors._({
    required this.background,
    required this.card,
    required this.text,
    required this.muted,
    required this.control,
    required this.divider,
    required this.outline,
    required this.primary,
    required this.expense,
    required this.income,
  });

  /// The sheet itself, behind its cards.
  final Color background;
  final Color card;
  final Color text;

  /// Labels, captions, and placeholder values.
  final Color muted;

  /// Neutral controls and icon circles.
  final Color control;
  final Color divider;

  /// Outlined buttons, unselected radio marks, and the drag handle.
  final Color outline;
  final Color primary;
  final Color expense;
  final Color income;

  static const _light = SheetColors._(
    background: lightPageBackground,
    card: Colors.white,
    text: Color(0xff171b27),
    muted: Color(0xff697180),
    control: Color(0xffefeff0),
    divider: Color(0xffe9edf2),
    outline: Color(0xffd5dbe4),
    primary: accent,
    expense: Color(0xffe23b4f),
    income: Color(0xff009b58),
  );

  static const _dark = SheetColors._(
    background: Color(0xff000000),
    card: Color(0xff292929),
    text: Color(0xfff2f4fa),
    muted: Color(0xffa1a1a1),
    control: Color(0xff282828),
    divider: Color(0xff303030),
    outline: Color(0xff484848),
    primary: accent,
    expense: coral,
    income: green,
  );

  static Color _lift(Color color, double amount) =>
      Color.alphaBlend(Colors.white.withValues(alpha: amount), color);

  static SheetColors of(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final base = dark ? _dark : _light;
    // In dark mode the sheet's frost is about the app's surface colour, so
    // cards drawn in that colour vanish into it. A touch of white lifts
    // them to a light grey that reads as a surface of its own.
    final glass = usesGlass(context);
    final card = dark
        ? _lift(theme.colorScheme.surface, glass ? .08 : .025)
        : base.card;
    return SheetColors._(
      background: dark ? theme.scaffoldBackgroundColor : base.background,
      card: card,
      text: base.text,
      muted: base.muted,
      control: dark
          ? _lift(theme.inputDecorationTheme.fillColor!, glass ? .08 : 0)
          : base.control,
      // Drawn on the lifted card, so it is lifted from the card itself
      // rather than from a fixed grey, which would match the card exactly.
      divider: dark ? _lift(card, .13) : base.divider,
      outline: base.outline,
      primary: theme.colorScheme.primary,
      expense: base.expense,
      income: base.income,
    );
  }
}
