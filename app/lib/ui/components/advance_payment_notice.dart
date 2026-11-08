import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

bool isFuturePayment(DateTime due, {DateTime? now}) {
  final today = now ?? DateTime.now();
  return DateTime(
    due.year,
    due.month,
    due.day,
  ).isAfter(DateTime(today.year, today.month, today.day));
}

/// Makes paying another, future cycle a deliberate choice each time.
class AdvancePaymentNotice extends StatelessWidget {
  const AdvancePaymentNotice({
    super.key,
    required this.due,
    required this.payment,
    required this.accepted,
    required this.onChanged,
  });

  final DateTime due;
  final String payment;
  final bool accepted;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 8),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                Icons.schedule_rounded,
                size: 20,
                color: scheme.onTertiaryContainer,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  'Future payment',
                  style: theme.textTheme.titleMedium?.copyWith(
                    color: scheme.onTertiaryContainer,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '$payment is due ${DateFormat('d MMM yyyy').format(due)}. '
            'This moves the schedule forward.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: scheme.onTertiaryContainer,
            ),
          ),
          Material(
            color: Colors.transparent,
            child: CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              visualDensity: VisualDensity.compact,
              controlAffinity: ListTileControlAffinity.leading,
              value: accepted,
              onChanged: onChanged == null
                  ? null
                  : (value) => onChanged!(value!),
              title: Text(
                "I've already paid it",
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: scheme.onTertiaryContainer,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
