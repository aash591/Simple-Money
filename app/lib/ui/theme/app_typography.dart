import 'package:flutter/material.dart';

/// Shared reading hierarchy for pages, cards, forms and financial summaries.
/// Text remains subject to the user's system text scaling setting.
abstract final class AppTypography {
  static const pageTitle = TextStyle(
    fontSize: 28,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    height: 1.2,
  );
  static const sectionTitle = TextStyle(
    fontSize: 19,
    fontWeight: FontWeight.w600,
    height: 1.3,
  );
  static const body = TextStyle(fontSize: 16, height: 1.4);
  static const caption = TextStyle(fontSize: 13, height: 1.4);
  static const button = TextStyle(
    fontSize: 16,
    fontWeight: FontWeight.w600,
    height: 1.25,
  );
  static const amount = TextStyle(
    fontSize: 40,
    height: 1.15,
    fontWeight: FontWeight.w700,
    letterSpacing: -1.2,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const rowAmount = TextStyle(
    fontSize: 17,
    height: 1.3,
    fontWeight: FontWeight.w600,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}
