import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/debt.dart';
import '../../../state/debt_store.dart';
import '../../components/feature_page.dart';
import '../../more/debts/debt_sheet.dart';
import '../../more/debts/debt_widgets.dart';
import '../../more/debts/debts_screen.dart';
import '../../more/debts/person_debts_screen.dart';
import '../../theme/surface_style.dart';
import 'reminder_card.dart';

/// Debts falling due this week (or already overdue), either way round: money
/// someone owes you, and money you owe.
class UpcomingDebtsCard extends StatelessWidget {
  const UpcomingDebtsCard({super.key, required this.store});
  final DebtStore store;

  @override
  Widget build(BuildContext context) => ReminderSection(
    title: 'Upcoming debts',
    listenable: store,
    onResume: store.load,
    viewAllLabel: (count) => 'View all $count due debts',
    onViewAll: () =>
        Navigator.push(context, FeatureRoute<void>(DebtsScreen(store: store))),
    cards: (context) {
      final horizon = ReminderSection.horizon;
      final due =
          store.people
              .where(
                (d) =>
                    !d.settled &&
                    d.dueDate != null &&
                    d.dueDate!.isBefore(horizon),
              )
              .toList()
            ..sort((a, b) => a.dueDate!.compareTo(b.dueDate!));
      return [for (final debts in due) _card(context, debts)];
    },
  );

  Widget _card(BuildContext context, PersonDebts debts) {
    final balance = debts.balances.first;
    final owesYou = balance.amountMinor > 0;
    final name = debts.person.name;
    return ReminderCard(
      gap: homeCardGap,
      icon: null,
      leading: PersonAvatar(name, size: 40),
      title: name,
      subtitle: owesYou ? 'Owes you' : 'You owe',
      amount: formatAccountMoney(
        balance.amountMinor.abs(),
        digits: balance.digits,
        currency: balance.currency,
      ),
      due: debts.dueDate!,
      actionLabel: owesYou ? 'Got paid' : 'Pay back',
      onTap: () => Navigator.push(
        context,
        FeatureRoute<void>(
          PersonDebtsScreen(store: store, personId: debts.person.id),
        ),
      ),
      onMarkPaid: store.saving
          ? null
          : () => showDebtPaymentSheet(
              context,
              store: store,
              personId: debts.person.id,
            ),
    );
  }
}
