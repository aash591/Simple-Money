import 'package:flutter/material.dart';

import '../../theme/app_typography.dart';

/// The checkbox and icon, with their padding: where a tap selects the row.
const _selectZone = 4.0 + 40 + 40 + 8;

/// One money movement in a list: icon, title, subtitle, amount and when.
///
/// Knows nothing about where the movement came from, so saved transactions,
/// SMS waiting for review and statement rows all look the same. A non-null
/// [selected] adds a checkbox in front, for lists the user picks from.
class TransactionRow extends StatelessWidget {
  const TransactionRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.amountColor,
    required this.stamp,
    this.onTap,
    this.onLongPress,
    this.subtitleColor,
    this.selected,
    this.onSelected,
    this.dimmed = false,
  });

  /// Drawn in a 40×40 box.
  final Widget icon;
  final String title, subtitle, amount, stamp;
  final Color amountColor;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// For a subtitle that needs action, such as a missing account.
  final Color? subtitleColor;

  /// Shows a checkbox when non-null; a null [onSelected] disables it.
  final bool? selected;
  final ValueChanged<bool>? onSelected;

  /// Already done or unavailable: faded and not tappable.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mutedStyle = AppTypography.caption.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final selected = this.selected;
    final row = Padding(
      padding: EdgeInsets.fromLTRB(selected == null ? 16 : 4, 16, 16, 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              constraints.maxWidth < 280 ||
              MediaQuery.textScalerOf(context).scale(16) > 21;
          final identity = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                maxLines: stacked ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: AppTypography.body.copyWith(
                  fontWeight: FontWeight.w600,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                maxLines: stacked ? 2 : 1,
                overflow: TextOverflow.ellipsis,
                style: subtitleColor == null
                    ? mutedStyle
                    : mutedStyle.copyWith(color: subtitleColor),
              ),
            ],
          );
          final details = Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                amount,
                textAlign: TextAlign.end,
                style: AppTypography.rowAmount.copyWith(color: amountColor),
              ),
              const SizedBox(height: 4),
              Text(stamp, style: mutedStyle),
            ],
          );
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (selected != null)
                SizedBox(
                  width: 40,
                  height: 40,
                  child: Checkbox(
                    value: selected,
                    onChanged: onSelected == null
                        ? null
                        : (value) => onSelected!(value ?? false),
                  ),
                ),
              SizedBox.square(dimension: 40, child: icon),
              const SizedBox(width: 12),
              Expanded(
                child: stacked
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          identity,
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.centerRight,
                            child: details,
                          ),
                        ],
                      )
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 5, child: identity),
                          const SizedBox(width: 12),
                          Expanded(flex: 4, child: details),
                        ],
                      ),
              ),
            ],
          );
        },
      ),
    );
    // While picking, a tap on the checkbox or icon selects the row and a tap
    // anywhere else does [onTap] (open it); the ripple is the whole row's
    // either way, so where the tap landed decides which one runs.
    final picking = selected != null && onSelected != null;
    var inSelectZone = false;
    return Opacity(
      opacity: dimmed ? .55 : 1,
      child: InkWell(
        onTapDown: (details) =>
            inSelectZone = picking && details.localPosition.dx < _selectZone,
        onTap: dimmed
            ? null
            : () {
                if (inSelectZone) {
                  onSelected!(!selected!);
                } else {
                  onTap?.call();
                }
              },
        onLongPress: dimmed ? null : onLongPress,
        child: Semantics(
          button: onTap != null && !dimmed,
          label: '$title, $subtitle, $amount, $stamp',
          child: row,
        ),
      ),
    );
  }
}
