import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../domain/account.dart';
import '../../domain/category.dart';
import '../../domain/transaction.dart';
import '../components/action_buttons.dart';
import '../components/adaptive_sheet.dart';
import '../components/date_picker_sheet.dart';
import '../components/number_keypad.dart';
import '../theme/sheet_colors.dart';
import 'amount_typing.dart';
import 'transaction_widgets.dart';

/// The pages of the transaction sheet (see `transaction_sheet.dart`). Each is
/// a plain view of the sheet's draft; every decision lives in the sheet.

/// Step 1 of adding: expense or income.
class TransactionTypePage extends StatelessWidget {
  const TransactionTypePage({
    super.key,
    required this.onChoose,
    required this.onCancel,
    this.onTransfer,
    this.onUpi,
  });
  final ValueChanged<TransactionType> onChoose;
  final VoidCallback onCancel;

  /// Shows a matching transfer choice when transfers are available.
  final VoidCallback? onTransfer;
  final VoidCallback? onUpi;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return SheetPage(
      header: const SheetHeader('Add a transaction', centered: true),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TypeChoiceCard(
            icon: Icons.arrow_upward_rounded,
            color: colors.expense,
            title: 'Add expense',
            subtitle: 'Record money you spent',
            onTap: () => onChoose(TransactionType.expense),
          ),
          const SizedBox(height: 12),
          TypeChoiceCard(
            icon: Icons.arrow_downward_rounded,
            color: colors.income,
            title: 'Add income',
            subtitle: 'Record money you received',
            onTap: () => onChoose(TransactionType.income),
          ),
          if (onUpi != null) ...[
            const SizedBox(height: 12),
            TypeChoiceCard(
              icon: Icons.qr_code_scanner_rounded,
              color: colors.primary,
              title: 'Pay with UPI',
              subtitle: 'Scan, pay and record your expense',
              onTap: onUpi!,
            ),
          ],
          if (onTransfer != null) ...[
            const SizedBox(height: 12),
            TypeChoiceCard(
              icon: Icons.swap_horiz_rounded,
              color: colors.primary,
              title: 'Transfer between accounts',
              onTap: onTransfer!,
            ),
          ],
        ],
      ),
      actions: ActionButtonBar(secondaryLabel: 'Cancel', onSecondary: onCancel),
    );
  }
}

/// Step 2: the amount, typed on the custom keypad.
class AmountPage extends StatelessWidget {
  const AmountPage({
    super.key,
    required this.type,
    required this.amountText,
    required this.digits,
    required this.currency,
    required this.onDigit,
    required this.onDecimalPoint,
    required this.onBackspace,
    required this.onClear,
    required this.onBack,
    required this.onCancel,
    required this.onContinue,
    this.headerTitle,
    this.recipientLabel,
    this.onOperation,
    this.calculatorStatus,
    this.calculatedAmount,
    this.replaceAmount = false,
    this.decimalAllowed,
  });
  final TransactionType type;
  final String? headerTitle, recipientLabel;
  final String amountText;
  final ValueChanged<String>? onOperation;
  final String? calculatorStatus;
  final String? calculatedAmount;
  final bool replaceAmount;
  final bool? decimalAllowed;

  /// Decimal places the chosen account's currency allows.
  final int digits;
  final String currency;
  final ValueChanged<String> onDigit;
  final VoidCallback onDecimalPoint, onBackspace, onClear, onBack, onCancel;

  /// Null (Continue disabled) until the amount is above zero.
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final isIncome = type == TransactionType.income;
    return SheetPage(
      startAtBottom: true,
      header: SheetHeader.flow(
        headerTitle ?? (isIncome ? 'Add income' : 'Add expense'),
        onBack: onBack,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SheetStepHeading(
            isIncome ? 'Amount received' : 'Amount',
            subtitle: recipientLabel,
          ),
          const SizedBox(height: 20),
          AmountDisplayCard(
            amount: AmountTyping.display(
              calculatedAmount ?? amountText,
              currency: currency,
              decimals: digits,
              showCurrency: false,
            ),
            empty: (calculatedAmount ?? amountText).isEmpty,
          ),
          SizedBox(
            height: 28,
            child: calculatorStatus == null
                ? null
                : CalculationHistory(text: calculatorStatus!),
          ),
          NumberKeypad(
            onOperation: onOperation,
            onDigit: onDigit,
            onDecimalPoint: onDecimalPoint,
            onBackspace: onBackspace,
            onClear: onClear,
            decimalEnabled:
                digits > 0 &&
                (decimalAllowed ??
                    (replaceAmount || !amountText.contains('.'))),
          ),
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: onCancel,
        primaryLabel: 'Continue',
        onPrimary: onContinue,
        primaryColor: colors.primary,
      ),
    );
  }
}

