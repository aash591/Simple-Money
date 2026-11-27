import 'package:flutter/material.dart';

/// Shared reading hierarchy for pages, cards, forms and financial summaries.
/// Calm and quiet: semibold rather than bold, modest title sizes, slightly
/// tightened large text. Text remains subject to the user's system text
/// scaling setting.
abstract final class AppTypography {
  static const fontFamily = 'Manrope';

  static const pageTitle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 24,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.6,
    height: 1.2,
  );
  static const sectionTitle = TextStyle(
    fontFamily: fontFamily,
    fontSize: 17,
    fontWeight: FontWeight.w500,
    letterSpacing: 0,
    height: 1.3,
  );
  static const body = TextStyle(
    fontFamily: fontFamily,
    fontSize: 14,
    letterSpacing: 0,
    height: 1.4,
  );
  static const caption = TextStyle(
    fontFamily: fontFamily,
    fontSize: 13,
    height: 1.4,
  );
  static const button = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.1,
    height: 1.25,
  );
  static const amount = TextStyle(
    fontFamily: fontFamily,
    fontSize: 38,
    height: 1.15,
    fontWeight: FontWeight.w600,
    letterSpacing: -1.4,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  /// Display scale for the home summary, separate from compact balances.
  static const heroAmount = TextStyle(
    fontFamily: fontFamily,
    fontSize: 30,
    height: 1.08,
    fontWeight: FontWeight.w700,
    letterSpacing: -1,
    fontFeatures: [FontFeature.tabularFigures()],
  );

  static const rowAmount = TextStyle(
    fontFamily: fontFamily,
    fontSize: 15,
    height: 1.3,
    fontWeight: FontWeight.w600,
    letterSpacing: -0.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}
