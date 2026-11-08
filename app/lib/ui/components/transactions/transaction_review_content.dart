import 'package:flutter/material.dart';

import '../../theme/sheet_colors.dart';
import '../adaptive_sheet.dart';
import '../segmented_pill.dart';

/// One way a review sheet can record a transaction, for its "Record as"
/// switch.
class ReviewKind<T extends Object> {
  const ReviewKind(this.value, this.label, this.icon);
  final T value;
  final String label;
  final IconData icon;
}

/// The body of a review sheet: what kind of movement this is, its amount,
/// title and date, a "Record as" switch, the tappable choices, and the text
/// it came from. Shared by SMS review, statement rows and editing a saved
/// transaction, so all three read the same.
///
/// Amount, title and date become tappable when given a callback.
class TransactionReviewContent<T extends Object> extends StatelessWidget {
  const TransactionReviewContent({
    super.key,
    required this.badge,
    required this.color,
    required this.badgeIcon,
    required this.amount,
    required this.title,
    required this.date,
    required this.kinds,
    required this.kind,
    required this.onKindChanged,
    required this.rows,
    this.onEditAmount,
    this.onEditTitle,
    this.onEditDate,
    this.helper,
    this.notice,
    this.sourceHeading = 'Original message',
    this.sourceIcon = Icons.sms_outlined,
    this.sourceDetail,
    this.sourceText,
    this.error,
  });

  /// "Money paid", "Money received", "Credit card repayment"…
  final String badge;
  final Color color;
  final IconData badgeIcon;
  final String amount, title, date;
  final VoidCallback? onEditAmount, onEditTitle, onEditDate;

  /// The "Record as" choices; one choice hides the switch.
  final List<ReviewKind<T>> kinds;
  final T kind;

  /// Null disables the switch.
  final ValueChanged<T>? onKindChanged;

  /// A note under the switch, only when the choice needs explaining.
  final String? helper;

  /// Shown above the choices, such as which loan owns this transaction.
  final Widget? notice;

  /// The tappable choice rows, already separated by dividers.
  final List<Widget> rows;

  /// The text the transaction was read from; hidden when empty.
  final String sourceHeading;
  final IconData sourceIcon;
  final String? sourceDetail, sourceText;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final text = sourceText?.trim() ?? '';
    Widget editable(Widget child, VoidCallback? onTap, String label) =>
        onTap == null
        ? child
        : Semantics(
            button: true,
            label: 'Edit $label',
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: child,
              ),
            ),
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: .10),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(badgeIcon, size: 14, color: color),
                const SizedBox(width: 5),
                Text(
                  badge,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: editable(
            Text(
              amount,
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                color: colors.text,
                fontSize: 34,
                fontWeight: FontWeight.w700,
                letterSpacing: -1,
              ),
              textAlign: TextAlign.center,
            ),
            onEditAmount,
            'amount',
          ),
        ),
        Center(
          child: editable(
            Text(
              title,
              style: TextStyle(
                color: colors.text,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            onEditTitle,
            'title',
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: editable(
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.schedule_rounded, size: 13, color: colors.muted),
                const SizedBox(width: 5),
                Flexible(
                  child: Text(
                    date,
                    style: TextStyle(color: colors.muted, fontSize: 12),
                  ),
                ),
              ],
            ),
            onEditDate,
            'date',
          ),
        ),
        if (notice != null) ...[const SizedBox(height: 12), notice!],
        if (kinds.length > 1) ...[
          const SizedBox(height: 14),
          Text(
            'Record as',
            style: TextStyle(color: colors.text, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SegmentedPill<T>(
            segments: [
              for (final kind in kinds)
                PillSegment(kind.value, kind.label, icon: kind.icon),
            ],
            value: kind,
            onChanged: onKindChanged,
          ),
        ],
        if (helper != null) ...[
          const SizedBox(height: 8),
          Text(helper!, style: TextStyle(color: colors.muted, fontSize: 13)),
        ],
        const SizedBox(height: 10),
        SheetCard(child: Column(children: rows)),
        if (text.isNotEmpty) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(sourceIcon, size: 16, color: colors.muted),
              const SizedBox(width: 6),
              Text(
                sourceHeading,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  sourceDetail ?? '',
                  style: TextStyle(color: colors.muted, fontSize: 12),
                  textAlign: TextAlign.end,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors.control,
              borderRadius: BorderRadius.circular(14),
            ),
            child: SelectableText(
              text,
              style: TextStyle(color: colors.muted, fontSize: 13, height: 1.4),
            ),
          ),
        ],
        if (error != null)
          Text(error!, style: TextStyle(color: colors.expense)),
      ],
    );
  }
}

/// One choice row of a review card. A [locked] row shows a lock where the
/// chevron would be and can't be tapped.
class ReviewChoiceRow extends StatelessWidget {
  const ReviewChoiceRow({
    super.key,
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
    this.detail,
    this.locked = false,
  });

  final String label;
  final String value;
  final String? detail;
  final Widget icon;
  final VoidCallback? onTap;
  final bool locked;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 14),
      minVerticalPadding: 6,
      leading: SizedBox(width: 36, height: 40, child: Center(child: icon)),
      title: Text(label, style: TextStyle(color: colors.muted, fontSize: 12)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: TextStyle(
              color: colors.text,
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (detail != null)
            Text(detail!, style: TextStyle(color: colors.muted, fontSize: 12)),
        ],
      ),
      trailing: Icon(
        locked ? Icons.lock_outline_rounded : Icons.chevron_right_rounded,
        color: colors.muted,
        size: locked ? 16 : 20,
      ),
      onTap: locked ? null : onTap,
    );
  }
}
