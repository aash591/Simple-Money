import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../state/account_store.dart';
import '../../../state/category_store.dart';
import '../../../state/transaction_store.dart';
import '../../components/account_tile.dart';
import '../../components/add_prompt_card.dart';
import '../../components/account_total.dart';
import '../../components/dashed_outline.dart';
import '../../components/feature_page.dart';
import '../../more/accounts/account_overview_screen.dart';
import '../../more/accounts/accounts_screen.dart';
import '../../more/accounts/edit_account_screen.dart';
import 'home_card.dart';

/// Where the money is: the total (tap it to manage accounts), then a swipeable
/// strip with a card per account and a dashed one at the end to add another.
class AccountsCard extends StatelessWidget {
  const AccountsCard({
    super.key,
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
  });
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;

  void _manage(BuildContext context) => Navigator.of(context).push(
    FeatureRoute<void>(
      AccountsScreen(store: accountStore, transactionStore: transactionStore),
    ),
  );

  void _add(BuildContext context) =>
      Navigator.of(context)
          .push(FeatureRoute<void>(EditAccountScreen(store: accountStore)));

  void _open(BuildContext context, Account account) =>
      Navigator.of(context).push(
        FeatureRoute<void>(
          AccountOverviewScreen(
            accountId: account.id,
            accountStore: accountStore,
            categoryStore: categoryStore,
            transactionStore: transactionStore,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final accounts = accountStore.accounts;
    if (accounts.isEmpty) {
      return AddPromptCard(
        icon: Icons.account_balance_wallet_outlined,
        title: 'Add your first account',
        message: 'Add one for each place your money is: a bank, a card, cash.',
        actions: [
          AddPromptAction(
            icon: Icons.add_rounded,
            label: 'Add account',
            onTap: () => _add(context),
          ),
        ],
      );
    }
    // The strip runs to the card's edges so a swipe isn't cut short by its
    // padding; everything else keeps the usual 20.
    const side = EdgeInsets.symmetric(horizontal: 20);
    return HomeCard(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: side,
            child: AccountTotal(
              store: accountStore,
              onTap: () => _manage(context),
            ),
          ),
          const SizedBox(height: 10),
          // A Row in a scroll view rather than a ListView: the tiles take
          // the height their text needs, so a large text scale grows them
          // instead of clipping a fixed-height strip.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: side,
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final account in accounts) ...[
                    AccountTile(
                      account: account,
                      onTap: () => _open(context, account),
                    ),
                    const SizedBox(width: 10),
                  ],
                  _AddTile(onTap: () => _add(context)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The last card in the strip: a dashed outline that starts a new account.
class _AddTile extends StatelessWidget {
  const _AddTile({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    const radius = BorderRadius.all(Radius.circular(22));
    return SizedBox(
      width: 150,
      child: CustomPaint(
        painter: DashedOutline(scheme.primary.withValues(alpha: .35)),
        child: Material(
          color: scheme.primary.withValues(alpha: .03),
          borderRadius: radius,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: scheme.primary.withValues(alpha: .1),
                      ),
                      child: Icon(Icons.add_rounded, color: scheme.primary),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      'Add account',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
