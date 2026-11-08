import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import 'chart_data.dart';

/// Every colour a chart is allowed to use, resolved for the current theme.
///
/// The categorical hues are a fixed, validated set rather than shades of the
/// user's accent colour: the accent is customisable, so anything derived from
/// it could land two unreadable neighbours next to each other. These eight
/// clear the colour-blind separation, chroma and lightness checks against both
/// the light card surface and the lightest dark style, in this order — so
/// slot 1 is always slot 1 and a filter that drops a category never repaints
/// the ones that remain.
@immutable
class ChartPalette {
  const ChartPalette._({
    required this.categorical,
    required this.other,
    required this.income,
    required this.expense,
    required this.grid,
    required this.track,
    required this.surface,
    required this.label,
  });

  factory ChartPalette.of(BuildContext context, {Color? surface}) {
    final scheme = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ChartPalette._(
      categorical: dark ? _darkHues : _lightHues,
      other: scheme.onSurfaceVariant,
      income: green,
      expense: coral,
      grid: scheme.onSurface.withValues(alpha: .045),
      track: scheme.surfaceContainerHighest,
      // What the 2px gaps between touching marks are painted in, so it has to
      // match whatever the chart is sitting on — a card by default.
      surface: surface ?? scheme.surface,
      label: scheme.onSurfaceVariant,
    );
  }

  static const _lightHues = [
    Color(0xff2a78d6), // blue
    Color(0xffeb6834), // orange
    Color(0xff1baf7a), // aqua
    Color(0xffeda100), // yellow
    Color(0xffe87ba4), // magenta
    Color(0xff008300), // green
    Color(0xff4a3aa7), // violet
    Color(0xffe34948), // red
  ];

  static const _darkHues = [
    Color(0xff3987e5),
    Color(0xffd95926),
    Color(0xff199e70),
    Color(0xffc98500),
    Color(0xffd55181),
    Color(0xff008300),
    Color(0xff9085e9),
    Color(0xffe66767),
  ];

  final List<Color> categorical;

  /// The grey the folded "Other" bucket wears. Deliberately not a hue: it is
  /// a leftover, not a category.
  final Color other;

  /// Money's two directions. Reserved — never reused as "series 3".
  final Color income, expense;

  final Color grid, track, surface, label;

  /// The categorical hue for slot [index]. Hues are assigned in order and
  /// never cycled: past the eighth, callers fold into "Other" (see [rank])
  /// or facet into small charts, so two categories can never share a colour.
  Color series(int index) =>
      index < categorical.length ? categorical[index] : other;

  /// Largest values first, the top [max] keeping their own hue and the rest
  /// folded into one grey [otherLabel] entry. This is the shape a pie, a
  /// ranked bar chart and a legend all want.
  List<ChartEntry> rank(
    Iterable<({String label, double value})> values, {
    int max = 5,
    String otherLabel = 'Other',
  }) {
    final sorted = values.toList()..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.take(max).toList();
    final rest = sorted.skip(max);
    return [
      for (var i = 0; i < top.length; i++)
        ChartEntry(label: top[i].label, value: top[i].value, color: series(i)),
      if (rest.isNotEmpty)
        ChartEntry(
          label: otherLabel,
          value: rest.fold(0, (sum, entry) => sum + entry.value),
          color: other,
        ),
    ];
  }
}
