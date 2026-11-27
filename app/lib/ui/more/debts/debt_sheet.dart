import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../data/people_platform.dart';
import '../../../domain/account.dart';
import '../../../domain/debt.dart';
import '../../../state/debt_store.dart';
import '../../components/action_buttons.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/app_icon.dart';
import '../../components/app_toast.dart';
import '../../components/choice_list_sheet.dart';
import '../../components/date_picker_sheet.dart';
import '../../components/number_keypad.dart';
import '../../components/search_field.dart';
import '../../components/text_entry_alert.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/amount_typing.dart';
import '../../transactions/quick_add_helpers.dart';
import '../../transactions/transaction_widgets.dart';
import 'debt_widgets.dart';

/// Adding a debt: I lent or I borrowed → who → how much → confirm, where the
/// account, date, due date and note can be changed. Passing [personId] (and
/// [kind]) skips those steps, as "Lend more" on a person's page does.
Future<void> showAddDebtSheet(
  BuildContext context, {
  required DebtStore store,
  int? personId,
  DebtKind? kind,
}) => _showSheet(
  context,
  DebtSheet(store: store, personId: personId, kind: kind),
);

/// Recording [personId] paying you back, or you paying them, whichever way
/// the debt runs: how much (all of it, to start with) → confirm.
Future<void> showDebtPaymentSheet(
  BuildContext context, {
  required DebtStore store,
  required int personId,
}) => _showSheet(
  context,
  DebtSheet(store: store, personId: personId, payment: true),
);

/// Changing a recorded [entry]: it opens on Confirm, where the amount,
/// account, date, due date and note can each be changed.
Future<void> showEditDebtEntrySheet(
  BuildContext context, {
  required DebtStore store,
  required DebtEntry entry,
}) => _showSheet(
  context,
  DebtSheet(store: store, personId: entry.personId, entry: entry),
);

/// Changing someone's name and phone number.
Future<void> showEditPersonSheet(
  BuildContext context, {
  required DebtStore store,
  required DebtPerson person,
}) => showAdaptiveSheet<void>(
  context,
  dismissible: false,
  builder: (_) => _EditPersonSheet(store: store, person: person),
);

/// Like the transaction sheet, a stray tap on the scrim doesn't lose a
/// half-entered debt; Cancel, back, or dragging down closes it.
Future<void> _showSheet(BuildContext context, Widget sheet) =>
    showAdaptiveSheet<void>(
      context,
      entrance: SheetEntrance.fadeRise,
      dismissible: false,
      avoidKeyboard: false,
      builder: (_) => sheet,
    );

enum _Step { type, person, amount, confirm }

/// Steps with a text field of their own, where the sheet lifts above the
/// keyboard.
const _typingSteps = {_Step.person, _Step.confirm};

class DebtSheet extends StatefulWidget {
  const DebtSheet({
    super.key,
    required this.store,
    this.personId,
    this.kind,
    this.payment = false,
    this.entry,
    this.initialAmountText,
    this.onLeave,
    this.onClose,
  }) : assert(!payment || personId != null),
       assert(entry == null || (!payment && personId != null));
  final DebtStore store;
  final int? personId;
  final DebtKind? kind;
  final bool payment;

  /// The entry being edited, if any.
  final DebtEntry? entry;

  /// An amount already typed elsewhere, as one page of a longer flow: the
  /// amount step is then skipped, though Confirm still lets it be changed.
  final String? initialAmountText;

  /// Called instead of closing when backing out of the first step, so a flow
  /// this is a page of can show its previous page again.
  final VoidCallback? onLeave;

  /// Called instead of popping this sheet's own route when it is cancelled
  /// or saved.
  final VoidCallback? onClose;

  @override
  State<DebtSheet> createState() => _DebtSheetState();
}

