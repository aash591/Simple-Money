import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/loan.dart';
import '../../../domain/currency_scope.dart';
import '../../components/charts/charts.dart';

/// When a set of open loans — all in one currency — will be paid off.
class LoanPayoff {
  LoanPayoff(Iterable<Loan> loans, {this.scope})
    : loans = [
        for (final loan in loans)
          if (!loan.closed &&
              loan.schedule.isNotEmpty &&
              (scope == null ||
                  (scope.includes(loan.terms.currency, loan.terms.digits) &&
                      scope.convert(
                            loan.outstanding,
                            loan.terms.currency,
                            loan.terms.digits,
                          ) !=
                          null)))
            loan,
      ];
  final List<Loan> loans;
  final CurrencyScope? scope;
  int _convert(Loan loan, int amount) => scope == null
      ? amount
      : scope!.convert(amount, loan.terms.currency, loan.terms.digits)!;

  bool get isEmpty => loans.isEmpty;
  int get outstanding =>
      loans.fold(0, (n, l) => n + _convert(l, l.outstanding));
  int get futureInterest =>
      loans.fold(0, (n, l) => n + _convert(l, l.futureInterest));
  DateTime get debtFree => loans
      .map((l) => l.schedule.last.due)
      .reduce((a, b) => a.isAfter(b) ? a : b);

  /// What's still owed at the end of each month from this one until the
  /// last payment, as the schedules have it.
  List<({DateTime month, int balance})> balances(DateTime now) {
    final start = DateTime(now.year, now.month);
    final end = DateTime(debtFree.year, debtFree.month);
    final count = (end.year - start.year) * 12 + end.month - start.month + 1;
    return [
      for (var i = 0; i < math.max(1, count); i++)
        () {
          final month = DateTime(start.year, start.month + i);
          final after = DateTime(month.year, month.month + 1);
          var balance = 0;
          for (final loan in loans) {
            balance += _convert(
              loan,
              loan.schedule
                  .lastWhere(
                    (row) => row.due.isBefore(after),
                    orElse: () =>
                        LoanInstallment(0, month, 0, 0, loan.outstanding),
                  )
                  .balance,
            );
          }
          return (month: month, balance: balance);
        }(),
    ];
  }
}

/// The balance falling to zero over the schedule, with the principal and
/// interest still to pay beneath it.
class LoanPayoffChart extends StatelessWidget {
  const LoanPayoffChart({
    super.key,
    required this.payoff,
    required this.currency,
    required this.digits,
    this.now,
  });
  final LoanPayoff payoff;
  final String currency;
  final int digits;

  /// Stands in for the clock in tests.
  final DateTime? now;

  String _money(num minor) =>
      '${payoff.scope is CombinedCurrency ? '≈ ' : ''}${formatAccountMoney(minor.round(), digits: digits, currency: currency)}';

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    var points = payoff.balances(now ?? DateTime.now());
    // Past three years, one point a year keeps the line and labels legible.
    final yearly = points.length > 36;
    if (yearly) {
      points = [
        for (var i = 0; i < points.length; i++)
          if (i == 0 || points[i].month.month == 12 || i == points.length - 1)
            points[i],
      ];
    }
    final format = yearly ? DateFormat.y() : DateFormat('MMM yy');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LineChart(
          height: 140,
          filled: true,
          series: [
            ChartSeries(
              label: 'Balance left',
              values: [for (final p in points) p.balance],
              color: primary,
            ),
          ],
          labels: [for (final p in points) format.format(p.month)],
          formatValue: _money,
          formatAxis: (v) =>
              '${currencyPrefix(currency)}'
              '${NumberFormat.compact().format(v / math.pow(10, digits))}',
        ),
        const SizedBox(height: 14),
        ChartLegend(
          direction: Axis.vertical,
          entries: [
            ChartEntry(
              label: 'Principal left',
              value: payoff.outstanding.toDouble(),
              color: primary,
            ),
            ChartEntry(
              label: 'Interest still to pay',
              value: payoff.futureInterest.toDouble(),
              color: palette.expense,
            ),
          ],
          formatValue: _money,
        ),
      ],
    );
  }
}
