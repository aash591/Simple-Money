part of 'transactions_screen.dart';

class _BalanceMetric extends StatelessWidget {
  const _BalanceMetric(this.label, this.value, {this.alignEnd = false});
  final String label;
  final String value;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: alignEnd
        ? CrossAxisAlignment.end
        : CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: Theme.of(context).textTheme.bodySmall
            ?.copyWith(fontSize: 11, height: 1),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.titleSmall
            ?.copyWith(fontWeight: FontWeight.w700),
      ),
    ],
  );
}

class _FlowMetric extends StatelessWidget {
  const _FlowMetric({
    required this.label,
    required this.value,
    required this.icon,
    required this.color,
  });
  final String label;
  final String value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
    decoration: BoxDecoration(
      color: color.withValues(alpha: .08),
      borderRadius: BorderRadius.circular(13),
    ),
    child: Row(
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: Theme.of(context).textTheme.bodySmall
                    ?.copyWith(fontSize: 10, height: 1),
              ),
              Text(
                value,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: color,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _DatedTransactions {
  const _DatedTransactions(this.date, this.transactions, {this.totals});
  final (int, int)? totals;
  final DateTime date;
  final List<MoneyTransaction> transactions;
}

class _CategorizedTransactions {
  const _CategorizedTransactions({
    required this.key,
    required this.category,
    required this.transactions,
    required this.income,
    required this.expenses,
    this.count,
  });
  final int? count;

  /// The grouped category's id, or `_transfersGroupKey` for the transfers
  /// that have no category to group by.
  final int key;
  final Category? category;

  /// Newest first, so a truncated group previews the latest activity.
  final List<MoneyTransaction> transactions;
  final int income;
  final int expenses;

  String get label => category?.name ?? 'Transfers';

  /// How much the category moved either way — what the groups are ranked on.
  int get magnitude => income + expenses;
}

/// One category's transactions within the selected period, headed by the
/// category's own total. A long group previews its most recent transactions
/// and expands in place.
class _CategoryGroup extends StatelessWidget {
  const _CategoryGroup({
    required this.title,
    required this.showHeader,
    required this.icon,
    required this.count,
    required this.transactions,
    required this.income,
    required this.expenses,
    required this.expanded,
    required this.onToggleExpanded,
    required this.accountById,
    required this.categoryById,
    required this.formatAmount,
    required this.onOpen,
  });
  final String title;
  final bool showHeader;
  final Widget icon;

  /// Everything the group holds, which [transactions] shows only the most
  /// recent of until the group is expanded.
  final int count;
  final List<MoneyTransaction> transactions;

  /// The group's formatted totals in the selected currency, or null for a
  /// side that is zero — most categories move money only one way, and a zero
  /// reads as a figure rather than as an absence.
  final String? income;
  final String? expenses;
  final bool expanded;
  final VoidCallback onToggleExpanded;
  final Account? Function(int?) accountById;
  final Category? Function(int?) categoryById;
  final String Function(MoneyTransaction) formatAmount;
  final ValueChanged<MoneyTransaction> onOpen;

  Widget _headerTotal(String amount, Color color) => FittedBox(
    fit: BoxFit.scaleDown,
    alignment: Alignment.centerRight,
    child: Text(
      amount,
      maxLines: 1,
      textAlign: TextAlign.end,
      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Inset to match the rows' own trailing padding, so the group's total
    // sits in the same column as the amounts it adds up.
    final header = Padding(
      padding: const EdgeInsets.fromLTRB(8, 4, 16, 14),
      child: Row(
        children: [
          SizedBox.square(dimension: 30, child: Center(child: icon)),
          const SizedBox(width: 12),
          // Tight, so the row has no slack left to strand on its right: a
          // merely flexible title would take only the width it needs and
          // leave the rest between the total and the edge.
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  count == 1 ? '1 transaction' : '$count transactions',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          // Keep totals in a bounded column so labels retain room on phones.
          if (income != null || expenses != null)
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (income != null) _headerTotal('+ $income', green),
                  if (expenses != null) _headerTotal('- $expenses', coral),
                ],
              ),
            ),
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeader) header,
          MoneyCard(
            padding: EdgeInsets.zero,
            // Transparent Material so the rows' ripples paint above the
            // card's own color rather than under it.
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                children: [
                  // Grows and shrinks from the top, so the rows past the
                  // preview unroll rather than appearing all at once.
                  AnimatedSize(
                    duration: MediaQuery.disableAnimationsOf(context)
                        ? Duration.zero
                        : const Duration(milliseconds: 280),
                    curve: Curves.easeInOutCubic,
                    alignment: Alignment.topCenter,
                    child: Column(
                      children: [
                        for (
                          var index = 0;
                          index < transactions.length;
                          index++
                        ) ...[
                          TransactionListRow(
                            transaction: transactions[index],
                            account: accountById(transactions[index].accountId),
                            toAccount: accountById(
                              transactions[index].toAccountId,
                            ),
                            category: categoryById(
                              transactions[index].categoryId,
                            ),
                            parentCategory: categoryById(
                              categoryById(transactions[index].categoryId)
                                  ?.parentId,
                            ),
                            formattedAmount: formatAmount(transactions[index]),
                            onTap: () => onOpen(transactions[index]),
                            // A category group spans the whole period, so the
                            // day is what places a row, not the hour.
                            showDate: true,
                          ),
                          if (index < transactions.length - 1)
                            const Divider(height: 1),
                        ],
                      ],
                    ),
                  ),
                  if (expanded || transactions.length < count) ...[
                    const Divider(height: 1),
                    InkWell(
                      onTap: onToggleExpanded,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              expanded ? 'Show less' : 'Show all $count',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: scheme.primary,
                              ),
                            ),
                            const SizedBox(width: 3),
                            Icon(
                              expanded
                                  ? Icons.expand_less_rounded
                                  : Icons.expand_more_rounded,
                              size: 18,
                              color: scheme.primary,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TransactionGroup extends StatelessWidget {
  const _TransactionGroup({
    required this.date,
    required this.transactions,
    required this.income,
    required this.expenses,
    required this.accountById,
    required this.categoryById,
    required this.formatAmount,
    required this.onOpen,
  });
  final DateTime date;
  final List<MoneyTransaction> transactions;

  /// The day's formatted income/expense totals in the selected currency, or
  /// null for a side that is zero — a day may have moved money only in another
  /// currency, or only between accounts.
  final String? income;
  final String? expenses;
  final Account? Function(int?) accountById;
  final Category? Function(int?) categoryById;
  final String Function(MoneyTransaction) formatAmount;
  final ValueChanged<MoneyTransaction> onOpen;

  @override
  Widget build(BuildContext context) => TransactionDayGroup(
    date: date,
    income: income,
    expenses: expenses,
    rows: [
      for (final transaction in transactions)
        TransactionListRow(
          transaction: transaction,
          account: accountById(transaction.accountId),
          toAccount: accountById(transaction.toAccountId),
          category: categoryById(transaction.categoryId),
          parentCategory: categoryById(
            categoryById(transaction.categoryId)?.parentId,
          ),
          formattedAmount: formatAmount(transaction),
          onTap: () => onOpen(transaction),
        ),
    ],
  );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.filtered});
  final bool filtered;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(28, 4, 28, 96),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GlassLens(
          size: 104,
          child: EmptyArtwork(
            filtered ? EmptyArt.search : EmptyArt.transfer,
            size: 56,
          ),
        ),
        const SizedBox(height: 22),
        Text(
          filtered
              ? 'No matching transactions'
              : 'No transactions in this period',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 7),
        Text(
          filtered
              ? 'Try another search or transaction filter.'
              : 'Your expenses, income, and transfers will appear here.',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(height: 1.5),
        ),
      ],
    ),
  );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(28),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.cloud_off_outlined,
          size: 42,
          color: Theme.of(context).colorScheme.error,
        ),
        const SizedBox(height: 14),
        Text(message, textAlign: TextAlign.center),
        const SizedBox(height: 14),
        OutlinedButton(onPressed: onRetry, child: const Text('Try again')),
      ],
    ),
  );
}
