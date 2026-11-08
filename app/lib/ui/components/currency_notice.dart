import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../domain/currency_scope.dart';

/// Warns when a combined total cannot be fully trusted — a currency had no
/// rate, or the rates behind it are old or missing entirely.
///
/// Silent when the conversion is sound. Several cards can be combining
/// currencies on one screen, and repeating "estimates at current rates" under
/// each of them buries the one case that genuinely needs attention. The `≈`
/// in front of a converted figure already says it is an estimate, and the
/// rate date stays one tap away on the totals it belongs to.
class CurrencyNotice extends StatelessWidget {
  const CurrencyNotice({
    super.key,
    required this.scope,
    this.missing = const {},
  });
  final CurrencyScope scope;

  /// Currency codes left out of the total because no rate was available.
  final Set<String> missing;

  /// How old a rate table may get before it is called out, in days.
  static const staleAfterDays = 7;

  static bool isStale(DateTime? date) =>
      date != null &&
      DateTime.now().toUtc().difference(date).inDays > staleAfterDays;

  @override
  Widget build(BuildContext context) {
    if (scope is! CombinedCurrency) return const SizedBox.shrink();
    final date = (scope as CombinedCurrency).rateDate;
    final codes = missing.toList()..sort();
    final stale = isStale(date);
    final message = [
      if (codes.isNotEmpty) 'Incomplete · Excludes ${codes.join(', ')}',
      if (date == null)
        'Rates not available'
      else if (stale)
        'Rates from ${DateFormat.yMMMd().format(date)} · '
            'more than $staleAfterDays days old',
    ].join(' · ');
    if (message.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    // Excluded money is a wrong number on screen; a stale rate is only a
    // slightly wrong one. Only the first earns the error colour.
    final serious = codes.isNotEmpty || date == null;
    final accent = serious ? colors.error : colors.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Semantics(
        liveRegion: serious,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: accent.withValues(alpha: serious ? .08 : .05),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                serious ? Icons.warning_amber_rounded : Icons.schedule_rounded,
                size: 16,
                color: accent,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: accent,
                    fontWeight: serious ? FontWeight.w600 : null,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The quiet "as of" line for a healthy combined total: no warning styling,
/// just the date the rates came from. Silent for a single-currency scope.
class CurrencyRateDate extends StatelessWidget {
  const CurrencyRateDate({
    super.key,
    required this.scope,
    this.label = 'Rates',
  });
  final CurrencyScope scope;

  /// What precedes the date, e.g. "Rates 17 Sep 2026".
  final String label;

  @override
  Widget build(BuildContext context) {
    final date = scope is CombinedCurrency
        ? (scope as CombinedCurrency).rateDate
        : null;
    if (date == null || CurrencyNotice.isStale(date)) {
      return const SizedBox.shrink();
    }
    return Text(
      '$label ${DateFormat.yMMMd().format(date)}',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
