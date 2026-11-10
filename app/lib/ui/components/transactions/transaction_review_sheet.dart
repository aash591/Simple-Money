import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../data/repositories/transaction_repository.dart';
import '../../../domain/account.dart';
import '../../../domain/category.dart';
import '../../../domain/loan.dart';
import '../../../domain/transaction.dart';
import '../../../state/account_store.dart';
import '../../../state/category_store.dart';
import '../../theme/app_theme.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/quick_add_helpers.dart';
import '../../transactions/transaction_widgets.dart';
import '../action_buttons.dart';
import '../adaptive_sheet.dart';
import '../app_icon.dart';
import '../choice_list_sheet.dart';
import '../date_picker_sheet.dart';
import '../text_entry_alert.dart';
import 'review_pickers.dart';
import 'transaction_review_content.dart';

/// A transaction being reviewed or edited: what [TransactionReviewSheet]
/// starts from and hands back. For a transfer, [accountId] is where the
/// money left and [toAccountId] where it arrived.
class ReviewDraft {
  ReviewDraft({
    required this.type,
    required this.amountMinor,
    required this.currency,
    required this.digits,
    required this.date,
    this.title = '',
    this.categoryId,
    this.accountId,
    this.toAccountId,
    this.note,
  });
  TransactionType type;
  int amountMinor;
  final String currency;
  final int digits;
  DateTime date;
  String title;
  int? categoryId, accountId, toAccountId;
  String? note;

  /// The loan this payment goes to, chosen in place of a category.
  int? loanId;

  bool get transfer => type == TransactionType.transfer;
}

/// Opens [TransactionReviewSheet] the way SMS review opens: same entrance,
/// same size.
Future<void> showTransactionReviewSheet(
  BuildContext context, {
  required String heading,
  required ReviewDraft draft,
  required AccountStore accounts,
  required CategoryStore categories,
  required Future<void> Function(ReviewDraft draft) onSave,
  List<TransactionType> types = TransactionType.values,
  TransactionLocks locks = const TransactionLocks(),
  List<Loan> loans = const [],
  bool editAmount = true,
  bool editTitle = true,
  bool editDate = true,
  bool editNote = true,
  Widget? notice,
  String? sourceHeading,
  IconData? sourceIcon,
  String? sourceDetail,
  String? sourceText,
  String saveLabel = 'Save',
}) => showAdaptiveSheet<void>(
  context,
  entrance: SheetEntrance.fadeRise,
  dismissible: false,
  topClearance: 62,
  builder: (_) => TransactionReviewSheet(
    heading: heading,
    draft: draft,
    accounts: accounts,
    categories: categories,
    onSave: onSave,
    types: types,
    locks: locks,
    loans: loans,
    editAmount: editAmount,
    editTitle: editTitle,
    editDate: editDate,
    editNote: editNote,
    notice: notice,
    sourceHeading: sourceHeading,
    sourceIcon: sourceIcon,
    sourceDetail: sourceDetail,
    sourceText: sourceText,
    saveLabel: saveLabel,
  ),
);

/// The SMS preview's layout for any transaction: kind, amount, title and
/// date up top, a "Record as" switch, then category and account choices.
/// Works on a copy of [draft] and calls [onSave] with it; the caller decides
/// what saving means (a database edit, or keeping it on a statement row).
///
/// [types] are what it may be recorded as; [locks] are fields an owning
/// loan, debt or recurring payment keeps.
class TransactionReviewSheet extends StatefulWidget {
  const TransactionReviewSheet({
    super.key,
    required this.heading,
    required this.draft,
    required this.accounts,
    required this.categories,
    required this.onSave,
    this.types = TransactionType.values,
    this.locks = const TransactionLocks(),
    this.loans = const [],
    this.editAmount = true,
    this.editTitle = true,
    this.editDate = true,
    this.editNote = true,
    this.notice,
    this.sourceHeading,
    this.sourceIcon,
    this.sourceDetail,
    this.sourceText,
    this.saveLabel = 'Save',
  });
  final String heading;
  final ReviewDraft draft;
  final AccountStore accounts;
  final CategoryStore categories;
  final Future<void> Function(ReviewDraft draft) onSave;
  final List<TransactionType> types;
  final TransactionLocks locks;

