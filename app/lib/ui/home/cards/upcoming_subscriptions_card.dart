import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/subscription.dart';
import '../../../state/subscription_store.dart';
import '../../components/feature_page.dart';
import '../../more/subscriptions/mark_paid_sheet.dart';
import '../../more/subscriptions/subscription_detail_screen.dart';
import '../../more/subscriptions/subscriptions_screen.dart';
import '../../theme/surface_style.dart';
import 'reminder_card.dart';

/// Subscriptions renewing this week. Paused ones and those with reminders
/// turned off stay out of the way.
class UpcomingSubscriptionsCard extends StatelessWidget {
  const UpcomingSubscriptionsCard({super.key, required this.store});
  final SubscriptionStore store;

  @override
  Widget build(BuildContext context) => ReminderSection(
    title: 'Upcoming subscriptions',
    listenable: store,
    onResume: store.load,
    viewAllLabel: (count) => 'View all $count due subscriptions',
    onViewAll: () => Navigator.push(
      context,
      FeatureRoute<void>(SubscriptionsScreen(store: store)),
    ),
    cards: (context) {
      final horizon = ReminderSection.horizon;
      final due =
          store.subscriptions
              .where(
                (s) => !s.paused && s.remind && s.nextDue.isBefore(horizon),
              )
              .toList()
            ..sort((a, b) => a.nextDue.compareTo(b.nextDue));
      return [for (final s in due) _card(context, s)];
    },
  );

  Widget _card(BuildContext context, Subscription s) {
    final account = store.accountStore.byId(s.accountId);
    return ReminderCard(
      gap: homeCardGap,
      icon: s.icon,
      title: s.name,
      subtitle: account == null
          ? '${s.cycle.label} subscription'
          : '${s.cycle.label} · ${account.name}',
      amount: formatAccountMoney(
        s.amountMinor,
        digits: s.digits,
        currency: s.currency,
      ),
      per: s.cycle.per,
      due: s.nextDue,
      onTap: () => Navigator.push(
        context,
        FeatureRoute<void>(SubscriptionDetailScreen(store: store, id: s.id)),
      ),
      onMarkPaid: store.saving
          ? null
          : () => showMarkPaidSheet(context, store: store, subscription: s),
    );
  }
}
