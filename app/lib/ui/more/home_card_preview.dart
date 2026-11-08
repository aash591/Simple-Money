import 'package:flutter/material.dart';

import '../../state/home_layout.dart';
import '../components/charts/charts.dart';

/// Read-only examples use Home's chart widgets without creating ledger data.
class HomeCardPreview extends StatelessWidget {
  const HomeCardPreview({super.key, required this.id});
  final HomeCardId id;

  @override
  Widget build(BuildContext context) {
    final palette = ChartPalette.of(context);
    final primary = Theme.of(context).colorScheme.primary;
    String money(double value) => '₹${value.round()}';
    Widget rows(List<(String, String)> values) => Column(
      children: [
        for (final (label, value) in values)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Row(
              children: [
                Expanded(child: Text(label)),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    value,
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
    Widget line(String label, List<int> values, {List<int>? previous}) =>
        LineChart(
          height: 140,
          filled: previous == null,
          series: [
            ChartSeries(label: label, values: values, color: primary),
            if (previous != null)
              ChartSeries(
                label: 'Last month',
                values: previous,
                color: palette.expense,
                dashed: true,
              ),
          ],
          labels: id == HomeCardId.spendingPace
              ? const ['1', '5', '10', '15', '20', '25']
              : const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun'],
          formatValue: money,
          formatAxis: (v) => '${(v / 1000).round()}k',
        );
    final content = switch (id) {
      HomeCardId.smsHistory => rows([
        ('Saved from SMS', '42'),
        ('To check', '3'),
      ]),
      HomeCardId.spendingPace => line(
        'This month',
        [1200, 3800, 6500, 9000, 11000, 13500],
        previous: [1500, 4500, 8000, 11000, 15000, 17500],
      ),
      HomeCardId.netWorth => line('Net worth', [
        42000,
        46000,
        44000,
        52000,
        58000,
        65000,
      ]),
      HomeCardId.loanPayoff => line('Principal remaining', [
        60000,
        50000,
        40000,
        28000,
        15000,
        0,
      ]),
      HomeCardId.cashFlow => BarChart(
        height: 140,
        series: [
          ChartSeries(
            label: 'Money in',
            values: [40, 45, 42, 48, 45, 50],
            color: palette.income,
          ),
          ChartSeries(
            label: 'Money out',
            values: [30, 32, 38, 31, 35, 30],
            color: palette.expense,
          ),
        ],
        labels: const ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun'],
        formatValue: (v) => '₹${v.round()}k',
      ),
      HomeCardId.spending => Column(
        children: [
          PieChart(
            slices: palette.rank([
              (label: 'Food', value: 4500),
              (label: 'Shopping', value: 3000),
              (label: 'Transport', value: 1500),
            ]),
            centerLabel: '₹9,000',
            centerCaption: 'spent',
            size: 140,
          ),
          const SizedBox(height: 12),
          rows([
            ('Food', '₹4,500'),
            ('Shopping', '₹3,000'),
            ('Transport', '₹1,500'),
          ]),
        ],
      ),
      HomeCardId.categoryChanges => BarChart(
        height: 140,
        series: [
          ChartSeries(
            label: 'Change from usual',
            values: [1800, -1200, 600],
            color: palette.expense,
            negativeColor: palette.income,
          ),
        ],
        labels: const ['Shopping', 'Food', 'Travel'],
        formatValue: money,
      ),
      HomeCardId.committed => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '₹12,800 due in 30 days',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 14),
          RankedBarChart(
            entries: palette.rank([
              (label: 'EMIs', value: 8000),
              (label: 'Subscriptions', value: 2800),
              (label: 'Debts', value: 2000),
            ]),
            formatValue: money,
          ),
        ],
      ),
      HomeCardId.overview => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Net savings', style: Theme.of(context).textTheme.bodySmall),
          const Text(
            '₹15,000',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700),
          ),
          rows([
            ('Income', '₹45,000'),
            ('Spent', '₹30,000'),
            ('Budget left', '₹5,000'),
          ]),
        ],
      ),
      HomeCardId.accounts => rows([
        ('Bank account', '₹42,500'),
        ('Wallet', '₹2,500'),
      ]),
      HomeCardId.recentTransactions => rows([
        ('Groceries · Today', '− ₹850'),
        ('Salary · Yesterday', '+ ₹45,000'),
        ('Coffee · Yesterday', '− ₹180'),
      ]),
      HomeCardId.upcomingEmis => rows([
        ('Phone EMI', '₹2,150'),
        ('Due tomorrow', 'Record EMI'),
      ]),
      HomeCardId.upcomingSubscriptions => rows([
        ('Netflix · Monthly', '₹649'),
        ('Renews tomorrow', 'Mark paid'),
      ]),
      HomeCardId.upcomingDebts => rows([
        ('Alex owes you', '₹1,500'),
        ('Due Friday', 'Receive'),
      ]),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(id.description, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 16),
        content,
      ],
    );
  }
}
