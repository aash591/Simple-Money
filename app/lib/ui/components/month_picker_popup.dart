import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_theme.dart' show usesGlass;
import 'date_picker_sheet.dart';
import 'frosted_modal_surface.dart';
import 'popup_zoom.dart';

/// An anchored calendar dropdown: year grid -> month grid -> apply.
/// Dismissing it leaves the original month unchanged.
Future<DateTime?> showMonthPickerPopup(
  BuildContext context, {
  required GlobalKey anchorKey,
  required DateTime initialMonth,
  bool alignRight = false,
}) => _showCalendarPickerPopup(
  context,
  anchorKey: anchorKey,
  initialDate: initialMonth,
  monthOnly: true,
  alignRight: alignRight,
  popupKey: const Key('month-picker-popup'),
);

/// Opens the shared calendar beside a transaction's Date row.
Future<DateTime?> showDatePickerPopup(
  BuildContext context, {
  required GlobalKey anchorKey,
  required DateTime initialDate,
}) => _showCalendarPickerPopup(
  context,
  anchorKey: anchorKey,
  initialDate: initialDate,
  monthOnly: false,
  popupKey: const Key('date-picker-popup'),
);

Future<DateTime?> _showCalendarPickerPopup(
  BuildContext context, {
  required GlobalKey anchorKey,
  required DateTime initialDate,
  required bool monthOnly,
  required Key popupKey,
  bool alignRight = false,
}) {
  final button = anchorKey.currentContext?.findRenderObject() as RenderBox?;
  if (button == null || !button.hasSize) return Future.value();
  final navigator = Navigator.of(context, rootNavigator: true);
  final overlay = navigator.overlay!.context.findRenderObject() as RenderBox;
  final anchor =
      button.localToGlobal(Offset.zero, ancestor: overlay) & button.size;
  final themes = InheritedTheme.capture(from: context, to: navigator.context);
  return navigator.push<DateTime>(
    _PopupRoute<DateTime>(
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      pageBuilder: (context, animation, _) {
        final media = MediaQuery.of(context);
        final safe = Rect.fromLTRB(
          12 + media.padding.left,
          12 + media.padding.top,
          media.size.width - 12 - media.padding.right,
          media.size.height -
              12 -
              math.max(media.padding.bottom, media.viewInsets.bottom),
        );
        return themes.wrap(
          PopupZoom(
            animation: animation,
            layoutBuilder: (scale, child) => CustomSingleChildLayout(
              delegate: _CalendarPosition(
                anchor,
                safe,
                bottomAligned: !monthOnly,
                alignRight: alignRight,
                width: monthOnly ? 280 : 328,
                scale: scale,
              ),
              child: child,
            ),
            child: FrostedModalSurface(
              key: popupKey,
              borderRadius: BorderRadius.circular(22),
              // The plain style has no glass to lift the popup, so its shadow
              // is clearer.
              shadows: [
                BoxShadow(
                  color: Colors.black.withValues(
                    alpha: usesGlass(context) ? .12 : .22,
                  ),
                  blurRadius: usesGlass(context) ? 24 : 32,
                  spreadRadius: usesGlass(context) ? -4 : -2,
                  offset: const Offset(0, 8),
                ),
              ],
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: CalendarPicker(
                  initialDate: initialDate,
                  monthOnly: monthOnly,
                  onChanged: (date) => Navigator.pop(context, date),
                ),
              ),
            ),
          ),
        );
      },
      transitionBuilder: (_, _, _, child) => child,
    ),
  );
}

/// A dialog route timed like the other popups: it eases open and closes
/// quicker than it opened.
class _PopupRoute<T> extends RawDialogRoute<T> with FrostBeforeOpening<T> {
  _PopupRoute({
    required super.pageBuilder,
    super.barrierDismissible,
    super.barrierColor,
    super.barrierLabel,
    super.transitionBuilder,
  }) : super(transitionDuration: PopupZoom.duration);

  @override
  Duration get reverseTransitionDuration => PopupZoom.reverseDuration;
}

class _CalendarPosition extends SingleChildLayoutDelegate {
  _CalendarPosition(
    this.anchor,
    this.safe, {
    required this.bottomAligned,
    this.alignRight = false,
    required this.width,
    required this.scale,
  });
  final double width, scale;
  final bool bottomAligned;
  final bool alignRight;
  final Rect anchor, safe;
  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tightFor(width: math.min(width, safe.width))
          .copyWith(minHeight: 0, maxHeight: safe.height);
  @override
  Offset getPositionForChild(Size size, Size childSize) {
    if (bottomAligned) {
      return Offset(
        safe.center.dx -
            childSize.width / 2 +
            childSize.width / 2 * (1 - scale),
        safe.bottom - childSize.height + childSize.height * (1 - scale),
      );
    }
    final below = anchor.bottom + 8;
    final above = anchor.top - childSize.height - 8;
    final top = below + childSize.height <= safe.bottom
        ? below
        : above >= safe.top
        ? above
        : below.clamp(safe.top, safe.bottom - childSize.height);
    final left = alignRight ? anchor.right - childSize.width : anchor.left;
    final x = left.clamp(safe.left, safe.right - childSize.width);
    // Use the actual laid-out size so the origin follows above/below flips.
    final pivotX = (alignRight ? anchor.right - x : anchor.left - x).clamp(
      0.0,
      childSize.width,
    );
    final pivotY = top < anchor.top ? childSize.height : 0.0;
    return Offset(x + pivotX * (1 - scale), top + pivotY * (1 - scale));
  }

  @override
  bool shouldRelayout(_CalendarPosition old) =>
      old.width != width ||
      old.scale != scale ||
      old.anchor != anchor ||
      old.safe != safe ||
      old.bottomAligned != bottomAligned ||
      old.alignRight != alignRight;
}