  /// Open loans this can become a payment of; none leaves the choice out, for
  /// a caller with no saved transaction to link.
  final List<Loan> loans;
  final bool editAmount, editTitle, editDate, editNote;
  final Widget? notice;
  final String? sourceHeading;
  final IconData? sourceIcon;
  final String? sourceDetail, sourceText;
  final String saveLabel;

  @override
  State<TransactionReviewSheet> createState() => _TransactionReviewSheetState();
}

class _TransactionReviewSheetState extends State<TransactionReviewSheet> {
  late final ReviewDraft d = ReviewDraft(
    type: widget.draft.type,
    amountMinor: widget.draft.amountMinor,
    currency: widget.draft.currency,
    digits: widget.draft.digits,
    date: widget.draft.date,
    title: widget.draft.title,
    categoryId: widget.draft.categoryId,
    accountId: widget.draft.accountId,
    toAccountId: widget.draft.toAccountId,
    note: widget.draft.note,
  );
  bool busy = false;
  String? error;

  TransactionLocks get locks => widget.locks;
  List<TransactionType> get types => [
    for (final type in widget.types)
      if (type != TransactionType.transfer ||
          !locks.transfer ||
          widget.draft.transfer)
        type,
  ];

  Account? account(int? id) => widget.accounts.byId(id);
  Category? category(int? id) =>
      widget.categories.categories.where((c) => c.id == id).firstOrNull;

  bool get valid =>
      d.amountMinor > 0 &&
      d.accountId != null &&
      (d.transfer
          ? d.toAccountId != null && d.toAccountId != d.accountId
          : d.categoryId != null || d.loanId != null);

  Loan? get _loan => widget.loans.where((l) => l.id == d.loanId).firstOrNull;

  List<Account> get _cards =>
      repayableCards(widget.accounts.accounts, d.currency, d.digits);

  /// Switching kind keeps the account the money actually moved through: an
  /// income's account is where a transfer arrived, and the other way round.
  void setType(TransactionType type) => setState(() {
    final was = d.type;
    if (was == type) return;
    if (type == TransactionType.transfer) {
      if (was == TransactionType.income) {
        d.toAccountId = d.accountId;
        d.accountId = null;
      }
    } else if (was == TransactionType.transfer) {
      if (type == TransactionType.income) d.accountId = d.toAccountId;
      d.toAccountId = null;
    }
    d.type = type;
    d.loanId = null;
    final picked = category(d.categoryId);
    if (picked == null || picked.type != _categoryType) d.categoryId = null;
    // Back where it started: restore what was there.
    if (type == widget.draft.type && d.categoryId == null) {
      d.categoryId = widget.draft.categoryId;
    }
  });

  CategoryType get _categoryType => d.type == TransactionType.income
      ? CategoryType.income
      : CategoryType.expense;

  Future<void> pickCategory() async {
    final expense = d.type == TransactionType.expense;
    final canTransfer = types.contains(TransactionType.transfer) && !locks.type;
    final pick = await showReviewCategoryPicker(
      context,
      title: widget.heading,
      categories: widget.categories.categories,
      store: widget.categories,
      type: _categoryType,
      selected: d.categoryId,
      shortcuts: CategoryShortcuts(
        transfer: canTransfer,
        cardRepayment: canTransfer && expense && _cards.isNotEmpty,
        loans: [
          if (expense)
            for (final loan in widget.loans)
              if (loan.terms.currency == d.currency &&
                  loan.terms.digits == d.digits)
                loan,
        ],
      ),
    );
    if (!mounted || pick == null) return;
    if (pick.transfer) {
      setType(TransactionType.transfer);
    } else if (pick.cardRepayment) {
      setType(TransactionType.transfer);
      final cards = _cards.where((c) => c.id != d.accountId).toList();
      if (cards.length == 1) {
        setState(() => d.toAccountId = cards.single.id);
      } else {
        await pickAccount(destination: true, cardsOnly: true);
      }
    } else {
      setState(() {
        d.loanId = pick.loanId;
        d.categoryId = pick.categoryId ?? d.categoryId;
      });
    }
  }

