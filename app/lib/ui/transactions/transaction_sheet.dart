import 'package:simple_money/state/vibration_settings.dart';
import 'package:flutter/material.dart';

import '../../domain/account.dart';
import '../../domain/category.dart';
import '../../domain/transaction.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import '../../state/transaction_store.dart';
import '../../state/loan_store.dart';
import '../../state/debt_store.dart';
import '../../domain/debt.dart';
import '../../domain/loan.dart';
import '../more/debts/debt_sheet.dart';
import '../more/debts/debt_widgets.dart';
import '../components/transactions/review_pickers.dart';
import '../more/loans/loan_action_sheet.dart';
import '../more/loans/loan_detail_screen.dart';
import '../../state/upi_settings.dart';
import '../../data/repositories/transaction_repository.dart';
import '../components/adaptive_sheet.dart';
import '../components/transactions/transaction_review_sheet.dart';
import '../components/app_icon.dart';
import '../components/app_toast.dart';
import '../components/choice_list_sheet.dart';
import '../components/confirmation_alert.dart';
import '../components/feature_page.dart';
import '../more/accounts/edit_account_screen.dart';
import 'amount_typing.dart';
import 'amount_calculator.dart';
import 'quick_add_helpers.dart';
import 'transaction_pages.dart';
import 'transaction_widgets.dart';
import 'transfer_sheet.dart';
import '../upi/upi_payment_flow.dart';

/// Which page of the transaction sheet is showing. Declared in visual
/// order, so comparing indexes tells which way to slide, and the entry
/// steps from [amount] to [confirm] follow one another in this order.
enum TransactionStep {
  view,
  type,
  amount,
  category,
  subcategory,
  account,
  date,
  confirm,
  upi,
  transfer,
  debt,
  loanPick,
  loanPay,
}

/// A row at the end of Choose category that is not a category: it carries on
/// into the debt flow instead.
const _debtChoice = -1;

/// Steps with a text field of their own (the pickers' search bars, and the
/// title and note on Confirm), where the sheet lifts above the keyboard.
/// Elsewhere it stays put under text popups stacked above it.
const _typingSteps = {
  TransactionStep.category,
  TransactionStep.subcategory,
  TransactionStep.account,
  TransactionStep.confirm,
  // Opens on the source picker; the transfer then sets this per step itself.
  TransactionStep.transfer,
  TransactionStep.debt,
  TransactionStep.loanPick,
  TransactionStep.loanPay,
};

/// Space kept clear above the sheet so, at its tallest (the Category step),
/// it stops just below Home's "SimpleMoney" header row: the list's 14dp top
/// padding plus the 48dp row (see `HomeDashboard`).
const _brandingClearance = 62.0;

/// Everything the Add/Edit flow has collected so far. Editing pre-fills it
/// from the saved transaction and keeps that transaction's id, so saving
/// updates it instead of adding a new one.
class TransactionDraft {
  TransactionDraft({
    this.type = TransactionType.expense,
    this.amountText = '',
    this.title,
    this.categoryId,
    this.accountId,
    DateTime? date,
    this.note,
    this.existingTransactionId,
  }) : date = date ?? DateTime.now();

  factory TransactionDraft.fromTransaction(
    MoneyTransaction transaction, {
    required int digits,
  }) => TransactionDraft(
    type: transaction.type,
    amountText: AmountTyping.fromMinor(transaction.amountMinor, digits),
    title: transaction.title,
    categoryId: transaction.categoryId,
    accountId: transaction.accountId,
    date: transaction.date,
    note: transaction.note,
    existingTransactionId: transaction.id,
  );

  TransactionType type;

  /// Exactly what was typed on the keypad, e.g. "1250.5".
  String amountText;
  String? title;
  int? categoryId;
  int? accountId;
  DateTime date;
  String? note;
  final int? existingTransactionId;
}

/// The + button's flow: Choose type → Amount → Category → Account → Date →
/// Confirm (where the title and note are typed). Tapping the scrim does
/// nothing here, so a half-entered transaction isn't lost to a stray tap;
/// Cancel, back, or dragging down closes it.
Future<void> showAddTransactionSheet(
  BuildContext context, {
  required AccountStore accountStore,
  required CategoryStore categoryStore,
  required TransactionStore transactionStore,
  TransactionType? initialType,
}) => showAdaptiveSheet<void>(
  context,
  entrance: SheetEntrance.fadeRise,
  dismissible: false,
  topClearance: _brandingClearance,
  avoidKeyboard: false,
  builder: (_) => TransactionSheet(
    accountStore: accountStore,
    categoryStore: categoryStore,
    transactionStore: transactionStore,
    initialType: initialType,
  ),
);

