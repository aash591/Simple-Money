import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../domain/account.dart';
import '../../../domain/loan.dart';
import '../../../state/loan_store.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/advance_payment_notice.dart';
import '../../components/app_icon.dart';
import '../../components/app_toast.dart';
import '../../components/choice_list_sheet.dart';
import '../../components/date_picker_sheet.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/amount_typing.dart';
import '../../transactions/transaction_widgets.dart';
import 'loan_widgets.dart';

Future<void> showLoanAction(
  BuildContext context,
  LoanStore store,
  Loan loan,
  LoanEventKind kind,
) async {
  await showAdaptiveSheet<void>(
    context,
    dismissible: false,
    entrance: SheetEntrance.fadeRise,
    builder: (_) => LoanActionSheet(store: store, loan: loan, kind: kind),
  );
}

String loanActionLabel(LoanEventKind kind) => switch (kind) {
  LoanEventKind.emi => 'Mark paid',
  LoanEventKind.partPayment => 'Part-payment',
  LoanEventKind.rateChange => 'Rate changed',
  LoanEventKind.closure => 'Close loan early',
};

class LoanActionSheet extends StatefulWidget {
  const LoanActionSheet({
    super.key,
    required this.store,
    required this.loan,
    required this.kind,
    this.initialAmountText,
    this.onBack,
    this.onClose,
  });
  final LoanStore store;
  final Loan loan;
  final LoanEventKind kind;

  /// An amount already typed elsewhere, as one page of a longer flow, in
  /// place of the usual suggestion.
  final String? initialAmountText;

  /// Shows a back arrow that calls this, for a sheet that is one page of a
  /// longer flow. Cancel and the close button then use [onClose].
  final VoidCallback? onBack;

  /// Called instead of popping this sheet's own route when it is cancelled
  /// or saved.
  final VoidCallback? onClose;
  @override
  State<LoanActionSheet> createState() => _LoanActionSheetState();
}