class _DebtSheetState extends State<DebtSheet> {
  /// The person being paid back or paying, as they were when this opened.
  late final PersonDebts? _paying = widget.payment
      ? widget.store.personById(widget.personId!)
      : null;
  late final DebtKind? _kind = widget.payment
      ? ((_paying?.owesYou ?? true) ? DebtKind.collect : DebtKind.repay)
      : widget.entry?.kind ?? widget.kind;
  late DebtKind? _chosenKind = _kind;
  bool get _editing => widget.entry != null;
  late final _Step _firstStep = _editing
      ? _Step.confirm
      : _chosenKind == null
      ? _Step.type
      : widget.personId == null
      ? _Step.person
      : _Step.amount;
  late var _step = _firstStep;
  var _forward = true;

  /// Set once Confirm has been reached: from then on, finishing (or backing
  /// out of) any step returns straight to Confirm.
  late var _reviewing = _editing;

  late int? _personId = widget.personId;
  PickedContact? _newPerson;
  var _amountText = '';
  int? _accountId;

  /// The account last chosen, kept while the balance update is switched off
  /// so the entry stays in its currency and switching back on restores it.
  int? _lastAccountId;
  var _date = DateTime.now();
  DateTime? _dueDate;
  String? _note;
  var _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    final entry = widget.entry;
    final balance = _paying?.balances.firstOrNull;
    if (entry != null) {
      // An account deleted since leaves the entry as just a record.
      _accountId = _accounts.any((account) => account.id == entry.accountId)
          ? entry.accountId
          : null;
      _amountText = AmountTyping.fromMinor(entry.amountMinor, entry.digits);
      _date = entry.date;
      _dueDate = entry.dueDate;
      _note = entry.note;
    } else if (balance != null) {
      _accountId = _accounts
          .where((a) => balance.sameCurrency(a.currency, a.digits))
          .firstOrNull
          ?.id;
      _amountText = AmountTyping.fromMinor(
        balance.amountMinor.abs(),
        balance.digits,
      );
    } else {
      _accountId = _accounts.firstOrNull?.id;
    }
    if (widget.initialAmountText case final text?) _amountText = text;
    _lastAccountId = _accountId;
    widget.store.accountStore.addListener(_onAccountsChanged);
  }

  @override
  void dispose() {
    widget.store.accountStore.removeListener(_onAccountsChanged);
    super.dispose();
  }

  void _onAccountsChanged() {
    if (mounted) setState(() {});
  }

  List<Account> get _accounts => widget.store.accountStore.accounts;

  Account? get _account =>
      _accounts.where((account) => account.id == _accountId).firstOrNull;

  /// The account's currency; for a plain record, that of the account it was
  /// switched off from, else the entry's own when editing one, the debt's
  /// when settling it, otherwise the first account's.
  (String, int) get _currency {
    final account =
        _account ?? _accounts.where((a) => a.id == _lastAccountId).firstOrNull;
    if (account != null) return (account.currency, account.digits);
    final entry = widget.entry;
    if (entry != null) return (entry.currency, entry.digits);
    final balance = _paying?.balances.firstOrNull;
    if (balance != null) return (balance.currency, balance.digits);
    final first = _accounts.firstOrNull;
    return (first?.currency ?? 'INR', first?.digits ?? 2);
  }

  int? get _amountMinor => parseAccountAmount(_amountText, _currency.$2);

  /// What's left to settle in the chosen currency, when recording a payment
  /// or editing one — then counting what that payment itself had settled.
  int? get _remaining {
    final (currency, digits) = _currency;
    final entry = widget.entry;
    if (entry != null) {
      if (entry.kind.opensDebt) return null;
      final balance =
          widget.store
              .personById(entry.personId)
              ?.balanceIn(currency, digits)
              ?.amountMinor ??
          0;
      final before = entry.currency == currency && entry.digits == digits
          ? balance - entry.signedMinor
          : balance;
      return math.max(-entry.kind.sign * before, 0);
    }
    if (!widget.payment) return null;
    return _paying?.balanceIn(currency, digits)?.amountMinor.abs() ?? 0;
  }

  bool get _amountValid {
    final minor = _amountMinor ?? 0;
    final remaining = _remaining;
    return minor > 0 && (remaining == null || minor <= remaining);
  }

  bool get _hasPerson => _newPerson != null || _personId != null;
  bool get _canSave => _chosenKind != null && _hasPerson && _amountValid;

  String get _personName =>
      _newPerson?.name ??
      widget.store.personById(_personId ?? -1)?.person.name ??
      '';

  String _money(int minor) {
    final (currency, digits) = _currency;
    return formatAccountMoney(minor, digits: digits, currency: currency);
  }

  void _goTo(_Step step) {
    setState(() {
      _forward = step.index > _step.index;
      _step = step;
      _error = null;
      if (step == _Step.confirm) _reviewing = true;
    });
    AdaptiveSheetRoute.of(context)?.avoidKeyboard = _typingSteps.contains(step);
  }

  _Step get _nextStep => switch (_step) {
    _Step.type => widget.personId == null ? _Step.person : _Step.amount,
    _Step.person =>
      widget.initialAmountText == null ? _Step.amount : _Step.confirm,
    _ => _Step.confirm,
  };

  void _advance() => _goTo(_reviewing ? _Step.confirm : _nextStep);

  void _close() =>
      widget.onClose == null ? Navigator.pop(context) : widget.onClose!();

  void _back() {
    if (_saving) return;
    if (_step == _firstStep) {
      widget.onLeave == null ? _close() : widget.onLeave!();
      return;
    }
    switch (_step) {
      case _Step.confirm:
        _reviewing = false;
        _goTo(widget.initialAmountText == null ? _Step.amount : _Step.person);
      case _ when _reviewing:
        _goTo(_Step.confirm);
      case _Step.amount:
        _goTo(widget.personId == null ? _Step.person : _Step.type);
      case _Step.person:
      case _Step.type:
        _goTo(_Step.type);
    }
  }

  void _chooseKind(DebtKind kind) {
    _chosenKind = kind;
    _reviewing = false;
    _goTo(_nextStep);
  }

  void _selectPerson(int id) {
    _personId = id;
    _newPerson = null;
    _advance();
  }

  /// Someone typed in or picked from contacts — the person already on the
  /// list when the name or phone number matches, rather than a duplicate.
  void _selectContact(PickedContact contact) {
    String tail(String? phone) {
      final digits = (phone ?? '').replaceAll(RegExp(r'\D'), '');
      return digits.length > 10 ? digits.substring(digits.length - 10) : digits;
    }

    final phone = tail(contact.phone);
    for (final debts in widget.store.people) {
      final person = debts.person;
      if (person.name.toLowerCase() == contact.name.toLowerCase() ||
          (phone.isNotEmpty && tail(person.phone) == phone)) {
        _selectPerson(person.id);
        return;
      }
    }
    _newPerson = contact;
    _personId = null;
    _advance();
  }

  Future<void> _pickContact() async {
    try {
      final contact = await const PeoplePlatform().pickContact();
      if (contact != null && mounted) _selectContact(contact);
    } catch (_) {
      if (mounted) showAppToast(context, 'Could not open your contacts.');
    }
  }

  Future<void> _typeNewPerson() async {
    final name = await showTextEntryAlert(
      context,
      title: 'New person',
      hintText: 'Who is it?',
      maxLength: 40,
    );
    if (name == null || name.isEmpty || !mounted) return;
    _selectContact(PickedContact(name, null));
  }

  void _typeDigit(String digit) => setState(
    () => _amountText = AmountTyping.digit(_amountText, digit, _currency.$2),
  );

  void _typePoint() => setState(
    () => _amountText = AmountTyping.point(_amountText, _currency.$2),
  );

  void _backspace() =>
      setState(() => _amountText = AmountTyping.backspace(_amountText));

  void _clearAmount() => setState(() => _amountText = '');

  /// Whether saving moves money through an account, or only keeps a record.
  bool get _updatesBalance => _account != null;

  void _setUpdatesBalance(bool on) {
    if (!on) {
      setState(() => _accountId = null);
      return;
    }
    final restored =
        _accounts.where((a) => a.id == _lastAccountId).firstOrNull ??
        _accounts.firstOrNull;
    if (restored == null) {
      // No account to move the money through yet: offer to add one.
      _pickAccount();
      return;
    }
    setState(() => _accountId = _lastAccountId = restored.id);
  }

  /// Dated before today while set to move an account's balance — likely money
  /// already accounted for, so the confirm page offers to keep it a record.
  bool get _looksOld {
    final today = DateTime.now();
    return !_editing &&
        _updatesBalance &&
        _date.isBefore(DateTime(today.year, today.month, today.day));
  }

  Future<void> _pickAccount() async {
    final picked = await showChoiceListSheet<int>(
      context,
      title: _chosenKind!.paysOut ? 'Paid from' : 'Received in',
      items: [
        for (final account in _accounts)
          ChoiceItem(
            value: account.id,
            icon: AppIcon(account.icon, size: 28),
            subtitle: account.maskedDigits,
            label: account.name,
          ),
      ],
      selected: _accountId,
      addLabel: 'Add account',
      onAdd: (context) async =>
          (await addAccountAndSelect(context, widget.store.accountStore))?.id,
    );
    if (picked == null || !mounted) return;
    setState(() => _accountId = _lastAccountId = picked);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePickerSheet(context, initialDate: _date);
    if (picked == null || !mounted) return;
    // Keep the time of day, so the day's list order stays put.
    setState(
      () => _date = DateTime(
        picked.year,
        picked.month,
        picked.day,
        _date.hour,
        _date.minute,
        _date.second,
      ),
    );
  }

  Future<void> _pickDueDate() async {
    final picked = await showAdaptiveSheet<(DateTime?,)>(
      context,
      builder: (_) => _DueDateSheet(
        initialDate: _dueDate ?? DateTime.now().add(const Duration(days: 7)),
        canClear: _dueDate != null,
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _dueDate = picked.$1);
    // Asked when it's about to matter, not when the app opens.
    if (picked.$1 != null) {
      unawaited(widget.store.reminders.requestPermission());
    }
  }

  Future<void> _save() async {
    if (_saving || !_canSave) return;
    final (currency, digits) = _currency;
    final name = _personName;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final entry = widget.entry;
      if (entry != null) {
        await widget.store.updateEntry(
          entry,
          amountMinor: _amountMinor!,
          accountId: _accountId,
          currency: currency,
          digits: digits,
          note: _note,
          date: _date,
          dueDate: _dueDate,
        );
        if (!mounted) return;
        showAppToast(context, 'Changes saved');
        _close();
        return;
      }
      final personId = await widget.store.addEntry(
        personId: _personId,
        newPersonName: _newPerson?.name,
        newPersonPhone: _newPerson?.phone,
        kind: _chosenKind!,
        amountMinor: _amountMinor!,
        accountId: _accountId,
        currency: currency,
        digits: digits,
        note: _note,
        date: _date,
        dueDate: _dueDate,
      );
      if (!mounted) return;
      final settled = widget.store.personById(personId)?.settled ?? false;
      showAppToast(
        context,
        !widget.payment
            ? 'Debt saved'
            : settled
            ? 'All settled with $name 🎉'
            : 'Payment recorded',
      );
      _close();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save this. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    // System back steps back like the arrow does; it only closes the sheet
    // from the first page.
    canPop: !_saving && _step == _firstStep,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: StepSlider(
      stepKey: _step,
      forward: _forward,
      modal: _reviewing,
      child: switch (_step) {
        _Step.type => _typePage(),
        _Step.person => _personPage(),
        _Step.amount => _amountPage(),
        _Step.confirm => _confirmPage(),
      },
    ),
  );

  String get _flowTitle => switch (_chosenKind) {
    DebtKind.lend => 'Lend money',
    DebtKind.borrow => 'Borrow money',
    DebtKind.collect => 'Record payment received',
    DebtKind.repay => 'Record payback',
    null => 'Add a debt',
  };

  Widget _typePage() {
    return SheetPage(
      header: const SheetHeader('Add a debt'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TypeChoiceCard(
            icon: DebtKind.lend.icon,
            color: debtKindColor(context, DebtKind.lend),
            title: 'I lent money',
            subtitle: 'Someone owes you',
            onTap: () => _chooseKind(DebtKind.lend),
          ),
          const SizedBox(height: 12),
          TypeChoiceCard(
            icon: DebtKind.borrow.icon,
            color: debtKindColor(context, DebtKind.borrow),
            title: 'I borrowed money',
            subtitle: 'You owe someone',
            onTap: () => _chooseKind(DebtKind.borrow),
          ),
        ],
      ),
      actions: ActionButtonBar(secondaryLabel: 'Cancel', onSecondary: _close),
    );
  }

  Widget _personPage() => _PersonPage(
    title: _flowTitle,
    question: _chosenKind == DebtKind.borrow
        ? 'Who lent you money?'
        : 'Who did you lend to?',
    people: widget.store.people,
    selectedId: _personId,
    newPerson: _newPerson,
    onBack: _back,
    onCancel: _close,
    onPickContact: _pickContact,
    onNewPerson: _typeNewPerson,
    onSelected: _selectPerson,
    onSelectNew: _advance,
  );

  Widget _amountPage() {
    final colors = SheetColors.of(context);
    final (currency, digits) = _currency;
    final remaining = _remaining;
    final minor = _amountMinor;
    final tooMuch = remaining != null && minor != null && minor > remaining;
    final name = _personName;
    final hint = remaining != null
        ? (tooMuch
              ? 'That’s more than the ${_money(remaining)} left'
              : '${_money(remaining)} left to settle')
        : name.isEmpty
        ? null
        : _chosenKind!.paysOut
        ? 'To $name'
        : 'From $name';
    return SheetPage(
      header: SheetHeader(
        _flowTitle,
        onBack: _back,
        titleStyle: _stepContextStyle(context),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StepQuestion(switch (_chosenKind!) {
            DebtKind.lend => 'How much did you lend?',
            DebtKind.borrow => 'How much did you borrow?',
            DebtKind.collect => 'How much did $name pay back?',
            DebtKind.repay => 'How much did you pay back?',
          }),
          if (hint != null) ...[
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: tooMuch ? colors.expense : colors.muted,
              ),
            ),
          ],
          const SizedBox(height: 20),
          AmountDisplayCard(
            amount: AmountTyping.display(
              _amountText,
              currency: currency,
              decimals: digits,
            ),
            empty: _amountText.isEmpty,
          ),
          const SizedBox(height: 20),
          NumberKeypad(
            onDigit: _typeDigit,
            onDecimalPoint: _typePoint,
            onBackspace: _backspace,
            onClear: _clearAmount,
            decimalEnabled: digits > 0 && !_amountText.contains('.'),
          ),
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: _close,
        primaryLabel: 'Continue',
        onPrimary: _amountValid ? _advance : null,
        primaryColor: colors.primary,
      ),
    );
  }

  Widget _confirmPage() {
    final colors = SheetColors.of(context);
    final kind = _chosenKind!;
    final (currency, _) = _currency;
    final minor = _amountMinor;
    final remaining = _remaining;
    final account = _account;
    final name = _personName;
    final problem = minor == null
        ? 'Too many decimals for $currency. Edit the amount or pick another account.'
        : remaining == 0
        ? 'Nothing is owed in $currency. Choose a different account.'
        : remaining != null && minor > remaining
        ? 'Only ${_money(remaining)} is left to settle. Tap the amount to change it.'
        : null;
    // Nothing can be changed while the save is in flight.
    VoidCallback? edit(VoidCallback onEdit) => _saving ? null : onEdit;
    return SheetPage(
      header: SheetHeader(
        _editing
            ? (kind.opensDebt ? 'Edit debt' : 'Edit payment')
            : widget.payment
            ? 'Confirm payment'
            : 'Confirm debt',
        // Editing starts here: Cancel closes, there's no step to go back to.
        onBack: _editing ? null : _back,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          InkWell(
            onTap: edit(() => _goTo(_Step.amount)),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: AmountHero(
                amount: minor != null
                    ? _money(minor)
                    : '$currency $_amountText',
                caption: kind.describe(name),
                color: debtKindColor(context, kind),
              ),
            ),
          ),
          const SizedBox(height: 16),
          TransactionDetailsCard(
            rows: [
              TransactionDetailRow(
                leading: SheetIconTile(child: PersonAvatar(name)),
                label: switch (kind) {
                  DebtKind.lend => 'Lent to',
                  DebtKind.borrow => 'Borrowed from',
                  DebtKind.collect => 'Received from',
                  DebtKind.repay => 'Paid to',
                },
                value: name,
                onTap: widget.personId == null
                    ? edit(() => _goTo(_Step.person))
                    : null,
              ),
              TransactionDetailRow(
                leading: const SheetIconTile(
                  icon: Icons.calendar_today_rounded,
                ),
                label: 'Date',
                value: formatTransactionDate(_date),
                onTap: edit(_pickDate),
              ),
              if (kind.opensDebt)
                TransactionDetailRow(
                  leading: const SheetIconTile(
                    icon: Icons.event_available_rounded,
                  ),
                  label: 'Due date',
                  value: _dueDate == null
                      ? 'Add a due date'
                      : formatTransactionDate(_dueDate!),
                  placeholder: _dueDate == null,
                  onTap: edit(_pickDueDate),
                ),
              TransactionTextRow(
                icon: Icons.notes_rounded,
                label: 'Note',
                hintText: 'Add a note',
                initialValue: _note ?? '',
                maxLength: 200,
                multiline: true,
                enabled: !_saving,
                // No rebuild needed: the field shows what's typed itself.
                onChanged: (text) => _note = text,
              ),
              TransactionSwitchRow(
                icon: Icons.account_balance_wallet_outlined,
                label: 'Update account balance',
                value: account == null
                    ? 'Only tracked here'
                    : kind.paysOut
                    ? 'Takes this out of your account'
                    : 'Adds this to your account',
                on: account != null,
                onChanged: _saving ? null : _setUpdatesBalance,
              ),
              if (account != null)
                TransactionDetailRow(
                  leading: EntityIconTile(
                    chosen: true,
                    iconKey: account.icon,
                    fallback: Icons.account_balance_wallet_outlined,
                  ),
                  label: kind.paysOut ? 'Paid from' : 'Received in',
                  value: account.name,
                  onTap: edit(_pickAccount),
                ),
            ],
          ),
          if (_looksOld)
            Align(
              child: TextButton.icon(
                onPressed: edit(() => _setUpdatesBalance(false)),
                icon: const Icon(Icons.history_rounded, size: 18),
                label: Text(
                  kind.opensDebt
                      ? 'Old debt? Don’t change balance'
                      : 'Old payment? Don’t change balance',
                ),
              ),
            ),
          if (problem != null) ...[
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
                      problem,
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
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: colors.expense),
            ),
          ],
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: _saving ? null : _close,
        primaryLabel: _saving ? 'Saving…' : 'Save',
        onPrimary: _saving || !_canSave ? null : _save,
        primaryColor: colors.primary,
      ),
    );
  }
}

