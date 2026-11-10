import 'package:flutter/material.dart';

import '../../domain/account.dart';
import '../../domain/currency_scope.dart';
import '../../state/account_store.dart';
import '../../state/main_currency_controller.dart';
import '../theme/sheet_colors.dart';
import 'adaptive_sheet.dart';
import 'animated_amount.dart';
import 'currency_notice.dart';
import 'common.dart';
import 'private_amount.dart';

/// Every account's balance added up. One conversion per currency group;
/// individual account balances stay in their own currency.
class AccountTotal extends StatelessWidget {
  const AccountTotal({
    super.key,
    required this.store,
    this.prominent = false,
    this.onTap,
  });
  final AccountStore store;
  final bool prominent;

  /// Replaces opening the per-currency breakdown, e.g. to go to the accounts
  /// page instead.
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final controller = MainCurrencyScope.maybeOf(context);
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (store.accounts.isEmpty) return const SizedBox.shrink();
        final first = store.accounts.first;
        final scope =
            controller?.accountScope ??
            (store.accounts.map((a) => a.currency).toSet().length > 1
                ? CombinedCurrency(first.currency, first.digits)
                : SingleCurrency(first.currency, first.digits));
        final groups = <(String, int), (int, int)>{};
        for (final account in store.accounts) {
          final key = (account.currency, account.digits);
          final (balance, count) = groups[key] ?? (0, 0);
          groups[key] = (balance + account.balanceMinor, count + 1);
        }
        final totals = CurrencyTotals(scope);
        for (final entry in groups.entries) {
          totals.add(entry.value.$1, entry.key.$1, entry.key.$2);
        }
        final estimated = scope is CombinedCurrency;
        final amount = formatAccountMoney(
          totals.total,
          digits: scope.digits,
          currency: scope.code,
        );
        final formatted = '${estimated ? '≈ ' : ''}$amount';
        // The same text, from the number itself, for the rolling digits.
        String money(int minor) =>
            '${estimated ? '≈ ' : ''}${formatAccountMoney(minor, digits: scope.digits, currency: scope.code)}';
        // "≈" is punctuation most screen readers skip, which would announce
        // an estimate as an exact figure.
        Widget rolling(TextStyle? style) => Semantics(
          label: estimated ? 'Approximately $amount' : amount,
          excludeSemantics: true,
          child: AnimatedAmount(
            value: totals.total,
            format: money,
            style: style,
          ),
        );
        if (prominent) {
          final theme = Theme.of(context);
          final scheme = theme.colorScheme;
          return MoneyCard(
            padding: EdgeInsets.zero,
            child: Material(
              color: Colors.transparent,
              child: InkWell(
                onTap: () => _open(context, scope, groups, totals, formatted),
                child: Padding(
                  padding: const EdgeInsets.all(22),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'Total balance',
                              style: theme.textTheme.titleSmall,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primary.withValues(alpha: .08),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              scope.code,
                              style: theme.textTheme.labelMedium?.copyWith(
                                color: scheme.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      PrivateAmount(
                        label: 'Total balance',
                        height: 52,
                        maskStyle: theme.textTheme.headlineLarge?.copyWith(
                          fontSize: 40,
                          fontWeight: FontWeight.w700,
                        ),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: rolling(
                            theme.textTheme.headlineLarge?.copyWith(
                              fontSize: 40,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                      CurrencyNotice(scope: scope, missing: totals.missing),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              'View breakdown',
                              style: theme.textTheme.labelLarge?.copyWith(
                                color: scheme.primary,
                              ),
                            ),
                          ),
                          Icon(
                            Icons.arrow_forward_rounded,
                            size: 18,
                            color: scheme.primary,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        }
        return InkWell(
          onTap:
              onTap ?? () => _open(context, scope, groups, totals, formatted),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Total balance · ${scope.code}',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Expanded(
                      child: PrivateAmount(
                        label: 'Total balance',
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: rolling(
                            Theme.of(context).textTheme.headlineSmall
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                        ),
                      ),
                    ),
                    const Icon(Icons.chevron_right_rounded, size: 20),
                  ],
                ),
                CurrencyNotice(scope: scope, missing: totals.missing),
              ],
            ),
          ),
        );
      },
    );
  }

  /// The breakdown behind the total: what each currency contributes, what it
  /// converts to, and the rates that did the converting.
  void _open(
    BuildContext context,
    CurrencyScope scope,
    Map<(String, int), (int, int)> groups,
    CurrencyTotals totals,
    String formatted,
  ) {
    final estimated = scope is CombinedCurrency;
    final entries = groups.entries.toList()
      ..sort((a, b) => a.key.$1.compareTo(b.key.$1));
    showAdaptiveSheet<void>(
      context,
      maxHeightFactor: .7,
      builder: (context) => SheetPage(
        header: const SheetHeader('Total balance'),
        actions: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              formatted,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.w700,
                color: SheetColors.of(context).text,
              ),
            ),
            if (estimated) ...[
              const SizedBox(height: 4),
              CurrencyRateDate(scope: scope, label: 'Converted at rates from'),
            ],
            CurrencyNotice(scope: scope, missing: totals.missing),
            const SizedBox(height: 12),
            SheetCard(
              child: Column(
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        indent: 16,
                        endIndent: 16,
                        color: SheetColors.of(context).divider,
                      ),
                    _GroupRow(
                      code: entries[i].key.$1,
                      digits: entries[i].key.$2,
                      balance: entries[i].value.$1,
                      accounts: entries[i].value.$2,
                      scope: scope,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One currency's contribution to the total.
class _GroupRow extends StatelessWidget {
  const _GroupRow({
    required this.code,
    required this.digits,
    required this.balance,
    required this.accounts,
    required this.scope,
  });
  final String code;
  final int digits, balance, accounts;
  final CurrencyScope scope;

  @override
  Widget build(BuildContext context) {
    final converted = scope.convert(balance, code, digits);
    final colors = SheetColors.of(context);
    // A group already in the main currency needs no "equals" line; repeating
    // the same figure underneath itself just reads as noise.
    final showsConversion = scope is CombinedCurrency && code != scope.code;
    // Laid out by hand rather than with ListTile: at large text scales a
    // two-line trailing amount pushes a tile's fixed-height row into an
    // overflow, and these rows have to survive that.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(code, style: TextStyle(color: colors.text)),
                Text(
                  '$accounts ${accounts == 1 ? 'account' : 'accounts'}',
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: colors.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatAccountMoney(balance, currency: code, digits: digits),
                  textAlign: TextAlign.end,
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: colors.text,
                  ),
                ),
                if (showsConversion)
                  Text(
                    converted == null
                        ? 'Rate unavailable'
                        : '≈ ${formatAccountMoney(converted, currency: scope.code, digits: scope.digits)}',
                    textAlign: TextAlign.end,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: converted == null
                          ? Theme.of(context).colorScheme.error
                          : colors.muted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
