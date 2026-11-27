import 'package:flutter/material.dart';

import '../components/adaptive_sheet.dart';

import '../../domain/account.dart';
import '../../state/account_store.dart';
import '../../state/transaction_store.dart';
import '../components/action_buttons.dart';
import '../components/app_icon.dart';
import '../components/app_toast.dart';
import '../components/choice_list_sheet.dart';
import '../components/common.dart';
import '../components/number_keypad.dart';
import '../components/segmented_pill.dart';
import '../theme/sheet_colors.dart';
import 'quick_add_helpers.dart';
import 'step_sheet.dart';

/// Sets, adds to, or subtracts from an account's balance directly — a
/// correction, not a categorized transaction (see [BalanceAdjustmentMode]).
Future<void> showAdjustBalanceSheet(
  BuildContext context, {
  required AccountStore accountStore,
  required TransactionStore transactionStore,
  int? initialAccountId,
}) => showAdaptiveSheet<void>(
  context,
  builder: (context) => AdjustBalanceSheet(
    accountStore: accountStore,
    transactionStore: transactionStore,
    initialAccountId: initialAccountId,
  ),
);

/// One screen, top to bottom: which account, how to change it, the amount,
/// and a live "current → new" preview — so there's no separate confirm step.
class AdjustBalanceSheet extends StatefulWidget {
  const AdjustBalanceSheet({
    super.key,
    required this.accountStore,
    required this.transactionStore,
    this.initialAccountId,
  });
  final AccountStore accountStore;
  final TransactionStore transactionStore;
  final int? initialAccountId;
  @override
  State<AdjustBalanceSheet> createState() => _AdjustBalanceSheetState();
}

class _AdjustBalanceSheetState extends State<AdjustBalanceSheet> {
  BalanceAdjustmentMode _mode = BalanceAdjustmentMode.setTo;
  late int? _accountId = widget.initialAccountId;
  String _amountText = '';
  bool _saving = false;
  String? _error;

  Account? get _account {
    for (final a in widget.accountStore.accounts) {
      if (a.id == _accountId) return a;
    }
    return null;
  }

  int get _digits => _account?.digits ?? 2;

  /// Null until something is typed, so an empty "Set to" can't zero the
  /// balance by accident.
  int? get _amountMinor =>
      _amountText.isEmpty ? null : parseAccountAmount(_amountText, _digits);

  int? get _newBalance {
    final account = _account;
    final amount = _amountMinor;
    if (account == null || amount == null) return null;
    return switch (_mode) {
      BalanceAdjustmentMode.setTo => amount,
      BalanceAdjustmentMode.add => account.balanceMinor + amount,
      BalanceAdjustmentMode.subtract => account.balanceMinor - amount,
    };
  }

  /// Save only once the balance would actually change.
  bool get _canSave {
    final next = _newBalance;
    return !_saving && next != null && next != _account!.balanceMinor;
  }

  void _onDigit(String d) {
    final dot = _amountText.indexOf('.');
    final full = dot >= 0
        ? _amountText.length - dot > _digits
        : _amountText.length >= 10;
    if (full) return;
    setState(() => _amountText = _amountText == '0' ? d : _amountText + d);
  }

  void _onDecimalPoint() {
    if (_digits == 0 || _amountText.contains('.')) return;
    setState(() => _amountText = _amountText.isEmpty ? '0.' : '$_amountText.');
  }

  void _onBackspace() => setState(() {
    if (_amountText.isNotEmpty) {
      _amountText = _amountText.substring(0, _amountText.length - 1);
    }
  });

