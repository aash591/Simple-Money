import 'package:flutter/material.dart';

import '../../domain/account.dart';
import '../../domain/currency.dart';
import '../theme/sheet_colors.dart';

typedef TransactionCurrency = (String, int);

class TransactionCurrencySummary {
  const TransactionCurrencySummary({
    required this.currency,
    required this.income,
    required this.expenses,
  });
  final TransactionCurrency currency;
  final int income, expenses;
  int get net => income - expenses;

  String money(int amount) =>
      formatAccountMoney(amount, currency: currency.$1, digits: currency.$2);
}

/// A single destination for comparing native totals and choosing their scope.
class TransactionCurrencySheet extends StatefulWidget {
  const TransactionCurrencySheet({
    super.key,
    required this.period,
    required this.selected,
    required this.summaries,
  });
  final String period;
  final TransactionCurrency selected;
  final List<TransactionCurrencySummary> summaries;

  @override
  State<TransactionCurrencySheet> createState() =>
      _TransactionCurrencySheetState();
}

class _TransactionCurrencySheetState extends State<TransactionCurrencySheet> {
  final _scroll = ScrollController();
  final _names = <String, String>{};

  @override
  void initState() {
    super.initState();
    _loadNames();
  }

  Future<void> _loadNames() async {
    try {
      final currencies = await Currency.load();
      if (!mounted) return;
      setState(() {
        for (final currency in currencies) {
          _names[currency.code] = currency.name;
        }
      });
    } catch (_) {
      // Currency codes remain sufficient if the optional names cannot load.
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = SheetColors.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.period,
            style: theme.textTheme.titleLarge?.copyWith(color: colors.text),
          ),
          const SizedBox(height: 4),
          Text(
            'Amounts are never added across currencies.',
            style: theme.textTheme.bodySmall?.copyWith(color: colors.muted),
          ),
          const SizedBox(height: 18),
          Flexible(
            child: Scrollbar(
              controller: _scroll,
              child: ListView.separated(
                controller: _scroll,
                shrinkWrap: true,
                padding: const EdgeInsets.only(right: 6, bottom: 8),
                itemCount: widget.summaries.length,
                separatorBuilder: (_, index) => const SizedBox(height: 8),
                itemBuilder: (context, index) =>
                    _currencyCard(widget.summaries[index]),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _currencyCard(TransactionCurrencySummary summary) {
    final theme = Theme.of(context);
    final colors = SheetColors.of(context);
    final selected = summary.currency == widget.selected;
    final code = summary.currency.$1;
    final name = _names[code];
    final metrics = <(String, String, Color)>[
      ('Money in', summary.money(summary.income), colors.income),
      ('Money out', summary.money(summary.expenses), colors.expense),
      (
        'Net',
        '${summary.net > 0 ? '+' : ''}${summary.money(summary.net)}',
        summary.net == 0
            ? colors.muted
            : summary.net > 0
            ? colors.income
            : colors.expense,
      ),
    ];
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected ? colors.primary.withValues(alpha: .08) : colors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: selected
                ? colors.primary.withValues(alpha: .4)
                : colors.divider,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: ValueKey('select-currency-$code'),
          onTap: () => Navigator.pop(context, summary.currency),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Text(
                      code,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colors.text,
                      ),
                    ),
                    const SizedBox(width: 10),
                    if (name != null)
                      Expanded(
                        child: Text(
                          name,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: colors.muted,
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    const SizedBox(width: 8),
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.circle_outlined,
                      size: 21,
                      color: selected ? colors.primary : colors.outline,
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final scale = MediaQuery.textScalerOf(context);
                    // Measure real amounts rather than truncating or shrinking money.
                    final columnWidth = (constraints.maxWidth - 20) / 3;
                    final stacked =
                        metrics.any((metric) {
                          final painter = TextPainter(
                            text: TextSpan(
                              text: metric.$2,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            textDirection: Directionality.of(context),
                            textScaler: scale,
                          )..layout();
                          final wide = painter.width > columnWidth;
                          painter.dispose();
                          return wide;
                        }) ||
                        scale.scale(14) > 19;
                    if (stacked) {
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (final metric in metrics)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    metric.$1,
                                    style: theme.textTheme.bodySmall?.copyWith(
                                      color: colors.muted,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    metric.$2,
                                    style: theme.textTheme.bodyMedium?.copyWith(
                                      fontWeight: FontWeight.w700,
                                      color: metric.$3,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (var i = 0; i < metrics.length; i++) ...[
                          if (i > 0) const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  metrics[i].$1,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: colors.muted,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  metrics[i].$2,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w700,
                                    color: metrics[i].$3,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
