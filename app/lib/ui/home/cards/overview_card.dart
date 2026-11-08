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
    return HomeCard(
      featured: true,
      padding: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onOpenTransactions,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
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
                  const SizedBox(height: 8),
                  PrivateAmount(
                    label: 'Net savings',
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: AnimatedAmount(
                        value: net,
                        format: (value) =>
                            '${value < 0 ? '-' : ''}${_amount(value.abs())}',
                        style: AppTypography.heroAmount.copyWith(
                          color: colors.onSurface,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: [
                      Expanded(
                        child: _Flow(
                          label: 'Money in',
                          value: data.income,
                          format: _amount,
                          icon: Icons.south_west_rounded,
                          color: green,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: _Flow(
                          label: 'Money out',
                          value: data.spent,
                          format: _amount,
                          icon: Icons.north_east_rounded,
                          color: coral,
                        ),
                      ),
                    ],
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

/// One side of the month's cash flow: an arrowed label over its total,
/// which keeps the box's full width.
class _Flow extends StatelessWidget {
  const _Flow({
    required this.label,
    required this.value,
    required this.format,
    required this.icon,
    required this.color,
  });
  final String label;
  final int value;
  final String Function(int) format;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: usesAurora(context)
            ? null
            : theme.colorScheme.onSurface.withValues(alpha: .035),
        gradient: usesAurora(context)
            ? LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                // A hint of the flow's colour, quieter than the accent glow
                // around it, so green and red don't fight the page.
                colors: [
                  color.withValues(alpha: .09),
                  color.withValues(alpha: .03),
                  color.withValues(alpha: .07),
                ],
              )
            : null,
        border: usesAurora(context)
            ? Border.all(color: color.withValues(alpha: .14))
            : null,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
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
          const SizedBox(height: 8),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
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
      ),
    );
  }
}
