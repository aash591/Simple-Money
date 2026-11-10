import 'package:flutter/material.dart';

import '../../data/repositories/home_repository.dart';
import '../../data/repositories/insights_repository.dart';
import '../../data/repositories/sms_import_repository.dart';
import '../../domain/budget.dart';
import '../../domain/currency_scope.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import '../../state/debt_store.dart';
import '../../state/home_layout.dart';
import '../../state/loan_store.dart';
import '../../state/sms_import_store.dart';
import '../../state/recurring_payment_store.dart';
import '../../state/transaction_store.dart';
import '../sms/sms_pending_card.dart';
import '../theme/surface_style.dart';
import 'cards/accounts_card.dart';
import 'cards/cash_flow_card.dart';
import 'cards/committed_card.dart';
import 'cards/loan_payoff_card.dart';
import 'cards/net_worth_card.dart';
import 'cards/overview_card.dart';
import 'cards/recent_transactions_card.dart';
import 'cards/spending_card.dart';
import 'cards/spending_pace_card.dart';
import 'cards/upcoming_debts_card.dart';
import 'cards/upcoming_emis_card.dart';
import 'cards/upcoming_payments_card.dart';

/// Everything a Home card needs to show itself. Home fills it from the
/// user's ledger; the arrange screen fills it with example data, so both
/// draw the very same cards.
class HomeCardContext {
  const HomeCardContext({
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    required this.month,
    required this.currency,
    required this.onOpenTransactions,
    required this.onOpenBudgets,
    this.loanStore,
    this.recurringPaymentStore,
    this.debtStore,
    this.smsStore,
    this.onReviewSms,
    this.summary,
    this.insights,
    this.budget,
    this.viewingPast = false,
    this.spaced = true,
    this.paceNow,
  });
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final LoanStore? loanStore;
  final RecurringPaymentStore? recurringPaymentStore;
  final DebtStore? debtStore;
  final SmsImportStore? smsStore;
  final ValueChanged<PendingSmsImport>? onReviewSms;

  /// The month shown, and the scope amounts are shown in.
  final DateTime month;
  final CurrencyScope currency;

  /// Null until loaded; the month's charts wait for them.
  final HomeSummary? summary;
  final HomeInsights? insights;
  final BudgetMonth? budget;

  /// Looking at an earlier month: what's due soon only matters in the present.
  final bool viewingPast;

  /// Whether to leave the usual gap above a card. Off where cards are listed
  /// with their own spacing.
  final bool spaced;

  /// Stands in for today when pacing the month, for example data.
  final DateTime? paceNow;
  final VoidCallback onOpenTransactions, onOpenBudgets;
}

/// The card [id] stands for, or null when it has nothing to show.
Widget? buildHomeCard(HomeCardId id, HomeCardContext c) {
  final data = c.summary;
  final trends = c.insights;
  final currency = c.currency;
  Widget spaced(Widget card) => c.spaced
      ? Padding(
          padding: const EdgeInsets.only(top: homeCardGap),
          child: card,
        )
      : card;
  return switch (id) {
    HomeCardId.smsHistory when c.smsStore != null && c.onReviewSms != null =>
      SmsPendingCard(
        store: c.smsStore!,
        accounts: c.accountStore,
        categories: c.categoryStore,
        transactions: c.transactionStore,
        onReview: c.onReviewSms!,
      ),
    HomeCardId.upcomingEmis when !c.viewingPast && c.loanStore != null =>
      UpcomingEmisCard(store: c.loanStore!),
    HomeCardId.upcomingPayments
        when !c.viewingPast && c.recurringPaymentStore != null =>
      UpcomingPaymentsCard(store: c.recurringPaymentStore!),
    HomeCardId.upcomingDebts when !c.viewingPast && c.debtStore != null =>
      UpcomingDebtsCard(store: c.debtStore!),
    HomeCardId.committed when !c.viewingPast && data != null => spaced(
      CommittedCard(
        accountStore: c.accountStore,
        loanStore: c.loanStore,
        recurringPaymentStore: c.recurringPaymentStore,
        debtStore: c.debtStore,
        currency: currency,
      ),
    ),
    HomeCardId.overview when data != null => spaced(
      OverviewCard(
        data: data,
        budget: c.budget?.total,
        currency: currency,
        onOpenTransactions: c.onOpenTransactions,
        onOpenBudgets: c.onOpenBudgets,
      ),
    ),
    HomeCardId.spendingPace when data != null && trends != null => spaced(
      SpendingPaceCard(
        month: c.month,
        daily: data.dailyExpenses,
        previousDaily: trends.previousDailyExpenses,
        budget: c.budget?.total,
        currency: currency,
        now: c.paceNow,
      ),
    ),
    HomeCardId.spending when data != null => spaced(
      SpendingCard(data: data, month: c.month, currency: currency),
    ),
    HomeCardId.cashFlow when trends != null => spaced(
      CashFlowCard(flows: trends.flows, currency: currency),
    ),
    HomeCardId.accounts when data != null => spaced(
      AccountsCard(
        accountStore: c.accountStore,
        categoryStore: c.categoryStore,
        transactionStore: c.transactionStore,
      ),
    ),
    HomeCardId.netWorth when trends != null => spaced(
      NetWorthCard(
        flows: trends.flows,
        balances: trends.balances,
        loanStore: c.loanStore,
        debtStore: c.debtStore,
        currency: currency,
      ),
    ),
    // Hides itself, spacing included, while there are no open loans.
    HomeCardId.loanPayoff when c.loanStore != null && data != null =>
      LoanPayoffCard(store: c.loanStore!, currency: currency),
    HomeCardId.recentTransactions when data != null => spaced(
      RecentTransactionsCard(
        transactions: data.recent,
        currency: currency,
        accountStore: c.accountStore,
        categoryStore: c.categoryStore,
        transactionStore: c.transactionStore,
        onSeeAll: c.onOpenTransactions,
      ),
    ),
    _ => null,
  };
}