/// Previously collected details, using the same visual language as Confirm.
class TransactionStepSummary extends StatelessWidget {
  const TransactionStepSummary({
    super.key,
    required this.type,
    required this.amount,
    this.category,
    this.parentCategory,
    this.account,
  });
  final TransactionType type;
  final String amount;
  final Category? category, parentCategory;
  final Account? account;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final income = type == TransactionType.income;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AmountHero(
          amount: amount,
          caption: income ? 'Income' : 'Expense',
          color: income
              ? Color.lerp(colors.income, colors.muted, 0.4)!
              : colors.expense,
          captionColor: income ? null : colors.expense,
        ),
        if (category != null || account != null) ...[
          const SizedBox(height: 16),
          TransactionDetailsCard(
            rows: [
              if (parentCategory != null)
                TransactionDetailRow(
                  leading: EntityIconTile(
                    chosen: true,
                    iconKey: parentCategory!.icon,
                    fallback: Icons.category_outlined,
                  ),
                  label: income ? 'Source' : 'Category',
                  value: parentCategory!.name,
                  valueColor: colors.muted,
                ),
              if (category != null)
                TransactionDetailRow(
                  leading: EntityIconTile(
                    chosen: true,
                    iconKey: category!.icon,
                    fallback: Icons.category_outlined,
                  ),
                  label: parentCategory != null
                      ? 'Subcategory'
                      : (income ? 'Source' : 'Category'),
                  value: category!.name,
                  valueColor: colors.muted,
                ),
              if (account != null)
                TransactionDetailRow(
                  leading: EntityIconTile(
                    chosen: true,
                    iconKey: account!.icon,
                    fallback: Icons.account_balance_wallet_outlined,
                  ),
                  label: income ? 'Deposited to' : 'Paid from',
                  value: account!.name,
                  valueColor: colors.muted,
                ),
            ],
          ),
        ],
      ],
    );
  }
}

/// The Date step: the shared calendar, inline. Picking a day moves on;
/// Continue keeps the date already set (today, for a new transaction).
class DateStepPage extends StatelessWidget {
  const DateStepPage({
    super.key,
    required this.header,
    this.summary,
    required this.question,
    required this.date,
    required this.onPick,
    required this.onBack,
    required this.onCancel,
    required this.onContinue,
  });
  final String header, question;
  final Widget? summary;
  final DateTime date;
  final ValueChanged<DateTime> onPick;
  final VoidCallback onBack, onCancel, onContinue;

  @override
  Widget build(BuildContext context) => SheetPage(
    startAtBottom: true,
    header: SheetHeader.flow(header, onBack: onBack),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (summary != null) ...[summary!, const SizedBox(height: 20)],
        SheetStepHeading(question),
        const SizedBox(height: 14),
        SheetCard(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
            child: CalendarPicker(initialDate: date, onChanged: onPick),
          ),
        ),
      ],
    ),
    actions: ActionButtonBar(
      secondaryLabel: 'Cancel',
      onSecondary: onCancel,
      primaryLabel: 'Continue',
      onPrimary: onContinue,
      primaryColor: SheetColors.of(context).primary,
    ),
  );
}

/// The last step: a summary to double-check before saving, where the
/// optional title and note are typed straight in. Every other part can be
/// tapped to jump back to its step, which then returns straight here.
class TransactionConfirmPage extends StatelessWidget {
  const TransactionConfirmPage({
    super.key,
    this.isEditing = false,
    required this.type,
    required this.amount,
    required this.account,
    required this.category,
    required this.title,
    required this.note,
    required this.date,
    required this.amountFitsAccount,
    required this.canSave,
    required this.saving,
    required this.error,
    required this.onBack,
    required this.onCancel,
    required this.onSave,
    required this.onEditAmount,
    required this.onEditCategory,
    required this.onEditAccount,
    required this.onEditDate,
    required this.onTitleChanged,
    required this.onNoteChanged,
    this.titleSuggestions,
  });

  /// True when this reopens a saved transaction for editing rather than
  /// confirming a new one — only the header and Save label read differently.
  final bool isEditing;
  final TransactionType type;

  /// The amount, already formatted in [account]'s currency.
  final String amount;
  final Account? account;
  final Category? category;
  final String? title, note, error;
  final DateTime date;

  /// False when the typed amount has more decimal places than [account]'s
  /// currency allows (possible after switching accounts).
  final bool amountFitsAccount;
  final bool canSave, saving;
  final VoidCallback onBack, onCancel, onSave;
  final VoidCallback onEditAmount, onEditCategory, onEditAccount, onEditDate;
  final ValueChanged<String> onTitleChanged, onNoteChanged;

