import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/category.dart';
import '../../../domain/transaction.dart';
import '../../../domain/transaction_icon.dart';
import '../../theme/app_theme.dart';
import '../app_icon.dart';
import 'transaction_row.dart';

/// A saved (or previewed) [MoneyTransaction] as a [TransactionRow].
class TransactionListRow extends StatelessWidget {
  const TransactionListRow({
    super.key,
    required this.transaction,
    required this.account,
    required this.toAccount,
    required this.category,
    required this.parentCategory,
    required this.formattedAmount,
    required this.onTap,
    this.onLongPress,
    this.showDate = false,
    this.amountColor,
    this.subtitle,
    this.subtitleColor,
    this.selected,
    this.onSelected,
    this.icon,
  });

  /// Replaces the row's usual icon (a transfer's swap arrows, say) where the
  /// list knows better, e.g. a deposit's own arrow.
  final Widget? icon;

  /// Replaces the usual subtitle, for a prompt such as "Select an account".
  final String? subtitle;
  final Color? subtitleColor;
  final MoneyTransaction transaction;
  final Account? account;
  final Account? toAccount;
  final Category? category;
  final Category? parentCategory;
  final String formattedAmount;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  final Color? amountColor;

  /// Shows a checkbox in front when non-null, as in the statement import.
  final bool? selected;
  final ValueChanged<bool>? onSelected;

  /// Stamps the row with its date rather than its time of day, for a group
  /// that spans days and so can't date its rows from its header.
  final bool showDate;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isTransfer = transaction.type == TransactionType.transfer;
    final isIncome = transaction.type == TransactionType.income;
    final hasTitle = transaction.title?.trim().isNotEmpty == true;
    final title = hasTitle
        ? transaction.title!.trim()
        : isTransfer
        ? 'Transfer to ${toAccount?.name ?? 'account'}'
        : category?.name ?? (isIncome ? 'Income' : 'Expense');
    // With a custom title the category reads as the subtitle; otherwise the
    // category is already the title, so fall back to its parent or account.
    final subtitle = isTransfer
        ? '${account?.name ?? 'Account'} → ${toAccount?.name ?? 'Account'}'
        : (hasTitle ? category?.name : parentCategory?.name) ??
              account?.name ??
              '';
    return TransactionRow(
      icon:
          icon ??
          (isTransfer
              ? Icon(Icons.swap_horiz_rounded, color: scheme.primary, size: 28)
              : BadgedAppIcon(
                  transactionIcon(transaction, category),
                  badgeKey: transaction.badgeIcon,
                )),
      title: title,
      subtitle: this.subtitle ?? subtitle,
      subtitleColor: subtitleColor,
      selected: selected,
      onSelected: onSelected,
      amount: formattedAmount,
      amountColor:
          amountColor ??
          (isIncome
              ? green
              : isTransfer
              ? scheme.onSurface
              : transaction.isCreditCard ||
                    account?.type == AccountType.creditCard
              ? Colors.orange
              : Colors.red),
      stamp: transactionStamp(transaction.date, showDate: showDate),
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

/// The time of day for a row under a day header, or its date (with the year
/// only when it isn't this one) for a list that spans days.
String transactionStamp(DateTime date, {bool showDate = false}) => DateFormat(
  !showDate
      ? 'h:mm a'
      : date.year == DateTime.now().year
      ? 'd MMM'
      : 'd MMM yyyy',
).format(date);
