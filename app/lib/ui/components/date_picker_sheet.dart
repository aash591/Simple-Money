import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../theme/sheet_colors.dart';
import 'adaptive_sheet.dart';

/// The calendar sheet for a transaction's date: month and year buttons,
/// weekday headings, and a swipeable grid of days. Tapping the
/// month or year swaps in a month or year grid to jump further; tapping a
/// day applies it and closes straight away. "Today" is a one-tap shortcut.
/// Returns the picked day at midnight.
Future<DateTime?> showDatePickerSheet(
  BuildContext context, {
  required DateTime initialDate,
}) => showAdaptiveSheet<DateTime>(
  context,
  builder: (_) => DatePickerSheet(initialDate: initialDate),
);

/// The transaction sheet and Home popup share the same calendar grids.
class DatePickerSheet extends StatelessWidget {
  const DatePickerSheet({super.key, required this.initialDate});
  final DateTime initialDate;
  @override
  Widget build(BuildContext context) => SheetPage(
    header: const SheetHeader('Select date'),
    body: CalendarPicker(
      initialDate: initialDate,
      onChanged: (date) => Navigator.pop(context, date),
    ),
  );
}

class CalendarPicker extends StatefulWidget {
  const CalendarPicker({
    super.key,
    required this.initialDate,
    required this.onChanged,
    this.monthOnly = false,
    this.selectsRange = false,
    this.rangeStart,
    this.rangeEnd,
  });

  /// The day (or month) shown first. Handing over a new object later moves
  /// the calendar back to its month, so an owner can steer it.
  final DateTime initialDate;
  final ValueChanged<DateTime> onChanged;
  final bool monthOnly;

  /// Range mode: the days from [rangeStart] to [rangeEnd] are drawn as one
  /// band, every tapped day is reported through [onChanged] for the owner
  /// to place, and the Today shortcut is left out.
  final bool selectsRange;
  final DateTime? rangeStart, rangeEnd;
  @override
  State<CalendarPicker> createState() => _CalendarPickerState();
}

enum _CalendarView { day, month, year }

const _weekdayLabels = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];

class _CalendarPickerState extends State<CalendarPicker> {
  DateTime get _selected =>
      DateUtils.dateOnly(widget.rangeStart ?? widget.initialDate);
  late DateTime _visibleMonth = DateTime(
    widget.initialDate.year,
    widget.initialDate.month,
  );
  late _CalendarView _view = _homeView;

  _CalendarView get _homeView =>
      widget.monthOnly ? _CalendarView.month : _CalendarView.day;

