import 'package:flutter/material.dart';

import '../../../data/agent/agent_portfolio.dart';
import '../../../domain/account.dart';
import '../../../domain/currency_digits.dart';
import '../../../domain/holding.dart';
import '../../components/common.dart';
import '../../components/menu_list.dart';
import '../../theme/sheet_colors.dart';
import '../portfolio/holding_logo.dart';

/// A suggested portfolio change drawn like the Portfolio screen draws a
/// holding: the same logo, name, units and value, as it would stand once the
/// change is approved. Under it, what the change does in plain lines.
///
/// Everything it needs is in the suggestion's `view`, written when it was
/// made, so it draws without loading the Portfolio. Returns null from
/// [maybe] for a suggestion with no view, which falls back to its text.
class PortfolioSuggestionPreview extends StatelessWidget {
  const PortfolioSuggestionPreview._({
    required this.action,
    required this.holding,
    required this.view,
    required this.changes,
  });

  static PortfolioSuggestionPreview? maybe({
    required Map<String, Object?> payload,
    required List<String> detail,
  }) {
    final action = AgentPortfolioAction.fromToolName(
      payload['action'] as String?,
    );
    final view = payload['view'];
    if (action == null || view is! Map) return null;
    final v = Map<String, Object?>.from(view);
    final kind = HoldingKind.parse(v['kind'] as String?);
    return PortfolioSuggestionPreview._(
      action: action,
      view: v,
      changes: detail,
      holding: Holding(
        id: -1,
        accountId: -1,
        kind: kind,
        name: v['name'] as String? ?? '',
        symbol: v['symbol'] as String?,
        exchange: v['exchange'] as String?,
        priceSource: v['priceSource'] as String?,
        meta: v['meta'] as String?,
        lastPriceE4: v['priceE4'] as int?,
      ),
    );
  }

  final AgentPortfolioAction action;
  final Holding holding;
  final Map<String, Object?> view;

  /// The lines naming what changes, under the row.
  final List<String> changes;

  IconData get _icon => switch (action) {
    AgentPortfolioAction.addHolding => Icons.add_chart_rounded,
    AgentPortfolioAction.editHolding => Icons.edit_outlined,
    AgentPortfolioAction.buy => Icons.add_shopping_cart_rounded,
    AgentPortfolioAction.sell => Icons.sell_outlined,
    AgentPortfolioAction.dividend => Icons.savings_outlined,
    AgentPortfolioAction.setPrice => Icons.price_change_outlined,
    AgentPortfolioAction.removeTrade => Icons.undo_rounded,
    AgentPortfolioAction.archiveHolding => Icons.archive_outlined,
    AgentPortfolioAction.restoreHolding => Icons.unarchive_outlined,
    AgentPortfolioAction.deleteHolding => Icons.delete_outline_rounded,
  };

  static String _percent(double fraction) =>
      '${fraction > 0 ? '+' : ''}${(fraction * 100).toStringAsFixed(1)}%';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final grave = action == AgentPortfolioAction.deleteHolding;
    final dim = grave || action == AgentPortfolioAction.removeTrade;
    final accent = grave ? scheme.error : scheme.primary;

    final digits = view['digits'] as int? ?? 2;
    final brokerCurrency = view['brokerCurrency'] as String? ?? 'INR';
    final code = view['currency'] as String? ?? brokerCurrency;
    final unitsE6 = view['unitsE6'] as int? ?? 0;
    final cost = view['costMinor'] as int? ?? 0;
    final price = view['priceE4'] as int?;
    final metal = holding.kind == HoldingKind.metal;
    String money(int minor, String currency) => formatAccountMoney(
      minor,
      digits: currency == brokerCurrency ? digits : currencyDigits(currency),
      currency: currency,
    );
    final sameCurrency = code == brokerCurrency;
    final value = price == null || unitsE6 <= 0
        ? null
        : tradeAmountMinor(
            unitsE6: unitsE6,
            priceE4: price,
            digits: sameCurrency ? digits : currencyDigits(code),
          );
    final gain = value == null || !sameCurrency || cost <= 0
        ? null
        : value - cost;
    final colors = SheetColors.of(context);
    final gainColor = gain == null || gain == 0
        ? colors.muted
        : (gain > 0 ? colors.income : colors.expense);

    final row = MenuRow(
      leading: HoldingLogo(
        holdingLogoUrl(holding),
        kind: holding.kind,
        iconKey: holding.iconKey,
      ),
      icon: HoldingLogo.iconFor(holding.kind),
      title: holding.name,
      subtitle: unitsE6 <= 0
          ? (action == AgentPortfolioAction.addHolding
                ? '${holding.kind.label} · in ${view['brokerName']}'
                : 'Sold out')
          : '${formatUnits(unitsE6)} ${metal ? 'g' : 'units'}'
                '${price == null ? ' · no price yet' : ''}',
      trailing: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null || cost > 0)
            Text(
              money(value ?? cost, value == null ? brokerCurrency : code),
              style: text.titleSmall,
            ),
          if (gain != null && cost > 0)
            Text(
              _percent(gain / cost),
              style: text.bodySmall?.copyWith(color: gainColor),
            ),
        ],
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
          child: Row(
            children: [
              Icon(_icon, size: 20, color: accent),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  action.label,
                  style: text.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: grave ? scheme.error : null,
                  ),
                ),
              ),
            ],
          ),
        ),
        Opacity(
          opacity: dim ? .6 : 1,
          child: MoneyCard(
            padding: EdgeInsets.zero,
            child: Material(type: MaterialType.transparency, child: row),
          ),
        ),
        if (changes.isNotEmpty) ...[
          const SizedBox(height: 10),
          for (final line in changes)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 2),
              child: Text(line, style: text.bodyMedium),
            ),
        ],
      ],
    );
  }
}
