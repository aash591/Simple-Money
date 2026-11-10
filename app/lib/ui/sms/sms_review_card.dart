import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/sms_import_repository.dart';
import '../../state/sms_import_store.dart';
import '../components/action_buttons.dart';
import '../theme/app_theme.dart';
import 'sms_pending_card.dart';

/// Home's card for bank messages the app could not finish on its own: they
/// need a category or an account from you. It lists the first few so one tap
/// starts sorting them, and is not shown at all once nothing is waiting.
class SmsReviewCard extends StatelessWidget {
  const SmsReviewCard({
    super.key,
    required this.store,
    required this.onOpen,
    required this.onReview,
    required this.onScan,
    this.unlinked = 0,
  });
  final SmsImportStore store;

  /// Opens the whole list.
  final VoidCallback onOpen;

  /// Starts a fresh scan of the inbox.
  final VoidCallback onScan;

  /// Opens one message.
  final ValueChanged<PendingSmsImport> onReview;

  /// Banks whose messages carry no account number to match.
  final int unlinked;

  static const title = 'Needs your review';
  static const previewRows = 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final number = NumberFormat.decimalPattern();
    final waiting = store.pendingCount;
    final rows = store.pending.take(previewRows).toList();
    final subtitle = waiting > 0
        ? '${number.format(waiting)} bank '
              '${waiting == 1 ? 'message needs' : 'messages need'} a category'
        : '${number.format(unlinked)} '
              '${unlinked == 1 ? 'bank needs' : 'banks need'} an account';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: orange.withValues(alpha: .14),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Icon(
                Icons.mark_chat_unread_outlined,
                size: 22,
                color: orange,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        if (rows.isNotEmpty) ...[
          const SizedBox(height: 6),
          for (final sms in rows)
            SmsCompactTile(sms: sms, onTap: () => onReview(sms)),
        ],
        if (waiting > 0 && unlinked > 0) ...[
          const SizedBox(height: 4),
          Text(
            '${number.format(unlinked)} '
            '${unlinked == 1 ? 'bank also needs' : 'banks also need'} an '
            'account',
            style: theme.textTheme.bodySmall?.copyWith(color: orange),
          ),
        ],
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              flex: 2,
              child: PillButton(
                primary: false,
                onPressed: store.busy ? null : onScan,
                label: 'Scan',
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              flex: 3,
              child: PillButton(
                onPressed: store.busy ? null : onOpen,
                label: waiting > 0
                    ? 'Review ${number.format(waiting)}'
                    : 'Review',
              ),
            ),
          ],
        ),
      ],
    );
  }
}
