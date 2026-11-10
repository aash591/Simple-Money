import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/category.dart';
import '../../../domain/recurring_payment.dart';
import '../../components/app_icon.dart';
import '../../theme/app_theme.dart';

/// A suggested recurring payment as it would look once approved: its icon and
/// name, how often and from which account, the amount (green with a plus when
/// it is money coming in), and when it is next due.
class RecurringSuggestionPreview extends StatelessWidget {
  const RecurringSuggestionPreview({
    super.key,
    required this.payload,
    required this.account,
    required this.category,
  });
  final Map<String, Object?> payload;

  /// The account it is paid from or into; null when accounts couldn't be loaded.
  final Account? account;

  /// Its category, when one was chosen and could be found.
  final Category? category;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final incoming = payload['incoming'] == true;
    final cycle = BillingCycleLabels.fromStorage(payload['cycle'] as String);
    final due = DateTime.parse(payload['nextDue'] as String);
    final minor = payload['amount'] as int;
    final amount = account == null
        ? '${incoming ? '+' : ''}$minor'
        : '${incoming ? '+' : ''}${formatAccountMoney(minor, digits: account!.digits, currency: account!.currency)}';
    final accent = incoming ? green : scheme.onSurface;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              AppIcon(payload['icon'] as String?, size: 44),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      payload['name'] as String,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(cycle.label, style: theme.textTheme.bodySmall),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 130),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    amount,
                    style: theme.textTheme.titleMedium?.copyWith(
                      color: accent,
                      fontWeight: FontWeight.w700,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              _Chip(
                icon: incoming
                    ? Icons.south_west_rounded
                    : Icons.north_east_rounded,
                label: incoming ? 'Money coming in' : 'Money going out',
                color: incoming ? green : scheme.onSurfaceVariant,
              ),
              _Chip(
                icon: Icons.event_rounded,
                label: 'Next ${DateFormat('d MMM yyyy').format(due)}',
              ),
              if (account != null)
                _Chip(
                  icon: Icons.account_balance_wallet_outlined,
                  label: account!.name,
                ),
              if (category != null)
                _Chip(icon: Icons.label_outline_rounded, label: category!.name),
            ],
          ),
        ],
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.icon, required this.label, this.color});
  final IconData icon;
  final String label;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = color ?? theme.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: tint.withValues(alpha: .12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: tint),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(color: tint),
            ),
          ),
        ],
      ),
    );
  }
}
