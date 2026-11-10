import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/recurring_payment.dart';
import '../../../state/recurring_payment_store.dart';
import '../../components/feature_page.dart';
import '../../more/recurring/mark_paid_sheet.dart';
import '../../more/recurring/recurring_payment_detail_screen.dart';
import '../../more/recurring/recurring_payments_screen.dart';
import '../../theme/surface_style.dart';
import 'reminder_card.dart';

/// Recurring payments renewing this week. Paused ones and those with reminders
/// turned off stay out of the way.
class UpcomingPaymentsCard extends StatelessWidget {
  const UpcomingPaymentsCard({super.key, required this.store});
  final RecurringPaymentStore store;

  @override
  Widget build(BuildContext context) => ReminderSection(
    title: 'Upcoming payments',
    listenable: store,
    onResume: store.load,
    viewAllLabel: (count) => 'View all $count due payments',
    onViewAll: () => Navigator.push(
      context,
      FeatureRoute<void>(RecurringPaymentsScreen(store: store)),
    ),
    cards: (context) {
      final horizon = ReminderSection.horizon;
      final due =
          store.recurringPayments
              .where(
                (s) => !s.paused && s.remind && s.nextDue.isBefore(horizon),
              )
              .toList()
            ..sort((a, b) => a.nextDue.compareTo(b.nextDue));
      return [for (final s in due) _card(context, s)];
    },
  );

  Widget _card(BuildContext context, RecurringPayment s) {
    return ReminderCard(
      gap: homeCardGap,
      icon: s.icon,
      title: s.name,
      subtitle: s.cycle.label,
      amount:
          '${s.incoming ? '+' : ''}${formatAccountMoney(s.amountMinor, digits: s.digits, currency: s.currency)}',
      actionLabel: s.incoming ? 'Mark received' : 'Mark paid',
      due: s.nextDue,
      onTap: () => Navigator.push(
        context,
        FeatureRoute<void>(
          RecurringPaymentDetailScreen(store: store, id: s.id),
        ),
      ),
      onMarkPaid: store.saving
          ? null
          : () => showMarkPaidSheet(context, store: store, recurringPayment: s),
    );
  }
}
