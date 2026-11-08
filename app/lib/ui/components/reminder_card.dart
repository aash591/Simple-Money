import 'package:flutter/material.dart';

import '../more/debts/debt_widgets.dart';
import '../theme/sheet_colors.dart';
import 'app_icon.dart';
import 'card_action.dart';
import 'common.dart';

/// A payment coming up — an EMI, a renewal, a debt: what it is, what it
/// costs, when it's due, and a clearly still-to-do way to settle it.
///
/// Shared by Home's reminder sections and by the Subscriptions, Loans and
/// Debts screens, so an EMI looks the same wherever it is listed.
///
/// Three states, in order of precedence: [completedLabel] for something
/// finished, [canSettle] false for something that can't be paid yet isn't
/// finished, and otherwise the ordinary due-and-payable card.
class ReminderCard extends StatelessWidget {
  const ReminderCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.amount,
    required this.onTap,
    this.due,
    required this.onMarkPaid,
    this.per,
    this.leading,
    this.actionLabel = 'Mark paid',
    this.status,
    this.gap = appCardGap,
  });

  /// An app icon key; ignored when [leading] is given.
  final String? icon;

  /// Something other than an app icon to lead with — a person's avatar.
  final Widget? leading;

  /// What settling it is called ("Mark paid", "Got paid").
  final String actionLabel;
  final String title, subtitle, amount;

  /// The period [amount] covers ("month"), when it repeats on a cycle.
  final String? per;

  /// When it falls due. Null for something with no date on it at all — an
  /// open debt nobody has agreed a date for — and the chip is left off.
  final DateTime? due;
  final VoidCallback onTap;

  /// Null while a save is in flight, which greys the action rather than
  /// removing it — the card must not jump while a payment is saving.
  final VoidCallback? onMarkPaid;

  /// Where it stands, when there is nothing to pay: a chip takes the
  /// action's place rather than leaving the card offering something that
  /// wouldn't work. [done] tells the two apart — a finished item ("Paid
  /// off", "Settled") is green and tints the whole card, while one that is
  /// merely not payable now ("Paused") stays muted, since it isn't an
  /// achievement.
  final ({String label, bool done})? status;

  /// The space below the card, before the next one.
  final double gap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SheetColors.of(context);
    final done = status?.done ?? false;
    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: MoneyCard(
        padding: EdgeInsets.zero,
        // Finished items sit on a green wash, so a paid-off loan reads as
        // done at a glance instead of looking like one more thing owed.
        color: done
            ? Color.alphaBlend(
                colors.income.withValues(
                  alpha: theme.brightness == Brightness.dark ? .15 : .09,
                ),
                theme.colorScheme.surface,
              )
            : null,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      leading ?? AppIcon(icon, size: 40),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  Icons.chevron_right_rounded,
                                  size: 20,
                                  color: SheetColors.of(context).muted,
                                ),
                              ],
                            ),
                            const SizedBox(height: 2),
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    subtitle,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall,
                                  ),
                                ),
                                const SizedBox(width: 10),
                                ConstrainedBox(
                                  constraints: const BoxConstraints(
                                    maxWidth: 150,
                                  ),
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerRight,
                                    child: Text.rich(
                                      TextSpan(
                                        text: amount,
                                        children: [
                                          if (per != null)
                                            TextSpan(
                                              text: '/$per',
                                              style: theme.textTheme.bodySmall,
                                            ),
                                        ],
                                      ),
                                      maxLines: 1,
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Divider(
                    height: 1,
                    thickness: 1,
                    color: theme.colorScheme.outlineVariant.withValues(
                      alpha: .4,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Flexible(
                        child: due == null
                            ? const SizedBox.shrink()
                            : DueChip(due!, minHeight: 36),
                      ),
                      const SizedBox(width: 10),
                      // The same slot either way: what you can do about it,
                      // or why you can't.
                      if (status case final state?)
                        _StatusChip(
                          state.label,
                          color: done ? colors.income : colors.muted,
                          icon: done
                              ? Icons.check_circle_rounded
                              : Icons.pause_circle_filled_rounded,
                        )
                      else
                        CardAction(
                          label: actionLabel,
                          icon: Icons.chevron_right_rounded,
                          iconAtEnd: true,
                          color: theme.colorScheme.primary,
                          outlined: true,
                          onTap: onMarkPaid,
                        ),
                    ],
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

/// Stands in for the action when there is nothing to do. Built to [DueChip]'s
/// measurements so a card keeps its height when it settles or pauses.
class _StatusChip extends StatelessWidget {
  const _StatusChip(this.label, {required this.color, required this.icon});
  final String label;
  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) => Container(
    constraints: const BoxConstraints(minHeight: 36),
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .14),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: color,
            ),
          ),
        ),
      ],
    ),
  );
}
