import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// How a transaction list is cut into periods.
enum PeriodKind {
  day('Day', Icons.today_outlined),
  week('Week', Icons.date_range_outlined),
  month('Month', Icons.calendar_view_month_outlined),
  quarter('Quarter', Icons.calendar_view_week_outlined),
  year('Year', Icons.calendar_month_outlined),
  all('All time', Icons.all_inclusive_rounded),
  custom('Custom range', Icons.tune_rounded);

  const PeriodKind(this.label, this.icon);
  final String label;
  final IconData icon;

  /// All time and a custom range are one page; the rest swipe period by
  /// period.
  bool get pages => this != all && this != custom;
}

/// The period a [PeriodPager] shows: its [kind], and which one of them.
///
/// Pages are counted from [baseAnchor]; [offset] is how many periods the
/// user has swiped away from it. [select] starts over from a new base, and
/// the pager jumps to match.
class PeriodController extends ChangeNotifier {
  PeriodController({
    this._kind = PeriodKind.month,
    DateTime? anchor,
    this._customRange,
  }) : _baseAnchor = anchor ?? DateTime.now();

  PeriodKind _kind;
  DateTimeRange? _customRange;
  DateTime _baseAnchor;
  int _offset = 0;

  /// Bumped by [select], so the pager knows to jump rather than follow.
  int resets = 0;

  PeriodKind get kind => _kind;
  DateTimeRange? get customRange => _customRange;
  DateTime get baseAnchor => _baseAnchor;
  int get offset => _offset;

  /// A date inside the current period.
  DateTime get anchor => dateAt(_offset);

  DateTimeRange get range => rangeAt(anchor);

  /// Switches to [kind] (with [customRange] for a custom one) and back to the
  /// period containing [anchor], today by default.
  void select(PeriodKind kind, {DateTimeRange? customRange, DateTime? anchor}) {
    _kind = kind;
    if (kind == PeriodKind.custom && customRange != null) {
      _customRange = DateTimeRange(
        start: DateUtils.dateOnly(customRange.start),
        end: DateUtils.dateOnly(customRange.end),
      );
    }
    _baseAnchor = anchor ?? DateTime.now();
    _offset = 0;
    resets++;
    notifyListeners();
  }

  /// Called by the pager as pages settle.
  void showOffset(int offset) {
    if (offset == _offset) return;
    _offset = offset;
    notifyListeners();
  }

  DateTime dateAt(int offset) => switch (_kind) {
    PeriodKind.day => _baseAnchor.add(Duration(days: offset)),
    PeriodKind.week => _baseAnchor.add(Duration(days: 7 * offset)),
    PeriodKind.month => DateTime(_baseAnchor.year, _baseAnchor.month + offset),
    PeriodKind.quarter => DateTime(
      _baseAnchor.year,
      _baseAnchor.month + 3 * offset,
    ),
    PeriodKind.year => DateTime(_baseAnchor.year + offset),
    PeriodKind.all || PeriodKind.custom => _baseAnchor,
  };

  DateTimeRange rangeAt(DateTime anchor) => rangeOf(_kind, anchor);

  DateTimeRange rangeOf(PeriodKind kind, DateTime anchor) {
    final day = DateTime(anchor.year, anchor.month, anchor.day);
    return switch (kind) {
      PeriodKind.day => DateTimeRange(start: day, end: day),
      PeriodKind.week => DateTimeRange(
        start: day.subtract(Duration(days: day.weekday - 1)),
        end: day.add(Duration(days: 7 - day.weekday)),
      ),
      PeriodKind.month => DateTimeRange(
        start: DateTime(day.year, day.month),
        end: DateTime(day.year, day.month + 1, 0),
      ),
      PeriodKind.quarter => DateTimeRange(
        start: DateTime(day.year, ((day.month - 1) ~/ 3) * 3 + 1),
        end: DateTime(day.year, ((day.month - 1) ~/ 3) * 3 + 4, 0),
      ),
      PeriodKind.year => DateTimeRange(
        start: DateTime(day.year),
        end: DateTime(day.year, 12, 31),
      ),
      PeriodKind.all => DateTimeRange(
        start: DateTime(1900),
        end: DateTime(2999, 12, 31),
      ),
      PeriodKind.custom => _customRange ?? DateTimeRange(start: day, end: day),
    };
  }

  /// The number of periods to move from [from] to land in the same period
  /// as [to].
  int offsetBetween(DateTime from, DateTime to) {
    DateTime monday(DateTime d) => d.subtract(Duration(days: d.weekday - 1));
    return switch (_kind) {
      PeriodKind.day => DateTime(
        to.year,
        to.month,
        to.day,
      ).difference(DateTime(from.year, from.month, from.day)).inDays,
      PeriodKind.week =>
        monday(DateTime(to.year, to.month, to.day))
                .difference(monday(DateTime(from.year, from.month, from.day)))
                .inDays ~/
            7,
      PeriodKind.month =>
        (to.year * 12 + to.month) - (from.year * 12 + from.month),
      PeriodKind.quarter =>
        (to.year * 4 + (to.month - 1) ~/ 3) -
            (from.year * 4 + (from.month - 1) ~/ 3),
      PeriodKind.year => to.year - from.year,
      PeriodKind.all || PeriodKind.custom => 0,
    };
  }

  /// A strip tab's label for the period containing [date].
  String itemLabel(DateTime date) {
    final today = DateTime.now();
    switch (_kind) {
      case PeriodKind.day:
        final diff = DateTime(
          date.year,
          date.month,
          date.day,
        ).difference(DateTime(today.year, today.month, today.day)).inDays;
        if (diff == 0) return 'Today';
        if (diff == -1) return 'Yesterday';
        if (diff == 1) return 'Tomorrow';
        return DateFormat('d MMM yyyy').format(date);
      case PeriodKind.week:
        final range = rangeOf(PeriodKind.week, date);
        return '${DateFormat('d MMM').format(range.start)} – '
            '${DateFormat('d MMM yyyy').format(range.end)}';
      case PeriodKind.month:
        return DateFormat('MMM yyyy').format(date);
      case PeriodKind.quarter:
        return 'Q${((date.month - 1) ~/ 3) + 1} ${date.year}';
      case PeriodKind.year:
        return '${date.year}';
      case PeriodKind.all:
      case PeriodKind.custom:
        return '';
    }
  }

  /// The current period spelled out, for a single-page kind's header.
  String get label {
    final range = this.range;
    return switch (_kind) {
      PeriodKind.day => DateFormat('d MMM yyyy').format(range.start),
      PeriodKind.week =>
        '${DateFormat('d MMM').format(range.start)} – '
            '${DateFormat('d MMM yyyy').format(range.end)}',
      PeriodKind.month => DateFormat('MMMM yyyy').format(range.start),
      PeriodKind.quarter =>
        'Q${((range.start.month - 1) ~/ 3) + 1} ${range.start.year}',
      PeriodKind.year => '${range.start.year}',
      PeriodKind.all => 'All time',
      PeriodKind.custom =>
        '${DateFormat('d MMM yyyy').format(range.start)} – '
            '${DateFormat('d MMM yyyy').format(range.end)}',
    };
  }
}
