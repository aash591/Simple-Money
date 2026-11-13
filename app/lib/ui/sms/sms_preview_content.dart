import 'package:flutter/material.dart';

import '../../data/repositories/sms_import_repository.dart';
import '../../domain/account.dart';
import '../../domain/category.dart';
import '../../state/category_store.dart';
import '../components/choice_list_sheet.dart';
import '../components/transactions/review_pickers.dart';
import '../components/transactions/transaction_review_content.dart';
import '../transactions/transaction_widgets.dart';
import 'sms_amount_style.dart';

/// The SMS preview's category picker, shared by the review modal and the
/// notification. Pops what was chosen.
Future<CategoryPick?> showSmsCategoryPicker(
  BuildContext context, {
  required Iterable<Category> categories,
  required CategoryStore store,
  required CategoryType type,
  required int? selected,
  CategoryShortcuts shortcuts = const CategoryShortcuts(),
}) => showReviewCategoryPicker(
  context,
  title: 'SMS preview',
  categories: categories,
  store: store,
  type: type,
  selected: selected,
  shortcuts: shortcuts,
);

/// The SMS preview's account picker. [items] carry the caller's own rules
/// for which accounts fit.
Future<int?> showSmsAccountPicker(
  BuildContext context, {
  required String heading,
  required List<ChoiceItem<int>> items,
  required int? selected,
  required Future<int?> Function(BuildContext context) onAdd,
}) => showReviewAccountPicker(
  context,
  title: 'SMS preview',
  heading: heading,
  items: items,
  selected: selected,
  onAdd: onAdd,
);

/// One tappable Category / account row of the preview card.
typedef SmsPreviewChoice = ReviewChoiceRow;

/// The body of the "SMS preview" modal, shared by the review flow and the
/// notification tap so both read the same: a [TransactionReviewContent]
/// filled from [sms].
class SmsPreviewContent extends StatelessWidget {
  const SmsPreviewContent({
    super.key,
    required this.sms,
    required this.transfer,
    required this.onTransferChanged,
    required this.rows,
    this.helper,
    this.message,
    this.error,
    this.title,
    this.onTitleChanged,
    this.titleSuggestions,
  });
  final PendingSmsImport sms;
  final bool transfer;

  /// Null disables the Expense/Transfer switch.
  final ValueChanged<bool>? onTransferChanged;

  /// A note under the switch, only when the choice needs explaining
  /// (an ATM movement, a card repayment, a NACH debit).
  final String? helper;

  /// The SMS text, when [sms] no longer carries it (a saved live SMS keeps
  /// it only in its transaction's note). Hidden when empty.
  final String? message;

  /// The tappable Category / account rows, already separated by dividers.
  final List<Widget> rows;
  final String? error;

  /// The title as edited so far (the message's own name until changed). With
  /// [onTitleChanged] it is typed in place under the amount; past titles that
  /// fit are offered through [titleSuggestions].
  final String? title;
  final ValueChanged<String>? onTitleChanged;
  final List<String> Function(String text)? titleSuggestions;

  @override
  Widget build(BuildContext context) => TransactionReviewContent<bool>(
    badge: sms.isCreditCardRepayment
        ? 'Credit card repayment'
        : sms.credit
        ? 'Money received'
        : 'Money paid',
    color: smsAmountColor(sms),
    badgeIcon: sms.credit ? Icons.south_west_rounded : Icons.north_east_rounded,
    amount: formatAccountMoney(
      sms.amountMinor,
      currency: sms.currency,
      digits: sms.digits,
    ),
    title: (title ?? sms.title).trim().isEmpty ? sms.title : title ?? sms.title,
    titleText: onTitleChanged != null && !transfer
        ? (title ?? sms.title)
        : null,
    onTitleChanged: onTitleChanged,
    titleSuggestions: titleSuggestions,
    date: formatTransactionDate(sms.receivedAt),
    kinds: [
      ReviewKind(
        false,
        sms.credit ? 'Income' : 'Expense',
        Icons.category_outlined,
      ),
      const ReviewKind(true, 'Transfer', Icons.swap_horiz),
    ],
    kind: transfer,
    onKindChanged: onTransferChanged,
    helper: helper,
    rows: rows,
    sourceDetail: sms.sender.trim().isEmpty ? 'Unknown sender' : sms.sender,
    sourceText: message ?? sms.body,
    error: error,
  );
}