  /// Past titles that fit what's typed so far, offered under the field.
  final List<String> Function(String text)? titleSuggestions;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final isIncome = type == TransactionType.income;
    // Nothing can be changed while the save is in flight.
    VoidCallback? edit(VoidCallback onEdit) => saving ? null : onEdit;
    return SheetPage(
      // Editing is a page of its own, not a step of the Add flow, so it
      // keeps a full-strength title and needs no step heading under it.
      header: isEditing
          ? SheetHeader(
              isIncome ? 'Edit income' : 'Edit expense',
              onBack: onBack,
            )
          : SheetHeader.flow(
              isIncome ? 'Add income' : 'Add expense',
              onBack: onBack,
            ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!isEditing) ...[
            SheetStepHeading(isIncome ? 'Confirm income' : 'Confirm expense'),
            const SizedBox(height: 4),
          ],
          const SizedBox(height: 8),
          InkWell(
            onTap: edit(onEditAmount),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: AmountHero(
                amount: amount,
                caption: isIncome ? 'Income' : 'Expense',
                color: isIncome ? colors.income : colors.expense,
              ),
            ),
          ),
          const SizedBox(height: 16),
          TransactionDetailsCard(
            rows: [
              TransactionTextRow(
                icon: Icons.edit_outlined,
                label: 'Title',
                hintText: 'Add a title',
                initialValue: title ?? '',
                maxLength: 50,
                enabled: !saving,
                onChanged: onTitleChanged,
                suggestions: titleSuggestions,
              ),
              TransactionDetailRow(
                leading: EntityIconTile(
                  chosen: category != null,
                  iconKey: category?.icon,
                  fallback: Icons.category_outlined,
                ),
                label: isIncome ? 'Source' : 'Category',
                value: category?.name ?? '',
                onTap: edit(onEditCategory),
              ),
              TransactionDetailRow(
                leading: EntityIconTile(
                  chosen: account != null,
                  iconKey: account?.icon,
                  fallback: Icons.account_balance_wallet_outlined,
                ),
                label: isIncome ? 'Deposited to' : 'Paid from',
                value: account?.name ?? '',
                onTap: edit(onEditAccount),
              ),
              TransactionDetailRow(
                leading: const SheetIconTile(
                  icon: Icons.calendar_today_rounded,
                ),
                label: 'Date',
                value: formatTransactionDate(date),
                onTap: edit(onEditDate),
              ),
              TransactionTextRow(
                icon: Icons.notes_rounded,
                label: 'Note',
                hintText: 'Add a note',
                initialValue: note ?? '',
                maxLength: 200,
                multiline: true,
                enabled: !saving,
                onChanged: onNoteChanged,
              ),
            ],
          ),
          if (account != null && !amountFitsAccount) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: colors.expense.withValues(alpha: .08),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.error_outline_rounded,
                    size: 20,
                    color: colors.expense,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Too many decimals for ${account!.currency}. Edit the amount or pick another account.',
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.4,
                        color: colors.text,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: colors.expense),
            ),
          ],
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: saving ? null : onCancel,
        primaryLabel: saving
            ? 'Saving…'
            : (isEditing
                  ? 'Save'
                  : (isIncome ? 'Save income' : 'Save expense')),
        onPrimary: saving || !canSave ? null : onSave,
        primaryColor: colors.primary,
      ),
    );
  }
}

/// A saved transaction, read-only, with an Edit button for expenses and
/// income (transfers can't be edited).
class TransactionViewPage extends StatelessWidget {
  const TransactionViewPage({
    super.key,
    required this.transaction,
    required this.account,
    required this.toAccount,
    required this.category,
    required this.onClose,
    required this.onEdit,
    required this.onDelete,
    this.onOpenAccount,
    this.busy = false,
  });
  final MoneyTransaction transaction;
  final Account? account, toAccount;
  final Category? category;
  final VoidCallback onClose;

  /// Opens an account's own screen. Only offered for an archived account,
  /// which is absent from the accounts list — this entry is the way back to
  /// it, to restore it or finish deleting it.
  final void Function(Account account)? onOpenAccount;

  /// Null hides the Edit button (transfers can't be edited).
  final VoidCallback? onEdit;

  /// Null hides the Delete button.
  final VoidCallback? onDelete;

  /// True while a delete is in flight: both buttons disable.
  final bool busy;

