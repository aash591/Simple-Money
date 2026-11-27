import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/service_icon.dart';
import '../../../domain/category.dart';
import '../../../domain/recurring_suggestions.dart';
import '../../components/transactions/review_pickers.dart';
import '../../../domain/recurring_payment.dart';
import '../../../state/ad_gate.dart';
import '../../../state/recurring_payment_store.dart';
import '../../components/action_buttons.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/app_icon.dart';
import '../../components/app_toast.dart';
import '../../components/choice_list_sheet.dart';
import '../../components/confirmation_alert.dart';
import '../../components/date_picker_sheet.dart';
import '../../components/feature_page.dart';
import '../../components/number_keypad.dart';
import '../../components/select_icon_screen.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/amount_typing.dart';
import '../../transactions/quick_add_helpers.dart';
import '../../transactions/transaction_widgets.dart';

/// Adding one: how much → the details. Editing opens on the details.
Future<void> showRecurringPaymentSheet(
  BuildContext context, {
  required RecurringPaymentStore store,
  RecurringPayment? existing,
}) => showAdaptiveSheet<void>(
  context,
  entrance: SheetEntrance.fadeRise,
  dismissible: false,
  avoidKeyboard: existing != null,
  builder: (_) => RecurringPaymentSheet(store: store, existing: existing),
);

enum _Step { amount, details }

class RecurringPaymentSheet extends StatefulWidget {
  const RecurringPaymentSheet({super.key, required this.store, this.existing});
  final RecurringPaymentStore store;
  final RecurringPayment? existing;

  @override
  State<RecurringPaymentSheet> createState() => _RecurringPaymentSheetState();
}

class _RecurringPaymentSheetState extends State<RecurringPaymentSheet> {
  late final RecurringPayment? _existing = widget.existing;
  late final _firstStep = _existing == null ? _Step.amount : _Step.details;
  late var _step = _firstStep;
  var _forward = true;

  late final _name = TextEditingController(text: _existing?.name ?? '');
  late var _amountText = _existing == null
      ? ''
      : AmountTyping.fromMinor(_existing.amountMinor, _existing.digits);
  late String? _pickedIcon = _existing?.icon;
  late var _incoming = _existing?.incoming ?? false;
  late var _cycle = _existing?.cycle ?? BillingCycle.monthly;
  late DateTime? _pickedDue = _existing?.nextDue;
  late int? _accountId =
      _existing?.accountId ??
      widget.store.accountStore.accounts.firstOrNull?.id;
  late int? _categoryId = _existing?.categoryId ?? _suggestedCategory?.id;

  /// Once a category is chosen by hand, typing a name stops changing it.
  late var _categoryPicked = _existing != null;
  late var _remind = _existing?.remind ?? true;
  var _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  List<Account> get _accounts => widget.store.accountStore.accounts;
  List<Category> get _categories => widget.store.categoryStore.categories
      .where((c) => c.type == _categoryType)
      .toList();

  CategoryType get _categoryType =>
      _incoming ? CategoryType.income : CategoryType.expense;

  Category? get _defaultCategory => _categories
      .where((c) => c.name == (_incoming ? 'Rental Income' : 'Subscriptions'))
      .firstOrNull;

  RecurringSuggestion? get _suggestion =>
      suggestRecurring(_name.text, incoming: _incoming);

  /// What the name points at, else the default for the direction.
  Category? get _suggestedCategory {
    final name = _suggestion?.category;
    return _categories.where((c) => c.name == name).firstOrNull ??
        _defaultCategory;
  }

  /// Follows the name while no category has been picked by hand.
  void _nameChanged() => setState(() {
    if (!_categoryPicked) _categoryId = _suggestedCategory?.id;
  });

  Account? get _account =>
      _accounts.where((a) => a.id == _accountId).firstOrNull;
  Category? get _category =>
      _categories.where((c) => c.id == _categoryId).firstOrNull;

  int get _digits => _account?.digits ?? _existing?.digits ?? 2;
  String get _currency => _account?.currency ?? _existing?.currency ?? 'INR';
  int? get _amountMinor => parseAccountAmount(_amountText, _digits);

  /// A known service's logo once its name is typed, until one is picked.
  String get _icon {
    if (_pickedIcon != null) return _pickedIcon!;
    return serviceIcon(_name.text) ??
        _suggestion?.icon ??
        (_incoming ? 'rent' : 'subscriptions');
  }

  /// One cycle from today, until a date is picked.
  DateTime get _due =>
      _pickedDue ?? _cycle.after(dateOnly(DateTime.now()), DateTime.now().day);

  bool get _canSave =>
      !_saving &&
      _name.text.trim().isNotEmpty &&
      (_amountMinor ?? 0) > 0 &&
      _account != null;

  String _money(int minor) =>
      formatAccountMoney(minor, digits: _digits, currency: _currency);

  void _goTo(_Step step) {
    setState(() {
      _forward = step.index > _step.index;
      _step = step;
      _error = null;
    });
    AdaptiveSheetRoute.of(context)?.avoidKeyboard = step == _Step.details;
  }

