import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/currency_scope.dart';
import '../../components/app_icon.dart';
import '../../components/choice_list_sheet.dart';
import '../../components/currency_notice.dart';
import 'home_card.dart';

/// Picks which accounts Home summarises: everything converted into the main
/// currency, or one currency on its own.
///
/// Shaped like the month bar above it — the same card, label weight and
/// chevron — so the two filters read as a pair rather than as a stock form
/// control dropped into a custom layout.
class CurrencyScopeBar extends StatelessWidget {
  const CurrencyScopeBar({
    super.key,
    required this.scope,
    required this.combined,
    required this.singles,
    required this.onChanged,
    required this.accounts,
  });
  final CurrencyScope scope;
  final List<Account> accounts;

  List<Account> _included(CurrencyScope value) => accounts
      .where(
        (a) =>
            value is CombinedCurrency ||
            (a.currency == value.code && a.digits == value.digits),
      )
      .toList();

  String _names(CurrencyScope value) =>
      _included(value).map((a) => a.name).join(' · ');

  Widget _icon(CurrencyScope value) {
    final included = _included(value);
    return included.length == 1 && value is! CombinedCurrency
        ? AppIcon(included.single.icon, size: 32)
        : const AllAccountsIcon(size: 32);
  }

  /// The "All accounts" option, carrying the rates currently in hand.
  final CombinedCurrency combined;
  final List<SingleCurrency> singles;
  final ValueChanged<CurrencyScope> onChanged;

  static String labelFor(CurrencyScope scope, CombinedCurrency combined) =>
      scope is CombinedCurrency
      ? 'All accounts · ${combined.code}'
      : '${scope.code} accounts';

  Future<void> _pick(BuildContext context) async {
    final picked = await showChoiceListSheet<CurrencyScope>(
      context,
      title: 'Accounts to include',
      selected: scope,
      items: [
        ChoiceItem<CurrencyScope>(
          value: combined,
          icon: _icon(combined),
          label: labelFor(combined, combined),
          subtitle: _names(combined),
        ),
        for (final single in singles)
          ChoiceItem<CurrencyScope>(
            value: single,
            icon: _icon(single),
            label: labelFor(single, combined),
            subtitle: _names(single),
          ),
      ],
    );
    if (picked != null && picked != scope) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: HomeCard(
        padding: EdgeInsets.zero,
        child: Semantics(
          button: true,
          label: 'Choose accounts to include',
          child: InkWell(
            onTap: () => _pick(context),
            borderRadius: BorderRadius.circular(24),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  _icon(scope),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Showing accounts',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        const SizedBox(height: 3),
                        Text(
                          labelFor(scope, combined),
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurface,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          _names(scope),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (scope is CombinedCurrency) ...[
                          const SizedBox(height: 6),
                          CurrencyRateDate(scope: scope),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    Icons.keyboard_arrow_down_rounded,
                    size: 22,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
