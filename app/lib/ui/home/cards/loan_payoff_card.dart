import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/currency_scope.dart';
import '../../../state/loan_store.dart';
import '../../components/common.dart';
import '../../components/currency_notice.dart';
import '../../components/feature_page.dart';
import '../../more/loans/loan_payoff_chart.dart';
import '../../more/loans/loans_screen.dart';
import 'home_card.dart';

/// Every open loan in Home's currency, paid down together to the day the
/// last one ends. Hidden while there's nothing to pay off.
class LoanPayoffCard extends StatelessWidget {
  const LoanPayoffCard({
    super.key,
    required this.store,
    required this.currency,
  });
  final LoanStore store;
  final CurrencyScope currency;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final code = currency.code;
      final digits = currency.digits;
      final conversion = CurrencyTotals(currency);
      for (final loan in store.loans.where((l) => !l.closed)) {
        conversion.convert(
          loan.outstanding,
          loan.terms.currency,
          loan.terms.digits,
        );
      }
      final payoff = LoanPayoff(store.loans, scope: currency);
      final unprojected = store.loans
          .where((l) => !l.closed && l.schedule.isEmpty)
          .length;
      if (payoff.isEmpty) {
        // Nothing can be charted, but staying silent would imply there are no
        // loans at all when the truth is that none of them could be converted.
        return conversion.missing.isEmpty && unprojected == 0
            ? const SizedBox.shrink()
            : Padding(
                padding: const EdgeInsets.only(top: homeCardGap),
                child: HomeCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      HomeChartHeader(
                        title: 'Loan payoff',
                        headline: unprojected > 0
                            ? 'Payoff date not projected'
                            : 'No loans could be converted',
                        action: 'See loans',
                        onTap: () => Navigator.push(
                          context,
                          FeatureRoute<void>(LoansScreen(store: store)),
                        ),
                      ),
                      CurrencyNotice(
                        scope: currency,
                        missing: conversion.missing,
                      ),
                    ],
                  ),
                ),
              );
      }
      final count = payoff.loans.length;
      return Padding(
        padding: const EdgeInsets.only(top: homeCardGap),
        child: HomeCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionTitle(
                'Loan payoff',
                compact: true,
                action: 'See loans',
                onTap: () => Navigator.push(
                  context,
                  FeatureRoute<void>(LoansScreen(store: store)),
                ),
              ),
              const SizedBox(height: 16),
              LoanPayoffChart(payoff: payoff, currency: code, digits: digits),
              const SizedBox(height: 16),
              Text(
                '${conversion.missing.isNotEmpty || unprojected > 0
                    ? '$count included loans paid off'
                    : count == 1
                    ? 'Debt-free'
                    : 'All $count loans paid off'} '
                'by ${DateFormat.yMMM().format(payoff.debtFree)}',
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(fontSize: 14, height: 1.45),
              ),
              CurrencyNotice(scope: currency, missing: conversion.missing),
              if (unprojected > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    '$unprojected ${unprojected == 1 ? 'loan has' : 'loans have'} no projected repayment schedule and ${unprojected == 1 ? 'is' : 'are'} not included in this chart.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}