class _LoanActionSheetState extends State<LoanActionSheet> {
  final _amount = TextEditingController(),
      _fee = TextEditingController(),
      _interest = TextEditingController(),
      _interestAfter = TextEditingController(),
      _rate = TextEditingController();
  late int? _accountId = widget.loan.accountId;
  DateTime _date = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    DateTime.now().day,
  );
  bool _reduceEmi = false, _saving = false;
  bool _advanceAccepted = false;
  bool get _futurePayment =>
      kind == LoanEventKind.emi &&
      loan.terms.mode.amortises &&
      isFuturePayment(loan.nextDue);
  bool get _manualAllocation => loan.schedule.isEmpty;

  /// Fees and a changed interest are rare, so they stay tucked away until
  /// asked for.
  bool _extras = false;
  String? _error;
  Loan get loan => widget.loan;
  LoanEventKind get kind => widget.kind;
  bool get _rateChange => kind == LoanEventKind.rateChange;
  String _money(int amount) => loanMoney(loan.terms, amount);

  /// The currency before an amount typed in a field.
  String get _prefix => currencyPrefix(loan.terms.currency).trim();

  /// [amount] without its currency, for after a field's [_prefix].
  String _digitsOf(int amount) => formatAccountAmount(
    amount,
    digits: loan.terms.digits,
    currency: loan.terms.currency,
  );
  @override
  void initState() {
    super.initState();
    _amount.text = switch (kind) {
      LoanEventKind.emi => AmountTyping.fromMinor(
        loan.schedule.firstOrNull?.amount ??
            (loan.terms.mode.amortises ? loan.emi : 0),
        loan.terms.digits,
      ),
      LoanEventKind.closure => AmountTyping.fromMinor(
        loan.outstanding,
        loan.terms.digits,
      ),
      _ => '',
    };
    _rate.text = '${loan.rate}';
    if (_manualAllocation &&
        !loan.terms.mode.amortises &&
        kind == LoanEventKind.emi) {
      _amount.clear();
    }
    if (widget.initialAmountText case final text?) _amount.text = text;
  }

  void _close() =>
      widget.onClose == null ? Navigator.pop(context) : widget.onClose!();

  @override
  void dispose() {
    _amount.dispose();
    _fee.dispose();
    _interest.dispose();
    _interestAfter.dispose();
    _rate.dispose();
    super.dispose();
  }

  int? get _value => parseAccountAmount(_amount.text, loan.terms.digits);
  int get _feeValue => parseAccountAmount(_fee.text, loan.terms.digits) ?? 0;

  /// The interest the lender actually charged, when it differs from the
  /// schedule's estimate — a payment made late is charged for longer.
  int? get _interestCharged => _interest.text.trim().isEmpty
      ? null
      : parseAccountAmount(_interest.text, loan.terms.digits);

  int get _interestShown =>
      _interestCharged ??
      (loan.terms.tracked
          ? math.min(_value ?? 0, loan.unpaidInterestAt(_date) ?? 0)
          : loan.schedule.firstOrNull?.interest ?? 0);
  ({List<LoanInstallment> schedule, int emi}) _preview(bool reduceEmi) {
    final amount = _value ?? 0;
    final balance = kind == LoanEventKind.partPayment
        ? loan.outstanding - amount
        : loan.outstanding;
    if (balance <= 0 || balance > loan.outstanding) {
      throw ArgumentError(
        'Enter a part-payment below the outstanding principal.',
      );
    }
    final rate = _rateChange
        ? double.tryParse(_rate.text) ?? double.nan
        : loan.rate;
    final emi = reduceEmi && loan.terms.mode.amortises
        ? loanEmi(balance, rate, loan.schedule.length)
        : loan.emi;
    return (
      schedule: loanSchedule(
        principal: balance,
        rate: rate,
        emi: emi,
        first: loan.nextDue,
        day: loan.terms.day,
        paid: loan.paid,
        mode: loan.terms.mode,
        months: loan.remainingMonths,
        basis: loan.terms.interestBasis,
        originalPrincipal: loan.terms.principal,
      ),
      emi: emi,
    );
  }

  Future<void> _save() async {
    if (_saving || (_futurePayment && !_advanceAccepted)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final fee = parseAccountAmount(_fee.text, loan.terms.digits);
      if (fee == null) throw ArgumentError('Enter a valid fee.');
      if (kind == LoanEventKind.emi &&
          _interest.text.trim().isNotEmpty &&
          _interestCharged == null) {
        throw ArgumentError('Enter a valid interest amount.');
      }
      if (!_rateChange && (_value == null || _value! <= 0)) {
        throw ArgumentError('Enter a valid payment amount.');
      }
      if (kind == LoanEventKind.emi &&
          _manualAllocation &&
          _interest.text.trim().isEmpty) {
        throw ArgumentError(
          'Enter the interest portion, or 0 for a principal-only payment.',
        );
      }
      final after = _interestAfter.text.trim().isEmpty
          ? null
          : parseAccountAmount(_interestAfter.text, loan.terms.digits);
      if (_interestAfter.text.trim().isNotEmpty && after == null) {
        throw ArgumentError('Enter valid unpaid interest after payment.');
      }
      await widget.store.save(
        () => widget.store.repository.record(
          loan,
          kind: kind,
          date: _date,
          accountId: _accountId,
          amount: _value,
          fee: fee,
          interestCharged: kind == LoanEventKind.emi ? _interestCharged : null,
          unpaidInterestAfter: after,
          newRate: double.tryParse(_rate.text),
          reduceEmi: _reduceEmi,
        ),
      );
      if (!mounted) return;
      showAppToast(context, switch (kind) {
        LoanEventKind.emi => 'Payment recorded',
        LoanEventKind.partPayment => 'Part payment recorded',
        LoanEventKind.rateChange => 'Interest rate updated',
        LoanEventKind.closure => 'Loan closed',
      });
      _close();
    } catch (e) {
      if (mounted) setState(() => _error = loanError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  List<Account> get _accounts => widget.store.accountStore.accounts
      .where(
        (a) =>
            a.currency == loan.terms.currency && a.digits == loan.terms.digits,
      )
      .toList();

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
      selected: _accountId ?? -1,
    );
    if (picked != null && mounted) setState(() => _accountId = picked);
  }

  Future<void> _pickDate() async {
    final picked = await showDatePickerSheet(context, initialDate: _date);
    if (picked != null && mounted) setState(() => _date = picked);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    // As a page of a longer flow, system back steps back like the arrow.
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop && !_saving) widget.onBack?.call();
    },
    child: SheetPage(
      header: SheetHeader(
        kind == LoanEventKind.emi
            ? (loan.terms.mode.amortises ? 'Record EMI' : 'Record payment')
            : loanActionLabel(kind),
        onBack: _saving ? null : widget.onBack,
        // Titled like Add a transaction; the sheet closes by dragging it
        // down or with Cancel.
        centered: true,
      ),
      body: AbsorbPointer(
        absorbing: _saving,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LoanIdentity(loan),
            _hero(),
            if (kind == LoanEventKind.emi && loan.terms.tracked) ...[
              const SizedBox(height: 16),
              LoanSection(
                title: _manualAllocation
                    ? 'How was this payment applied?'
                    : 'Estimated allocation',
                children: [
                  if (_manualAllocation || _extras)
                    LoanField(
                      _interest,
                      'Interest paid',
                      prefix: _prefix,
                      placeholder: 'From the lender’s statement',
                      hint: 'Enter 0 if it all went to principal.',
                      onChanged: () => setState(() {}),
                    )
                  else ...[
                    LoanValue('Interest', _money(_interestShown)),
                    TextButton(
                      onPressed: () => setState(() => _extras = true),
                      child: const Text('Edit allocation'),
                    ),
                  ],
                  LoanValue(
                    'Principal',
                    _manualAllocation && _interest.text.isEmpty
                        ? 'Enter interest first'
                        : _money(math.max(0, (_value ?? 0) - _interestShown)),
                  ),
                  LoanValue(
                    'Outstanding before payment',
                    _money(loan.outstanding),
                  ),
                  LoanValue(
                    'Outstanding principal after',
                    _manualAllocation && _interest.text.isEmpty
                        ? 'Not calculated'
                        : _money(
                            loan.outstanding -
                                math.max(0, (_value ?? 0) - _interestShown),
                          ),
                  ),
                  LoanValue('Estimated unpaid interest before', switch (loan
                      .unpaidInterestAt(_date)) {
                    final int interest => _money(interest),
                    _ => 'Unknown',
                  }),
                  LoanField(
                    _interestAfter,
                    'Unpaid interest after payment',
                    prefix: _prefix,
                    placeholder: 'Estimated',
                    hint: 'Optional, if your statement shows it.',
                    onChanged: () => setState(() {}),
                  ),
                ],
              ),
            ],
            if (_futurePayment) ...[
              const SizedBox(height: 16),
              AdvancePaymentNotice(
                due: loan.nextDue,
                following: loan.schedule.length > 1
                    ? loan.schedule[1].due
                    : null,
                payment: '${loan.terms.mode.paymentNoun} ${loan.paid + 1}',
                accepted: _advanceAccepted,
                onChanged: (value) => setState(() => _advanceAccepted = value),
              ),
            ],
            const SizedBox(height: 16),
            if (kind == LoanEventKind.partPayment || _rateChange) ...[
              _plan(),
              const SizedBox(height: 16),
            ],
            _details(),
            if (!_rateChange) ...[const SizedBox(height: 8), _extrasSection()],
          ],
        ),
      ),
      actions: LoanFormActions(
        error: _error,
        saving: _saving,
        label: _futurePayment
            ? 'Record advance payment'
            : kind == LoanEventKind.emi
            ? 'Save payment'
            : loanActionLabel(kind),
        onSave: _futurePayment && !_advanceAccepted ? null : _save,
        onBack: _close,
      ),
    ),
  );

  /// What's being paid, typed straight into the headline, with what it
  /// covers spelled out underneath as it changes.
  Widget _hero() {
    final theme = Theme.of(context);
    final colors = SheetColors.of(context);
    final first = loan.schedule.firstOrNull;
    final installment = loan.terms.mode.amortises
        ? 'EMI ${first?.number ?? loan.paid + 1}'
        : 'Payment ${loan.paid + 1}';
    final caption = switch (kind) {
      LoanEventKind.emi =>
        loan.terms.mode.amortises
            ? '$installment · due ${loanDate(loan.nextDue)}'
            : 'Amount paid',
      LoanEventKind.partPayment => '${_money(loan.outstanding)} principal left',
      LoanEventKind.closure => 'Settlement amount',
      LoanEventKind.rateChange => 'New interest rate',
    };
    final paid = _value ?? 0;
    final breakdown = switch (kind) {
      LoanEventKind.emi =>
        _manualAllocation && _interest.text.trim().isEmpty
            ? 'Confirm the interest and principal allocation below'
            : '${_money(math.max(0, paid - _interestShown))} principal · '
                  '${_money(_interestShown)} interest',
      LoanEventKind.partPayment => 'All of it goes to your principal',
      LoanEventKind.closure =>
        '${_money(loan.outstanding)} principal · '
            '${_money(math.max(0, paid - loan.outstanding))} interest',
      LoanEventKind.rateChange => 'Currently ${loan.rate}% p.a.',
    };
    final muted = theme.textTheme.bodySmall?.copyWith(color: colors.muted);
    return SheetCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
        child: Column(
          children: [
            Text(caption, textAlign: TextAlign.center, style: muted),
            const SizedBox(height: 4),
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 96),
                child: IntrinsicWidth(
                  child: TextField(
                    controller: _rateChange ? _rate : _amount,
                    autofocus: kind == LoanEventKind.partPayment,
                    textAlign: TextAlign.center,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    maxLength: _rateChange ? 6 : 16,
                    onChanged: (_) => setState(() {}),
                    style: TextStyle(
                      fontSize: 34,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -.5,
                      color: colors.text,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      filled: false,
                      isDense: true,
                      counterText: '',
                      contentPadding: const EdgeInsets.symmetric(vertical: 4),
                      hintText: _rateChange
                          ? '0'
                          : AmountTyping.fromMinor(0, loan.terms.digits),
                      hintStyle: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        color: colors.muted.withValues(alpha: .5),
                      ),
                      prefixText: _rateChange
                          ? null
                          : currencyPrefix(loan.terms.currency),
                      suffixText: _rateChange ? '%' : null,
                      prefixStyle: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        color: colors.text,
                      ),
                      suffixStyle: TextStyle(
                        fontSize: 34,
                        fontWeight: FontWeight.w700,
                        color: colors.text,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Text(breakdown, textAlign: TextAlign.center, style: muted),
            if (_feeValue > 0) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: colors.control,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '+ ${_money(_feeValue)} fees · '
                  '${_money(paid + _feeValue)} total',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The two ways a smaller balance or a new rate can play out, side by side.
  Widget _plan() {
    final theme = Theme.of(context);
    final colors = SheetColors.of(context);
    if (!loan.terms.mode.amortises ||
        loan.schedule.isEmpty ||
        loan.terms.interestBasis != LoanInterestBasis.remaining) {
      return const LoanNote(
        'Future interest uses the new amount or rate. The term stays the same.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Text(
            _rateChange ? 'After the change' : 'Use it to',
            style: theme.textTheme.titleSmall,
          ),
        ),
        LayoutBuilder(
          builder: (context, constraints) {
            final stacked =
                constraints.maxWidth < 320 ||
                MediaQuery.textScalerOf(context).scale(14) > 17;
            final options = [_option(false), _option(true)];
            return stacked
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      options[0],
                      const SizedBox(height: 10),
                      options[1],
                    ],
                  )
                : IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(child: options[0]),
                        const SizedBox(width: 10),
                        Expanded(child: options[1]),
                      ],
                    ),
                  );
          },
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
          child: Text(
            'Estimates. Confirm revised terms with your lender.',
            style: theme.textTheme.bodySmall?.copyWith(color: colors.muted),
          ),
        ),
      ],
    );
  }

  Widget _option(bool reduceEmi) {
    final theme = Theme.of(context);
    final colors = SheetColors.of(context);
    final selected = _reduceEmi == reduceEmi;
    final title = _rateChange
        ? (reduceEmi ? 'Keep tenure' : 'Keep EMI')
        : (reduceEmi ? 'Reduce EMI' : 'Reduce tenure');
    final base = theme.textTheme.bodySmall?.copyWith(height: 1.5);
    InlineSpan description;
    if (!_rateChange && (_value ?? 0) <= 0) {
      description = TextSpan(
        text: 'Enter an amount to compare',
        style: base?.copyWith(color: colors.muted),
      );
    } else {
      try {
        final preview = _preview(reduceEmi);
        final interest = preview.schedule.fold(0, (n, r) => n + r.interest);
        final savings = loan.futureInterest - interest;
        description = TextSpan(
          style: base?.copyWith(color: colors.muted),
          children: [
            TextSpan(
              text: '${_money(preview.emi)}/mo\n',
              style: TextStyle(color: colors.text, fontWeight: FontWeight.w600),
            ),
            TextSpan(
              text:
                  'Ends ${DateFormat('MMM yyyy').format(preview.schedule.last.due)}\n',
            ),
            TextSpan(
              text:
                  '${savings >= 0 ? 'Saves' : 'Adds'} ${_money(savings.abs())}',
              style: TextStyle(
                color: savings >= 0 ? colors.income : colors.expense,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        );
      } catch (e) {
        description = TextSpan(
          text: loanError(e),
          style: base?.copyWith(color: colors.muted),
        );
      }
    }
    return Semantics(
      checked: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected ? colors.primary.withValues(alpha: .08) : colors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: selected ? colors.primary : colors.outline,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => setState(() => _reduceEmi = reduceEmi),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        title,
                        style: theme.textTheme.titleSmall?.copyWith(
                          color: selected ? colors.primary : null,
                        ),
                      ),
                    ),
                    Icon(
                      selected
                          ? Icons.check_circle_rounded
                          : Icons.radio_button_off,
                      color: selected ? colors.primary : colors.muted,
                      size: 20,
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text.rich(description),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Where the money came from and when — one tap each.
  Widget _details() => ListenableBuilder(
    listenable: widget.store.accountStore,
    builder: (context, _) {
      final account = _accounts.where((a) => a.id == _accountId).firstOrNull;
      return TransactionDetailsCard(
        rows: [
          if (!_rateChange)
            TransactionDetailRow(
              leading: EntityIconTile(
                chosen: account != null,
                iconKey: account?.icon,
                fallback: Icons.account_balance_wallet_outlined,
              ),
              label: 'Paid from',
              value: account?.name ?? 'Choose an account',
              placeholder: account == null,
              onTap: _saving ? null : _pickAccount,
            ),
          TransactionDetailRow(
            leading: const SheetIconTile(icon: Icons.event_rounded),
            label: _rateChange ? 'Effective from' : 'Paid on',
            value: loanDate(_date),
            onTap: _saving ? null : _pickDate,
          ),
        ],
      );
    },
  );

  Widget _extrasSection() {
    final colors = SheetColors.of(context);
    final emi = kind == LoanEventKind.emi;
    if (!_extras && _fee.text.isEmpty && _interest.text.isEmpty) {
      return Center(
        child: TextButton.icon(
          onPressed: () => setState(() => _extras = true),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text(emi ? 'Add late fee or adjust interest' : 'Add a fee'),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SheetCard(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 18, 16, 2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (emi && !loan.terms.tracked)
                LoanField(
                  _interest,
                  'Interest charged',
                  prefix: _prefix,
                  // Blank means the schedule's figure, so it shows there.
                  placeholder:
                      '${_digitsOf(loan.schedule.firstOrNull?.interest ?? 0)} as scheduled',
                  hint: 'Only if the lender charged a different amount.',
                  onChanged: () => setState(() {}),
                ),
              LoanField(
                _fee,
                emi ? 'Late fee or penal charge' : 'Fee',
                prefix: _prefix,
                placeholder: 'None',
                hint: 'Paid on top. Never added to your principal.',
                onChanged: () => setState(() {}),
              ),
              if (!emi && kind == LoanEventKind.closure)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Add foreclosure or prepayment charges here.',
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: colors.muted),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
