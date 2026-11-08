import 'package:flutter/material.dart';

import '../common.dart';
import 'transaction_day_header.dart';

/// One day of a transaction list: its [TransactionDayHeader] over a card of
/// rows, usually [TransactionRow]s, divided by hairlines.
class TransactionDayGroup extends StatelessWidget {
  const TransactionDayGroup({
    super.key,
    required this.date,
    required this.rows,
    this.income,
    this.expenses,
    this.padding = const EdgeInsets.fromLTRB(18, 0, 18, 22),
  });
  final DateTime date;
  final List<Widget> rows;
  final String? income, expenses;

  /// The default suits a full-width list; inside an already padded list pass
  /// `EdgeInsets.only(bottom: 22)`.
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TransactionDayHeader(date: date, income: income, expenses: expenses),
        MoneyCard(
          padding: EdgeInsets.zero,
          // Transparent Material so the rows' ripples paint above the card's
          // own color rather than under it.
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                for (var index = 0; index < rows.length; index++) ...[
                  rows[index],
                  if (index < rows.length - 1) const Divider(height: 1),
                ],
              ],
            ),
          ),
        ),
      ],
    ),
  );
}

/// [items] split into days, newest day first, keeping each day's order.
List<(DateTime, List<T>)> groupByDay<T>(
  Iterable<T> items,
  DateTime Function(T) dateOf,
) {
  final days = <DateTime, List<T>>{};
  for (final item in items) {
    days.putIfAbsent(DateUtils.dateOnly(dateOf(item)), () => []).add(item);
  }
  return [
    for (final day in days.keys.toList()..sort((a, b) => b.compareTo(a)))
      (day, days[day]!),
  ];
}
