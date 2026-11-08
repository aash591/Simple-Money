import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/app_icons.dart';
import '../../../domain/currency.dart';
import '../../../domain/currency_scope.dart';
import '../../../state/main_currency_controller.dart';
import '../../../state/account_store.dart';
import '../../../state/transaction_store.dart';
import '../../components/action_buttons.dart';
import '../../components/app_icon.dart';
import '../../components/app_toast.dart';
import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../components/currency_flag.dart';
import '../../components/feature_page.dart';
import '../../components/more_popup_button.dart';
import '../../components/select_icon_screen.dart';
import '../../transactions/adjust_balance_sheet.dart';
import '../../transactions/transfer_sheet.dart';
import 'currency_screen.dart';
import 'account_card.dart';

import 'package:flutter/services.dart';

enum _AccountAction { edit, adjust, transfer, archive, restore, delete }

/// Above this many entries, deleting an account throws away enough history to
/// be worth a third look, so [_confirmDelete] adds a warning step that says
/// the number out loud. Archiving is offered either way and keeps all of it.
const _bulkDeleteThreshold = 10;

class EditAccountScreen extends StatefulWidget {
  const EditAccountScreen({
    super.key,
    required this.store,
    this.account,
    this.transactionStore,
    this.initialName,
    this.initialIcon,
    this.initialCurrency,
    this.initialLastDigits,
    this.initialInstitution,
    this.initialType = AccountType.bank,
  }) : assert(account == null || transactionStore != null);
  final String? initialName, initialIcon, initialCurrency;
  final String? initialLastDigits, initialInstitution;
  final AccountType initialType;
  final AccountStore store;
  final Account? account;
  final TransactionStore? transactionStore;
  @override
  State<EditAccountScreen> createState() => _EditAccountScreenState();
}

class _EditAccountScreenState extends State<EditAccountScreen> {
  late final _name = TextEditingController(
    text: widget.account?.name ?? widget.initialName ?? '',
  );
  final _balance = TextEditingController();
  late AccountType _type = widget.account?.type ?? widget.initialType;
  late final _lastDigits = TextEditingController(
    text: widget.account?.lastDigits ?? widget.initialLastDigits ?? '',
  );
  late final _creditLimit = TextEditingController(
    text: widget.account?.creditLimitMinor == null
        ? ''
        : (widget.account!.creditLimitMinor! /
                  math.pow(10, widget.account!.digits))
              .toString(),
  );
  late final _availableLimit = TextEditingController(
    text: widget.account?.availableCreditLimitMinor == null
        ? ''
        : (widget.account!.availableCreditLimitMinor! /
                  math.pow(10, widget.account!.digits))
              .toString(),
  );
  int? _limit(TextEditingController c) =>
      c.text.trim().isEmpty ? null : parseAccountAmount(c.text.trim(), _digits);
  bool get _limitsValid => [_creditLimit, _availableLimit].every(
    (c) => c.text.trim().isEmpty || (_limit(c) != null && _limit(c)! >= 0),
  );
  bool get _suffixValid =>
      _type == AccountType.cash ||
      RegExp(r'^\d{2,4}$').hasMatch(_lastDigits.text) ||
      (_editing &&
          _lastDigits.text.isEmpty &&
          widget.account?.lastDigits == null);

  late String _currency =
      widget.account?.currency ?? widget.initialCurrency ?? 'INR';
  late int _digits = widget.account?.digits ?? 2;
  // New accounts default to India, matching the default 'INR' currency;
  // editing an existing account keeps whatever territory it has (which is
  // null for accounts saved before territory tracking existed).
  String? get _initialTerritory => widget.account == null
      ? ((widget.initialCurrency ?? 'INR') == 'INR' ? 'IN' : null)
      : widget.account!.territory;
  late String? _territory = _initialTerritory;
  String? get _initialIcon => widget.account == null
      ? (widget.initialIcon ?? defaultAccountIcon)
      : widget.account!.icon;
  late String? _icon = _initialIcon;
  bool _saving = false, _leaving = false, _askingToDiscard = false;
  String? _error;
  bool _actionOpen = false;
  bool _editMode = false;
  bool get _canEdit => !_editing || _editMode;

