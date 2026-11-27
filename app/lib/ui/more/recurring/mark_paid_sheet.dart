import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/recurring_payment.dart';
import '../../../state/recurring_payment_store.dart';
import '../../components/action_buttons.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/advance_payment_notice.dart';
import '../../components/app_icon.dart';
import '../../components/app_toast.dart';
import '../../components/choice_list_sheet.dart';
import '../../components/date_picker_sheet.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/quick_add_helpers.dart';
import '../../transactions/transaction_widgets.dart';
import '../debts/debt_widgets.dart';
import 'renewal_outcome.dart';

/// Logs one renewal of [recurringPayment] as paid: which account it came out of
/// and on what day, with what that does spelled out before it's confirmed.
Future<void> showMarkPaidSheet(
  BuildContext context, {
  required RecurringPaymentStore store,
  required RecurringPayment recurringPayment,
}) => showAdaptiveSheet<void>(
  context,
  builder: (_) =>
      MarkPaidSheet(store: store, recurringPayment: recurringPayment),
);

class MarkPaidSheet extends StatefulWidget {
  const MarkPaidSheet({
    super.key,
    required this.store,
    required this.recurringPayment,
  });
  final RecurringPaymentStore store;
  final RecurringPayment recurringPayment;

  @override
  State<MarkPaidSheet> createState() => _MarkPaidSheetState();
}

class _MarkPaidSheetState extends State<MarkPaidSheet> {
  RecurringPayment get _s => widget.recurringPayment;
  List<Account> get _accounts => widget.store.accountStore.accounts;

  /// Its own account, or the first one it could be paid from.
  late int? _accountId =
      _accounts.where((a) => a.id == _s.accountId).firstOrNull?.id ??
      _accounts.where(_fits).firstOrNull?.id;

  /// Paid just now, until another day is picked.
  var _date = DateTime.now();
  var _saving = false;
  bool _advanceAccepted = false;
  bool get _futurePayment => isFuturePayment(_s.nextDue);
  String? _error;

  bool _fits(Account a) => a.currency == _s.currency && a.digits == _s.digits;

  Account? get _account =>
      _accounts.where((a) => a.id == _accountId).firstOrNull;

  bool get _canSave =>
      !_saving &&
      _account != null &&
      _fits(_account!) &&
      (!_futurePayment || _advanceAccepted);

  String _money(int minor) =>
      formatAccountMoney(minor, digits: _s.digits, currency: _s.currency);

  String get _dateLabel {
    final day = dateOnly(_date);
    final today = dateOnly(DateTime.now());
    final date = formatTransactionDate(day);
    if (day == today) return 'Today · $date';
    if (day == DateTime(today.year, today.month, today.day - 1)) {
      return 'Yesterday · $date';
    }
    return date;
  }

