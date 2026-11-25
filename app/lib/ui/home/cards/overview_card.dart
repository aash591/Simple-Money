import 'package:flutter/material.dart';

import '../../../data/repositories/home_repository.dart';
import '../../../domain/budget.dart';
import '../../../domain/currency_scope.dart';
import '../../budgets/budget_widgets.dart';
import '../../theme/app_theme.dart';
import '../../theme/app_typography.dart';
import 'home_card.dart';
import '../../components/private_amount.dart';
import '../../components/animated_amount.dart';
import '../../components/empty_chart_preview.dart';

/// The month at a glance: what was saved, the money in and out behind it,
/// and how much of the budget is left.
class OverviewCard extends StatelessWidget {
  const OverviewCard({
    super.key,
    required this.data,
    required this.budget,
    required this.currency,
    required this.onOpenTransactions,
    required this.onOpenBudgets,
  });
  final HomeSummary data;
  final BudgetLine? budget;
  final CurrencyScope currency;
  final VoidCallback onOpenTransactions;
  final VoidCallback onOpenBudgets;

  String _amount(int value) => homeMoney(value, currency);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final net = data.income - data.spent;
    final budget = this.budget;
    final empty = data.income == 0 && data.spent == 0;
    return HomeCard(
      featured: true,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onOpenTransactions,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Net savings',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 15,
                            fontWeight: FontWeight.w400,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        size: 20,
                        color: colors.onSurfaceVariant,
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (empty)
                    // Nothing this month yet: the card as it will look.
                    EmptyChartPreview(
                      title: 'Nothing recorded yet.',
                      message:
                          'Add income or an expense to see your month at a '
                          'glance.',
                      sample: _summary(
                        context,
                        net: 124000,
                        income: 300000,
                        spent: 176000,
                        sample: true,
                      ),
                    )
                  else
                    _summary(
                      context,
                      net: net,
                      income: data.income,
                      spent: data.spent,
                    ),
                ],
              ),
            ),
          ),
          if (currency is SingleCurrency && budget != null) ...[
            Divider(
              height: 1,
              indent: 20,
              endIndent: 20,
              color: colors.outlineVariant.withValues(alpha: .35),
            ),
            InkWell(
              onTap: onOpenBudgets,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                child: Row(
                  children: [
                    const BudgetTotalIcon(size: 44),
                    const SizedBox(width: 12),
                    Expanded(child: _budget(context, budget)),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// A short verdict on the month, shown beside the title: the share of the
  /// income kept, or that more went out than came in. Null when there is
  /// nothing to judge.
  Widget? _chip(BuildContext context) {
    final theme = Theme.of(context);
    final income = data.income, net = data.income - data.spent;
    final String text;
    final Color color;
    if (income == 0 && data.spent == 0) {
      return null;
    } else if (income <= 0) {
      text = 'No income recorded';
      color = theme.colorScheme.onSurfaceVariant;
    } else {
      text =
          "Spent ${(data.spent / income * 100).round()}% of this month's income";
      // Quiet grey while on track; only an overspend gets a colour.
      color = net >= 0 ? theme.colorScheme.onSurfaceVariant : coral;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: color == coral
            ? color.withValues(alpha: .10)
            : theme.colorScheme.onSurface.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        // The same face and size as the small labels around it.
        style: theme.textTheme.bodySmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// The month in one look: the savings, how much of the income went out, and
  /// the two totals behind it. [sample] draws it with made-up numbers, with
  /// nothing hidden, for the empty state.
  Widget _summary(
    BuildContext context, {
    required int net,
    required int income,
    required int spent,
    bool sample = false,
  }) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final chip = sample ? null : _chip(context);
    final hero = AnimatedAmount(
      value: net,
      format: (value) => '${value < 0 ? '-' : ''}${_amount(value.abs())}',
      style: AppTypography.heroAmount.copyWith(color: colors.onSurface),
    );
    // Share of the money in that went out; with none in, all of it did.
    final spentShare = income <= 0 ? 1.0 : (spent / income).clamp(0.0, 1.0);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (sample)
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: hero,
          )
        else
          PrivateAmount(
            label: 'Net savings',
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: hero,
            ),
          ),
        // Flush with the bar's left edge, which is where the amount starts.
        if (chip != null) ...[
          const SizedBox(height: 8),
          Align(alignment: Alignment.centerLeft, child: chip),
        ],
        const SizedBox(height: 12),
        // The bar is the month's money in: what went out, then what's left.
        Semantics(
          label: 'Spent ${(spentShare * 100).round()}% of money in',
          child: SizedBox(
            height: 6,
            // Stretched, or the colour boxes have no child to size them and
            // collapse to nothing.
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (spentShare > 0)
                  Expanded(
                    flex: (spentShare * 1000).round().clamp(1, 1000),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        // Ink while on track, coral only once it passes the income.
                        color: spent > income ? coral : colors.onSurface,
                        borderRadius: const BorderRadius.all(Radius.circular(3)),
                      ),
                    ),
                  ),
                if (spentShare > 0 && spentShare < 1) const SizedBox(width: 3),
                if (spentShare < 1)
                  Expanded(
                    flex: ((1 - spentShare) * 1000).round().clamp(1, 1000),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.onSurface.withValues(alpha: .10),
                        borderRadius: const BorderRadius.all(Radius.circular(3)),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 10),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: _Flow(
                label: 'Money in',
                value: income,
                format: _amount,
                icon: Icons.south_west_rounded,
                color: green,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: _Flow(
                label: 'Money out',
                value: spent,
                format: _amount,
                icon: Icons.north_east_rounded,
                color: coral,
                end: true,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _budget(BuildContext context, BudgetLine budget) {
    final theme = Theme.of(context);
    final color = budget.isOver ? coral : green;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                budget.isOver ? 'Over budget' : 'Budget left',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: _amount(budget.left.abs()),
                        style: TextStyle(
                          color: color,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextSpan(
                        text: '  of ${_amount(budget.limit)}',
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                  maxLines: 1,
                  style: theme.textTheme.titleSmall,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        LinearProgressIndicator(
          value: budget.fraction.clamp(0.0, 1.0),
          color: color,
          backgroundColor: color.withValues(alpha: .12),
          borderRadius: BorderRadius.circular(8),
          minHeight: 6,
          semanticsLabel: 'Budget used',
          semanticsValue: '${budget.percentUsed.clamp(0, 100)}%',
        ),
      ],
    );
  }
}

/// One side of the month's cash flow: an arrowed label over its total.
class _Flow extends StatelessWidget {
  const _Flow({
    required this.label,
    required this.value,
    required this.format,
    required this.icon,
    required this.color,
    this.end = false,
  });
  final String label;
  final int value;
  final String Function(int) format;
  final IconData icon;
  final Color color;

  /// Aligns to the right, for the figure at the bar's far end.
  final bool end;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: end
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Neutral: the figures carry the meaning, not the arrows.
            Icon(icon, size: 14, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: end ? Alignment.centerRight : Alignment.centerLeft,
          child: AnimatedAmount(
            value: value,
            format: format,
            style: theme.textTheme.titleSmall?.copyWith(
              fontSize: 20,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}