  Future<void> _pickAccount() async {
    final items = widget.accountStore.accounts
        .map(
          (a) => ChoiceItem<int>(
            value: a.id,
            icon: AppIcon(a.icon, size: 28),
            label: a.name,
            subtitle: a.maskedDigits,
          ),
        )
        .toList();
    final picked = await showChoiceListSheet<int>(
      context,
      title: 'Choose account',
      items: items,
      selected: _accountId,
      addLabel: 'Add account',
      onAdd: (context) async {
        final created = await addAccountAndSelect(context, widget.accountStore);
        return created?.id;
      },
    );
    if (picked != null && mounted) {
      setState(() {
        _accountId = picked;
        _error = null;
      });
    }
  }

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.transactionStore.adjustBalance(
        accountId: _accountId!,
        mode: _mode,
        amountMinor: _amountMinor!,
      );
      if (!mounted) return;
      showAppToast(context, 'Balance updated');
      Navigator.pop(context);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not update this balance. Please try again.';
        });
      }
    }
  }

  void _cancel() => Navigator.pop(context);

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final account = _account;
    final newBalance = _newBalance;
    final tone = switch (_mode) {
      BalanceAdjustmentMode.setTo => colors.primary,
      BalanceAdjustmentMode.add => colors.income,
      BalanceAdjustmentMode.subtract => colors.expense,
    };

    return StepSheetScaffold(
      currentIndex: 0,
      onBack: _cancel,
      title: 'Adjust balance',
      showClose: false,
      footerPadding: EdgeInsets.zero,
      footer: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: _saving ? null : _cancel,
        primaryLabel: _saving ? 'Saving…' : 'Save',
        onPrimary: _canSave ? _save : null,
      ),
      pages: [
        SingleChildScrollView(
          // Bottom room so the keys' shadows aren't cut off by the scroll view.
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AccountField(
                account: account,
                onTap: _saving ? null : _pickAccount,
              ),
              const SizedBox(height: 14),
              _ModeSelector(
                mode: _mode,
                onChanged: (mode) => setState(() {
                  _mode = mode;
                  _error = null;
                }),
              ),
              const SizedBox(height: 22),
              _AmountDisplay(
                mode: _mode,
                amountText: _amountText,
                currency: account?.currency,
                color: tone,
              ),
              const SizedBox(height: 16),
              _BalancePreview(
                account: account,
                newBalance: newBalance,
                color: newBalance != null && newBalance < 0
                    ? colors.expense
                    : tone,
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: colors.expense),
                  ),
                ),
              const SizedBox(height: 16),
              NumberKeypad(
                onDigit: _onDigit,
                onDecimalPoint: _onDecimalPoint,
                onBackspace: _onBackspace,
                onClear: () => setState(() => _amountText = ''),
                decimalEnabled: _digits > 0 && !_amountText.contains('.'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The account being adjusted, tappable to switch to another one.
class _AccountField extends StatelessWidget {
  const _AccountField({required this.account, required this.onTap});
  final Account? account;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return Material(
      color: colors.card,
      borderRadius: BorderRadius.circular(18),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              account == null
                  ? const IconTile(
                      Icons.account_balance_wallet_outlined,
                      size: 36,
                    )
                  : AppIcon(account!.icon, size: 36),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Account',
                      style: TextStyle(fontSize: 12, color: colors.muted),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      account == null
                          ? 'Choose an account'
                          : [account!.name, ?account!.maskedDigits].join('  '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: account == null ? colors.primary : colors.text,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.expand_more_rounded, color: colors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Set to / Add / Subtract. The selected segment takes on that mode's color.
class _ModeSelector extends StatelessWidget {
  const _ModeSelector({required this.mode, required this.onChanged});
  final BalanceAdjustmentMode mode;
  final ValueChanged<BalanceAdjustmentMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return SegmentedPill<BalanceAdjustmentMode>(
      segments: [
        PillSegment(
          BalanceAdjustmentMode.setTo,
          'Set to',
          icon: Icons.edit_rounded,
          tone: colors.primary,
        ),
        PillSegment(
          BalanceAdjustmentMode.add,
          'Add',
          icon: Icons.add_rounded,
          tone: colors.income,
        ),
        PillSegment(
          BalanceAdjustmentMode.subtract,
          'Subtract',
          icon: Icons.remove_rounded,
          tone: colors.expense,
        ),
      ],
      value: mode,
      onChanged: onChanged,
    );
  }
}

/// The amount typed so far, large and centered, signed by the mode
/// (+ for add, − for subtract) so its effect reads at a glance.
class _AmountDisplay extends StatelessWidget {
  const _AmountDisplay({
    required this.mode,
    required this.amountText,
    required this.currency,
    required this.color,
  });
  final BalanceAdjustmentMode mode;
  final String amountText;
  final String? currency;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final empty = amountText.isEmpty;
    final sign = switch (mode) {
      BalanceAdjustmentMode.setTo => '',
      BalanceAdjustmentMode.add => '+',
      BalanceAdjustmentMode.subtract => '−',
    };
    final prefix = currency == null ? '' : currencyPrefix(currency);
    return Column(
      children: [
        Text(switch (mode) {
          BalanceAdjustmentMode.setTo => 'New balance amount',
          BalanceAdjustmentMode.add => 'Amount to add',
          BalanceAdjustmentMode.subtract => 'Amount to subtract',
        }, style: TextStyle(fontSize: 13, color: colors.muted)),
        const SizedBox(height: 4),
        SizedBox(
          height: 56,
          child: FittedBox(
            child: Text(
              '$sign$prefix${empty ? '0' : amountText}',
              style: TextStyle(
                fontSize: 44,
                fontWeight: FontWeight.w700,
                color: empty ? colors.muted.withValues(alpha: .5) : color,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// "Current balance → New balance", updating as the amount is typed.
class _BalancePreview extends StatelessWidget {
  const _BalancePreview({
    required this.account,
    required this.newBalance,
    required this.color,
  });
  final Account? account;
  final int? newBalance;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    String money(int? minor) => account == null || minor == null
        ? '—'
        : formatAccountMoney(
            minor,
            digits: account!.digits,
            currency: account!.currency,
          );

    Widget column(
      String label,
      String value,
      CrossAxisAlignment align, {
      Color? valueColor,
    }) => Expanded(
      child: Column(
        crossAxisAlignment: align,
        children: [
          Text(label, style: TextStyle(fontSize: 12, color: colors.muted)),
          const SizedBox(height: 3),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              value,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: valueColor ?? colors.text,
              ),
            ),
          ),
        ],
      ),
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          column(
            'Current balance',
            money(account?.balanceMinor),
            CrossAxisAlignment.start,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              Icons.arrow_forward_rounded,
              size: 18,
              color: colors.muted,
            ),
          ),
          column(
            'New balance',
            money(newBalance),
            CrossAxisAlignment.end,
            valueColor: newBalance == null ? colors.muted : color,
          ),
        ],
      ),
    );
  }
}
