import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme/sheet_colors.dart';
import 'action_buttons.dart';
import 'adaptive_sheet.dart';
import 'date_picker_sheet.dart';

/// Opens the range calendar: From and To cards on top, one-tap presets,
/// and the app's shared calendar drawing the chosen span as a band.
/// Returns the range with both ends at midnight (a single day when no end
/// was picked), or null if dismissed.
Future<DateTimeRange?> showDateRangePickerSheet(
  BuildContext context, {
  DateTimeRange? initialRange,
}) => showAdaptiveSheet<DateTimeRange>(
  context,
  floating: true,
  builder: (_) => DateRangePickerSheet(initialRange: initialRange),
);

enum _Edge { start, end }

class DateRangePickerSheet extends StatefulWidget {
  const DateRangePickerSheet({super.key, this.initialRange});
  final DateTimeRange? initialRange;
  @override
  State<DateRangePickerSheet> createState() => _DateRangePickerSheetState();
}

class _DateRangePickerSheetState extends State<DateRangePickerSheet> {
  late final DateTime _today = DateUtils.dateOnly(DateTime.now());
  late final _presets = _presetsFor(_today);
  late DateTime? _start = _dateOnly(widget.initialRange?.start);
  late DateTime? _end = _dateOnly(widget.initialRange?.end);

  /// Which end the next tapped day sets.
  _Edge _editing = _Edge.start;

  /// The day whose month the calendar shows; a new object makes it jump.
  late DateTime _focus = _start ?? _today;

  static DateTime? _dateOnly(DateTime? date) =>
      date == null ? null : DateUtils.dateOnly(date);

  static List<(String, DateTimeRange)> _presetsFor(DateTime t) => [
    (
      'Last 7 days',
      DateTimeRange(start: DateTime(t.year, t.month, t.day - 6), end: t),
    ),
    (
      'Last 30 days',
      DateTimeRange(start: DateTime(t.year, t.month, t.day - 29), end: t),
    ),
    (
      'This month',
      DateTimeRange(
        start: DateTime(t.year, t.month),
        end: DateTime(t.year, t.month + 1, 0),
      ),
    ),
    (
      'Last month',
      DateTimeRange(
        start: DateTime(t.year, t.month - 1),
        end: DateTime(t.year, t.month, 0),
      ),
    ),
    (
      'Last 90 days',
      DateTimeRange(start: DateTime(t.year, t.month, t.day - 89), end: t),
    ),
    (
      'This year',
      DateTimeRange(start: DateTime(t.year), end: DateTime(t.year, 12, 31)),
    ),
  ];

  /// Places a tapped day. Setting the start moves on to the end; a day
  /// before the start begins the range again; a day on or after it closes
  /// the range, and the next tap adjusts the start.
  void _pick(DateTime day) => setState(() {
    final start = _start;
    if (_editing == _Edge.start || start == null) {
      _start = day;
      if (_end != null && day.isAfter(_end!)) _end = null;
      _editing = _Edge.end;
    } else if (day.isBefore(start)) {
      _start = day;
      _end = null;
    } else {
      _end = day;
      _editing = _Edge.start;
    }
  });

  void _select(_Edge edge) => setState(() {
    _editing = edge;
    final day = edge == _Edge.start ? _start : _end ?? _start;
    if (day != null) _focus = DateTime(day.year, day.month, day.day);
  });

  void _applyPreset(DateTimeRange range) => setState(() {
    _start = range.start;
    _end = range.end;
    _editing = _Edge.start;
    _focus = DateTime(range.start.year, range.start.month, range.start.day);
  });

  void _clear() => setState(() {
    _start = null;
    _end = null;
    _editing = _Edge.start;
  });

