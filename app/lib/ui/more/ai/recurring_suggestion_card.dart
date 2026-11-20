import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/category.dart';
import '../../../domain/recurring_payment.dart';
import '../../components/reminder_card.dart';
import '../../components/transactions/transaction_list_row.dart';
import '../../components/transactions/transaction_row.dart';
import '../../theme/sheet_colors.dart';
import '../loans/loan_widgets.dart';

/// A suggested recurring payment as it will look once approved: the same
/// card Home and the Recurring payments screen show, what it's paid from and
/// filed under, and the past payments it takes as its history, each as the
/// ledger shows it.
class RecurringSuggestionPreview extends StatefulWidget {
  const RecurringSuggestionPreview({
    super.key,
    required this.payload,
    required this.account,
    required this.category,
    required this.rowFor,
    this.accountOf,
    this.pending = true,
    this.savedFromSms = const [],
  });

  /// Once approved, the transactions its bank messages became.
  final List<int> savedFromSms;
  final Map<String, Object?> payload;

  /// An account by id, to say where a bank message is saved.
  final Account? Function(int? id)? accountOf;

  /// Still to be decided: its bank messages are yet to be saved.
  final bool pending;

  /// The account it is paid from or into; null when accounts couldn't be loaded.
  final Account? account;

  /// Its category, when one was chosen and could be found.
  final Category? category;

  /// The row for a saved transaction, or null when it can't be shown.
  final Widget? Function(int transactionId) rowFor;

  @override
  State<RecurringSuggestionPreview> createState() =>
      _RecurringSuggestionPreviewState();
}

class _RecurringSuggestionPreviewState
    extends State<RecurringSuggestionPreview> {
  /// Rows shown before "Show all", as in the loan suggestion.
  static const _collapsed = 3;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = widget.payload;
    final account = widget.account;
    final incoming = p['incoming'] == true;
    final cycle = BillingCycleLabels.fromStorage(p['cycle'] as String);
    final minor = p['amount'] as int;
    String money(int value) => account == null
        ? '$value'
        : formatAccountMoney(
            value,
            digits: account.digits,
            currency: account.currency,
          );
    final colors = SheetColors.of(context);
    // Bank messages it saves on approval, as the loan suggestion shows them:
    // waiting in SMS review, or unread by any rule. Once approved they are
    // ordinary transactions, listed with the rest.
    Widget message(Map sms) {
      final into = widget.accountOf?.call(sms['accountId'] as int?) ?? account;
      final unread = sms['kind'] == 'unparsed';
      return TransactionRow(
        icon: Icon(
          unread ? Icons.mark_chat_unread_outlined : Icons.sms_outlined,
          color: theme.colorScheme.onSurfaceVariant,
          size: 28,
        ),
        title: unread ? 'Unread bank message' : 'Bank message in review',
        subtitle:
            '${widget.pending ? 'Saves to' : 'Saved to'} '
            '${into?.name ?? 'your account'}',
        amount: '${incoming ? '+' : '-'} ${money(sms['amount'] as int)}',
        amountColor: incoming ? colors.income : colors.expense,
        stamp: transactionStamp(
          DateTime.parse(sms['date'] as String),
          showDate: true,
        ),
      );
    }

    final messages = (p['smsHistory'] as List? ?? const []).cast<Map>();
    final rows = [
      if (widget.pending)
        for (final sms in messages.reversed) message(sms),
      for (final id in [
        ...(p['history'] as List? ?? const []).cast<int>(),
        ...widget.savedFromSms,
      ])
        ?widget.rowFor(id),
    ];
    final fromSms = widget.pending ? messages.length : 0;
    final hidden = rows.length - _collapsed > 1 && !_expanded;
    final categoryName =
        widget.category?.name ?? p['categoryName'] as String? ?? 'Automatic';
    const inset = EdgeInsets.symmetric(horizontal: 16);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: inset,
          // As the Recurring payments list will show it.
          child: ReminderCard(
            icon: p['icon'] as String?,
            title: p['name'] as String,
            subtitle: cycle.label,
            amount: '${incoming ? '+' : ''}${money(minor)}',
            due: DateTime.parse(p['nextDue'] as String),
            onTap: () {},
            onMarkPaid: null,
            status: (label: 'Suggested', done: false),
            gap: 4,
          ),
        ),
        Padding(
          padding: inset,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LoanValue(
                incoming ? 'Paid into' : 'Paid from',
                account?.name ?? 'Your account',
              ),
              LoanValue('Category', categoryName),
              LoanValue(
                'Next due',
                DateFormat('d MMM yyyy')
                    .format(DateTime.parse(p['nextDue'] as String)),
              ),
              LoanValue(
                'Reminders',
                p['remind'] == false ? 'Off' : 'Two days before and on the day',
              ),
            ],
          ),
        ),
        if (rows.isNotEmpty) ...[
          const Divider(height: 24),
          Padding(
            padding: inset,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    incoming ? 'Past receipts' : 'Past payments',
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  fromSms == 0
                      ? '${rows.length} found in your accounts'
                      : '${rows.length - fromSms} saved · $fromSms from SMS',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 180),
            alignment: Alignment.topCenter,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: hidden ? rows.take(_collapsed).toList() : rows,
            ),
          ),
          if (rows.length - _collapsed > 1)
            Center(
              child: TextButton(
                onPressed: () => setState(() => _expanded = !_expanded),
                child: Text(
                  _expanded ? 'Show less' : 'Show all ${rows.length}',
                ),
              ),
            ),
        ],
      ],
    );
  }
}