/// Opens [transaction] read-only, from which expenses and income can be
/// edited in the same sheet: View → Confirm, its fields editable in place.
Future<void> showViewTransactionSheet(
  BuildContext context, {
  required MoneyTransaction transaction,
  required AccountStore accountStore,
  required CategoryStore categoryStore,
  required TransactionStore transactionStore,
}) => showAdaptiveSheet<void>(
  context,
  entrance: SheetEntrance.fadeRise,
  topClearance: _brandingClearance,
  avoidKeyboard: false,
  builder: (_) => TransactionSheet(
    transaction: transaction,
    accountStore: accountStore,
    categoryStore: categoryStore,
    transactionStore: transactionStore,
  ),
);

/// Opens a transaction that isn't saved yet — one an AI app suggested — on
/// the edit page, so it can be corrected. Saving hands the result to
/// [onSave] rather than adding it to the ledger.
Future<void> showSuggestedTransactionSheet(
  BuildContext context, {
  required TransactionDraft draft,
  required Future<void> Function(TransactionDraft) onSave,
  required AccountStore accountStore,
  required CategoryStore categoryStore,
  required TransactionStore transactionStore,
}) => showAdaptiveSheet<void>(
  context,
  entrance: SheetEntrance.fadeRise,
  dismissible: false,
  topClearance: _brandingClearance,
  avoidKeyboard: false,
  builder: (_) => TransactionSheet(
    initialDraft: draft,
    onSaveDraft: onSave,
    accountStore: accountStore,
    categoryStore: categoryStore,
    transactionStore: transactionStore,
  ),
);

/// [draft] as the edit page shows it, for looking only: Save stays off. For
/// an entry a shared SMS fix would make, so how it reads can be checked.
Future<void> showPreviewTransactionSheet(
  BuildContext context, {
  required TransactionDraft draft,
  required AccountStore accountStore,
  required CategoryStore categoryStore,
  required TransactionStore transactionStore,
}) => showAdaptiveSheet<void>(
  context,
  entrance: SheetEntrance.fadeRise,
  topClearance: _brandingClearance,
  avoidKeyboard: false,
  builder: (_) => TransactionSheet(
    initialDraft: draft,
    onSaveDraft: (_) async {},
    readOnly: true,
    accountStore: accountStore,
    categoryStore: categoryStore,
    transactionStore: transactionStore,
  ),
);

/// Add, view, and edit are one sheet with one draft — see FLUTTER_GUIDE.md
/// §5. Editing opens straight on the Confirm page (its fields editable in
/// place, with Cancel/Save) rather than sliding through the Add wizard;
/// tapping a field still drills into that field's own picker or keypad.
class TransactionSheet extends StatefulWidget {
  const TransactionSheet({
    super.key,
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    this.transaction,
    this.initialType,
    this.initialDraft,
    this.onSaveDraft,
    this.requiredCurrency,
    this.readOnly = false,
  });
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;

  /// The saved transaction to show, opening on the View page; null opens
  /// on Choose type to add a new one.
  final MoneyTransaction? transaction;
  final TransactionType? initialType;
  final String? requiredCurrency;
  final TransactionDraft? initialDraft;
  final Future<void> Function(TransactionDraft)? onSaveDraft;

  /// Shown to look at only: Save is never on.
  final bool readOnly;

  @override
  State<TransactionSheet> createState() => _TransactionSheetState();
}

class _TransactionSheetState extends State<TransactionSheet> {
  late TransactionStep _step = widget.initialDraft != null
      ? TransactionStep.confirm
      : widget.transaction == null
      ? (widget.initialType == null
            ? TransactionStep.type
            : TransactionStep.amount)
      : TransactionStep.view;
  var _forward = true;
  late final TransactionDraft _draft = _freshDraft();
  final _calculator = AmountCalculator();
  bool _saving = false;
  String? _error;
  bool _deleting = false;

  /// Set once Confirm has been reached: from then on, finishing (or backing
  /// out of) any step returns straight to Confirm.
  late bool _reviewing = widget.initialDraft != null;

  int? _subcategoryParentId;

  bool get _isEditFlow => widget.transaction != null;

  /// The transaction the View page shows: the one the sheet opened on, or what
  /// it became after being edited from here.
  MoneyTransaction? _viewed;
  MoneyTransaction get _current => _viewed ?? widget.transaction!;
  bool get _busy => _saving || _deleting;

  Animation<double>? _routeAnimation;