  Future<void> pickAccount({
    bool destination = false,
    bool cardsOnly = false,
  }) async {
    final other = destination ? d.accountId : d.toAccountId;
    bool fits(Account? a) =>
        a != null &&
        a.archivedAt == null &&
        a.currency == d.currency &&
        a.digits == d.digits &&
        (!cardsOnly || a.type == AccountType.creditCard) &&
        (!d.transfer || a.id != other);
    final id = await showReviewAccountPicker(
      context,
      title: widget.heading,
      heading: _accountLabel(destination),
      selected: destination ? d.toAccountId : d.accountId,
      items: [
        for (final a in widget.accounts.accounts)
          if (fits(a))
            ChoiceItem(
              value: a.id,
              icon: AppIcon(a.icon, size: 28),
              label: a.name,
              subtitle: formatTransactionMoney(a.balanceMinor, a),
              chevron: true,
            ),
      ],
      onAdd: (context) async {
        final a = await addAccountAndSelect(
          context,
          widget.accounts,
          initialCurrency: d.currency,
        );
        return fits(a) ? a!.id : null;
      },
    );
    if (mounted && id != null) {
      setState(() => destination ? d.toAccountId = id : d.accountId = id);
    }
  }

  String _accountLabel(bool destination) => d.transfer
      ? (destination ? 'Transfer to' : 'Transfer from')
      : d.type == TransactionType.income
      ? 'Received in'
      : 'Paid from';

  Future<void> editAmount() async {
    final text = await showTextEntryAlert(
      context,
      title: 'Amount',
      initialValue: formatAccountAmount(
        d.amountMinor,
        digits: d.digits,
        currency: d.currency,
      ).replaceAll(',', ''),
      maxLength: 15,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
    );
    if (text == null || !mounted) return;
    final minor = parseAccountAmount(text.replaceAll(',', ''), d.digits);
    if (minor == null || minor <= 0) {
      setState(() => error = 'Enter an amount greater than zero.');
      return;
    }
    setState(() {
      d.amountMinor = minor;
      error = null;
    });
  }

  Future<void> editTitle() async {
    final text = await showTextEntryAlert(
      context,
      title: 'Title',
      initialValue: d.title,
      allowEmpty: true,
    );
    if (text != null && mounted) setState(() => d.title = text);
  }

  Future<void> editNote() async {
    final text = await showTextEntryAlert(
      context,
      title: 'Note',
      initialValue: d.note ?? '',
      maxLength: 500,
      multiline: true,
      allowEmpty: true,
    );
    if (text != null && mounted) {
      setState(() => d.note = text.isEmpty ? null : text);
    }
  }

  Future<void> editDate() async {
    final day = await showDatePickerSheet(context, initialDate: d.date);
    if (day == null || !mounted) return;
    // A new day keeps the time it happened.
    setState(
      () => d.date = DateTime(
        day.year,
        day.month,
        day.day,
        d.date.hour,
        d.date.minute,
        d.date.second,
      ),
    );
  }