  @override
  void didUpdateWidget(covariant CalendarPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Identity, not equality: re-sending the same day (tapping "From" again
    // after swiping away) should still bring its month back.
    if (!identical(widget.initialDate, oldWidget.initialDate)) {
      _visibleMonth = DateTime(
        widget.initialDate.year,
        widget.initialDate.month,
      );
      _view = _homeView;
    }
  }

  /// Opens [view]'s grid, or returns to days if it is already open.
  void _toggle(_CalendarView view) => setState(() {
    _view = _view == view ? _homeView : view;
  });

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final today = DateUtils.dateOnly(DateTime.now());
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Row(
                mainAxisAlignment: widget.monthOnly
                    ? MainAxisAlignment.center
                    : MainAxisAlignment.start,
                children: [
                  Flexible(
                    child: _PeriodButton(
                      label:
                          (widget.monthOnly
                                  ? DateFormat.MMM()
                                  : DateFormat.MMMM())
                              .format(_visibleMonth),
                      active: _view == _CalendarView.month,
                      onTap: () => _toggle(_CalendarView.month),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: _PeriodButton(
                      label: '${_visibleMonth.year}',
                      active: _view == _CalendarView.year,
                      onTap: () => _toggle(_CalendarView.year),
                    ),
                  ),
                ],
              ),
            ),
            if (!widget.selectsRange && !widget.monthOnly)
              TextButton(
                style: TextButton.styleFrom(
                  foregroundColor: colors.primary,
                  backgroundColor: colors.primary.withValues(alpha: .05),
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  shape: const StadiumBorder(),
                  textStyle: Theme.of(context).textTheme.labelMedium
                      ?.copyWith(fontSize: 12, fontWeight: FontWeight.w500),
                ),
                onPressed: () => widget.onChanged(
                  widget.monthOnly ? DateTime(today.year, today.month) : today,
                ),
                child: const Text('Today'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        AnimatedSize(
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 280),
          curve: Curves.easeInOutCubic,
          alignment: Alignment.topCenter,
          child: AnimatedSwitcher(
            duration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 280),
            switchInCurve: Curves.easeInOutCubic,
            reverseDuration: MediaQuery.disableAnimationsOf(context)
                ? Duration.zero
                : const Duration(milliseconds: 280),
            switchOutCurve: Curves.easeInOutCubic,
            transitionBuilder: (child, animation) =>
                FadeTransition(opacity: animation, child: child),
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [
                for (final child in previous)
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: IgnorePointer(child: ExcludeSemantics(child: child)),
                  ),
                ?current,
              ],
            ),
            child: Column(
              key: ValueKey(_view),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                switch (_view) {
                  _CalendarView.day => _DayGridPager(
                    visibleMonth: _visibleMonth,
                    selected: _selected,
                    today: today,
                    selectsRange: widget.selectsRange,
                    rangeStart: widget.rangeStart,
                    rangeEnd: widget.rangeEnd,
                    onPick: widget.onChanged,
                    onPageChanged: (month) =>
                        setState(() => _visibleMonth = month),
                  ),
                  _CalendarView.month => _ChoiceGrid(
                    key: const Key('month-grid'),
                    count: 12,
                    label: (i) =>
                        DateFormat('MMM').format(DateTime(2000, i + 1)),
                    isSelected: (i) =>
                        _visibleMonth.year == _selected.year &&
                        i + 1 == _selected.month,
                    isCurrent: (i) =>
                        _visibleMonth.year == today.year &&
                        i + 1 == today.month,
                    onPick: (i) {
                      final picked = DateTime(_visibleMonth.year, i + 1);
                      if (widget.monthOnly) {
                        widget.onChanged(picked);
                      } else {
                        setState(() {
                          _visibleMonth = picked;
                          _view = _CalendarView.day;
                        });
                      }
                    },
                  ),
                  _CalendarView.year => _YearGridPager(
                    initialYear: _visibleMonth.year,
                    selectedYear: _selected.year,
                    currentYear: today.year,
                    onPick: (year) => setState(() {
                      _visibleMonth = DateTime(year, _visibleMonth.month);
                      _view = _CalendarView.month;
                    }),
                  ),
                },
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// A real pager lets the year grid follow the finger in either direction.
class _YearGridPager extends StatefulWidget {
  const _YearGridPager({
    required this.initialYear,
    required this.selectedYear,
    required this.currentYear,
    required this.onPick,
  });
  final int initialYear, selectedYear, currentYear;
  final ValueChanged<int> onPick;
  @override
  State<_YearGridPager> createState() => _YearGridPagerState();
}

class _YearGridPagerState extends State<_YearGridPager> {
  static const _pageCount = 834;
  late final _controller = PageController(
    initialPage: (widget.initialYear - 1) ~/ 12,
  );
  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 208,
    child: PageView.builder(
      key: const Key('year-grid-pager'),
      controller: _controller,
      itemCount: _pageCount,
      itemBuilder: (context, page) {
        final start = page * 12 + 1;
        return _ChoiceGrid(
          count: (10000 - start).clamp(0, 12),
          label: (i) => '${start + i}',
          isSelected: (i) => start + i == widget.selectedYear,
          isCurrent: (i) => start + i == widget.currentYear,
          onPick: (i) => widget.onPick(start + i),
        );
      },
    ),
  );
}

class _PeriodButton extends StatelessWidget {
  const _PeriodButton({
    required this.label,
    required this.active,
    required this.onTap,
  });
  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final foreground = colors.text;
    return Material(
      color: colors.control,
      shape: const StadiumBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: foreground,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                active
                    ? Icons.keyboard_arrow_up_rounded
                    : Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: colors.primary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DayGridPager extends StatefulWidget {
  const _DayGridPager({
    required this.visibleMonth,
    required this.selected,
    required this.today,
    required this.onPick,
    required this.onPageChanged,
    this.selectsRange = false,
    this.rangeStart,
    this.rangeEnd,
  });
  final DateTime visibleMonth, selected, today;
  final ValueChanged<DateTime> onPick, onPageChanged;
  final bool selectsRange;
  final DateTime? rangeStart, rangeEnd;

  @override
  State<_DayGridPager> createState() => _DayGridPagerState();
}

class _DayGridPagerState extends State<_DayGridPager> {
  static int _index(DateTime date) => (date.year - 1) * 12 + date.month - 1;
  late final _controller = PageController(
    initialPage: _index(widget.visibleMonth),
  );

  @override
  void didUpdateWidget(covariant _DayGridPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    final target = _index(widget.visibleMonth);
    if (_controller.hasClients && _controller.page!.round() != target) {
      if (MediaQuery.disableAnimationsOf(context)) {
        _controller.jumpToPage(target);
      } else {
        _controller.animateToPage(
          target,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeInOutCubic,
        );
      }
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
    // Reserve only the rows used by the visible month.
    height:
        32 +
        ((DateTime(
                          widget.visibleMonth.year,
                          widget.visibleMonth.month,
                        ).weekday %
                        7 +
                    DateUtils.getDaysInMonth(
                      widget.visibleMonth.year,
                      widget.visibleMonth.month,
                    ) +
                    6) ~/
                7) *
            44.0,
    child: PageView.builder(
      key: const Key('day-grid-pager'),
      controller: _controller,
      itemCount: 9999 * 12,
      onPageChanged: (page) =>
          widget.onPageChanged(DateTime(page ~/ 12 + 1, page % 12 + 1)),
      itemBuilder: (context, page) => SingleChildScrollView(
        physics: const NeverScrollableScrollPhysics(),
        child: _DayGrid(
          visibleMonth: DateTime(page ~/ 12 + 1, page % 12 + 1),
          selected: widget.selected,
          today: widget.today,
          selectsRange: widget.selectsRange,
          rangeStart: widget.rangeStart,
          rangeEnd: widget.rangeEnd,
          onPick: widget.onPick,
        ),
      ),
    ),
  );
}

class _DayGrid extends StatelessWidget {
  const _DayGrid({
    required this.visibleMonth,
    required this.selected,
    required this.today,
    required this.onPick,
    this.selectsRange = false,
    this.rangeStart,
    this.rangeEnd,
  });
  final DateTime visibleMonth;
  final DateTime selected;
  final DateTime today;
  final ValueChanged<DateTime> onPick;
  final bool selectsRange;
  final DateTime? rangeStart, rangeEnd;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final firstOfMonth = DateTime(visibleMonth.year, visibleMonth.month);
    final daysInMonth = DateUtils.getDaysInMonth(
      visibleMonth.year,
      visibleMonth.month,
    );
    final leading = firstOfMonth.weekday % 7; // Sunday-first columns.
    final cells = ((leading + daysInMonth) / 7).ceil() * 7;
    return Column(
      children: [
        Row(
          children: [
            for (final label in _weekdayLabels)
              Expanded(
                child: SizedBox(
                  height: 32,
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: colors.muted,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        GridView.builder(
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            mainAxisExtent: 44,
          ),
          itemCount: cells,
          itemBuilder: (context, index) {
            final date = DateTime(
              visibleMonth.year,
              visibleMonth.month,
              index - leading + 1,
            );
            if (date.month != visibleMonth.month) {
              return const SizedBox.shrink();
            }
            if (selectsRange) {
              return _RangeDay(
                date: date,
                start: rangeStart,
                end: rangeEnd,
                today: today,
                column: index % 7,
                daysInMonth: daysInMonth,
                onTap: () => onPick(date),
              );
            }
            return Center(
              child: SizedBox.square(
                dimension: 40,
                child: _Cell(
                  label: '${date.day}',
                  semanticLabel: DateFormat.yMMMMd().format(date),
                  circle: true,
                  selected: DateUtils.isSameDay(date, selected),
                  current: DateUtils.isSameDay(date, today),
                  muted: date.month != visibleMonth.month,
                  onTap: () => onPick(date),
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}

/// A day in range mode. The span between the two ends is a soft band that
/// rounds off at the start and end of each week row (and of the month);
/// the ends themselves are solid circles that pop in when placed.
class _RangeDay extends StatelessWidget {
  const _RangeDay({
    required this.date,
    required this.start,
    required this.end,
    required this.today,
    required this.column,
    required this.daysInMonth,
    required this.onTap,
  });
  final DateTime date, today;
  final DateTime? start, end;
  final int column, daysInMonth;
  final VoidCallback onTap;

  static const _round = Radius.circular(20);

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    final motion = reduceMotion
        ? Duration.zero
        : const Duration(milliseconds: 280);
    final start = this.start, end = this.end;
    final isStart = start != null && DateUtils.isSameDay(date, start);
    final isEnd = end != null && DateUtils.isSameDay(date, end);
    final spans = start != null && end != null && end.isAfter(start);
    final inside = spans && !date.isBefore(start) && !date.isAfter(end);
    final endpoint = isStart || isEnd;
    final band = colors.primary.withValues(alpha: .13);

    Widget half({required bool on, required bool left}) {
      final edge = left
          ? column == 0 || date.day == 1
          : column == 6 || date.day == daysInMonth;
      return Expanded(
        child: AnimatedContainer(
          duration: motion,
          curve: Curves.easeOutCubic,
          decoration: BoxDecoration(
            color: on ? band : band.withValues(alpha: 0),
            borderRadius: !edge
                ? BorderRadius.zero
                : left
                ? const BorderRadius.horizontal(left: _round)
                : const BorderRadius.horizontal(right: _round),
          ),
        ),
      );
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        Positioned.fill(
          top: 2,
          bottom: 2,
          child: Row(
            children: [
              half(on: inside && !isStart, left: true),
              half(on: inside && !isEnd, left: false),
            ],
          ),
        ),
        SizedBox.square(
          dimension: 40,
          child: TweenAnimationBuilder<double>(
            key: ValueKey(endpoint),
            tween: Tween(begin: endpoint && !reduceMotion ? .72 : 1, end: 1),
            duration: const Duration(milliseconds: 320),
            curve: Curves.easeOutBack,
            builder: (context, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: _Cell(
              label: '${date.day}',
              semanticLabel: DateFormat.yMMMMd().format(date),
              circle: true,
              selected: endpoint,
              inRange: inside && !endpoint,
              current: !inside && !endpoint && DateUtils.isSameDay(date, today),
              onTap: onTap,
            ),
          ),
        ),
      ],
    );
  }
}

/// The 3-column month or year grid.
class _ChoiceGrid extends StatelessWidget {
  const _ChoiceGrid({
    super.key,
    required this.count,
    required this.label,
    required this.isSelected,
    required this.isCurrent,
    required this.onPick,
  });
  final int count;
  final String Function(int index) label;
  final bool Function(int index) isSelected;
  final bool Function(int index) isCurrent;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) => GridView.builder(
    shrinkWrap: true,
    padding: EdgeInsets.zero,
    physics: const NeverScrollableScrollPhysics(),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 3,
      mainAxisExtent: 52,
    ),
    itemCount: count,
    itemBuilder: (context, index) => Padding(
      padding: const EdgeInsets.all(4),
      child: _Cell(
        label: label(index),
        circle: false,
        selected: isSelected(index),
        current: isCurrent(index),
        onTap: () => onPick(index),
      ),
    ),
  );
}

/// A calendar cell: solid blue when selected, a lighter blue for today
/// (or the current month/year), blue text inside a picked range, faded
/// when outside the visible month.
class _Cell extends StatelessWidget {
  const _Cell({
    required this.label,
    required this.circle,
    required this.selected,
    required this.current,
    required this.onTap,
    this.muted = false,
    this.inRange = false,
    this.semanticLabel,
  });
  final String label;
  final bool circle, selected, current, muted, inRange;
  final VoidCallback onTap;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final background = selected
        ? colors.primary
        : current
        ? colors.primary.withValues(alpha: .12)
        : !circle
        ? colors.control
        : Colors.transparent;
    final foreground = selected
        ? Colors.white
        : current || inRange
        ? colors.primary
        : muted
        ? colors.muted.withValues(alpha: .5)
        : colors.text;
    return Semantics(
      selected: selected || inRange,
      button: true,
      child: Material(
        color: background,
        shape: circle
            ? const CircleBorder()
            : RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Center(
            child: Text(
              label,
              semanticsLabel: semanticLabel,
              style: TextStyle(
                fontSize: 15,
                fontWeight: selected || current
                    ? FontWeight.w700
                    : inRange
                    ? FontWeight.w600
                    : FontWeight.w500,
                color: foreground,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
