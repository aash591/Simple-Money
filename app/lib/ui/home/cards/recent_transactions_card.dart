import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/currency_scope.dart';
import '../../../domain/transaction.dart';
import '../../../domain/transaction_icon.dart';
import '../../../state/account_store.dart';
import '../../../state/category_store.dart';
import '../../../state/transaction_store.dart';
import '../../components/app_icon.dart';
import '../../components/common.dart';
import '../../theme/app_theme.dart';
import '../../transactions/transaction_sheet.dart';
import 'home_card.dart';

/// The month's latest transactions, each opening its details.
class RecentTransactionsCard extends StatelessWidget {
  const RecentTransactionsCard({
    super.key,
    required this.transactions,
    required this.currency,
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    required this.onSeeAll,
  });
  final List<MoneyTransaction> transactions;
  final CurrencyScope currency;
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final VoidCallback onSeeAll;

  @override
  Widget build(BuildContext context) => HomeCard(
    child: Column(
      children: [
        SectionTitle('Recent transactions', action: 'See all', onTap: onSeeAll),
        if (transactions.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text('No transactions this month.'),
          ),
        for (final transaction in transactions) _row(context, transaction),
      ],
    ),
  );

  Widget _row(BuildContext context, MoneyTransaction transaction) {
    final account = accountStore.byId(transaction.accountId);
    final category = categoryStore.categories
        .where((c) => c.id == transaction.categoryId)
        .firstOrNull;
    final transfer = transaction.type == TransactionType.transfer;
    final income = transaction.type == TransactionType.income;
    final title =
        transaction.title ??
        (transfer ? 'Transfer' : category?.name ?? 'Uncategorized');
    return ListTile(
      contentPadding: EdgeInsets.zero,
      minVerticalPadding: 12,
      horizontalTitleGap: 12,
      titleTextStyle: Theme.of(context).textTheme.bodyMedium
          ?.copyWith(fontWeight: FontWeight.w600),
      subtitleTextStyle: Theme.of(context).textTheme.bodySmall,
      leading: transfer
          ? const Icon(Icons.swap_horiz)
          : BadgedAppIcon(
              transactionIcon(transaction, category),
              badgeKey: transaction.badgeIcon,
              size: 36,
            ),
      title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        '${account?.name ?? 'Account'} · ${DateFormat.MMMd().format(transaction.date)}',
      ),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 130),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            '${transfer
                ? ''
                : income
                ? '+ '
                : '- '}${homeMoney(transaction.amountMinor, SingleCurrency(account?.currency ?? currency.code, account?.digits ?? currency.digits))}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: income ? green : null,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
      onTap: () => showViewTransactionSheet(
        context,
        transaction: transaction,
        accountStore: accountStore,
        categoryStore: categoryStore,
        transactionStore: transactionStore,
      ),
    );
  }
}