  Future<void> save() async {
    if (!valid || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await widget.onSave(d);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = switch (e) {
            ArgumentError(:final message) => '$message',
            StateError(:final message) => message,
            _ => 'Could not save this. Try again.',
          };
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final picked = category(d.categoryId);
    final from = account(d.accountId), to = account(d.toAccountId);
    final color = switch (d.type) {
      TransactionType.income => green,
      TransactionType.expense => colors.expense,
      TransactionType.transfer => colors.primary,
    };
    VoidCallback? unless(bool locked, VoidCallback action) =>
        busy || locked ? null : action;
    final divider = Divider(height: 1, indent: 64, color: colors.divider);
    return PopScope(
      canPop: !busy,
      child: SheetPage(
        header: SheetHeader.flow(
          widget.heading,
          onBack: busy ? null : () => Navigator.pop(context),
        ),
        body: TransactionReviewContent<TransactionType>(
          badge: switch (d.type) {
            TransactionType.income => 'Money received',
            TransactionType.expense => 'Money paid',
            TransactionType.transfer => 'Between your accounts',
          },
          color: color,
          badgeIcon: switch (d.type) {
            TransactionType.income => Icons.south_west_rounded,
            TransactionType.expense => Icons.north_east_rounded,
            TransactionType.transfer => Icons.swap_horiz_rounded,
          },
          amount: formatAccountMoney(
            d.amountMinor,
            currency: d.currency,
            digits: d.digits,
          ),
          onEditAmount: widget.editAmount && !locks.amount
              ? unless(false, editAmount)
              : null,
          title: d.transfer
              ? '${from?.name ?? 'Account'} → ${to?.name ?? 'Account'}'
              : d.title.isEmpty
              ? (picked?.name ?? 'Add a title')
              : d.title,
          onEditTitle: widget.editTitle && !d.transfer
              ? unless(false, editTitle)
              : null,
          date: formatTransactionDate(d.date),
          onEditDate: widget.editDate && !locks.date
              ? unless(false, editDate)
              : null,
          notice: widget.notice,
          kinds: [
            for (final type in types)
              ReviewKind(
                type,
                switch (type) {
                  TransactionType.expense => 'Expense',
                  TransactionType.income => 'Income',
                  TransactionType.transfer => 'Transfer',
                },
                switch (type) {
                  TransactionType.transfer => Icons.swap_horiz,
                  _ => Icons.category_outlined,
                },
              ),
          ],
          kind: d.type,
          onKindChanged: busy || locks.type ? null : setType,
          rows: [
            if (!d.transfer) ...[
              ReviewChoiceRow(
                label: d.type == TransactionType.income ? 'Source' : 'Category',
                value: _loan?.title ?? picked?.name ?? 'Choose category',
                icon: AppIcon(_loan?.icon ?? picked?.icon, size: 30),
                locked: locks.category,
                onTap: unless(locks.category, pickCategory),
              ),
              divider,
            ],
            ReviewChoiceRow(
              label: _accountLabel(false),
              value: from?.name ?? 'Choose ${d.currency} account',
              icon: AppIcon(from?.icon ?? 'bank', size: 30),
              locked: locks.accounts,
              onTap: unless(locks.accounts, () => pickAccount()),
            ),
            if (d.transfer) ...[
              divider,
              ReviewChoiceRow(
                label: _accountLabel(true),
                value: to?.name ?? 'Choose ${d.currency} account',
                icon: AppIcon(to?.icon ?? 'bank_transfer', size: 30),
                locked: locks.accounts,
                onTap: unless(
                  locks.accounts,
                  () => pickAccount(destination: true),
                ),
              ),
            ],
            if (widget.editNote) ...[
              divider,
              ReviewChoiceRow(
                label: 'Note',
                value: d.note?.trim().isNotEmpty == true
                    ? d.note!.trim()
                    : 'Add a note',
                icon: Icon(Icons.notes_rounded, color: colors.primary),
                onTap: unless(false, editNote),
              ),
            ],
          ],
          sourceHeading: widget.sourceHeading ?? 'Original message',
          sourceIcon: widget.sourceIcon ?? Icons.sms_outlined,
          sourceDetail: widget.sourceDetail,
          sourceText: widget.sourceText,
          error: error,
        ),
        actions: ActionButtonBar(
          secondaryLabel: 'Cancel',
          onSecondary: busy ? null : () => Navigator.pop(context),
          primaryLabel: busy ? 'Saving…' : widget.saveLabel,
          onPrimary: valid && !busy ? save : null,
        ),
      ),
    );
  }
}

/// "Part of loan HDFC Home Loan" over what it keeps, with a way there.
class TransactionLinkNotice extends StatelessWidget {
  const TransactionLinkNotice({super.key, required this.link, this.onOpen});
  final TransactionLink link;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final (owner, icon, kept) = switch (link.kind) {
      TransactionLinkKind.loan => (
        'loan',
        Icons.account_balance_outlined,
        'Its amount, account and date come from the loan.',
      ),
      TransactionLinkKind.debt => (
        'debt with',
        Icons.handshake_outlined,
        'Its amount, account and date come from the debt.',
      ),
      TransactionLinkKind.recurringPayment => (
        'recurring payment',
        Icons.autorenew_rounded,
        'It stays a payment; correct the amount or date here.',
      ),
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 6, 10),
      decoration: BoxDecoration(
        color: colors.primary.withValues(alpha: .08),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: colors.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Part of $owner ${link.name}',
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(kept, style: TextStyle(color: colors.muted, fontSize: 12)),
              ],
            ),
          ),
          if (onOpen != null)
            TextButton(
              onPressed: () {
                HapticFeedback.selectionClick();
                onOpen!();
              },
              child: const Text('Open'),
            ),
        ],
      ),
    );
  }
}
