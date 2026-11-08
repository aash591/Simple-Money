import 'dart:async';

import 'package:flutter/material.dart';

import '../../../domain/account.dart';
import '../../../domain/service_icon.dart';
import '../../../domain/category.dart';
import '../../../domain/subscription.dart';
import '../../../state/ad_gate.dart';
import '../../../state/subscription_store.dart';
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
Future<void> showSubscriptionSheet(
  BuildContext context, {
  required SubscriptionStore store,
  Subscription? existing,
}) => showAdaptiveSheet<void>(
  context,
  entrance: SheetEntrance.fadeRise,
  dismissible: false,
  avoidKeyboard: existing != null,
  builder: (_) => SubscriptionSheet(store: store, existing: existing),
);

enum _Step { amount, details }

class SubscriptionSheet extends StatefulWidget {
  const SubscriptionSheet({super.key, required this.store, this.existing});
  final SubscriptionStore store;
  final Subscription? existing;

  @override
  State<SubscriptionSheet> createState() => _SubscriptionSheetState();
}

class _SubscriptionSheetState extends State<SubscriptionSheet> {
  late final Subscription? _existing = widget.existing;
  late final _firstStep = _existing == null ? _Step.amount : _Step.details;
  late var _step = _firstStep;
  var _forward = true;

  late final _name = TextEditingController(text: _existing?.name ?? '');
  late var _amountText = _existing == null
      ? ''
      : AmountTyping.fromMinor(_existing.amountMinor, _existing.digits);
  late String? _pickedIcon = _existing?.icon;
  late var _cycle = _existing?.cycle ?? BillingCycle.monthly;
  late DateTime? _pickedDue = _existing?.nextDue;
  late int? _accountId =
      _existing?.accountId ??
      widget.store.accountStore.accounts.firstOrNull?.id;
  late int? _categoryId = _existing?.categoryId ?? _defaultCategory?.id;
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
      .where((c) => c.type == CategoryType.expense)
      .toList();

  Category? get _defaultCategory =>
      _categories.where((c) => c.name == 'Subscriptions').firstOrNull;

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
    return serviceIcon(_name.text) ?? 'subscriptions';
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
    final parents = _categories.where((c) => c.parentId == null);
    final picked = await showChoiceListSheet<int>(
      context,
      title: 'Category',
      items: [
        for (final parent in parents) ...[
          ChoiceItem(
            value: parent.id,
            icon: AppIcon(parent.icon, size: 28),
            label: parent.name,
          ),
          for (final child in _categories.where((c) => c.parentId == parent.id))
            ChoiceItem(
              value: child.id,
              icon: AppIcon(child.icon, size: 28),
              label: child.name,
              indent: true,
            ),
        ],
      ],
      selected: _categoryId,
      addLabel: 'Add category',
      onAdd: (context) async => (await addCategoryAndSelect(
        context,
        widget.store.categoryStore,
        CategoryType.expense,
      ))?.id,
    );
    if (picked != null && mounted) setState(() => _categoryId = picked);
  }

  SubscriptionDraft get _draft => SubscriptionDraft(
    name: _name.text,
    icon: _icon,
    amountMinor: _amountMinor ?? 0,
    cycle: _cycle,
    nextDue: _due,
    accountId: _accountId ?? -1,
    categoryId: _categoryId,
    remind: _remind,
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
        _existing == null ? 'Subscription added' : 'Subscription saved',
      );
      _close();
      unawaited(AdGate.instance.after(AdMoment.subscription));
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
      s.paused ? 'Subscription resumed' : 'Subscription paused',
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
      'Subscription deleted',
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
        editing ? 'Edit subscription' : 'Add subscription',
        onBack: editing ? _back : null,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'How much does it cost?',
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
        existing == null ? 'Add subscription' : 'Edit subscription',
        onBack: existing == null ? _back : null,
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TransactionDetailsCard(
            rows: [
              TransactionTextRow(
                icon: Icons.label_outline_rounded,
                label: 'Name',
                hintText: 'Netflix, gym, cloud storage…',
                controller: _name,
                maxLength: 40,
                enabled: !_saving,
                onChanged: (_) => setState(() {}),
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
                label: 'Next renewal',
                value: formatTransactionDate(_due),
                onTap: edit(_pickDue),
              ),
              TransactionDetailRow(
                leading: EntityIconTile(
                  chosen: account != null,
                  iconKey: account?.icon,
                  fallback: Icons.account_balance_wallet_outlined,
                ),
                label: 'Paid from',
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
                value: category?.name ?? 'Subscriptions',
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
                      label: 'Skip this renewal',
                      onTap: edit(_skip),
                    ),
                    Divider(height: 1, indent: 66, color: colors.divider),
                  ],
                  _ActionRow(
                    icon: existing.paused
                        ? Icons.play_circle_outline_rounded
                        : Icons.pause_circle_outline_rounded,
                    label: existing.paused
                        ? 'Resume subscription'
                        : 'Pause subscription',
                    onTap: edit(_togglePause),
                  ),
                  Divider(height: 1, indent: 66, color: colors.divider),
                  _ActionRow(
                    icon: Icons.delete_outline_rounded,
                    label: 'Delete subscription',
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
