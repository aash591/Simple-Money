import 'package:flutter/material.dart';

import '../../domain/account.dart';
import '../../domain/convert_minor.dart';
import '../../state/account_store.dart';
import '../../state/main_currency_controller.dart';
import '../../state/transaction_store.dart';
import '../components/action_buttons.dart';
import '../components/adaptive_sheet.dart';
import '../components/app_toast.dart';
import '../components/choice_list_sheet.dart';
import '../components/currency_notice.dart';
import '../../domain/money.dart';
import '../components/number_keypad.dart';
import '../theme/sheet_colors.dart';
import 'amount_typing.dart';
import 'quick_add_helpers.dart';
import 'transaction_pages.dart';
import 'transaction_widgets.dart';

/// Moves money between two of the user's own accounts. Never counted as
/// income or expense — see the README's "core idea".
Future<void> showTransferSheet(
  BuildContext context, {
  required AccountStore accountStore,
  required TransactionStore transactionStore,
  int? initialFromAccountId,
}) => showAdaptiveSheet<void>(
  context,
  builder: (context) => TransferSheet(
    accountStore: accountStore,
    transactionStore: transactionStore,
    initialFromAccountId: initialFromAccountId,
  ),
);

/// What an account holds right now, in its own currency — the figure that
/// decides which side of a transfer it belongs on.
String _balanceOf(Account account) =>
    formatTransactionMoney(account.balanceMinor, account);

/// One decision per page. The source comes first so the keypad already knows
/// which currency — and how many decimal places — the amount is in.
/// [TransferStep.received] is skipped unless the two accounts disagree.
enum TransferStep { from, amount, to, received, date, confirm }

class TransferDraft {
  const TransferDraft({
    required this.fromAccountId,
    required this.toAccountId,
    required this.amountMinor,
    required this.date,
    this.toAmountMinor,
    this.note,
  });
  final int fromAccountId, toAccountId, amountMinor;
  final int? toAmountMinor;
  final DateTime date;
  final String? note;
}

class TransferSheet extends StatefulWidget {
  const TransferSheet({
    super.key,
    required this.accountStore,
    required this.transactionStore,
    this.initialFromAccountId,
    this.onClose,
    this.onLeave,
    this.initialDraft,
    this.onSaveDraft,
    this.requiredCurrency,
    this.initialAmountText,
    this.cardRepayment = false,
  });
  final AccountStore accountStore;
  final TransactionStore transactionStore;
  final int? initialFromAccountId;
  final String? requiredCurrency;
  final TransferDraft? initialDraft;
  final Future<void> Function(TransferDraft)? onSaveDraft;

  /// An amount already typed, so the keypad is skipped unless the source
  /// chosen can't hold it.
  final String? initialAmountText;

  /// Paying a card's bill: the money comes from a non-card account and goes
  /// to a credit card, picked here when there is only one.
  final bool cardRepayment;

  /// Called instead of popping this sheet's own route when the transfer is
  /// cancelled or completed — e.g. to also close the sheet it was opened
  /// from. When null, popping this route is enough.
  final VoidCallback? onClose;

  /// Called instead of [onClose] when backing out of the first step, for a
  /// transfer embedded as one page of another flow that should show its
  /// previous page again rather than close.
  final VoidCallback? onLeave;

  @override
  State<TransferSheet> createState() => _TransferSheetState();
}

/// Steps with a text field of their own (the pickers' search bars, and the
/// note on Confirm), where the sheet lifts above the keyboard.
const _typingSteps = {TransferStep.from, TransferStep.to, TransferStep.confirm};

class _TransferSheetState extends State<TransferSheet> {
  TransferStep _step = TransferStep.from;
  bool _forward = true;
  bool _reviewing = false;

  late int? _fromId = widget.initialFromAccountId;
  int? _toId;
  late String _amountText = widget.initialAmountText ?? '';

  /// Only meaningful while [_receivedEdited]; otherwise the figure shown is
  /// derived from the rate, so there is nothing to keep in sync here.
  String _receivedText = '';
  bool _receivedEdited = false;

