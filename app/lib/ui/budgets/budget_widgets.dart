import 'package:flutter/material.dart';

import '../../domain/budget.dart';
import '../../domain/category.dart';
import '../components/app_icon.dart';
import '../components/common.dart';
import '../components/money_text.dart';
import '../theme/app_theme.dart';

/// Accent while under the limit, coral once spending passes it.
Color budgetColor(BuildContext context, BudgetLine line) =>
    line.isOver ? coral : Theme.of(context).colorScheme.primary;

/// The midpoint between plenty left and running out.
const budgetAmber = Color(0xffe59400);

/// Green while half or more is left, shading through amber (a quarter left)
/// to coral as it runs out; coral once over.
Color budgetLeftColor(BudgetLine line) {
  if (line.isOver) return coral;
  final left = 1 - line.fraction.clamp(0, 1).toDouble();
  if (left >= .5) return green;
  return left >= .25
      ? Color.lerp(budgetAmber, green, (left - .25) / .25)!
      : Color.lerp(coral, budgetAmber, left / .25)!;
}

/// The 3D budget illustration on a soft glow in the accent colour.
class BudgetTotalIcon extends StatelessWidget {
  const BudgetTotalIcon({super.key, this.size = 56});
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Stack(
      alignment: Alignment.center,
      children: [
        // A soft ambient glow behind the icon, not a projected drop shadow:
        // centered, no offset.
        Container(
          width: size * .78,
          height: size * .78,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Theme.of(context).colorScheme.primary
                    .withValues(alpha: .18),
                blurRadius: size * .3,
                spreadRadius: size * .03,
              ),
            ],
          ),
        ),
        Image.asset(
          'assets/images/budget_total_3d.webp',
          width: size,
          height: size,
          fit: BoxFit.contain,
          excludeFromSemantics: true,
        ),
      ],
    ),
  );
}

/// "₹551.50 left" or, past the limit, "₹12 over".
String budgetCaption(BudgetLine line, String Function(int) format) =>
    line.isOver ? '${format(-line.left)} over' : '${format(line.left)} left';

/// A rounded track filled to how much of a budget is used; the fill eases to
/// its new width when the numbers change, unless motion is reduced.
class BudgetProgressBar extends StatelessWidget {
  const BudgetProgressBar({
    super.key,
    required this.fraction,
    required this.color,
    this.height = 6,
  });
  final double fraction;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: Container(
        height: height,
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: .07),
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: fraction.clamp(0, 1).toDouble()),
          duration: MediaQuery.disableAnimationsOf(context)
              ? Duration.zero
              : const Duration(milliseconds: 450),
          curve: Curves.easeOutCubic,
          builder: (context, value, _) => FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: value,
            child: ColoredBox(color: color),
          ),
        ),
      ),
    ),
  );
}

/// The month's overall budget: the limit large, coloured by how much is
/// left, then what's left (or over) beside how much is used, over a bar.
class TotalBudgetCard extends StatelessWidget {
  const TotalBudgetCard({
    super.key,
    required this.line,
    required this.derived,
    required this.format,
    this.onTap,
  });
  final BudgetLine line;

  /// True when this is the category budgets added up rather than an
  /// "All spending" budget of its own.
  final bool derived;
  final String Function(int) format;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final leftColor = budgetLeftColor(line);
    return MoneyCard(
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    if (derived) ...[
                      const BudgetTotalIcon(),
                      const SizedBox(width: 14),
                    ],
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text(
                            derived
                                ? 'Total of category budgets'
                                : 'Total monthly budget',
                            textAlign: TextAlign.end,
                            style: text.bodySmall?.copyWith(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 2),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: MoneyText(
                              format(line.limit),
                              color: leftColor,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: leftColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        budgetCaption(line, format),
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: leftColor,
                        ),
                      ),
                    ),
                    Text('${line.percentUsed}% used', style: text.bodySmall),
                  ],
                ),
                const SizedBox(height: 10),
                BudgetProgressBar(
                  fraction: line.fraction,
                  color: budgetColor(context, line),
                  height: 8,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A custom budget's own name, else its categories': "Food & Beverage" for
/// one, "Food & Beverage + 2 more" for several.
String budgetTitle(String? name, List<Category> categories) {
  if (name != null) return name;
  if (categories.isEmpty) return 'Budget';
  return categories.length == 1
      ? categories.single.name
      : '${categories.first.name} + ${categories.length - 1} more';
}

/// A budget's picked [icon]; else a category budget shows its category's,
/// and a custom budget, which combines several, a shared one of its own.
Widget budgetIcon(
  List<Category> categories, {
  String? icon,
  required double size,
}) => icon != null
    ? AppIcon(icon, size: size)
    : categories.length == 1
    ? AppIcon(categories.single.icon, size: size)
    : IconTile(Icons.dashboard_customize_outlined, size: size);

/// One category or custom budget: its icon, name and limit (and, for a
/// custom budget, the categories it combines), a bar, and what's left
/// beside the percentage used.
class BudgetRow extends StatelessWidget {
  const BudgetRow({
    super.key,
    required this.line,
    required this.categories,
    required this.format,
    required this.onTap,
  });
  static const iconSize = 36.0;
  static const padding = EdgeInsets.fromLTRB(16, 14, 18, 14);

  /// Where a divider between rows starts, so it lines up with the text.
  static const dividerIndent = 16 + iconSize + 14;

  final BudgetLine line;

  /// The categories [line] covers, in the category list's order.
  final List<Category> categories;
  final String Function(int) format;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final overColor = line.isOver ? coral : null;
    final name = budgetTitle(line.name, categories);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            budgetIcon(categories, icon: line.icon, size: iconSize),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        format(line.limit),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  if (categories.length > 1) ...[
                    const SizedBox(height: 2),
                    Text(
                      categories.map((c) => c.name).join(', '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodySmall,
                    ),
                  ],
                  const SizedBox(height: 8),
                  BudgetProgressBar(
                    fraction: line.fraction,
                    color: budgetColor(context, line),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          budgetCaption(line, format),
                          style: text.bodySmall?.copyWith(color: overColor),
                        ),
                      ),
                      Text(
                        '${line.percentUsed}%',
                        style: text.bodySmall?.copyWith(color: overColor),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