  @override
  void initState() {
    super.initState();
    widget.accountStore.addListener(_onStoresChanged);
    widget.categoryStore.addListener(_onStoresChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_routeAnimation != null) return;
    _routeAnimation = ModalRoute.of(context)?.animation;
    _routeAnimation?.addStatusListener(_onRouteStatus);
    if (_routeAnimation?.isCompleted ?? false) _onRouteStatus(.completed);
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    widget.accountStore.removeListener(_onStoresChanged);
    widget.categoryStore.removeListener(_onStoresChanged);
    super.dispose();
  }

  /// Once the sheet has finished opening, loads the category and account
  /// icons in the background, so the picker steps slide in with every
  /// icon already drawn instead of popping in partway through the slide.
  void _onRouteStatus(AnimationStatus status) {
    if (!status.isCompleted || !mounted) return;
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    final brightness = Theme.of(context).brightness;
    final keys = {
      for (final category in widget.categoryStore.categories) category.icon,
      for (final account in widget.accountStore.accounts) account.icon,
    };
    for (final key in keys) {
      if (appIconImage(key, brightness) case final image?) {
        precacheImage(image, context);
      }
    }
  }

  void _onStoresChanged() {
    if (mounted) setState(() {});
  }

  TransactionDraft _freshDraft() {
    if (widget.initialDraft != null) return widget.initialDraft!;
    final transaction = widget.transaction;
    if (transaction == null) {
      return TransactionDraft(
        type: widget.initialType ?? TransactionType.expense,
        accountId: widget.initialType == null
            ? null
            : widget.accountStore.accounts
                  .where((a) => !a.isBroker)
                  .firstOrNull
                  ?.id,
      );
    }
    return TransactionDraft.fromTransaction(
      transaction,
      digits: _accountById(transaction.accountId)?.digits ?? 2,
    );
  }

  /// Resolves against every account, archived included: an entry already saved
  /// against one still has to render. The picker itself reads the active list.
  Account? _accountById(int? id) => widget.accountStore.byId(id);

  Category? _categoryById(int? id) {
    for (final category in widget.categoryStore.categories) {
      if (category.id == id) return category;
    }
    return null;
  }

  /// Top-level categories of [type], each followed by its subcategories.
  List<Category> _categoriesOf(CategoryType type) {
    final all = widget.categoryStore.categories
        .where((c) => c.type == type)
        .toList();
    return [
      for (final parent in all.where((c) => c.parentId == null)) ...[
        parent,
        ...all.where((c) => c.parentId == parent.id),
      ],
    ];
  }

  /// Recorded by lending, borrowing or paying back a debt.
  bool _isDebt(MoneyTransaction transaction) =>
      _categoryById(transaction.categoryId)?.isDebtLoan ?? false;

  bool get _isIncome => _draft.type == TransactionType.income;

  /// Named in the header of every step, so the flow being followed stays
  /// on screen while each step's own question leads its content.
  String get _flowTitle => _isIncome ? 'Add income' : 'Add expense';
  CategoryType get _categoryType =>
      _isIncome ? CategoryType.income : CategoryType.expense;
  Account? get _account => _accountById(_draft.accountId);
  Category? get _category => _categoryById(_draft.categoryId);
  int get _digits => _account?.digits ?? 2;
  int? get _amountMinor => parseAccountAmount(_draft.amountText, _digits);
  bool get _amountValid => (_amountMinor ?? 0) > 0;
  bool get _detailsValid =>
      _amountValid && _account != null && _category != null;

  String get _amountLabel {
    final minor = _amountMinor;
    return minor != null
        ? formatTransactionMoney(minor, _account)
        : '${_account?.currency ?? 'INR'} ${_draft.amountText}';
  }

  void _goTo(TransactionStep step) {
    if (step != _step) VibrationSettings.selectionClick();
    setState(() {
      _forward = step.index > _step.index;
      _step = step;
      _error = null;
      if (step == TransactionStep.confirm) _reviewing = true;
    });
    final route = AdaptiveSheetRoute.of(context);
    // Only the read-only View closes on a scrim tap; a form never does.
    route?.dismissible = step == TransactionStep.view;
    route?.avoidKeyboard = _typingSteps.contains(step);
  }

  /// The next step — or, once Confirm has been reached, straight back to
  /// it, so changing one thing there doesn't mean redoing the rest.
  void _advance() => _goTo(
    _reviewing
        ? TransactionStep.confirm
        : TransactionStep.values[_step.index + 1],
  );

  void _close() => Navigator.pop(context);