  String? _note;
  DateTime _date = DateTime.now();
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    widget.accountStore.addListener(_onAccountsChanged);
    // A source handed in by the caller is already answered; open on the
    // amount rather than asking again.
    if (_fromId != null) _step = TransferStep.amount;
    if (widget.cardRepayment) {
      final cards = _cards;
      if (cards.length == 1) _toId = cards.single.id;
      _cardChosen = cards.length == 1;
    }
    final draft = widget.initialDraft;
    if (draft != null) {
      _fromId = draft.fromAccountId;
      _toId = draft.toAccountId;
      _amountText = AmountTyping.fromMinor(draft.amountMinor, _digits);
      if (draft.toAmountMinor != null) {
        _receivedText = AmountTyping.fromMinor(draft.toAmountMinor!, _toDigits);
        _receivedEdited = true;
      }
      _date = draft.date;
      _note = draft.note;
      _step = TransferStep.confirm;
      _reviewing = true;
    }
  }

  @override
  void dispose() {
    widget.accountStore.removeListener(_onAccountsChanged);
    super.dispose();
  }

  void _onAccountsChanged() {
    if (!mounted) return;
    setState(() {
      if (_byId(_fromId) == null) _fromId = null;
      if (_byId(_toId) == null) _toId = null;
    });
  }

  List<Account> get _cards => [
    for (final a in widget.accountStore.accounts)
      if (a.type == AccountType.creditCard) a,
  ];

  /// The only card there is to repay: Transfer to needn't ask.
  bool _cardChosen = false;

  /// What [step] doesn't need to ask.
  bool _skips(TransferStep step) => switch (step) {
    TransferStep.amount => widget.initialAmountText != null && _amountValid,
    TransferStep.to => _cardChosen,
    TransferStep.received => !_crossCurrency,
    _ => false,
  };

  Account? _byId(int? id) {
    if (id == null) return null;
    for (final a in widget.accountStore.accounts) {
      if (a.id == id) return a;
    }
    return null;
  }

  Account? get _from => _byId(_fromId);
  Account? get _to => _byId(_toId);

  int get _digits => _from?.digits ?? 2;
  int get _toDigits => _to?.digits ?? 2;
  int? get _amountMinor => parseAccountAmount(_amountText, _digits);
  bool get _amountValid => (_amountMinor ?? 0) > 0;

  /// True when the destination holds a different currency (or counts decimals
  /// differently), so what arrives cannot be assumed to be what was sent.
  bool get _crossCurrency {
    final from = _from, to = _to;
    if (from == null || to == null) return false;
    return from.currency != to.currency || from.digits != to.digits;
  }

  /// The destination amount at today's rate, or null when no rate covers the
  /// pair — offline before a first fetch, or a currency the provider omits.
  int? get _convertedMinor {
    final from = _from, to = _to, amount = _amountMinor;
    if (from == null || to == null || amount == null || amount <= 0) {
      return null;
    }
    final table = MainCurrencyScope.maybeOf(context)?.table;
    if (table == null) return null;
    return crossConvertMinor(
      amount,
      fromDigits: from.digits,
      toDigits: to.digits,
      perMainFrom: table.rates[from.currency],
      perMainTo: table.rates[to.currency],
    );
  }

  /// What the Received step shows: the user's own figure once they have typed
  /// one, otherwise the converted amount pre-filled for them to accept.
  String get _receivedDisplayText {
    if (_receivedEdited) return _receivedText;
    final converted = _convertedMinor;
    return converted == null
        ? ''
        : AmountTyping.fromMinor(converted, _toDigits);
  }

  int? get _receivedMinor =>
      parseAccountAmount(_receivedDisplayText, _toDigits);
  bool get _receivedValid => (_receivedMinor ?? 0) > 0;

  /// Null on a same-currency transfer, where the whole amount arrives unless
  /// the user says otherwise — the column stays null and nothing is implied.
  int? get _savedReceivedMinor {
    if (!_crossCurrency && !_receivedEdited) return null;
    return _receivedMinor;
  }

  /// What the transfer cost, in the destination's currency: the gap between
  /// the rate's figure and what actually landed. Null when there is no rate to
  /// compare against, or when more arrived than the rate predicted — a better
  /// rate is not a negative charge, and saying so reads as a bug.
  int? get _chargeMinor {
    final converted = _convertedMinor, received = _receivedMinor;
    if (converted == null || received == null) return null;
    final charge = converted - received;
    return charge > 0 ? charge : null;
  }

  bool get _detailsValid =>
      _amountValid &&
      _fromId != null &&
      _toId != null &&
      _fromId != _toId &&
      (!_crossCurrency || _receivedValid);

  String get _amountLabel => formatTransactionMoney(_amountMinor ?? 0, _from);

  String get _receivedLabel => formatTransactionMoney(_receivedMinor ?? 0, _to);

  void _goTo(TransferStep step) {
    setState(() {
      _forward = step.index > _step.index;
      _step = step;
      _error = null;
      if (step == TransferStep.confirm) _reviewing = true;
    });
    AdaptiveSheetRoute.of(context)?.avoidKeyboard = _typingSteps.contains(step);
  }

  /// The next step — or, once Confirm has been reached, straight back to it,
  /// so changing one thing there doesn't mean redoing the rest.
  void _advance() {
    if (_reviewing) return _goTo(TransferStep.confirm);
    var next = TransferStep.values[_step.index + 1];
    while (_skips(next)) {
      next = TransferStep.values[next.index + 1];
    }
    _goTo(next);
  }

  void _back() {
    if (_saving) return;
    switch (_step) {
      case TransferStep.from:
        widget.onLeave == null ? _finish() : widget.onLeave!();
      case TransferStep.amount when widget.initialFromAccountId != null:
        _finish();
      case TransferStep.confirm:
        if (widget.initialDraft != null) {
          _finish();
          return;
        }
        _reviewing = false;
        _goTo(TransferStep.date);
      case _ when _reviewing:
        _goTo(TransferStep.confirm);
      default:
        var previous = TransferStep.values[_step.index - 1];
        while (_skips(previous)) {
          previous = TransferStep.values[previous.index - 1];
        }
        _goTo(previous);
    }
  }

  /// Unlike [_back], this always closes the whole flow — including the sheet
  /// this was opened from, when it's embedded in one.
  void _finish() =>
      widget.onClose == null ? Navigator.pop(context) : widget.onClose!();

  void _selectFrom(int id) {
    setState(() {
      _fromId = id;
      // A source in a new currency invalidates an amount typed for the old
      // one's precision, and any rate-derived figure that followed from it.
      if (_amountMinor == null) _amountText = '';
      _receivedEdited = false;
    });
    _advance();
  }

  void _selectTo(int id) {
    setState(() {
      _toId = id;
      _receivedEdited = false;
    });
    _advance();
  }

  void _typeDigit(String d) =>
      setState(() => _amountText = AmountTyping.digit(_amountText, d, _digits));
  void _typePoint() =>
      setState(() => _amountText = AmountTyping.point(_amountText, _digits));
  void _backspace() =>
      setState(() => _amountText = AmountTyping.backspace(_amountText));
  void _clearAmount() => setState(() => _amountText = '');

  void _typeReceivedDigit(String d) => setState(() {
    _receivedText = AmountTyping.digit(_receivedDisplayText, d, _toDigits);
    _receivedEdited = true;
  });
  void _typeReceivedPoint() => setState(() {
    _receivedText = AmountTyping.point(_receivedDisplayText, _toDigits);
    _receivedEdited = true;
  });
  void _backspaceReceived() => setState(() {
    _receivedText = AmountTyping.backspace(_receivedDisplayText);
    _receivedEdited = true;
  });
  void _clearReceived() => setState(() {
    _receivedText = '';
    _receivedEdited = true;
  });
  void _resetReceivedToRate() => setState(() {
    _receivedText = '';
    _receivedEdited = false;
  });

  void _pickDate(DateTime picked) {
    final time = _date;
    setState(
      () => _date = DateTime(
        picked.year,
        picked.month,
        picked.day,
        time.hour,
        time.minute,
        time.second,
      ),
    );
    _advance();
  }

  Future<void> _save() async {
    if (!_detailsValid || _saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (widget.onSaveDraft != null) {
        await widget.onSaveDraft!(
          TransferDraft(
            fromAccountId: _fromId!,
            toAccountId: _toId!,
            amountMinor: _amountMinor!,
            toAmountMinor: _savedReceivedMinor,
            date: _date,
            note: _note,
          ),
        );
      } else {
        await widget.transactionStore.addTransfer(
          amountMinor: _amountMinor!,
          fromAccountId: _fromId!,
          toAccountId: _toId!,
          toAmountMinor: _savedReceivedMinor,
          note: _note,
          date: _date,
        );
      }
      if (!mounted) return;
      showAppToast(context, 'Transfer saved');
      _finish();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save this transfer. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop:
        !_saving &&
        (_step == TransferStep.from ||
            (widget.initialDraft != null && _step == TransferStep.confirm)),
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: StepSlider(
      stepKey: _step,
      forward: _forward,
      modal: _reviewing,
      child: _buildPage(),
    ),
  );

  Widget _summary({bool includeTo = false, bool withAmount = true}) =>
      _TransferSummary(
        amount: withAmount && _amountValid ? _amountLabel : null,
        from: _from,
        to: includeTo ? _to : null,
      );

  /// With [cards] true only credit cards, with false only other accounts,
  /// for a card repayment; null lists every account.
  List<ChoiceItem<int>> _accountItems({int? excludeId, bool? cards}) {
    final cardIds = _cards.map((a) => a.id).toSet();
    return [
      for (final item in accountChoiceItems(
        widget.accountStore,
        excludeId: excludeId,
        currency: widget.requiredCurrency,
      ))
        if (cards == null || cardIds.contains(item.value) == cards) item,
    ];
  }

  String get _flowTitle =>
      widget.cardRepayment ? 'Credit card repayment' : 'Transfer money';

  Widget _buildPage() => switch (_step) {
    TransferStep.from => ChoicePickerPage<int>(
      header: SheetHeader.flow(_flowTitle, onBack: _back),
      heading: widget.cardRepayment ? 'Pay from' : 'Transfer from',
      items: _accountItems(
        excludeId: _toId,
        cards: widget.cardRepayment ? false : null,
      ),
      selected: null,
      onSelected: _selectFrom,
      searchHint: 'Search accounts',
      addLabel: 'Add account',
      onAdd: (context) async =>
          (await addAccountAndSelect(context, widget.accountStore))?.id,
    ),
    TransferStep.amount => _TransferAmountPage(
      summary: _summary(withAmount: false),
      amountText: _amountText,
      digits: _digits,
      currency: _from?.currency ?? 'INR',
      onDigit: _typeDigit,
      onDecimalPoint: _typePoint,
      onBackspace: _backspace,
      onClear: _clearAmount,
      onBack: _back,
      onCancel: _finish,
      onContinue: _amountValid ? _advance : null,
    ),
    TransferStep.to => ChoicePickerPage<int>(
      header: SheetHeader.flow(_flowTitle, onBack: _back),
      heading: widget.cardRepayment ? 'Which card?' : 'Transfer to',
      summary: _summary(),
      items: _accountItems(
        excludeId: _fromId,
        cards: widget.cardRepayment ? true : null,
      ),
      selected: null,
      onSelected: _selectTo,
      searchHint: 'Search accounts',
      addLabel: 'Add account',
      onAdd: (context) async =>
          (await addAccountAndSelect(context, widget.accountStore))?.id,
    ),
    TransferStep.received => _ReceivedPage(
      summary: _summary(includeTo: true),
      amountText: _receivedDisplayText,
      digits: _toDigits,
      currency: _to?.currency ?? 'INR',
      rateLine: _rateLine(),
      onReset: _receivedEdited && _convertedMinor != null
          ? _resetReceivedToRate
          : null,
      onDigit: _typeReceivedDigit,
      onDecimalPoint: _typeReceivedPoint,
      onBackspace: _backspaceReceived,
      onClear: _clearReceived,
      onBack: _back,
      onCancel: _finish,
      onContinue: _receivedValid ? _advance : null,
    ),
    TransferStep.date => DateStepPage(
      header: 'Transfer money',
      summary: _summary(includeTo: true),
      question: 'When did you transfer it?',
      date: _date,
      onPick: _pickDate,
      onBack: _back,
      onCancel: _finish,
      onContinue: _advance,
    ),
    TransferStep.confirm => _TransferConfirmPage(
      amount: _amountLabel,
      received: _crossCurrency || _receivedEdited ? _receivedLabel : null,
      charge: _chargeMinor == null
          ? null
          : formatAccountMoney(
              _chargeMinor!,
              digits: _toDigits,
              currency: _to?.currency ?? 'INR',
            ),
      from: _from,
      to: _to,
      note: _note,
      date: _date,
      saving: _saving,
      canSave: _detailsValid,
      error: _error,
      onBack: _back,
      onCancel: _finish,
      onSave: _save,
      onEditAmount: () => _goTo(TransferStep.amount),
      onEditFrom: () => _goTo(TransferStep.from),
      onEditTo: () => _goTo(TransferStep.to),
      onEditReceived: _crossCurrency || _receivedEdited
          ? () => _goTo(TransferStep.received)
          : null,
      onEditDate: () => _goTo(TransferStep.date),
      onNoteChanged: (value) => _note = value.isEmpty ? null : value,
    ),
  };

  /// The line under "How much arrived?": the rate the figure came from, or —
  /// once the user has typed their own — the rate they actually got.
  String? _rateLine() {
    final from = _from, to = _to, amount = _amountMinor;
    if (from == null || to == null || amount == null || amount <= 0) {
      return null;
    }
    final received = _receivedMinor;
    if (_receivedEdited && received != null && received > 0) {
      return 'You got ${formatExchangeRate(amount, from, received, to)}';
    }
    final converted = _convertedMinor;
    if (converted == null) {
      return 'No rate for ${from.currency} to ${to.currency} — '
          'enter what arrived';
    }
    final table = MainCurrencyScope.maybeOf(context)?.table;
    final rate = formatExchangeRate(amount, from, converted, to);
    return CurrencyNotice.isStale(table?.date)
        ? 'At rates from ${formatShortDate(table!.date)} · $rate'
        : "At today's rate · $rate";
  }
}