  void _close() => Navigator.pop(context);

  void _back() {
    if (_saving) return;
    if (_step == _firstStep) {
      _close();
    } else {
      _goTo(_Step.details);
    }
  }

  Future<void> _pickIcon() async {
    final icon = await Navigator.of(context)
        .push(FeatureRoute<String>(SelectIconScreen(selectedKey: _icon)));
    if (icon != null && mounted) setState(() => _pickedIcon = icon);
  }

  Future<void> _pickCycle() async {
    final picked = await showChoiceListSheet<BillingCycle>(
      context,
      title: 'Billing cycle',
      items: [
        for (final cycle in BillingCycle.values)
          ChoiceItem(
            value: cycle,
            icon: const Icon(Icons.autorenew_rounded),
            label: cycle.label,
          ),
      ],
      selected: _cycle,
    );
    if (picked != null && mounted) setState(() => _cycle = picked);
  }

  Future<void> _pickDue() async {
    final picked = await showDatePickerSheet(context, initialDate: _due);
    if (picked != null && mounted) setState(() => _pickedDue = picked);
  }

  Future<void> _pickAccount() async {
    final picked = await showChoiceListSheet<int>(
      context,
      title: 'Paid from',
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
    if (picked != null && mounted) setState(() => _accountId = picked);
  }

  Future<void> _pickCategory() async {
    final pick = await showReviewCategoryPicker(
      context,
      title: _existing == null ? 'New recurring' : 'Edit recurring',
      categories: widget.store.categoryStore.categories,
      store: widget.store.categoryStore,
      type: _categoryType,
      selected: _categoryId,
    );
    final id = pick?.categoryId;
    if (id != null && mounted) {
      setState(() {
        _categoryId = id;
        _categoryPicked = true;
      });
    }
  }

  RecurringPaymentDraft get _draft => RecurringPaymentDraft(
    name: _name.text,
    icon: _icon,
    amountMinor: _amountMinor ?? 0,
    cycle: _cycle,
    nextDue: _due,
    accountId: _accountId ?? -1,
    categoryId: _categoryId,
    remind: _remind,
    incoming: _incoming,
  );

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final repository = widget.store.repository;
    final draft = _draft;
    final existing = _existing;
    try {
      await widget.store.save(
        () => existing == null
            ? repository.add(draft)
            : repository.update(existing.id, draft),
      );
      if (draft.remind) unawaited(widget.store.reminders.requestPermission());
      if (!mounted) return;
      showAppToast(
        context,
        _existing == null
            ? 'Recurring payment added'
            : 'Recurring payment saved',
      );
      _close();
      unawaited(AdGate.instance.after(AdMoment.recurringPayment));
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is ArgumentError
              ? error.message.toString()
              : 'Could not save this. Please try again.';
        });
      }
    }
  }

  /// Skip, pause and delete apply straight away, apart from the form.
  Future<void> _run(String done, Future<void> Function() action) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.save(action);
      if (!mounted) return;
      showAppToast(context, done);
      _close();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not update this. Please try again.';
        });
      }
    }
  }

  Future<void> _skip() {
    final s = _existing!;
    return _run(
      'Skipped to ${formatTransactionDate(s.followingDue)}',
      () => widget.store.repository.skip(s),
    );
  }

  Future<void> _togglePause() {
    final s = _existing!;
    return _run(
      s.paused ? 'Recurring payment resumed' : 'Recurring payment paused',
      () => widget.store.repository.setPaused(s, !s.paused),
    );
  }

  Future<void> _delete() async {
    final s = _existing!;
    final confirmed = await showDeleteConfirmation(
      context,
      title: 'Delete ${s.name}?',
      message: 'Payments you already marked paid stay in your transactions.',
    );
    if (!confirmed || !mounted) return;
    await _run(
      'Recurring payment deleted',
      () => widget.store.repository.delete(s.id),
    );
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving && _step == _firstStep,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: StepSlider(
      stepKey: _step,
      forward: _forward,
      modal: _existing != null,
      child: switch (_step) {
        _Step.amount => _amountPage(),
        _Step.details => _detailsPage(),
      },
    ),
  );

  Widget _amountPage() {
    final colors = SheetColors.of(context);
    final editing = _existing != null;
    return SheetPage(
      header: SheetHeader(
        editing ? 'Edit recurring' : 'New recurring',
        onBack: editing ? _back : null,
        centered: true,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'How much?',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 22,
              height: 1.3,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.4,
              color: colors.text,
            ),
          ),
          const SizedBox(height: 20),
          AmountDisplayCard(
            amount: AmountTyping.display(
              _amountText,
              currency: _currency,
              decimals: _digits,
            ),
            empty: _amountText.isEmpty,
          ),
          const SizedBox(height: 20),
          NumberKeypad(
            onDigit: (digit) => setState(
              () =>
                  _amountText = AmountTyping.digit(_amountText, digit, _digits),
            ),
            onDecimalPoint: () => setState(
              () => _amountText = AmountTyping.point(_amountText, _digits),
            ),
            onBackspace: () => setState(
              () => _amountText = AmountTyping.backspace(_amountText),
            ),
            onClear: () => setState(() => _amountText = ''),
            decimalEnabled: _digits > 0 && !_amountText.contains('.'),
          ),
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: _close,
        primaryLabel: editing ? 'Done' : 'Continue',
        onPrimary: (_amountMinor ?? 0) > 0 ? () => _goTo(_Step.details) : null,
        primaryColor: colors.primary,
      ),
    );
  }

  Widget _detailsPage() {
    final colors = SheetColors.of(context);
    final existing = _existing;
    final account = _account;
    final category = _category;
    final minor = _amountMinor;
    VoidCallback? edit(VoidCallback onEdit) => _saving ? null : onEdit;
    return SheetPage(
      header: SheetHeader(
        existing == null ? 'New recurring' : 'Edit recurring',
        onBack: existing == null ? _back : null,
        centered: true,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TransactionDetailsCard(
            rows: [
              TransactionSwitchRow(
                icon: Icons.south_west_rounded,
                label: 'Money coming in',
                value: 'Like rent you receive',
                on: _incoming,
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                        _incoming = value;
                        if (!_categoryPicked) {
                          _categoryId = _suggestedCategory?.id;
                        }
                      }),
              ),
              TransactionTextRow(
                icon: Icons.label_outline_rounded,
                label: 'Name',
                hintText: 'Netflix, rent, gym…',
                controller: _name,
                maxLength: 40,
                enabled: !_saving,
                onChanged: (_) => _nameChanged(),
              ),
              TransactionDetailRow(
                leading: SheetIconTile(child: AppIcon(_icon, size: 28)),
                label: 'Icon',
                value: 'Change icon',
                onTap: edit(_pickIcon),
              ),
              TransactionDetailRow(
                leading: const SheetIconTile(icon: Icons.payments_outlined),
                label: 'Amount',
                value: minor == null
                    ? '$_currency $_amountText'
                    : '${_money(minor)}/${_cycle.per}',
                onTap: edit(() => _goTo(_Step.amount)),
              ),
              TransactionDetailRow(
                leading: const SheetIconTile(icon: Icons.autorenew_rounded),
                label: 'Billing cycle',
                value: _cycle.label,
                onTap: edit(_pickCycle),
              ),
              TransactionDetailRow(
                leading: const SheetIconTile(icon: Icons.event_repeat_rounded),
                label: 'Next due',
                value: formatTransactionDate(_due),
                onTap: edit(_pickDue),
              ),
              TransactionDetailRow(
                leading: EntityIconTile(
                  chosen: account != null,
                  iconKey: account?.icon,
                  fallback: Icons.account_balance_wallet_outlined,
                ),
                label: _incoming ? 'Paid into' : 'Paid from',
                value: account?.name ?? 'Choose an account',
                placeholder: account == null,
                onTap: edit(_pickAccount),
              ),
              TransactionDetailRow(
                leading: EntityIconTile(
                  chosen: category != null,
                  iconKey: category?.icon,
                  fallback: Icons.grid_view_rounded,
                ),
                label: 'Category',
                value:
                    category?.name ??
                    (_incoming ? 'Rental Income' : 'Subscriptions'),
                placeholder: category == null,
                onTap: edit(_pickCategory),
              ),
              TransactionSwitchRow(
                icon: Icons.notifications_none_rounded,
                label: 'Remind me',
                value: 'Two days before, and on the day',
                on: _remind,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _remind = value),
              ),
            ],
          ),
          if (existing != null) ...[
            const SizedBox(height: 16),
            SheetCard(
              child: Column(
                children: [
                  if (!existing.paused) ...[
                    _ActionRow(
                      icon: Icons.skip_next_rounded,
                      label: 'Skip this one',
                      onTap: edit(_skip),
                    ),
                    Divider(height: 1, indent: 66, color: colors.divider),
                  ],
                  _ActionRow(
                    icon: existing.paused
                        ? Icons.play_circle_outline_rounded
                        : Icons.pause_circle_outline_rounded,
                    label: existing.paused
                        ? 'Resume recurring payment'
                        : 'Pause recurring payment',
                    onTap: edit(_togglePause),
                  ),
                  Divider(height: 1, indent: 66, color: colors.divider),
                  _ActionRow(
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete recurring payment',
                    color: colors.expense,
                    onTap: edit(_delete),
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
        onPrimary: _canSave ? _save : null,
        primaryColor: colors.primary,
      ),
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
  });
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tint = color ?? SheetColors.of(context).primary;
    return ListTile(
      minTileHeight: 60,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      horizontalTitleGap: 12,
      leading: SheetIconTile(icon: icon, color: tint),
      title: Text(
        label,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: tint,
        ),
      ),
      onTap: onTap,
    );
  }
}