  void _back() {
    if (_busy) return;
    switch (_step) {
      case TransactionStep.view:
      case TransactionStep.type:
        _close();
      case TransactionStep.confirm:
        if (widget.initialDraft != null) {
          Navigator.pop(context);
          return;
        }
        // Editing opens straight on Confirm (see _startEdit), so its own
        // back arrow discards edits like Cancel rather than entering the
        // Add wizard's Date step.
        if (_isEditFlow) {
          _cancel();
        } else {
          _reviewing = false;
          _goTo(TransactionStep.date);
        }
      case TransactionStep.subcategory:
        _goTo(TransactionStep.category);
      case TransactionStep.transfer:
        _goTo(
          _transferFromCategory
              ? TransactionStep.category
              : TransactionStep.type,
        );
      case TransactionStep.debt || TransactionStep.loanPick:
        _goTo(TransactionStep.category);
      case TransactionStep.loanPay:
        _goTo(TransactionStep.loanPick);
      case _ when _reviewing:
        _goTo(TransactionStep.confirm);
      case TransactionStep.amount:
        if (!_isEditFlow && widget.initialType != null) {
          _close();
        } else {
          _goTo(_isEditFlow ? TransactionStep.view : TransactionStep.type);
        }
      default:
        _goTo(TransactionStep.values[_step.index - 1]);
    }
  }

  /// Adding: closes everything. Editing: drops the edits and returns to
  /// View (the next Edit starts again from the saved transaction).
  void _cancel() {
    if (_busy) return;
    _isEditFlow ? _goTo(TransactionStep.view) : _close();
  }

  /// Confirms, then permanently deletes the viewed transaction and closes
  /// the sheet — the account balance(s) it moved are reversed to match.
  Future<void> _deleteTransaction() async {
    final transaction = widget.transaction;
    if (transaction == null || _busy) return;
    setState(() => _deleting = true);
    int? loanId;
    try {
      loanId = await widget.transactionStore.repository.linkedLoanId(
        transaction.id,
      );
    } catch (_) {
      if (mounted) {
        showAppToast(context, 'Could not check this transaction. Try again.');
      }
      return;
    } finally {
      if (mounted) setState(() => _deleting = false);
    }
    if (!mounted) return;
    if (loanId != null) {
      final loans = LoanStoreScope.maybeOf(context);
      final goToLoan = await showConfirmationAlert(
        context,
        title: 'Undo from the loan',
        message: 'This is a loan payment. Undo it from the loan: Undo latest action.',
        confirmLabel: 'Go to loan',
        destructive: false,
      );
      if (!mounted || !goToLoan) return;
      if (loans == null) {
        showAppToast(context, 'Open this loan from More → Loans.');
        return;
      }
      final navigator = Navigator.of(context);
      navigator.pop();
      await navigator.push(
        FeatureRoute<void>(LoanDetailScreen(store: loans, id: loanId)),
      );
      return;
    }
    final isTransfer = transaction.type == TransactionType.transfer;
    final confirmed = await showDeleteConfirmation(
      context,
      title: 'Delete this transaction?',
      message: isTransfer
          ? 'Deletes this transfer for good. Both balances update to match.'
          : _isDebt(transaction)
          ? 'Deletes this transaction for good. The balance updates and it leaves Debts.'
          : 'Deletes this transaction for good. The balance updates to match.',
    );
    if (!confirmed || !mounted) return;
    final navigator = Navigator.of(context);
    final route = AdaptiveSheetRoute.of(context);
    route?.dismissible = false;
    setState(() => _deleting = true);
    try {
      await widget.transactionStore.deleteTransaction(transaction.id);
      if (!mounted) return;
      showAppToast(context, 'Transaction deleted');
      navigator.pop();
    } catch (_) {
      if (mounted) {
        setState(() => _deleting = false);
        route?.dismissible = true;
        showAppToast(
          context,
          'Could not delete this transaction. Please try again.',
        );
      }
    }
  }

  void _chooseType(TransactionType type) {
    _draft.type = type;
    _calculator.clear();
    final accounts = widget.accountStore.accounts
        .where((a) => !a.isBroker)
        .toList();
    if (_account == null && accounts.isNotEmpty) {
      _draft.accountId = accounts.first.id;
    }
    // The category has a step of its own, so none is picked in advance.
    if (_category?.type != _categoryType) _draft.categoryId = null;
    _reviewing = false;
    _goTo(TransactionStep.amount);
  }

