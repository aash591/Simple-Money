import 'package:flutter/material.dart';

import '../theme/app_typography.dart';

/// The large hero figure on a stat card — total income, budget left, an
/// account's balance, and so on. Every such figure shares this size and
/// weight; only the colour changes by context. Wrap in a [FittedBox] with
/// [BoxFit.scaleDown] where the value's width isn't already constrained.
class MoneyText extends StatelessWidget {
  const MoneyText(
    this.value, {
    super.key,
    required this.color,
    this.textAlign,
    this.maxLines,
    this.overflow,
  });
  final String value;
  final Color color;
  final TextAlign? textAlign;
  final int? maxLines;
  final TextOverflow? overflow;

  static TextStyle style({required Color color}) =>
      AppTypography.amount.copyWith(color: color);

  @override
  Widget build(BuildContext context) => Text(
    value,
    textAlign: textAlign,
    maxLines: maxLines,
    overflow: overflow,
    style: style(color: color),
  );
}
