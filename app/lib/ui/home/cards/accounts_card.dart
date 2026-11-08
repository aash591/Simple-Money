import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../state/account_store.dart';
import '../../../state/transaction_store.dart';
import '../../components/app_icon.dart';
import '../../components/account_total.dart';
import '../../components/common.dart';
import '../../components/feature_page.dart';
import '../../more/accounts/accounts_screen.dart';
import '../../more/accounts/edit_account_screen.dart';
import 'home_card.dart';
import '../../components/private_amount.dart';

/// The first few accounts and their balances.
class AccountsCard extends StatelessWidget {
  const AccountsCard({
    super.key,
    required this.accountStore,
    required this.transactionStore,
  });
  final AccountStore accountStore;
  final TransactionStore transactionStore;

  @override
  Widget build(BuildContext context) => HomeCard(
    child: Column(
      children: [
        SectionTitle(
          'Accounts',
          action: 'See all',
          onTap: () => Navigator.of(context).push(
            FeatureRoute<void>(
              AccountsScreen(
                store: accountStore,
                transactionStore: transactionStore,
              ),
            ),
          ),
        ),
        AccountTotal(store: accountStore),
        if (accountStore.accounts.isEmpty)
          TextButton(
            onPressed: () => Navigator.of(
              context,
            ).push(FeatureRoute<void>(EditAccountScreen(store: accountStore))),
            child: const Text('Add your first account'),
          ),
        for (final account in accountStore.accounts.take(3))
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: AppIcon(account.icon, size: 40),
            title: Text(account.name),
            subtitle: Text(account.currency),
            trailing: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 130),
              child: PrivateAmount(
                height: 30,
                label: '${account.name} balance',
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    formatAccountMoney(
                      account.balanceMinor,
                      digits: account.digits,
                      currency: account.currency,
                    ),
                  ),
                ),
              ),
            ),
            onTap: () => Navigator.of(context).push(
              FeatureRoute<void>(
                EditAccountScreen(
                  store: accountStore,
                  account: account,
                  transactionStore: transactionStore,
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