  /// Edit opens the same review sheet as SMS and statement rows, where any
  /// transaction can change kind — an expense can become a transfer and
  /// back. What an owning loan, debt or recurring payment depends on stays
  /// locked, and a transfer between currencies keeps its amounts and
  /// accounts, since there is no rate here to redo them.
  Future<void> _editInReview() async {
    final transaction = _current;
    final account = _accountById(transaction.accountId);
    if (account == null) return;
    TransactionLink? link;
    try {
      link = await widget.transactionStore.repository.link(transaction.id);
    } catch (_) {
      if (mounted) {
        showAppToast(context, 'Could not open this transaction. Try again.');
      }
      return;
    }
    if (!mounted) return;
    final owned = link?.locks ?? const TransactionLocks();
    final crossCurrency = transaction.toAmountMinor != null;
    final locks = TransactionLocks(
      type: owned.type || crossCurrency,
      amount: owned.amount || crossCurrency,
      accounts: owned.accounts || crossCurrency,
      date: owned.date,
      category: owned.category,
      transfer: owned.transfer,
    );
    final loans = LoanStoreScope.maybeOf(context);
    final navigator = Navigator.of(context);
    var saved = false;
    await showTransactionReviewSheet(
      context,
      heading: 'Edit transaction',
      titleSuggestions: (text, type, categoryId) => widget
          .transactionStore
          .titleSuggestions
          .suggest(text, type: type, categoryId: categoryId),
      draft: ReviewDraft(
        type: transaction.type,
        amountMinor: transaction.amountMinor,
        currency: account.currency,
        digits: account.digits,
        date: transaction.date,
        title: transaction.title ?? '',
        categoryId: transaction.categoryId,
        accountId: transaction.accountId,
        toAccountId: transaction.toAccountId,
        note: transaction.note,
      ),
      accounts: widget.accountStore,
      categories: widget.categoryStore,
      locks: locks,
      // One a loan, debt or recurring payment already owns can't become a payment.
      loans: link == null && transaction.type != TransactionType.transfer
          ? _activeLoans
          : const [],
      notice: link == null
          ? null
          : TransactionLinkNotice(
              link: link,
              onOpen: link.kind == TransactionLinkKind.loan && loans != null
                  ? () {
                      // Leave both sheets for the loan's own screen.
                      navigator
                        ..pop()
                        ..pop()
                        ..push(
                          FeatureRoute<void>(
                            LoanDetailScreen(store: loans, id: link!.ownerId),
                          ),
                        );
                    }
                  : null,
            ),
      onSave: (draft) async {
        final title = draft.title.trim();
        if ((draft.loanId, loans) case (final int loan, final store?)) {
          // Together: a payment the loan refuses leaves the edit unsaved too.
          final repository = store.repository;
          await store.save(
            () => repository.database.transaction(() async {
              await widget.transactionStore.repository.edit(
                id: transaction.id,
                type: draft.type,
                amountMinor: draft.amountMinor,
                accountId: draft.accountId!,
                toAccountId: draft.toAccountId,
                categoryId: await repository.paymentCategory(),
                title: title.isEmpty ? null : title,
                note: draft.note,
                date: draft.date,
              );
              await repository.payWith(loan, transaction.id);
            }),
          );
          saved = true;
          return;
        }
        await widget.transactionStore.edit(
          id: transaction.id,
          type: draft.type,
          amountMinor: draft.amountMinor,
          accountId: draft.accountId!,
          toAccountId: draft.toAccountId,
          categoryId: draft.categoryId,
          title: title.isEmpty ? null : title,
          note: draft.note,
          date: draft.date,
        );
        saved = true;
      },
    );
    // Back to the View, now showing the saved transaction.
    if (saved && mounted) {
      showAppToast(context, 'Transaction updated');
      final updated = widget.transactionStore.transactions
          .where((t) => t.id == transaction.id)
          .firstOrNull;
      if (updated == null) {
        _close();
      } else {
        setState(() => _viewed = updated);
      }
    }
  }

  void _typeDigit(String digit) => setState(
    () => _draft.amountText = _calculator.digit(
      _draft.amountText,
      digit,
      _digits,
    ),
  );

  void _typePoint() => setState(
    () => _draft.amountText = _calculator.point(_draft.amountText, _digits),
  );

  void _backspace() => setState(() {
    _draft.amountText = _calculator.backspace(_draft.amountText, _digits);
  });

  void _clearAmount() => setState(() {
    _calculator.clear();
    _draft.amountText = '';
  });

  void _calculate(String key) => setState(() {
    _draft.amountText = _calculator.press(key, _draft.amountText, _digits);
  });

  void _continueAmount() {
    _calculate('=');
    if (_calculator.error == null && _amountValid) _advance();
  }