/// Previously answered steps, in the same visual language as Confirm: the
/// amount as a hero once it is known, then a row per account chosen.
class _TransferSummary extends StatelessWidget {
  const _TransferSummary({this.amount, this.from, this.to});
  final String? amount;
  final Account? from, to;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (amount != null) ...[
          AmountHero(
            amount: amount!,
            caption: 'Transfer',
            color: Color.lerp(colors.primary, colors.muted, 0.4)!,
          ),
          const SizedBox(height: 16),
        ],
        if (from != null || to != null)
          TransactionDetailsCard(
            rows: [
              if (from case final account?)
                TransactionDetailRow(
                  leading: EntityIconTile(
                    chosen: true,
                    iconKey: account.icon,
                    fallback: Icons.account_balance_wallet_outlined,
                  ),
                  label: 'From',
                  value: account.name,
                  valueColor: colors.muted,
                  trailing: _balanceOf(account),
                ),
              if (to case final account?)
                TransactionDetailRow(
                  leading: EntityIconTile(
                    chosen: true,
                    iconKey: account.icon,
                    fallback: Icons.account_balance_wallet_outlined,
                  ),
                  label: 'To',
                  value: account.name,
                  valueColor: colors.muted,
                  trailing: _balanceOf(account),
                ),
            ],
          ),
      ],
    );
  }
}