  String get _hint {
    final start = _start, end = _end;
    if (start == null) return 'Tap a day to set the start';
    if (end == null) return 'Tap the last day, or apply for just one day';
    // UTC keeps a daylight-saving change from shaving off a day.
    final days =
        DateTime.utc(
          end.year,
          end.month,
          end.day,
        ).difference(DateTime.utc(start.year, start.month, start.day)).inDays +
        1;
    return days == 1 ? '1 day' : '$days days';
  }

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final start = _start;
    return SheetPage(
      header: const SheetHeader('Select date range'),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: _EdgeCard(
                  label: 'From',
                  date: _start,
                  active: _editing == _Edge.start,
                  onTap: () => _select(_Edge.start),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Icon(
                  Icons.arrow_forward_rounded,
                  size: 18,
                  color: colors.muted,
                ),
              ),
              Expanded(
                child: _EdgeCard(
                  label: 'To',
                  date: _end,
                  active: _editing == _Edge.end,
                  onTap: () => _select(_Edge.end),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _Swap(
            child: Text(
              _hint,
              key: ValueKey(_hint),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: colors.muted,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final (label, range) in _presets)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: _PresetChip(
                      label: label,
                      selected: _start == range.start && _end == range.end,
                      onTap: () => _applyPreset(range),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          SheetCard(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
              child: CalendarPicker(
                initialDate: _focus,
                selectsRange: true,
                rangeStart: _start,
                rangeEnd: _end,
                onChanged: _pick,
              ),
            ),
          ),
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Clear',
        onSecondary: start == null ? null : _clear,
        primaryLabel: 'Apply',
        onPrimary: start == null
            ? null
            : () => Navigator.pop(
                context,
                DateTimeRange(start: start, end: _end ?? start),
              ),
      ),
    );
  }
}

Duration _motion(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 220);

/// Cross-fades a changing line of text with a slight rise.
class _Swap extends StatelessWidget {
  const _Swap({required this.child, this.alignment = Alignment.center});
  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: _motion(context),
    switchInCurve: Curves.easeOutCubic,
    switchOutCurve: Curves.easeInCubic,
    transitionBuilder: (child, animation) => FadeTransition(
      opacity: animation,
      child: SlideTransition(
        position: animation.drive(
          Tween(begin: const Offset(0, .3), end: Offset.zero),
        ),
        child: child,
      ),
    ),
    layoutBuilder: (current, previous) =>
        Stack(alignment: alignment, children: [...previous, ?current]),
    child: child,
  );
}

/// The From or To card: a caption, the date, and its weekday. The end
/// being set next wears an accent outline and a soft accent glow.
class _EdgeCard extends StatelessWidget {
  const _EdgeCard({
    required this.label,
    required this.date,
    required this.active,
    required this.onTap,
  });
  final String label;
  final DateTime? date;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final motion = _motion(context);
    final date = this.date;
    final radius = BorderRadius.circular(18);
    return AnimatedContainer(
      duration: motion,
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: radius,
        border: Border.all(
          color: active ? colors.primary : colors.primary.withValues(alpha: 0),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: active
                ? colors.primary.withValues(alpha: .16)
                : Colors.black.withValues(alpha: .04),
            blurRadius: active ? 16 : 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: radius,
          child: Semantics(
            selected: active,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 10, 14, 11),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AnimatedDefaultTextStyle(
                    duration: motion,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: .6,
                      color: active ? colors.primary : colors.muted,
                    ),
                    child: Text(label.toUpperCase()),
                  ),
                  const SizedBox(height: 4),
                  _Swap(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      date == null
                          ? 'Select'
                          : DateFormat('d MMM yyyy').format(date),
                      key: ValueKey(date),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: date == null
                            ? colors.muted.withValues(alpha: .7)
                            : colors.text,
                      ),
                    ),
                  ),
                  const SizedBox(height: 2),
                  _Swap(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      date == null ? ' ' : DateFormat.EEEE().format(date),
                      key: ValueKey('weekday-$date'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: colors.muted),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A one-tap range shortcut; it fills in accent while it matches the
/// picked range.
class _PresetChip extends StatelessWidget {
  const _PresetChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final motion = _motion(context);
    return AnimatedContainer(
      duration: motion,
      curve: Curves.easeOutCubic,
      decoration: ShapeDecoration(
        color: selected ? colors.primary : colors.card,
        shape: StadiumBorder(
          side: BorderSide(color: selected ? colors.primary : colors.outline),
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          customBorder: const StadiumBorder(),
          child: Semantics(
            selected: selected,
            button: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              child: AnimatedDefaultTextStyle(
                duration: motion,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: selected ? Colors.white : colors.text,
                ),
                child: Text(label),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