  /// Trimmed [text], or null when it's blank (title and note are optional).
  static String? _optional(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  /// Lending or borrowing, and paying a loan, are recorded by their own flows,
  /// so Choose category offers them only when adding something new.
  bool get _offersDebtAndLoan =>
      !_isEditFlow && widget.initialDraft == null && widget.onSaveDraft == null;

  DebtStore? get _debtStore => DebtStoreScope.maybeOf(context);

  /// Loans still being paid off — what a "Loan repayment" can go to.
  List<Loan> get _activeLoans =>
      LoanStoreScope.maybeOf(context)?.loans.where((l) => !l.closed).toList() ??
      const [];

  int? _loanId;

  /// How Transfer was reached: from Choose category it keeps what was typed
  /// and backs out to there, and may be a card repayment.
  bool _transferFromCategory = false, _cardRepayment = false;

  CategoryShortcuts get _shortcuts => !_offersDebtAndLoan
      ? const CategoryShortcuts()
      : CategoryShortcuts(
          transfer: true,
          cardRepayment:
              !_isIncome &&
              widget.accountStore.accounts.any(
                (a) => a.type == AccountType.creditCard,
              ),
          loans: _isIncome ? const [] : _activeLoans,
        );

  List<ChoiceItem<int>> get _debtItems {
    final debtKind = _isIncome ? DebtKind.borrow : DebtKind.lend;
    return [
      if (_offersDebtAndLoan && _debtStore != null)
        ChoiceItem(
          value: _debtChoice,
          icon: Icon(
            debtKind.icon,
            size: 24,
            color: debtKindColor(context, debtKind),
          ),
          label: _isIncome ? 'Borrowed from someone' : 'Lend to someone',
          chevron: true,
        ),
    ];
  }

  void _chooseCategory(int id) {
    if (id == _debtChoice) {
      _goTo(TransactionStep.debt);
      return;
    }
    if (id == loanChoice) {
      _goTo(TransactionStep.loanPick);
      return;
    }
    if (id == transferChoice || id == cardRepaymentChoice) {
      _transferFromCategory = true;
      _cardRepayment = id == cardRepaymentChoice;
      _goTo(TransactionStep.transfer);
      return;
    }
    final category = _categoryById(id);
    if (category == null) return;
    if (category.parentId != null) {
      _selectCategory(id);
      return;
    }
    _subcategoryParentId = id;
    _goTo(TransactionStep.subcategory);
  }

  void _selectCategory(int id) {
    _draft.categoryId = id;
    _subcategoryParentId = _category?.parentId ?? id;
    _goTo(_reviewing ? TransactionStep.confirm : TransactionStep.account);
  }

  Widget _summary({Category? category, bool includeAccount = false}) =>
      TransactionStepSummary(
        type: _draft.type,
        amount: _amountLabel,
        category: category,
        parentCategory: _categoryById(category?.parentId),
        account: includeAccount ? _account : null,
      );

  void _selectAccount(int id) {
    _draft.accountId = id;
    _advance();
  }

  void _pickDate(DateTime picked) {
    // Keep the original time of day, so the day's list order stays put.
    final time = _draft.date;
    _draft.date = DateTime(
      picked.year,
      picked.month,
      picked.day,
      time.hour,
      time.minute,
      time.second,
    );
    _advance();
  }

  Future<void> _save() async {
    if (_saving || !_detailsValid) return;
    final navigator = Navigator.of(context);
    final existingId = _draft.existingTransactionId;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (widget.onSaveDraft != null) {
        await widget.onSaveDraft!(_draft);
      } else if (existingId == null) {
        await widget.transactionStore.addExpenseOrIncome(
          type: _draft.type,
          amountMinor: _amountMinor!,
          accountId: _draft.accountId!,
          categoryId: _draft.categoryId!,
          title: _draft.title,
          note: _draft.note,
          date: _draft.date,
        );
      } else {
        await widget.transactionStore.updateExpenseOrIncome(
          id: existingId,
          type: _draft.type,
          amountMinor: _amountMinor!,
          accountId: _draft.accountId!,
          categoryId: _draft.categoryId!,
          title: _draft.title,
          note: _draft.note,
          date: _draft.date,
        );
      }
      if (!mounted) return;
      VibrationSettings.lightImpact();
      showAppToast(
        context,
        widget.onSaveDraft != null
            ? 'Suggestion updated'
            : existingId != null
            ? 'Transaction updated'
            : (_isIncome ? 'Income saved' : 'Expense saved'),
      );
      navigator.pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save this transaction. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // System back steps back like the arrow does; it only closes the sheet
    // from the first page.
    canPop:
        !_busy &&
        (_step == TransactionStep.view ||
            _step == TransactionStep.type ||
            (widget.initialDraft != null && _step == TransactionStep.confirm)),
    // UPI, Transfer, debts and loan payments own their nested steps and
    // their own PopScope.
    onPopInvokedWithResult:
        const {
          TransactionStep.upi,
          TransactionStep.transfer,
          TransactionStep.debt,
          TransactionStep.loanPay,
        }.contains(_step)
        ? null
        : (didPop, _) {
            if (!didPop) _back();
          },
    child: StepSlider(
      stepKey: _step,
      forward: _forward,
      modal: _reviewing,
      child: _buildPage(),
    ),
  );

  Widget _buildPage() => switch (_step) {
    TransactionStep.view => _buildViewPage(),
    TransactionStep.type => TransactionTypePage(
      onChoose: _chooseType,
      onCancel: _close,
      onTransfer: () {
        _transferFromCategory = _cardRepayment = false;
        _goTo(TransactionStep.transfer);
      },
      onUpi: (UpiSettingsScope.maybeOf(context)?.enabled ?? false)
          ? () => _goTo(TransactionStep.upi)
          : null,
    ),
    TransactionStep.upi => UpiPaymentFlow(
      isActive: () => mounted && _step == TransactionStep.upi,
      accountStore: widget.accountStore,
      categoryStore: widget.categoryStore,
      transactionStore: widget.transactionStore,
      onBack: () => _goTo(TransactionStep.type),
      onClose: _close,
    ),
    TransactionStep.transfer => TransferSheet(
      accountStore: widget.accountStore,
      transactionStore: widget.transactionStore,
      initialAmountText: _transferFromCategory ? _draft.amountText : null,
      cardRepayment: _cardRepayment,
      // Backing out of its first step returns to where it was chosen; Cancel
      // or a saved transfer closes the whole sheet.
      onLeave: _back,
      onClose: _close,
    ),
    TransactionStep.debt => DebtSheet(
      store: _debtStore!,
      kind: _isIncome ? DebtKind.borrow : DebtKind.lend,
      // The amount is already typed; only who it was with is left to ask.
      initialAmountText: _draft.amountText,
      onLeave: () => _goTo(TransactionStep.category),
      onClose: _close,
    ),
    TransactionStep.loanPick => ChoicePickerPage<int>(
      header: SheetHeader.flow(_flowTitle, onBack: _back),
      heading: 'Which loan?',
      summary: _summary(),
      items: [for (final loan in _activeLoans) loanChoiceItem(loan)],
      selected: null,
      onSelected: (id) {
        _loanId = id;
        _goTo(TransactionStep.loanPay);
      },
      searchHint: 'Search loans',
    ),
    TransactionStep.loanPay => _buildLoanPayPage(),
    TransactionStep.amount => AmountPage(
      type: _draft.type,
      amountText: _draft.amountText,
      calculatedAmount: _calculator.resultFor(_draft.amountText, _digits),
      digits: _digits,
      currency: _account?.currency ?? 'INR',
      onDigit: _typeDigit,
      onDecimalPoint: _typePoint,
      onBackspace: _backspace,
      onClear: _clearAmount,
      onOperation: _calculate,
      replaceAmount: _calculator.replace,
      decimalAllowed: _calculator.enteringPercent
          ? _calculator.percentDecimalEnabled
          : null,
      calculatorStatus:
          _calculator.error ?? _calculator.expressionFor(_draft.amountText),
      onBack: _back,
      onCancel: _cancel,
      onContinue: (_amountValid || _calculator.operation != null)
          ? _continueAmount
          : null,
    ),
    TransactionStep.category => ChoicePickerPage<int>(
      header: SheetHeader.flow(_flowTitle, onBack: _back),
      heading: _isIncome ? 'Choose source' : 'Choose category',
      summary: _summary(),
      fillHeight: true,
      items: [
        ..._shortcuts.items,
        for (final category in _shortcuts.topLevel(
          _categoriesOf(_categoryType),
        )) ...[
          ChoiceItem(
            value: category.id,
            icon: AppIcon(category.icon, size: 28),
            label: category.name,
            chevron: true,
          ),
          // Subcategories show only while searching (e.g. "fuel").
          for (final sub in _categoriesOf(
            _categoryType,
          ).where((c) => c.parentId == category.id))
            ChoiceItem(
              value: sub.id,
              icon: AppIcon(sub.icon, size: 28),
              label: sub.name,
              indent: true,
              searchOnly: true,
              chevron: true,
            ),
        ],
        ..._debtItems,
      ],
      selected: null,
      onSelected: _chooseCategory,
      searchHint: _isIncome ? 'Search sources' : 'Search categories',
      addLabel: _isIncome ? 'Add source' : 'Add category',
      onAdd: (context) async => (await addCategoryAndSelect(
        context,
        widget.categoryStore,
        _categoryType,
      ))?.id,
    ),
    TransactionStep.subcategory => ChoicePickerPage<int>(
      header: SheetHeader.flow(_flowTitle, onBack: _back),
      heading: 'Choose subcategory',
      summary: _summary(category: _categoryById(_subcategoryParentId)),
      fillHeight: true,
      items: [
        if (_categoryById(_subcategoryParentId) case final parent?)
          ChoiceItem(
            value: parent.id,
            icon: AppIcon(parent.icon, size: 28),
            label: 'Use ${parent.name} only',
            chevron: true,
          ),
        for (final category in _categoriesOf(
          _categoryType,
        ).where((c) => c.parentId == _subcategoryParentId))
          ChoiceItem(
            value: category.id,
            icon: AppIcon(category.icon, size: 28),
            label: category.name,
            chevron: true,
          ),
      ],
      selected: null,
      onSelected: _selectCategory,
      searchHint: 'Search subcategories',
      addLabel: 'Add subcategory',
      onAdd: (context) async => (await addCategoryAndSelect(
        context,
        widget.categoryStore,
        _categoryType,
        parentId: _subcategoryParentId,
      ))?.id,
    ),
    TransactionStep.account => ChoicePickerPage<int>(
      header: SheetHeader.flow(_flowTitle, onBack: _back),
      heading: _isIncome ? 'Deposited to' : 'Paid from',
      summary: _summary(category: _category),
      items: accountChoiceItems(
        widget.accountStore,
        currency: widget.requiredCurrency,
      ),
      selected: null,
      onSelected: _selectAccount,
      searchHint: 'Search accounts',
      addLabel: 'Add account',
      onAdd: (context) async =>
          (await addAccountAndSelect(context, widget.accountStore))?.id,
    ),
    TransactionStep.date => DateStepPage(
      summary: _summary(category: _category, includeAccount: true),
      header: _flowTitle,
      question: _isIncome
          ? 'When did you receive it?'
          : 'When did you spend it?',
      date: _draft.date,
      onPick: _pickDate,
      onBack: _back,
      onCancel: _cancel,
      onContinue: _advance,
    ),
    TransactionStep.confirm => TransactionConfirmPage(
      isEditing: _isEditFlow,
      type: _draft.type,
      amount: _amountLabel,
      account: _account,
      category: _category,
      title: _draft.title,
      note: _draft.note,
      date: _draft.date,
      amountFitsAccount: _amountMinor != null,
      canSave: _detailsValid && !widget.readOnly,
      saving: _saving,
      error: _error,
      onBack: _back,
      onCancel: _cancel,
      onSave: _save,
      onEditAmount: () => _goTo(TransactionStep.amount),
      onEditCategory: () => _goTo(TransactionStep.category),
      onEditAccount: () => _goTo(TransactionStep.account),
      onEditDate: () => _goTo(TransactionStep.date),
      // No rebuild needed: the fields show what's typed themselves.
      onTitleChanged: (text) => _draft.title = _optional(text),
      onNoteChanged: (text) => _draft.note = _optional(text),
      titleSuggestions: (text) => widget.transactionStore.titleSuggestions
          .suggest(text, type: _draft.type, categoryId: _draft.categoryId),
    ),
  };

  Widget _buildLoanPayPage() {
    final store = LoanStoreScope.maybeOf(context);
    final loan = store?.byId(_loanId ?? -1);
    if (store == null || loan == null) {
      // The loan is gone (deleted elsewhere): back to Choose category.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _step == TransactionStep.loanPay) {
          _goTo(TransactionStep.category);
        }
      });
      return const SizedBox.shrink();
    }
    final account = _account;
    // What was typed counts as the payment only in the loan's own currency.
    final sameCurrency =
        account != null &&
        account.currency == loan.terms.currency &&
        account.digits == loan.terms.digits;
    return LoanActionSheet(
      store: store,
      loan: loan,
      kind: LoanEventKind.emi,
      initialAmountText: sameCurrency ? _draft.amountText : null,
      onBack: _back,
      onClose: _close,
    );
  }

  Widget _buildViewPage() {
    final transaction = _current;
    return TransactionViewPage(
      transaction: transaction,
      account: _accountById(transaction.accountId),
      toAccount: _accountById(transaction.toAccountId),
      category: _categoryById(transaction.categoryId),
      onClose: _close,
      onEdit: _deleting ? null : _editInReview,
      onDelete: _deleteTransaction,
      onOpenAccount: _openAccount,
      busy: _deleting,
    );
  }

  /// Leaves the sheet and opens the account's own screen. Shown only for an
  /// archived account: it is the one place left that still names it, so it is
  /// also where restoring it has to start.
  void _openAccount(Account account) {
    if (_busy) return;
    final navigator = Navigator.of(context);
    navigator.pop();
    navigator.push(
      FeatureRoute<void>(
        EditAccountScreen(
          store: widget.accountStore,
          account: account,
          transactionStore: widget.transactionStore,
        ),
      ),
    );
  }
}