/// Who the debt is with: pick from contacts, type a new name, or choose
/// someone already on the list.
class _PersonPage extends StatefulWidget {
  const _PersonPage({
    required this.title,
    required this.question,
    required this.people,
    required this.selectedId,
    required this.newPerson,
    required this.onBack,
    required this.onCancel,
    required this.onPickContact,
    required this.onNewPerson,
    required this.onSelected,
    required this.onSelectNew,
  });
  final String title, question;
  final List<PersonDebts> people;
  final int? selectedId;

  /// Someone new chosen earlier in this sheet, not saved yet.
  final PickedContact? newPerson;
  final VoidCallback onBack, onCancel, onPickContact, onNewPerson, onSelectNew;
  final ValueChanged<int> onSelected;

  @override
  State<_PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<_PersonPage> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _listKey = GlobalKey();

  /// While searching, the people list is scrolled to the top so the question
  /// and the contact rows give their room to it above the keyboard — until
  /// the person scrolls it themselves.
  bool _followList = false;

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(() {
      _followList = _searchFocus.hasFocus;
      if (_followList) _revealList(animate: true);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _revealList({required bool animate}) {
    final context = _listKey.currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      duration: animate ? const Duration(milliseconds: 250) : Duration.zero,
      curve: Curves.easeOutCubic,
    );
  }

  bool _onScroll(Notification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      // A drag by the person hands the list back to them.
      _followList = false;
    } else if (notification is ScrollMetricsNotification && _followList) {
      // The keyboard is still sliding in: keep the list in place.
      _revealList(animate: false);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final query = _search.text.trim().toLowerCase();
    final people = widget.people
        .where((debts) => debts.person.name.toLowerCase().contains(query))
        .toList();
    final newPerson = widget.newPerson;
    final rows = <Widget>[
      if (newPerson != null)
        _PersonChoice(
          name: newPerson.name,
          subtitle: 'New',
          selected: true,
          onTap: widget.onSelectNew,
        ),
      for (final debts in people)
        _PersonChoice(
          name: debts.person.name,
          subtitle: debts.settled
              ? 'Settled'
              : '${debts.owesYou ? 'Owes you' : 'You owe'} '
                    '${formatDebtAmounts(debts.balances)}',
          selected: debts.person.id == widget.selectedId,
          onTap: () => widget.onSelected(debts.person.id),
        ),
    ];
    final page = SheetPage(
      header: SheetHeader(
        widget.title,
        onBack: widget.onBack,
        titleStyle: _stepContextStyle(context),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _StepQuestion(widget.question),
          const SizedBox(height: 20),
          SheetCard(
            child: Column(
              children: [
                _ActionRow(
                  icon: Icons.contacts_rounded,
                  label: 'Choose from contacts',
                  onTap: widget.onPickContact,
                ),
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: 66,
                  color: colors.divider,
                ),
                _ActionRow(
                  icon: Icons.person_add_alt_1_rounded,
                  label: 'New person',
                  onTap: widget.onNewPerson,
                ),
              ],
            ),
          ),
          if (widget.people.isNotEmpty || newPerson != null) ...[
            const SizedBox(height: 20),
            SheetCard(
              key: _listKey,
              child: Column(
                children: [
                  if (rows.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Text(
                        'No matches',
                        style: TextStyle(fontSize: 14, color: colors.muted),
                      ),
                    ),
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0)
                      Divider(
                        height: 1,
                        thickness: 1,
                        indent: 66,
                        color: colors.divider,
                      ),
                    rows[i],
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
      // Pinned below the scrolling list, like the category sheet's search.
      actions: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: SearchField(
          controller: _search,
          focusNode: _searchFocus,
          onChanged: (_) => setState(() {}),
          hintText: 'Search people',
          fillColor: colors.card,
        ),
      ),
    );
    // The page's own scroll view reports up through here.
    return NotificationListener<Notification>(
      onNotification: _onScroll,
      child: page,
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    minTileHeight: 60,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12),
    horizontalTitleGap: 12,
    leading: SheetIconTile(icon: icon),
    title: Text(
      label,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: SheetColors.of(context).primary,
      ),
    ),
    onTap: onTap,
  );
}

class _PersonChoice extends StatelessWidget {
  const _PersonChoice({
    required this.name,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final String name, subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return ListTile(
      minTileHeight: 60,
      contentPadding: const EdgeInsets.only(left: 12, right: 16),
      horizontalTitleGap: 12,
      leading: PersonAvatar(name),
      title: Text(
        name,
        style: TextStyle(
          fontSize: 15,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: colors.text,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12.5, color: colors.muted),
      ),
      trailing: Icon(
        selected ? Icons.check_circle_rounded : Icons.radio_button_unchecked,
        size: 22,
        color: selected ? colors.primary : colors.outline,
      ),
      selected: selected,
      selectedTileColor: colors.primary.withValues(alpha: .07),
      onTap: onTap,
    );
  }
}

class _EditPersonSheet extends StatefulWidget {
  const _EditPersonSheet({required this.store, required this.person});
  final DebtStore store;
  final DebtPerson person;

  @override
  State<_EditPersonSheet> createState() => _EditPersonSheetState();
}

class _EditPersonSheetState extends State<_EditPersonSheet> {
  late final _name = TextEditingController(text: widget.person.name);
  late final _phone = TextEditingController(text: widget.person.phone ?? '');
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  bool get _changed =>
      _name.text.trim() != widget.person.name ||
      _phone.text.trim() != (widget.person.phone ?? '');

  bool get _canSave => !_saving && _name.text.trim().isNotEmpty && _changed;

  Future<void> _pickContact() async {
    try {
      final contact = await const PeoplePlatform().pickContact();
      if (contact == null || !mounted) return;
      setState(() {
        _name.text = contact.name.characters.take(40).toString();
        _phone.text = contact.phone ?? '';
      });
    } catch (_) {
      if (mounted) showAppToast(context, 'Could not open your contacts.');
    }
  }

  Future<void> _save() async {
    if (!_canSave) return;
    final navigator = Navigator.of(context);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.updatePerson(
        widget.person.id,
        name: _name.text,
        phone: _phone.text,
      );
      if (!mounted) return;
      showAppToast(context, 'Changes saved');
      navigator.pop();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not save this. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return PopScope(
      canPop: !_saving,
      child: SheetPage(
        header: const SheetHeader('Edit person'),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            Center(child: PersonAvatar(_name.text, size: 64)),
            const SizedBox(height: 20),
            TransactionDetailsCard(
              rows: [
                TransactionTextRow(
                  controller: _name,
                  icon: Icons.person_outline_rounded,
                  label: 'Name',
                  hintText: 'Who is it?',
                  maxLength: 40,
                  enabled: !_saving,
                  onChanged: (_) => setState(() {}),
                ),
                TransactionTextRow(
                  controller: _phone,
                  icon: Icons.phone_outlined,
                  label: 'Phone',
                  hintText: 'Add a phone number',
                  maxLength: 20,
                  keyboardType: TextInputType.phone,
                  enabled: !_saving,
                  onChanged: (_) => setState(() {}),
                ),
                _ActionRow(
                  icon: Icons.contacts_rounded,
                  label: 'Choose from contacts',
                  onTap: _saving ? null : _pickContact,
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: colors.expense),
              ),
            ],
          ],
        ),
        actions: ActionButtonBar(
          secondaryLabel: 'Cancel',
          onSecondary: _saving ? null : () => Navigator.pop(context),
          primaryLabel: _saving ? 'Saving…' : 'Save',
          onPrimary: _canSave ? _save : null,
          primaryColor: colors.primary,
        ),
      ),
    );
  }
}

/// The calendar for a due date, which can also be taken away again.
class _DueDateSheet extends StatelessWidget {
  const _DueDateSheet({required this.initialDate, required this.canClear});
  final DateTime initialDate;
  final bool canClear;

  @override
  Widget build(BuildContext context) => SheetPage(
    header: const SheetHeader('Due date'),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'You’ll get a reminder that morning.',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: 13, color: SheetColors.of(context).muted),
        ),
        const SizedBox(height: 8),
        SheetCard(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 10, 10),
            child: CalendarPicker(
              initialDate: initialDate,
              onChanged: (date) => Navigator.pop(context, (date,)),
            ),
          ),
        ),
      ],
    ),
    actions: ActionButtonBar(
      secondaryLabel: canClear ? 'No due date' : 'Cancel',
      onSecondary: () =>
          Navigator.pop<(DateTime?,)>(context, canClear ? (null,) : null),
    ),
  );
}

// The flow label is secondary to the question for the current step (as in
// the transaction sheet's pages).
TextStyle _stepContextStyle(BuildContext context) => TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w500,
  letterSpacing: 0,
  color: SheetColors.of(context).muted,
);

class _StepQuestion extends StatelessWidget {
  const _StepQuestion(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    textAlign: TextAlign.center,
    style: TextStyle(
      fontSize: 22,
      height: 1.3,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.4,
      color: SheetColors.of(context).text,
    ),
  );
}
