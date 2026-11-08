import 'package:flutter/material.dart';

import '../../../domain/loan.dart';
import '../../../state/loan_store.dart';
import '../../components/feature_page.dart';
import '../../more/loans/loan_action_sheet.dart';
import '../../more/loans/loan_detail_screen.dart';
import '../../more/loans/loan_widgets.dart';
import '../../more/loans/loans_screen.dart';
import '../../theme/surface_style.dart';
import 'reminder_card.dart';

/// EMIs falling due this week, each with its loan and which payment it is.
class UpcomingEmisCard extends StatelessWidget {
  const UpcomingEmisCard({super.key, required this.store});
  final LoanStore store;

  @override
  Widget build(BuildContext context) => ReminderSection(
    title: 'Upcoming EMIs',
    listenable: store,
    onResume: store.load,
    viewAllLabel: (count) => 'View all $count due loans',
    onViewAll: () =>
        Navigator.push(context, FeatureRoute<void>(LoansScreen(store: store))),
    cards: (context) {
      final horizon = ReminderSection.horizon;
      final loans =
          store.loans
              .where((l) => !l.closed && l.nextDue.isBefore(horizon))
              .toList()
            ..sort((a, b) => a.nextDue.compareTo(b.nextDue));
      return [for (final loan in loans) _card(context, loan)];
    },
  );

  Widget _card(BuildContext context, Loan loan) {
    final noun = loan.terms.mode.paymentNoun;
    return ReminderCard(
      gap: homeCardGap,
      icon: loan.icon,
      title: loan.title,
      subtitle:
          '${noun[0].toUpperCase()}${noun.substring(1)} '
          '${loan.paid + 1} of ${loan.paid + loan.schedule.length}',
      amount: loanMoney(loan.terms, loan.nextAmount),
      due: loan.nextDue,
      onTap: () => Navigator.push(
        context,
        FeatureRoute<void>(LoanDetailScreen(store: store, id: loan.id)),
      ),
      onMarkPaid: store.saving
          ? null
          : () => showLoanAction(context, store, loan, LoanEventKind.emi),
    );
  }
}