  /// A tap handler for an account row, but only where there is somewhere
  /// useful to go: an active account is already in the accounts list, so
  /// only an archived one gets the chevron.
  VoidCallback? _openIfArchived(Account? account) =>
      account == null || !account.isArchived || onOpenAccount == null || busy
      ? null
      : () => onOpenAccount!(account);

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final type = transaction.type;
    final isTransfer = type == TransactionType.transfer;
    final isIncome = type == TransactionType.income;
    final (color, sign, caption) = switch (type) {
      TransactionType.income => (colors.income, '+ ', 'Income'),
      TransactionType.expense => (colors.expense, '- ', 'Expense'),
      TransactionType.transfer => (colors.primary, '', 'Transfer'),
    };
    final customTitle = transaction.title?.trim();
    final title = customTitle != null && customTitle.isNotEmpty
        ? customTitle
        : isTransfer
        ? 'Transfer'
        : category?.name ?? caption;
    final note = transaction.note?.trim();

    final sent = formatTransactionMoney(transaction.amountMinor, account);
    final received = formatTransactionMoney(
      transaction.receivedMinor,
      toAccount,
    );
    // A transfer whose two sides moved different figures — across currencies,
    // or with a charge taken — cannot be told by one number.
    final split = isTransfer && sent != received;
    final crossCurrency =
        isTransfer &&
        account != null &&
        toAccount != null &&
        (account!.currency != toAccount!.currency ||
            account!.digits != toAccount!.digits);
    // Only separable while both sides are in one currency. Across currencies
    // the charge is inside the rate, and the mid-market rate of the day it
    // happened is not recorded — recomputing it from today's table would make
    // a settled transaction's charge drift every time this page is opened.
    final chargeMinor = split && !crossCurrency
        ? transaction.amountMinor - transaction.receivedMinor
        : 0;

    return SheetPage(
      header: SheetHeader('Transaction', onBack: onClose),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          AmountHero(
            amount: split ? '$sent  →  $received' : '$sign$sent',
            caption: caption,
            color: color,
          ),
          const SizedBox(height: 20),
          TransactionDetailsCard(
            rows: [
              TransactionDetailRow(
                leading: const SheetIconTile(icon: Icons.edit_outlined),
                label: 'Title',
                value: title,
                maxLines: 2,
              ),
              TransactionDetailRow(
                leading: EntityIconTile(
                  chosen: account != null,
                  iconKey: account?.icon,
                  fallback: Icons.account_balance_wallet_outlined,
                ),
                label: isTransfer ? 'From' : 'Account',
                value: account?.name ?? 'Deleted account',
                caption: archivedCaption(account),
                onTap: _openIfArchived(account),
                // Each side carries what it actually moved, so the two legs of
                // a cross-currency transfer can be read off separately.
                trailing: split ? '- $sent' : null,
              ),
              if (isTransfer) ...[
                TransactionDetailRow(
                  leading: EntityIconTile(
                    chosen: toAccount != null,
                    iconKey: toAccount?.icon,
                    fallback: Icons.account_balance_wallet_outlined,
                  ),
                  label: 'To',
                  value: toAccount?.name ?? 'Deleted account',
                  caption: archivedCaption(toAccount),
                  onTap: _openIfArchived(toAccount),
                  trailing: split ? '+ $received' : null,
                ),
                if (crossCurrency)
                  TransactionDetailRow(
                    leading: const SheetIconTile(
                      icon: Icons.swap_horiz_rounded,
                    ),
                    label: 'Rate applied',
                    value: formatExchangeRate(
                      transaction.amountMinor,
                      account,
                      transaction.receivedMinor,
                      toAccount,
                    ),
                  ),
                if (chargeMinor > 0)
                  TransactionDetailRow(
                    leading: const SheetIconTile(
                      icon: Icons.receipt_long_outlined,
                    ),
                    label: 'Charge',
                    value: formatTransactionMoney(chargeMinor, account),
                  ),
              ] else
                TransactionDetailRow(
                  leading: EntityIconTile(
                    chosen: category != null,
                    iconKey: category?.icon,
                    fallback: Icons.category_outlined,
                  ),
                  label: isIncome ? 'Source' : 'Category',
                  value: category?.name ?? 'Deleted category',
                ),
              TransactionDetailRow(
                leading: const SheetIconTile(
                  icon: Icons.calendar_today_rounded,
                ),
                label: 'Date',
                value: DateFormat('MMM d, yyyy · h:mm a')
                    .format(transaction.date),
              ),
              if (note != null && note.isNotEmpty)
                TransactionDetailRow(
                  leading: const SheetIconTile(icon: Icons.notes_rounded),
                  label: 'Note',
                  value: note,
                  maxLines: 6,
                ),
            ],
          ),
        ],
      ),
      actions: onEdit == null && onDelete == null
          ? null
          : ActionButtonBar(
              secondaryLabel: onDelete == null ? null : 'Delete',
              onSecondary: busy ? null : onDelete,
              secondaryForegroundColor: colors.expense,
              primaryLabel: onEdit == null ? null : 'Edit',
              onPrimary: busy ? null : onEdit,
            ),
    );
  }
}