  /// Read from [AccountStore.allAccounts] rather than the active list: an
  /// archived account is opened on this screen too, to be restored or deleted.
  Account? get _account =>
      widget.store.byId(widget.account?.id) ?? widget.account;

  bool get _editing => widget.account != null;
  bool get _dirty =>
      _name.text.trim() != (widget.account?.name ?? widget.initialName ?? '') ||
      _currency !=
          (widget.account?.currency ?? widget.initialCurrency ?? 'INR') ||
      _territory != _initialTerritory ||
      _icon != _initialIcon ||
      _type != (widget.account?.type ?? AccountType.bank) ||
      _lastDigits.text != (widget.account?.lastDigits ?? '') ||
      (_type == AccountType.creditCard &&
          (_creditLimit.text !=
                  (widget.account?.creditLimitMinor == null
                      ? ''
                      : (widget.account!.creditLimitMinor! /
                                math.pow(10, widget.account!.digits))
                            .toString()) ||
              _availableLimit.text !=
                  (widget.account?.availableCreditLimitMinor == null
                      ? ''
                      : (widget.account!.availableCreditLimitMinor! /
                                math.pow(10, widget.account!.digits))
                            .toString()))) ||
      (!_editing && _balance.text.isNotEmpty);
  int? get _amount => parseAccountAmount(_balance.text, _digits);
  bool get _precisionValid =>
      !_editing ||
      relabelAmount(_account!.balanceMinor, _account!.digits, _digits) != null;
  bool get _valid =>
      _name.text.trim().isNotEmpty &&
      _name.text.trim().length <= 40 &&
      (_editing || _amount != null) &&
      _precisionValid &&
      _suffixValid &&
      (_type != AccountType.creditCard || _limitsValid);

  @override
  void initState() {
    super.initState();
    // Parse the currency list now, while this form is idle, so opening the
    // currency picker doesn't do it mid-transition.
    Currency.load();
    widget.store.addListener(_refreshAccount);
  }

