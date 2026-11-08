import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// How a chart turns a plotted value into text — an axis tick, a direct label
/// or a tooltip row. Charts here are unit-agnostic: money screens pass minor
/// units and format them with their own currency formatter, so nothing in this
/// folder needs to know about currencies or digits.
typedef ChartValueFormatter = String Function(double value);

/// One named run of values sharing a colour. Every plotted chart in this
/// folder takes its data this way, so a screen can hand the same list to a
/// [BarChart] or a [LineChart] without reshaping it.
@immutable
class ChartSeries {
  ChartSeries({
    required this.label,
    required List<num> values,
    required this.color,
    this.negativeColor,
    this.valueColors,
    this.dashed = false,
  }) : values = List.unmodifiable(values.map((v) => v.toDouble()));

  final String label;

  /// One value per slot, in slot order. Slots are whatever the screen is
  /// comparing — days, months, categories — and every series in a chart is
  /// read against the same slot list.
  final List<double> values;
  final Color color;

  /// Drawn instead of [color] below the baseline, for a chart whose sign
  /// carries meaning (spent more vs spent less than last month).
  final Color? negativeColor;

  /// A colour per slot, for the one-series chart where each bar is its own
  /// category rather than a step in a trend. Wins over [color].
  final List<Color>? valueColors;

  /// Lines only: draws this series dashed, marking it as a projection or a
  /// target rather than something that was measured (a budget's even pace).
  final bool dashed;

  double get total => values.fold(0, (sum, value) => sum + value);

  Color colorAt(int index) {
    final custom = valueColors;
    if (custom != null && index < custom.length) return custom[index];
    return values[index] < 0 ? negativeColor ?? color : color;
  }

  @override
  bool operator ==(Object other) =>
      other is ChartSeries &&
      other.label == label &&
      other.color == color &&
      other.negativeColor == negativeColor &&
      other.dashed == dashed &&
      listEquals(other.values, values) &&
      listEquals(other.valueColors, valueColors);

  @override
  int get hashCode => Object.hash(
    label,
    color,
    negativeColor,
    dashed,
    Object.hashAll(values),
    valueColors == null ? null : Object.hashAll(valueColors!),
  );
}

/// A single labelled value: what a pie slice, a ranked bar and a legend row
/// are each made of. Build these with `ChartPalette.rank` so colours are
/// assigned in the palette's fixed order.
@immutable
class ChartEntry {
  const ChartEntry({
    required this.label,
    required this.value,
    required this.color,
  });
  final String label;
  final double value;
  final Color color;

  @override
  bool operator ==(Object other) =>
      other is ChartEntry &&
      other.label == label &&
      other.value == value &&
      other.color == color;

  @override
  int get hashCode => Object.hash(label, value, color);
}

/// The plotted range, rounded out to tick values a reader can do arithmetic
/// with (0 / 500 / 1,000), with the baseline always included so bars grow
/// from zero and a negative value reads as negative.
@immutable
class ChartBounds {
  const ChartBounds({
    required this.min,
    required this.max,
    required this.divisions,
  });

  /// Rounds [values] out to clean ticks. [divisions] is the target number of
  /// gaps between gridlines; the real count can differ by one after rounding.
  factory ChartBounds.of(Iterable<double> values, {int divisions = 4}) {
    var low = 0.0, high = 0.0;
    for (final value in values) {
      low = math.min(low, value);
      high = math.max(high, value);
    }
    if (low == 0 && high == 0) {
      return const ChartBounds(min: 0, max: 1, divisions: 1);
    }
    final step = _niceStep((high - low) / math.max(1, divisions));
    final min = (low / step).floor() * step;
    final max = (high / step).ceil() * step;
    return ChartBounds(
      min: min,
      max: max,
      divisions: math.max(1, ((max - min) / step).round()),
    );
  }

  final double min, max;
  final int divisions;

  double get span => max - min == 0 ? 1 : max - min;

  /// Where [value] sits in the plot, 0 at the bottom and 1 at the top.
  double fraction(double value) => (value - min) / span;

  /// The baseline's height fraction — zero when the data is all positive.
  double get baseline => fraction(math.max(min, math.min(0, max)));

  List<double> get ticks => [
    for (var i = 0; i <= divisions; i++) min + span * i / divisions,
  ];

  @override
  bool operator ==(Object other) =>
      other is ChartBounds &&
      other.min == min &&
      other.max == max &&
      other.divisions == divisions;

  @override
  int get hashCode => Object.hash(min, max, divisions);
}

/// The 1 / 2 / 2.5 / 5 / 10 ladder, so ticks land on numbers people round to.
double _niceStep(double raw) {
  if (raw <= 0) return 1;
  final magnitude = math
      .pow(10, (math.log(raw) / math.ln10).floor())
      .toDouble();
  final normalized = raw / magnitude;
  final step = normalized <= 1
      ? 1.0
      : normalized <= 2
      ? 2.0
      : normalized <= 2.5
      ? 2.5
      : normalized <= 5
      ? 5.0
      : 10.0;
  return step * magnitude;
}