  Future<void> _pickAccount() async {
    final picked = await showChoiceListSheet<int>(
      context,
      title: _s.incoming ? 'Paid into' : 'Paid from',
      items: [
        for (final account in _accounts)
          ChoiceItem(
            value: account.id,
            icon: AppIcon(account.icon, size: 28),
            subtitle: account.maskedDigits,
            label: _fits(account)
                ? account.name
                : '${account.name} · ${account.currency}',
            enabled: _fits(account),
          ),
      ],
      selected: _accountId,
      addLabel: 'Add account',
      onAdd: (context) async =>
          (await addAccountAndSelect(context, widget.store.accountStore))?.id,
    );
    if (picked != null && mounted) {
      setState(() {
        _accountId = picked;
        _error = null;
      });
    }
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

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final store = widget.store;
    try {
      await store.save(
        () => store.repository.markPaid(_s, date: _date, accountId: _accountId),
      );
      if (!mounted) return;
      showAppToast(context, 'Payment logged');
      Navigator.pop(context);
    } catch (error) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = error is ArgumentError
              ? error.message.toString()
              : error is StateError
              ? error.message
              : 'Could not log this payment. Please try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final account = _account;
    final mismatch = account != null && !_fits(account);
    VoidCallback? edit(VoidCallback onEdit) => _saving ? null : onEdit;
    return PopScope(
      canPop: !_saving,
      child: SheetPage(
        header: SheetHeader(_s.incoming ? 'Mark as received' : 'Mark as paid'),
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Summary(recurringPayment: _s, amount: _money(_s.amountMinor)),
            if (_futurePayment) ...[
              const SizedBox(height: 18),
              AdvancePaymentNotice(
                due: _s.nextDue,
                following: _s.followingDue,
                payment: 'This payment',
                accepted: _advanceAccepted,
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _advanceAccepted = value),
              ),
            ],
            const SizedBox(height: 18),
            _SectionLabel('Payment details'),
            TransactionDetailsCard(
              rows: [
                TransactionDetailRow(
                  leading: EntityIconTile(
                    chosen: account != null,
                    iconKey: account?.icon,
                    fallback: Icons.account_balance_wallet_outlined,
                  ),
                  label: _s.incoming ? 'Paid into' : 'Paid from',
                  value: account?.name ?? 'Choose an account',
                  placeholder: account == null,
                  onTap: edit(_pickAccount),
                ),
                TransactionDetailRow(
                  leading: const SheetIconTile(icon: Icons.event_rounded),
                  label: _s.incoming ? 'Received on' : 'Paid on',
                  value: _dateLabel,
                  onTap: edit(_pickDate),
                ),
              ],
            ),
            const SizedBox(height: 18),
            _SectionLabel('What happens'),
            SheetCard(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 6,
                ),
                child: Column(
                  children: [
                    RenewalOutcome(
                      icon: Icons.receipt_long_rounded,
                      color: _s.incoming ? colors.income : colors.expense,
                      label: _s.incoming
                          ? 'Income recorded'
                          : 'Expense recorded',
                      value: _money(_s.amountMinor),
                      caption: account == null || mismatch
                          ? 'Choose a payment account'
                          : '${_s.incoming ? 'Into' : 'From'} ${account.name}',
                    ),
                    RenewalOutcome(
                      icon: Icons.event_repeat_rounded,
                      color: colors.primary,
                      label: 'Next due',
                      value: DateFormat('d MMM yyyy').format(_s.followingDue),
                    ),
                  ],
                ),
              ),
            ),
            if (mismatch || _error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error ??
                    '${account!.name} is in ${account.currency}. Choose an '
                        'account in ${_s.currency}.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: colors.expense),
              ),
            ] else if (account == null) ...[
              const SizedBox(height: 12),
              Text(
                _s.incoming
                    ? 'Choose the account it was paid into.'
                    : 'Choose the account it was paid from.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 13, color: colors.muted),
              ),
            ],
          ],
        ),
        actions: ActionButtonBar(
          secondaryLabel: 'Cancel',
          onSecondary: _saving ? null : () => Navigator.pop(context),
          primaryLabel: _saving
              ? 'Saving…'
              : _futurePayment
              ? (_s.incoming
                    ? 'Record advance receipt'
                    : 'Record advance payment')
              : (_s.incoming ? 'Mark received' : 'Mark paid'),
          onPrimary: _canSave ? _save : null,
          primaryColor: colors.primary,
        ),
      ),
    );
  }
}

/// The recurring payment and the amount being paid, front and centre.
class _Summary extends StatelessWidget {
  const _Summary({required this.recurringPayment, required this.amount});
  final RecurringPayment recurringPayment;
  final String amount;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final s = recurringPayment;
    return SheetCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 20),
        child: Column(
          children: [
            AppIcon(s.icon, size: 56),
            const SizedBox(height: 10),
            Text(
              s.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                amount,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 32,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.8,
                  color: colors.text,
                ),
              ),
            ),
            Text(
              'Charged every ${s.cycle.per}',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, color: colors.muted),
            ),
            const SizedBox(height: 10),
            DueChip(s.nextDue),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.label);
  final String label;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: SheetColors.of(context).muted,
      ),
    ),
  );
}