  void _refreshAccount() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.store.removeListener(_refreshAccount);
    _name.dispose();
    _balance.dispose();
    _lastDigits.dispose();
    _creditLimit.dispose();
    _availableLimit.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    setState(() => _leaving = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  /// "Cash · ₹1,050", naming what an alert is about so its title does not
  /// have to carry the name as well.
  String _subtitleFor(Account account) => account.balanceMinor == 0
      ? account.name
      : '${account.name} · ${_money(account)}';

  String _money(Account account) => formatAccountMoney(
    account.balanceMinor,
    digits: account.digits,
    currency: account.currency,
  );

  /// The delete gauntlet: what goes, then — for an account carrying
  /// [_bulkDeleteThreshold] entries or more — a step that says the number out
  /// loud and points at archiving, then the final can't-be-undone. Deleting
  /// stays possible at any size, since an account you can never be rid of is
  /// its own problem; the history at stake is just never glossed over.
  ///
  /// Composed here rather than through [showDeleteConfirmation] so the bulk
  /// warning falls between the specifics and the last word, which is the
  /// order it has to be read in.
  Future<bool> _confirmDelete(Account account) async {
    final count = account.transactionCount;
    final bulk = count >= _bulkDeleteThreshold;
    final last = widget.store.accounts.length == 1;
    var archiveSelected = false;
    if (!await showConfirmationAlert(
      context,
      title: 'Delete this account?',
      cancelLabel: account.isArchived ? 'Cancel' : 'Archive',
      onCancel: account.isArchived ? null : () => archiveSelected = true,
      content: ConfirmationFacts(
        subtitle: _subtitleFor(account),
        facts: [
          if (count > 0)
            ConfirmationFact(
              Icons.delete_outline_rounded,
              '$count ${count == 1 ? 'transaction' : 'transactions'} deleted',
              grave: true,
            ),
          if (count > 0)
            const ConfirmationFact(
              Icons.swap_horiz_rounded,
              'Transfers involving it go too',
            ),
          if (account.balanceMinor != 0)
            ConfirmationFact(
              Icons.account_balance_wallet_outlined,
              '${_money(account)} leaves your totals',
            ),
          const ConfirmationFact(
            Icons.account_balance_outlined,
            'Other balances stay the same',
          ),
          if (last)
            const ConfirmationFact(
              Icons.warning_amber_rounded,
              'No account left to record into',
              grave: true,
            ),
          if (bulk)
            const ConfirmationFact(
              Icons.archive_outlined,
              'Archiving keeps all of it',
            ),
        ],
      ),
    )) {
      if (archiveSelected && mounted) {
        setState(() {
          _saving = true;
          _error = null;
        });
        await widget.transactionStore!.archiveAccount(account.id);
        if (mounted) {
          showAppToast(context, 'Account archived');
          await _leave();
        }
      }
      return false;
    }
    if (bulk) {
      if (!mounted) return false;
      if (!await showConfirmationAlert(
        context,
        title: 'Delete $count transactions?',
        content: ConfirmationFacts(
          facts: [
            ConfirmationFact(
              Icons.delete_forever_outlined,
              '$count entries erased for good',
              grave: true,
            ),
            const ConfirmationFact(
              Icons.insights_outlined,
              'Past months and budgets change',
            ),
            const ConfirmationFact(
              Icons.archive_outlined,
              'Archive keeps every one',
            ),
          ],
        ),
        confirmLabel: 'Delete it all',
      )) {
        return false;
      }
    }
    if (!mounted) return false;
    return showConfirmationAlert(
      context,
      title: 'Are you sure?',
      message: 'This can’t be undone.',
      confirmLabel: 'Yes, delete',
      confirmFirst: true,
    );
  }

  Future<void> _discard() async {
    if (_saving || _askingToDiscard) return;
    _askingToDiscard = true;
    final discard = await showConfirmationAlert(
      context,
      title: 'Discard changes?',
      message: 'Your unsaved account details will be lost.',
      cancelLabel: 'Keep editing',
      confirmLabel: 'Discard',
    );
    _askingToDiscard = false;
    if (discard && mounted) await _leave();
  }

  Future<void> _save() async {
    if (!_valid || _saving) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.save(
        existing: _account,
        name: _name.text.trim(),
        currency: _currency,
        territory: _territory,
        icon: _icon,
        digits: _digits,
        openingBalance:
            _type == AccountType.creditCard &&
                _limit(_creditLimit) != null &&
                _limit(_availableLimit) != null
            ? _limit(_availableLimit)! - _limit(_creditLimit)!
            : _amount ?? 0,
        type: _type,
        institution: widget.account?.institution ?? widget.initialInstitution,
        updateCreditLimits: true,
        lastDigits: _type == AccountType.cash || _lastDigits.text.isEmpty
            ? null
            : _lastDigits.text,
        creditLimitMinor: _type == AccountType.creditCard
            ? _limit(_creditLimit)
            : null,
        availableCreditLimitMinor: _type == AccountType.creditCard
            ? _limit(_availableLimit)
            : null,
      );
      if (!mounted) return;
      showAppToast(context, _editing ? 'Account updated' : 'Account added');
      await _leave();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Couldn’t save. Your changes are still here. Try again.';
        });
      }
    }
  }

  Future<void> _onAction(_AccountAction action) async {
    final transactions = widget.transactionStore;
    final account = _account;
    if (_saving ||
        _actionOpen ||
        widget.store.saving ||
        transactions == null ||
        transactions.saving ||
        account == null) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _actionOpen = true);
    try {
      switch (action) {
        case _AccountAction.edit:
          setState(() => _editMode = true);
        case _AccountAction.adjust:
          await showAdjustBalanceSheet(
            context,
            accountStore: widget.store,
            transactionStore: transactions,
            initialAccountId: account.id,
          );
        case _AccountAction.transfer:
          await showTransferSheet(
            context,
            accountStore: widget.store,
            transactionStore: transactions,
            initialFromAccountId: account.id,
          );
        case _AccountAction.archive:
          final count = account.transactionCount;
          final confirmed = await showConfirmationAlert(
            context,
            title: 'Archive this account?',
            content: ConfirmationFacts(
              subtitle: _subtitleFor(account),
              facts: [
                const ConfirmationFact(
                  Icons.visibility_off_outlined,
                  'Hidden from accounts and totals',
                ),
                ConfirmationFact(
                  Icons.receipt_long_outlined,
                  '$count ${count == 1 ? 'transaction' : 'transactions'} kept',
                ),
                if (account.balanceMinor != 0)
                  ConfirmationFact(
                    Icons.account_balance_wallet_outlined,
                    '${_money(account)} stops counting',
                  ),
                if (widget.store.accounts.length == 1)
                  const ConfirmationFact(
                    Icons.warning_amber_rounded,
                    'No account left to record into',
                    grave: true,
                  ),
                const ConfirmationFact(
                  Icons.history_rounded,
                  'Restore from any of its entries',
                ),
              ],
            ),
            confirmLabel: 'Archive',
            destructive: false,
          );
          if (!confirmed || !mounted) return;
          setState(() {
            _saving = true;
            _error = null;
          });
          await transactions.archiveAccount(account.id);
          if (!mounted) return;
          showAppToast(context, 'Account archived');
          await _leave();
        case _AccountAction.restore:
          setState(() {
            _saving = true;
            _error = null;
          });
          await transactions.restoreAccount(account.id);
          if (!mounted) return;
          setState(() => _saving = false);
          showAppToast(context, 'Account restored');
        case _AccountAction.delete:
          if (!await _confirmDelete(account) || !mounted) return;
          setState(() {
            _saving = true;
            _error = null;
          });
          await transactions.deleteAccount(account.id);
          if (!mounted) return;
          showAppToast(context, 'Account and its history deleted');
          await _leave();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not complete this action. Please try again.';
        });
      }
    } finally {
      if (mounted) setState(() => _actionOpen = false);
    }
  }

  Widget _accountActions() {
    final busy =
        _saving ||
        _actionOpen ||
        widget.store.saving ||
        (widget.transactionStore?.saving ?? false);
    return LayoutBuilder(
      builder: (context, constraints) {
        final buttons = [
          PillButton(
            label: 'Adjust balance',
            primary: false,
            onPressed: busy ? null : () => _onAction(_AccountAction.adjust),
          ),
          PillButton(
            label: 'Transfer',
            onPressed: busy ? null : () => _onAction(_AccountAction.transfer),
          ),
        ];
        if (constraints.maxWidth < 300 ||
            MediaQuery.textScalerOf(context).scale(14) > 18) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [buttons[0], const SizedBox(height: 10), buttons[1]],
          );
        }
        return Row(
          children: [
            Expanded(child: buttons[0]),
            const SizedBox(width: 10),
            Expanded(child: buttons[1]),
          ],
        );
      },
    );
  }

  /// Says why this account is nowhere else in the app, and offers the way
  /// back. Restoring is on the menu too, but an account reached from a
  /// transaction is reached by someone who may not know it can be undone.
  Widget _archivedBanner(BuildContext context) {
    final account = _account!;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return MoneyCard(
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Archived on ${DateFormat('MMM d, yyyy').format(account.archivedAt!)}',
            style: theme.textTheme.titleSmall,
          ),
          const SizedBox(height: 6),
          Text(
            'Hidden from accounts and totals. Transactions are saved.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 16),
          OutlinedButton.icon(
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.primary,
              minimumSize: const Size(0, 48),
              shape: const StadiumBorder(),
              side: BorderSide(color: scheme.primary.withValues(alpha: .25)),
            ),
            onPressed: _saving || widget.store.saving
                ? null
                : () => _onAction(_AccountAction.restore),
            icon: const Icon(Icons.restore_rounded, size: 20),
            label: const Text('Restore account'),
          ),
        ],
      ),
    );
  }

  Widget _balanceSummary(BuildContext context) {
    final account = _account!;
    if (account.type == AccountType.creditCard) {
      return AccountCard(account: account);
    }
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final scope = MainCurrencyScope.maybeOf(context)?.accountScope;
    final showEquivalent =
        scope is CombinedCurrency && scope.code != account.currency;
    final converted = showEquivalent
        ? scope.convert(account.balanceMinor, account.currency, account.digits)
        : null;
    final equivalent = converted == null
        ? null
        : formatAccountMoney(
            converted,
            currency: scope!.code,
            digits: scope.digits,
          );
    return MoneyCard(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Current balance',
                  style: theme.textTheme.bodyMedium,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                account.currency,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: AlignmentDirectional.centerStart,
            child: Text(
              account.formattedBalance,
              maxLines: 1,
              style: theme.textTheme.headlineLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -1,
              ),
            ),
          ),
          if (showEquivalent) ...[
            const SizedBox(height: 6),
            Text(
              equivalent == null ? 'Rate unavailable' : '≈ $equivalent',
              semanticsLabel: equivalent == null
                  ? null
                  : 'Approximately $equivalent',
              style: theme.textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                Icons.receipt_long_outlined,
                size: 16,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${account.transactionCount} ${account.transactionCount == 1 ? 'transaction' : 'transactions'}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// An archived account offers Restore in place of Edit and Archive: it is
  /// out of circulation, so the only useful moves are bringing it back or
  /// finishing the job.
  ///
  /// Archive is withheld from an account with no transactions at all. It is
  /// there to save history, and with none to save it would only hide the
  /// account somewhere nothing links to — an entry of its own is what makes
  /// an archived account reachable again. Deleting an empty account costs
  /// nothing, so that is the offer.
  List<MorePopupItem<_AccountAction>> get _menuItems {
    final account = _account;
    if (account?.isArchived ?? false) {
      return const [
        MorePopupItem(
          value: _AccountAction.restore,
          label: 'Restore',
          icon: Icons.unarchive_outlined,
        ),
        MorePopupItem(
          value: _AccountAction.delete,
          label: 'Delete',
          icon: Icons.delete_outline_rounded,
          dividerBefore: true,
        ),
      ];
    }
    return [
      const MorePopupItem(
        value: _AccountAction.edit,
        label: 'Edit',
        icon: Icons.edit_outlined,
      ),
      if ((account?.transactionCount ?? 0) > 0)
        const MorePopupItem(
          value: _AccountAction.archive,
          label: 'Archive',
          icon: Icons.archive_outlined,
          dividerBefore: true,
        ),
      MorePopupItem(
        value: _AccountAction.delete,
        label: 'Delete',
        icon: Icons.delete_outline_rounded,
        dividerBefore: (account?.transactionCount ?? 0) == 0,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return PopScope(
      canPop: _leaving || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _discard();
      },
      child: FeaturePage(
        title: _editing
            ? (_editMode ? 'Edit account' : 'Account info')
            : 'Add account',
        actions: _editing && !_editMode
            ? [
                MorePopupButton<_AccountAction>(
                  tooltip: 'Account options',
                  items: _saving || _actionOpen ? const [] : _menuItems,
                  onSelected: _onAction,
                ),
              ]
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  if (_editing) ...[
                    _balanceSummary(context),
                    const SizedBox(height: 24),
                    Padding(
                      padding: const EdgeInsets.only(left: 4, bottom: 10),
                      child: Text('Account details', style: text.titleMedium),
                    ),
                  ],
                  if (_canEdit) ...[
                    MoneyCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text('Account type', style: text.titleMedium),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              for (final type in AccountType.values) ...[
                                if (type != AccountType.bank)
                                  const SizedBox(width: 8),
                                Expanded(
                                  child: _AccountTypeOption(
                                    type: type,
                                    selected: _type == type,
                                    onTap: _saving
                                        ? null
                                        : () => setState(() => _type = type),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          if (_type != AccountType.cash) ...[
                            const SizedBox(height: 16),
                            TextField(
                              key: const Key('account-last-digits'),
                              controller: _lastDigits,
                              enabled: _canEdit && !_saving,
                              keyboardType: TextInputType.number,
                              inputFormatters: [
                                FilteringTextInputFormatter.digitsOnly,
                                LengthLimitingTextInputFormatter(4),
                              ],
                              decoration: const InputDecoration(
                                labelText: 'Last 2 to 4 digits',
                                helperText: 'For matching bank messages.',
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ],
                          if (_type == AccountType.creditCard) ...[
                            const SizedBox(height: 16),
                            TextField(
                              key: const Key('account-credit-limit'),
                              controller: _creditLimit,
                              enabled: _canEdit && !_saving,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: InputDecoration(
                                labelText: 'Credit limit',
                                prefixText: '$_currency ',
                                helperText: 'Leave blank if unknown.',
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                            const SizedBox(height: 16),
                            TextField(
                              key: const Key('account-available-limit'),
                              controller: _availableLimit,
                              enabled: _canEdit && !_saving,
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: InputDecoration(
                                labelText: 'Available limit',
                                prefixText: '$_currency ',
                                helperText: 'Leave blank if unknown.',
                              ),
                              onChanged: (_) => setState(() {}),
                            ),
                          ],
                        ],
                      ),
                    ),
                    const SizedBox(height: 18),
                  ],
                  MoneyCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  customBorder: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      34 * .4,
                                    ),
                                  ),
                                  onTap: _saving || !_canEdit
                                      ? null
                                      : () async {
                                          FocusScope.of(context).unfocus();
                                          final icon =
                                              await Navigator.of(context).push(
                                                FeatureRoute<String>(
                                                  SelectIconScreen(
                                                    selectedKey: _icon,
                                                  ),
                                                ),
                                              );
                                          if (icon != null && mounted) {
                                            setState(() => _icon = icon);
                                          }
                                        },
                                  child: AppIcon(_icon, size: 34),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextField(
                                  key: const Key('account-name'),
                                  controller: _name,
                                  enabled: !_saving,
                                  readOnly: !_canEdit,
                                  enableInteractiveSelection: _canEdit,
                                  maxLength: 40,
                                  textCapitalization: TextCapitalization.words,
                                  textInputAction: _editing
                                      ? TextInputAction.done
                                      : TextInputAction.next,
                                  onChanged: (_) =>
                                      setState(() => _error = null),
                                  decoration: const InputDecoration(
                                    labelText: 'Account name',
                                    hintText: 'e.g. Cash or HDFC Bank',
                                    filled: false,
                                    contentPadding: EdgeInsets.zero,
                                    counterText: '',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 18),
                          child: Divider(height: 24),
                        ),
                        Material(
                          color: Colors.transparent,
                          child: InkWell(
                            borderRadius: const BorderRadius.vertical(
                              bottom: Radius.circular(24),
                            ),
                            onTap: _saving || !_canEdit
                                ? null
                                : () async {
                                    FocusScope.of(context).unfocus();
                                    final currency = await Navigator.of(context)
                                        .push(
                                          FeatureRoute<Currency>(
                                            CurrencyScreen(
                                              selectedCode: _currency,
                                              selectedTerritory: _territory,
                                            ),
                                          ),
                                        );
                                    if (currency != null && mounted) {
                                      setState(() {
                                        _currency = currency.code;
                                        _digits = currency.digits;
                                        _territory = currency.territory;
                                        _error = null;
                                      });
                                    }
                                  },
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
                              child: Row(
                                children: [
                                  _territory == null
                                      ? const IconTile(
                                          Icons.language_rounded,
                                          size: 34,
                                        )
                                      : CurrencyFlag(
                                          _territory!,
                                          width: 34,
                                          height: 34,
                                          borderRadius: 34 * .4,
                                        ),
                                  const SizedBox(width: 12),
                                  const Expanded(child: Text('Currency')),
                                  Text(
                                    _currency,
                                    style: text.titleMedium?.copyWith(
                                      fontSize: 14,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  if (_canEdit)
                                    Icon(
                                      Icons.chevron_right_rounded,
                                      size: 20,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  if (_account?.isArchived ?? false) _archivedBanner(context),
                  // Not for an archived account: adjusting or transferring
                  // would move money into one that is out of circulation, and
                  // the transfer sheet does not list it as a side anyway.
                  if (!_canEdit && !(_account?.isArchived ?? false))
                    _accountActions(),
                  if (!_editing && _type != AccountType.creditCard)
                    MoneyCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Opening balance',
                            style: text.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextField(
                            key: const Key('opening-balance'),
                            controller: _balance,
                            enabled: !_saving,
                            keyboardType: const TextInputType.numberWithOptions(
                              decimal: true,
                              signed: true,
                            ),
                            textInputAction: TextInputAction.done,
                            style: text.headlineLarge?.copyWith(fontSize: 30),
                            onChanged: (_) => setState(() => _error = null),
                            decoration: InputDecoration(
                              hintText: '0',
                              prefixIconConstraints: const BoxConstraints(
                                minWidth: 0,
                                minHeight: 0,
                              ),
                              prefixIcon: Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Text(
                                  _currency,
                                  style: text.titleMedium?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                              filled: false,
                              contentPadding: EdgeInsets.zero,
                              errorText: _amount == null
                                  ? (_digits == 0
                                        ? 'Enter a whole number for $_currency.'
                                        : 'Use a number with up to $_digits decimal places.')
                                  : null,
                              errorMaxLines: 3,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'What’s in this account right now. Zero is fine, too.',
                            style: text.bodySmall?.copyWith(height: 1.5),
                          ),
                        ],
                      ),
                    ),
                  if (_editing && _currency != widget.account!.currency)
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary
                              .withValues(alpha: .07),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 19,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _precisionValid
                                    ? 'Only the label changes. Amounts aren’t converted.'
                                    : 'This balance has more decimals than $_currency allows. Pick another currency.',
                                style: text.bodySmall?.copyWith(
                                  height: 1.6,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                  if (!_editing)
                    Padding(
                      padding: const EdgeInsets.only(top: 24),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.lock_outline_rounded,
                            size: 13,
                            color: scheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(
                              'Saved on your device',
                              style: text.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (_canEdit)
              ActionButtonBar(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
                secondaryLabel: 'Cancel',
                onSecondary: _saving ? null : () => Navigator.maybePop(context),
                primaryLabel: _saving
                    ? 'Saving…'
                    : _editing
                    ? 'Save changes'
                    : 'Add account',
                onPrimary: _valid && _dirty && !_saving ? _save : null,
              ),
          ],
        ),
      ),
    );
  }
}

class _AccountTypeOption extends StatelessWidget {
  const _AccountTypeOption({
    required this.type,
    required this.selected,
    required this.onTap,
  });
  final AccountType type;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final foreground = selected ? colors.primary : colors.onSurfaceVariant;
    return Semantics(
      selected: selected,
      child: Material(
        color: selected
            ? colors.primary.withValues(alpha: .09)
            : colors.onSurface.withValues(alpha: .035),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('account-type-${type.name}'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 16),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected
                    ? colors.primary.withValues(alpha: .45)
                    : Colors.transparent,
              ),
            ),
            child: Column(
              children: [
                Icon(
                  switch (type) {
                    AccountType.bank => Icons.account_balance_outlined,
                    AccountType.creditCard => Icons.credit_card_rounded,
                    AccountType.cash => Icons.payments_outlined,
                  },
                  color: foreground,
                  size: 24,
                ),
                const SizedBox(height: 8),
                Text(
                  type == AccountType.bank ? 'Bank' : type.label,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: foreground,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
