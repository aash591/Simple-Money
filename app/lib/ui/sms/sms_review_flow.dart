import '../components/app_icon.dart';
import '../theme/sheet_colors.dart';
import 'sms_suggestions.dart';
import 'sms_preview_content.dart';

import 'package:flutter/material.dart';

import '../../data/repositories/sms_import_repository.dart';
import '../../domain/account.dart';
import '../../domain/category.dart';
import '../../domain/loan.dart';
import '../../domain/transaction.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import '../../state/loan_store.dart';
import '../../state/transaction_store.dart';
import '../../state/sms_import_store.dart';
import '../components/adaptive_sheet.dart';
import '../components/choice_list_sheet.dart';
import '../components/action_buttons.dart';
import '../components/transactions/review_pickers.dart';
import '../more/loans/loan_widgets.dart';
import '../transactions/quick_add_helpers.dart';
import '../transactions/transaction_widgets.dart';

class SmsReviewFlow extends StatefulWidget {
  const SmsReviewFlow({
    super.key,
    required this.sms,
    required this.store,
    required this.accounts,
    required this.categories,
    required this.transactions,
  });
  final PendingSmsImport sms;
  final SmsImportStore store;
  final AccountStore accounts;
  final CategoryStore categories;
  final TransactionStore transactions;
  @override
  State<SmsReviewFlow> createState() => _SmsReviewFlowState();
}

class _SmsReviewFlowState extends State<SmsReviewFlow> {
  bool transfer = false, busy = false;
  int? categoryId, accountId, toAccountId;

  /// The title as edited here; null keeps the message's own name.
  String? _title;

  /// The loan this payment goes to, chosen in place of a category.
  int? loanId;
  List<Category>? draftCategories;
  List<Category> get reviewCategories =>
      draftCategories ?? widget.categories.categories;
  String? error;
  TransactionType get type =>
      widget.sms.credit ? TransactionType.income : TransactionType.expense;
  CategoryType get categoryType =>
      widget.sms.credit ? CategoryType.income : CategoryType.expense;
  Account? account(int? id) => widget.accounts.byId(id);
  @override
  void initState() {
    super.initState();
    // An approved correction already says which loan this pays.
    loanId = widget.sms.assignedLoanId;
    _loadDraftCategories();
    accountId = smsAccount(
      widget.sms,
      widget.store,
      widget.accounts.accounts,
    )?.id;
    categoryId =
        widget.store.selectedCategories[widget.sms.id] ??
        smsCategory(widget.sms, widget.categories.categories)?.id;
    if (widget.sms.requiresTransfer) {
      transfer = true;
      categoryId = null;
      if (widget.sms.credit) {
        toAccountId = accountId;
        accountId = null;
      }
      if (widget.sms.isAtmDeposit) {
        accountId = smsCashAccount(widget.sms, widget.accounts.accounts)?.id;
      }
      if (widget.sms.isAtmWithdrawal) {
        toAccountId = smsCashAccount(widget.sms, widget.accounts.accounts)?.id;
      }
    }
  }

  LoanStore? get _loanStore => LoanStoreScope.maybeOf(context);

  /// Open loans this message's money can go to.
  List<Loan> get _loans => [
    for (final loan in _loanStore?.loans ?? const <Loan>[])
      if (!loan.closed && loan.terms.currency == widget.sms.currency) loan,
  ];

  Loan? get _loan => _loans.where((l) => l.id == loanId).firstOrNull;

  List<Account> get _cards => repayableCards(
    widget.accounts.accounts,
    widget.sms.currency,
    widget.sms.digits,
  );

  void setTransfer(bool value) => setState(() {
    transfer = value;
    loanId = null;
    if (transfer && widget.sms.credit) {
      toAccountId = accountId;
      accountId = null;
    } else {
      accountId ??= smsAccount(
        widget.sms,
        widget.store,
        widget.accounts.accounts,
      )?.id;
      toAccountId = null;
    }
  });

