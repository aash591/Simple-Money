import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/currency_scope.dart';
import '../../../state/debt_store.dart';
import '../../components/common.dart';
import '../../components/feature_page.dart';
import '../../more/debts/debt_widgets.dart';
import '../../more/debts/debts_screen.dart';
import 'home_card.dart';

/// What people owe you and what you owe them, in Home's currency. Hidden
/// while nothing is outstanding.
class DebtsCard extends StatelessWidget {
  const DebtsCard({super.key, required this.store, required this.currency});
  final DebtStore store;
  final CurrencyScope currency;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: store,
    builder: (context, _) {
      final owedToYou = CurrencyTotals(currency);
      final youOwe = CurrencyTotals(currency);
      var toYouCount = 0, youOweCount = 0;
      for (final debts in store.people) {
        for (final balance in debts.balances) {
          final toYou = balance.amountMinor > 0;
          (toYou ? owedToYou : youOwe).add(
            balance.amountMinor.abs(),
            balance.currency,
            balance.digits,
          );
          if (!currency.includes(balance.currency, balance.digits)) continue;
          if (toYou) {
            toYouCount++;
          } else {
            youOweCount++;
          }
        }
      }
      if (toYouCount + youOweCount == 0) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(top: homeCardGap),
        child: HomeCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SectionTitle(
                'Debts',
                compact: true,
                action: 'See all',
                onTap: () => Navigator.push(
                  context,
                  FeatureRoute<void>(DebtsScreen(store: store)),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _Side(
                      label: 'Owed to you',
                      amount: owedToYou.total,
                      people: toYouCount,
                      currency: currency,
                      color: owedColor(context, toYou: true),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: _Side(
                      label: 'You owe',
                      amount: youOwe.total,
                      people: youOweCount,
                      currency: currency,
                      color: owedColor(context, toYou: false),
                      alignEnd: true,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _Side extends StatelessWidget {
  const _Side({
    required this.label,
    required this.amount,
    required this.people,
    required this.currency,
    required this.color,
    this.alignEnd = false,
  });
  final String label;
  final int amount, people;
  final CurrencyScope currency;
  final Color color;

  /// The right-hand side lines up with the card's right edge.
  final bool alignEnd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: alignEnd
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: alignEnd ? Alignment.centerRight : Alignment.centerLeft,
          child: Text(
            formatAccountMoney(
              amount,
              digits: currency.digits,
              currency: currency.code,
            ),
            style: theme.textTheme.titleLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          people == 0
              ? 'Nobody'
              : '$people ${people == 1 ? 'balance' : 'balances'}',
          style: theme.textTheme.bodySmall,
        ),
      ],
    );
  }
}
