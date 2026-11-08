import 'package:flutter/material.dart';

import '../../components/app_back_button.dart';

import '../../../domain/loan.dart';
import '../../../state/loan_store.dart';
import '../../components/common.dart';
import '../../components/empty_state.dart';
import '../../components/feature_page.dart';
import '../../components/reminder_card.dart';
import '../../components/search_field.dart';
import '../../components/secondary_header.dart';
import '../../components/skeleton.dart';
import 'loan_action_sheet.dart';
import 'loan_detail_screen.dart';
import 'loan_flow_screen.dart';
import 'loan_widgets.dart';
import 'loan_progress_card.dart';

class LoansScreen extends StatefulWidget {
  const LoansScreen({super.key, required this.store});
  final LoanStore store;
  @override
  State<LoansScreen> createState() => _LoansScreenState();
}

class _LoansScreenState extends State<LoansScreen> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  var _searching = false;

  LoanStore get _store => widget.store;

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _openSearch() {
    setState(() => _searching = true);
    _searchFocus.requestFocus();
  }

  void _cancelSearch() {
    _searchFocus.unfocus();
    setState(() {
      _searching = false;
      _search.clear();
    });
  }

  void _add() => showAddLoanFlow(context, _store);

  /// By what it bought, the lender, or the kind of loan.
  static bool _matches(Loan loan, String query) {
    if (query.isEmpty) return true;
    return loan.title.toLowerCase().contains(query) ||
        loan.terms.lender.toLowerCase().contains(query) ||
        loan.terms.kind.label.toLowerCase().contains(query);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_searching,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _cancelSearch();
    },
    child: FeaturePage(
      title: 'Loans',
      header: SearchableHeader(
        searching: _searching,
        controller: _search,
        focusNode: _searchFocus,
        fieldKey: const Key('loan-search'),
        hintText: 'Search lender or loan type',
        onChanged: (_) => setState(() {}),
        onCancel: _cancelSearch,
        header: SecondaryHeader(
          title: 'Loans',
          leading: Navigator.of(context).canPop()
              ? const AppBackButton()
              : null,
          actions: [
            AppSearchButton(tooltip: 'Search loans', onPressed: _openSearch),
          ],
        ),
      ),
      floatingActionButton: _searching
          ? null
          : AddFab(tooltip: 'Add loan', onPressed: _add),
      child: ListenableBuilder(
        listenable: _store,
        builder: (context, _) => _body(context),
      ),
    ),
  );

  Widget _body(BuildContext context) {
    if (_store.loading) return const SkeletonList(cards: 3, rows: 2);
    if (_store.error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(_store.error!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _store.load,
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );
    }
    final loans = _store.loans;
    if (loans.isEmpty) {
      return EmptyState(
        icon: Icons.account_balance_outlined,
        title: 'No loans. Even nicer.',
        message: 'Track EMIs, interest and what’s left on a home, car or personal loan.',
        actionLabel: 'Add your first loan',
        onAction: _add,
      );
    }
    final query = _search.text.trim().toLowerCase();
    final active = loans.where((l) => !l.closed).toList()
      ..sort((a, b) => a.nextDue.compareTo(b.nextDue));
    final closed = loans.where((l) => l.closed).toList();
    final results = [
      ...active,
      ...closed,
    ].where((l) => _matches(l, query)).toList();
    return ListView(
      padding: const EdgeInsets.fromLTRB(18, 20, 18, 100),
      children: [
        _summary(active),
        const SizedBox(height: appCardGap),
        for (final loan in results) LoanCard(loan: loan, store: _store),
        if (results.isEmpty) const NoResultsState('No matching loans'),
      ],
    );
  }

  Widget _summary(List<Loan> loans) {
    final groups = <(String, int), List<Loan>>{};
    for (final loan in loans) {
      groups
          .putIfAbsent((loan.terms.currency, loan.terms.digits), () => [])
          .add(loan);
    }
    if (groups.isEmpty) {
      return const MoneyCard(child: Text('All loans closed'));
    }
    return Column(
      children: [
        for (final (index, group) in groups.values.indexed) ...[
          if (index > 0) const SizedBox(height: appCardGap),
          LoanProgressCard(loans: group),
        ],
      ],
    );
  }
}

/// One loan in the list. The same [ReminderCard] Home shows for an upcoming
/// EMI, so a loan reads identically in both places.
class LoanCard extends StatelessWidget {
  const LoanCard({super.key, required this.loan, required this.store});
  final Loan loan;
  final LoanStore store;

  @override
  Widget build(BuildContext context) {
    final noun = loan.terms.mode.paymentNoun;
    return ReminderCard(
      icon: loan.icon,
      title: loan.title,
      subtitle: loan.closed
          ? '${loan.terms.kind.label} · ${loan.terms.lender}'
          : loan.schedule.isEmpty
          ? 'Outstanding principal · ${loan.terms.mode.label}'
          : '${noun[0].toUpperCase()}${noun.substring(1)} '
                '${loan.paid + 1} of ${loan.paid + loan.schedule.length}',
      // A closed loan has no next payment, so show what it was rather than
      // the zero that is left of it.
      amount: loanMoney(
        loan.terms,
        loan.closed
            ? loan.terms.openingBalance
            : loan.schedule.isEmpty
            ? loan.outstanding
            : loan.nextAmount,
      ),
      due: loan.closed
          ? null
          : loan.terms.mode == LoanRepaymentMode.flexible
          ? loan.terms.maturityDate
          : loan.nextDue,
      actionLabel: loan.terms.mode.amortises ? 'Record EMI' : 'Record payment',
      status: loan.closed ? (label: 'Paid off', done: true) : null,
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