  Future<void> pickCategory() async {
    final debit = !widget.sms.credit;
    final pick = await showSmsCategoryPicker(
      context,
      categories: reviewCategories,
      store: widget.categories,
      type: categoryType,
      selected: categoryId,
      shortcuts: CategoryShortcuts(
        transfer: true,
        cardRepayment: debit && _cards.isNotEmpty,
        loans: debit ? _loans : const [],
      ),
    );
    if (!mounted || pick == null) return;
    if (pick.transfer) {
      setTransfer(true);
    } else if (pick.cardRepayment) {
      setTransfer(true);
      final cards = _cards.where((c) => c.id != accountId).toList();
      if (cards.length == 1) {
        setState(() => toAccountId = cards.single.id);
      } else {
        await pickAccount(destination: true, cardsOnly: true);
      }
    } else {
      setState(() {
        loanId = pick.loanId;
        categoryId = pick.categoryId ?? categoryId;
      });
    }
  }

  Future<void> pickAccount({
    bool destination = false,
    bool cardsOnly = false,
  }) async {
    final id = await showSmsAccountPicker(
      context,
      heading: destination
          ? 'Transfer to'
          : transfer
          ? 'Transfer from'
          : widget.sms.credit
          ? 'Received in'
          : 'Paid from',
      selected: destination ? toAccountId : accountId,
      items: [
        for (final a in widget.accounts.accounts)
          if (a.currency == widget.sms.currency &&
              a.archivedAt == null &&
              a.digits == widget.sms.digits &&
              (!cardsOnly || a.type == AccountType.creditCard) &&
              (!widget.sms.isAtmCashMovement ||
                  ((destination != widget.sms.isAtmDeposit)
                      ? a.type == AccountType.cash
                      : a.type == AccountType.bank)) &&
              (!widget.sms.isCreditCardRepayment ||
                  (destination
                      ? a.type == AccountType.creditCard
                      : a.type != AccountType.creditCard)) &&
              (!transfer || a.id != (destination ? accountId : toAccountId)))
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
          initialName:
              widget.sms.isAtmCashMovement &&
                  (destination != widget.sms.isAtmDeposit)
              ? 'Cash'
              : widget.sms.bankName,
          initialIcon:
              widget.sms.isAtmCashMovement &&
                  (destination != widget.sms.isAtmDeposit)
              ? 'wallet_one'
              : smsBankIcon(widget.sms),
          initialType:
              widget.sms.isAtmCashMovement &&
                  (destination != widget.sms.isAtmDeposit)
              ? AccountType.cash
              : AccountType.bank,
          initialCurrency: widget.sms.currency,
        );
        return a?.currency == widget.sms.currency &&
                (!widget.sms.isAtmCashMovement ||
                    ((destination != widget.sms.isAtmDeposit)
                        ? a?.type == AccountType.cash
                        : a?.type == AccountType.bank)) &&
                a?.digits == widget.sms.digits &&
                (!widget.sms.isCreditCardRepayment ||
                    (destination
                        ? a?.type == AccountType.creditCard
                        : a?.type != AccountType.creditCard))
            ? a?.id
            : null;
      },
    );
    if (mounted && id != null) {
      setState(() => destination ? toAccountId = id : accountId = id);
    }
  }

  bool get valid =>
      accountId != null &&
      (transfer
          ? toAccountId != null && accountId != toAccountId
          : categoryId != null || _loan != null);
  Future<void> save() async {
    if (!valid || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      final sms = widget.sms;
      final imports = widget.store.repository;
      Future<void> saveAs(int? category) => imports.save(
        sms,
        type: transfer ? TransactionType.transfer : type,
        amountMinor: sms.amountMinor,
        accountId: accountId!,
        toAccountId: transfer ? toAccountId : null,
        categoryId: transfer ? null : category,
        title: (_title ?? sms.title).trim().isEmpty
            ? sms.title
            : (_title ?? sms.title).trim(),
        note: sms.originalSmsNote,
        date: sms.receivedAt,
      );
      final loans = _loanStore;
      if (_loan case final loan? when !transfer && loans != null) {
        // Together: a payment the loan refuses leaves the message to review.
        final repository = loans.repository;
        await imports.database.transaction(() async {
          await saveAs(await repository.paymentCategory());
          await repository.payWith(
            loan.id,
            (await imports.transactionOf(sms.id))!,
          );
        });
      } else {
        await saveAs(categoryId);
      }
      await refresh();
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = loanId != null
              ? loanError(e)
              : 'Could not save this transaction. Try again.';
        });
      }
    }
  }

  Future<void> _loadDraftCategories() async {
    final categories = await widget.categories.repository.load(
      includeDrafts: true,
    );
    if (!mounted) return;
    setState(() {
      draftCategories = categories;
      if (!widget.store.selectedCategories.containsKey(widget.sms.id)) {
        categoryId = smsCategory(widget.sms, categories)?.id;
      }
    });
  }

  Future<void> refresh() async {
    await widget.store.reload();
    await Future.wait([
      widget.transactions.load(),
      widget.accounts.load(),
      widget.categories.load(),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final sms = widget.sms;
    final colors = SheetColors.of(context);
    final category =
        reviewCategories.where((c) => c.id == categoryId).firstOrNull ??
        (categoryId != null && categoryId! < 0
            ? smsCategory(sms, reviewCategories)
            : null);
    return SheetPage(
      header: SheetHeader.flow(
        'SMS preview',
        onBack: busy ? null : () => Navigator.pop(context),
      ),
      body: SmsPreviewContent(
        sms: sms,
        transfer: transfer,
        title: _title,
        onTitleChanged: busy ? null : (text) => _title = text,
        titleSuggestions: (text) => widget.transactions.titleSuggestions
            .suggest(text, type: type, categoryId: categoryId),
        onTransferChanged: busy || sms.requiresTransfer ? null : setTransfer,
        helper: transfer
            ? sms.isAtmDeposit
                  ? 'ATM deposit. Moves money from cash to your bank.'
                  : sms.isAtmWithdrawal
                  ? 'ATM withdrawal. Transfer from the withdrawal account to your cash account.'
                  : sms.isCreditCardRepayment
                  ? 'Credit card repayment. Choose the paying account and credit card.'
                  : null
            : sms.needsCategoryConfirmation
            ? 'Auto debit (NACH). Choose what it was for: EMI, insurance, investment or bill.'
            : null,
        error: error,
        rows: [
          if (!transfer) ...[
            SmsPreviewChoice(
              label: 'Category',
              value: _loan?.title ?? category?.name ?? 'Choose category',
              icon: AppIcon(_loan?.icon ?? category?.icon, size: 30),
              onTap: busy ? null : pickCategory,
            ),
            Divider(height: 1, indent: 64, color: colors.divider),
          ],
          SmsPreviewChoice(
            label: transfer
                ? 'Transfer from'
                : sms.credit
                ? 'Received in'
                : 'Paid from',
            value: account(accountId)?.name ?? 'Choose ${sms.currency} account',
            detail: sms.accountLast4 != null && (!transfer || !sms.credit)
                ? 'Account ending ${sms.accountLast4}'
                : null,
            icon: AppIcon(
              account(accountId)?.icon ?? smsBankIcon(sms),
              size: 30,
            ),
            onTap: busy ? null : () => pickAccount(),
          ),
          if (transfer) ...[
            Divider(height: 1, indent: 64, color: colors.divider),
            SmsPreviewChoice(
              label: 'Transfer to',
              value:
                  account(toAccountId)?.name ??
                  'Choose ${sms.currency} account',
              detail: sms.credit && sms.accountLast4 != null
                  ? 'Account ending ${sms.accountLast4}'
                  : null,
              icon: AppIcon(
                account(toAccountId)?.icon ?? 'bank_transfer',
                size: 30,
              ),
              onTap: busy ? null : () => pickAccount(destination: true),
            ),
          ],
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: busy ? null : () => Navigator.pop(context),
        primaryLabel: busy ? 'Saving...' : 'Save',
        onPrimary: valid && !busy ? save : null,
      ),
    );
  }
}