/// The keypad step, shared in shape with the Add flow's amount page but
/// carrying the transfer's own question and accent.
class _TransferAmountPage extends StatelessWidget {
  const _TransferAmountPage({
    required this.summary,
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
  });
  final Widget summary;
  final String amountText, currency;
  final int digits;
  final ValueChanged<String> onDigit;
  final VoidCallback onDecimalPoint, onBackspace, onClear, onBack, onCancel;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) => SheetPage(
    startAtBottom: true,
    header: SheetHeader.flow('Transfer money', onBack: onBack),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        summary,
        const SizedBox(height: 20),
        const SheetStepHeading('How much are you transferring?'),
        const SizedBox(height: 20),
        AmountDisplayCard(
          amount: AmountTyping.display(
            amountText,
            currency: currency,
            decimals: digits,
          ),
          empty: amountText.isEmpty,
        ),
        const SizedBox(height: 20),
        NumberKeypad(
          onDigit: onDigit,
          onDecimalPoint: onDecimalPoint,
          onBackspace: onBackspace,
          onClear: onClear,
          decimalEnabled: digits > 0 && !amountText.contains('.'),
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

/// "How much arrived?" — the same keypad, opened on the converted figure so
/// accepting the rate is one tap, and typing over it records what really
/// landed. The difference between the two is the charge.
class _ReceivedPage extends StatelessWidget {
  const _ReceivedPage({
    required this.summary,
    required this.amountText,
    required this.digits,
    required this.currency,
    required this.rateLine,
    required this.onReset,
    required this.onDigit,
    required this.onDecimalPoint,
    required this.onBackspace,
    required this.onClear,
    required this.onBack,
    required this.onCancel,
    required this.onContinue,
  });
  final Widget summary;
  final String amountText, currency;
  final String? rateLine;
  final int digits;
  final VoidCallback? onReset, onContinue;
  final ValueChanged<String> onDigit;
  final VoidCallback onDecimalPoint, onBackspace, onClear, onBack, onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return SheetPage(
      startAtBottom: true,
      header: SheetHeader.flow('Transfer money', onBack: onBack),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          summary,
          const SizedBox(height: 20),
          SheetStepHeading('How much arrived?', subtitle: rateLine),
          if (onReset != null)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onReset,
                icon: const Icon(Icons.refresh_rounded, size: 18),
                label: const Text('Use the rate again'),
                style: TextButton.styleFrom(
                  foregroundColor: colors.primary,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
          const SizedBox(height: 16),
          AmountDisplayCard(
            amount: AmountTyping.display(
              amountText,
              currency: currency,
              decimals: digits,
            ),
            empty: amountText.isEmpty,
          ),
          const SizedBox(height: 20),
          NumberKeypad(
            onDigit: onDigit,
            onDecimalPoint: onDecimalPoint,
            onBackspace: onBackspace,
            onClear: onClear,
            decimalEnabled: digits > 0 && !amountText.contains('.'),
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

/// The last step: what is about to be saved, with the note typed straight in
/// and every other part tappable to jump back to its own step.
class _TransferConfirmPage extends StatelessWidget {
  const _TransferConfirmPage({
    required this.amount,
    required this.received,
    required this.charge,
    required this.from,
    required this.to,
    required this.note,
    required this.date,
    required this.saving,
    required this.canSave,
    required this.error,
    required this.onBack,
    required this.onCancel,
    required this.onSave,
    required this.onEditAmount,
    required this.onEditFrom,
    required this.onEditTo,
    required this.onEditReceived,
    required this.onEditDate,
    required this.onNoteChanged,
  });
  final String amount;

  /// Null when the whole amount arrives, which is most transfers.
  final String? received, charge, note, error;
  final Account? from, to;
  final DateTime date;
  final bool saving, canSave;
  final VoidCallback onBack, onCancel, onSave;
  final VoidCallback onEditAmount, onEditFrom, onEditTo, onEditDate;
  final VoidCallback? onEditReceived;
  final ValueChanged<String> onNoteChanged;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    VoidCallback? edit(VoidCallback? onEdit) =>
        saving || onEdit == null ? null : onEdit;
    return SheetPage(
      header: SheetHeader.flow('Transfer money', onBack: onBack),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SheetStepHeading('Confirm transfer'),
          const SizedBox(height: 12),
          InkWell(
            onTap: edit(onEditAmount),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: AmountHero(
                // The pair reads as a pair: one figure cannot stand for a
                // transfer whose two sides moved different amounts.
                amount: received == null ? amount : '$amount  →  $received',
                caption: 'Transfer',
                color: colors.primary,
              ),
            ),
          ),
          if (charge != null) ...[
            const SizedBox(height: 4),
            Text(
              'Charge  ≈ $charge',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: colors.muted),
            ),
          ],
          const SizedBox(height: 16),
          TransactionDetailsCard(
            rows: [
              TransactionDetailRow(
                leading: EntityIconTile(
                  chosen: from != null,
                  iconKey: from?.icon,
                  fallback: Icons.account_balance_wallet_outlined,
                ),
                label: 'From',
                value: from?.name ?? '',
                trailing: from == null ? null : _balanceOf(from!),
                onTap: edit(onEditFrom),
              ),
              TransactionDetailRow(
                leading: EntityIconTile(
                  chosen: to != null,
                  iconKey: to?.icon,
                  fallback: Icons.account_balance_wallet_outlined,
                ),
                label: 'To',
                value: to?.name ?? '',
                trailing: to == null ? null : _balanceOf(to!),
                onTap: edit(onEditTo),
              ),
              if (received != null)
                TransactionDetailRow(
                  leading: const SheetIconTile(
                    icon: Icons.call_received_rounded,
                  ),
                  label: 'Amount received',
                  value: received!,
                  onTap: edit(onEditReceived),
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
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              error!,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ],
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: saving ? null : onCancel,
        primaryLabel: saving ? 'Saving…' : 'Save transfer',
        onPrimary: saving || !canSave ? null : onSave,
        primaryColor: colors.primary,
      ),
    );
  }
}
