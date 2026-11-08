import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/app_back_button.dart';

import '../../../domain/account.dart';
import '../../../data/repositories/loan_repository.dart';
import '../../../domain/loan.dart';
import '../../../state/ad_gate.dart';
import '../../../state/loan_store.dart';
import '../../components/action_buttons.dart';
import '../../components/adaptive_sheet.dart';
import '../../components/app_icon.dart';
import '../../components/app_toast.dart';
import '../../components/choice_list_sheet.dart';
import '../../components/confirmation_alert.dart';
import '../../components/date_picker_sheet.dart';
import '../../components/feature_page.dart';
import '../../components/number_keypad.dart';
import '../../components/page_slider.dart';
import '../../components/secondary_header.dart';
import '../../components/segmented_pill.dart';
import '../../components/select_icon_screen.dart';
import '../../theme/sheet_colors.dart';
import '../../transactions/amount_typing.dart';
import '../../transactions/quick_add_helpers.dart';
import '../../transactions/transaction_widgets.dart';
import 'loan_widgets.dart';
import 'loan_review_card.dart';

Future<void> showAddLoanFlow(BuildContext context, LoanStore store) =>
    Navigator.of(context)
        .push(FeatureRoute<void>(LoanFlowScreen(store: store)));
Future<void> showEditLoanFlow(
  BuildContext context,
  LoanStore store,
  Loan loan,
) =>
    Navigator.of(context)
        .push(FeatureRoute<void>(LoanFlowScreen(store: store, editing: loan)));

/// The flow's screens, in the order they are shown. Each groups the answers
/// that belong together, so a loan takes a handful of screens, not a dozen.
enum _Step { name, amount, interest, term, history, repayment, account, review }

enum _InterestKind { charged, free, unknown }

enum _InterestPosition { none, entered, unknown }

/// A full-screen, answer-driven flow using the shared transaction components.
class LoanFlowScreen extends StatefulWidget {
  const LoanFlowScreen({super.key, required this.store, this.editing});
  final LoanStore store;
  final Loan? editing;
  @override
  State<LoanFlowScreen> createState() => _LoanFlowScreenState();
}

class _LoanFlowScreenState extends State<LoanFlowScreen> {
  final _name = TextEditingController(),
      _asset = TextEditingController(),
      _rate = TextEditingController(),
      _duration = TextEditingController(),
      _emi = TextEditingController(),
      _principalLeft = TextEditingController(),
      _interestLeft = TextEditingController(),
      _fees = TextEditingController();
  _Step _step = _Step.name;
  VoidCallback? _restoreReview;
  final _completed = <_Step>{};
  String _amount = '', _icon = 'bank';
  String? _assetIcon, _error;
  int? _accountId, _receivedIn;
  bool _loadingReceivedAccount = false;
  String? _receivedAccountError;
  bool _saving = false,
      _returnToReview = false,
      _cancelAlertOpen = false,
      _showMissing = false,
      _monthlyRate = false,
      _years = false,
      _noDuration = false,
      _remind = true,
      _deducted = false,
      _detailsOpen = false;
  bool? _fixed, _existing;
  _InterestKind? _interestKind;
  LoanInterestBasis? _basis;
  LoanAccrual _accrual = LoanAccrual.monthly;
  bool _accrualChosen = false;
  LoanCompounding _compounding = LoanCompounding.none;
  _InterestPosition _interestPosition = _InterestPosition.unknown;
  late DateTime _start = _today, _snapshot = _today;
  DateTime? _due, _maturity, _interestStarts, _interestReminder;

  DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  bool get _editing => widget.editing != null;

  /// Editing a loan that already has payments recorded: its money answers
  /// shaped that history, so only its name, account and reminders can change.
  bool get _locked => _editing && !LoanRepository.canRestate(widget.editing!);
  List<Account> get _accounts => widget.store.accountStore.accounts
      .where(
        (a) =>
            !_locked ||
            (a.currency == widget.editing!.terms.currency &&
                a.digits == widget.editing!.terms.digits),
      )
      .toList();
  Account? get _account =>
      _accounts.where((a) => a.id == _accountId).firstOrNull;
  int get _digits => _account?.digits ?? 2;
  String get _currency => _account?.currency ?? 'INR';
  int get _principal => parseAccountAmount(_amount, _digits) ?? 0;
  bool get _rateKnown => _interestKind != _InterestKind.unknown;
  double get _annualRate => switch (_interestKind) {
    _InterestKind.free || _InterestKind.unknown => 0,
    _InterestKind.charged =>
      (double.tryParse(_rate.text.trim()) ?? double.nan) *
          (_monthlyRate ? 12 : 1),
    null => double.nan,
  };
  bool get _rateValid =>
      _annualRate.isFinite && _annualRate > 0 && _annualRate <= 100;
  int get _months =>
      _noDuration ? 0 : (int.tryParse(_duration.text) ?? 0) * (_years ? 12 : 1);
  LoanInterestBasis get _interestBasis => _rateKnown && _annualRate == 0
      ? LoanInterestBasis.remaining
      : _basis ?? LoanInterestBasis.unknown;
  DateTime? get _finalDue =>
      _noDuration ? null : _maturity ?? loanMonth(_start, _months, _start.day);
  DateTime get _firstDue =>
      _due ?? loanMonth(_existing == true ? _snapshot : _start, 1, _start.day);
  String _money(int n) =>
      formatAccountMoney(n, currency: _currency, digits: _digits);
  int? _parse(TextEditingController c) =>
      c.text.trim().isEmpty ? null : parseAccountAmount(c.text, _digits);
  List<_Step> get _steps =>
      _locked ? const [_Step.name, _Step.account, _Step.review] : _Step.values;
  int? get _estimate {
    if (!_rateKnown ||
        !_annualRate.isFinite ||
        _interestBasis == LoanInterestBasis.unknown ||
        _months < 1 ||
        _principal <= 0 ||
        _accrual != LoanAccrual.monthly ||
        _compounding != LoanCompounding.none ||
        _interestStarts != null) {
      return null;
    }
    try {
      if (_interestBasis == LoanInterestBasis.original) {
        return (_principal / _months + _principal * _annualRate / 1200).ceil();
      }
      return loanEmi(_principal, _annualRate, _months);
    } catch (_) {
      return null;
    }
  }

  int get _instalment => _fixed == true
      ? (_emi.text.trim().isEmpty ? _estimate ?? 0 : _parse(_emi) ?? 0)
      : 0;
  int? get _openingInterest =>
      _existing != true || _interestPosition == _InterestPosition.none
      ? 0
      : _interestPosition == _InterestPosition.unknown
      ? null
      : _parse(_interestLeft);

  @override
  void initState() {
    super.initState();
    _accountId = widget.editing?.accountId ?? _accounts.firstOrNull?.id;
    final loan = widget.editing;
    if (loan != null) {
      _prefill(loan);
      _step = _Step.review;
    }
  }

  /// Populate the review and its focused editors from the recorded terms.
  void _prefill(Loan loan) {
    final t = loan.terms;
    String minor(int value) => AmountTyping.fromMinor(value, t.digits);
    _name.text = t.lender;
    _asset.text = t.asset ?? '';
    _icon = t.icon;
    _assetIcon = t.assetIcon;
    _remind = t.remind;
    _amount = minor(t.principal);
    _start = t.startDate ?? t.firstDue;
    _interestKind = !t.rateKnown
        ? _InterestKind.unknown
        : t.rate == 0
        ? _InterestKind.free
        : _InterestKind.charged;
    if (_interestKind == _InterestKind.charged) {
      _rate.text = t.rate % 1 == 0 ? '${t.rate.toInt()}' : '${t.rate}';
      _basis = t.interestBasis;
    }
    _accrual = t.accrual;
    _accrualChosen = true;
    _compounding = t.compounding;
    _interestStarts = t.interestStartsOn;
    _noDuration = t.months == 0;
    if (t.months > 0) {
      _years = t.months % 12 == 0;
      _duration.text = '${_years ? t.months ~/ 12 : t.months}';
      // A worked-out end date keeps following the start date; only one the
      // user moved stays pinned.
      if (t.maturityDate != loanMonth(_start, t.months, _start.day)) {
        _maturity = t.maturityDate;
      }
    }
    _existing = t.existing;
    if (t.existing) {
      _snapshot = t.snapshotDate ?? _start;
      _principalLeft.text = minor(t.openingBalance);
      final interest = t.openingInterest;
      _interestPosition = interest == null
          ? _InterestPosition.unknown
          : interest == 0
          ? _InterestPosition.none
          : _InterestPosition.entered;
      if (interest != null && interest > 0) {
        _interestLeft.text = minor(interest);
      }
    }
    _fixed = switch (t.mode) {
      LoanRepaymentMode.emi => true,
      LoanRepaymentMode.flexible => false,
      _ => null,
    };
    if (_fixed == true) {
      _emi.text = minor(t.emi);
      _due = t.firstDue;
    }
    _interestReminder = t.interestReminderDate;
    if (t.chargesMinor > 0) _fees.text = minor(t.chargesMinor);
    _deducted = t.chargesDeducted;
    _completed.addAll(_Step.values);
    if (loan.disbursalId case final id?) {
      _loadReceivedAccount(id);
    }
  }

  Future<void> _loadReceivedAccount(int id) async {
    // Review is now the entry screen. Do not allow saving before the existing
    // disbursal account loads, which would otherwise remove that transaction.
    _loadingReceivedAccount = true;
    try {
      final account = await widget.store.repository.transactionAccount(id);
      if (mounted) setState(() => _receivedIn = account);
    } catch (_) {
      if (mounted) {
        setState(
          () => _receivedAccountError =
              'Couldn’t load the account. Reopen this loan to try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _loadingReceivedAccount = false);
    }
  }

  @override
  void dispose() {
    for (final c in [
      _name,
      _asset,
      _rate,
      _duration,
      _emi,
      _principalLeft,
      _interestLeft,
      _fees,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  LoanTerms _terms({bool validate = true}) {
    if (_account == null) throw ArgumentError('Choose a repayment account.');
    final terms = LoanTerms(
      lender: _name.text,
      kind: widget.editing?.terms.kind ?? LoanKind.other,
      icon: _icon,
      asset: _asset.text.trim().isEmpty ? null : _asset.text.trim(),
      assetIcon: _assetIcon,
      principal: _principal,
      openingBalance: _existing == true
          ? _parse(_principalLeft) ?? -1
          : _principal,
      openingInterest: _openingInterest,
      startDate: _start,
      snapshotDate: _existing == true ? _snapshot : _start,
      rate: _annualRate,
      rateKnown: _rateKnown,
      interestBasis: _interestBasis,
      accrual: _accrual,
      compounding: _compounding,
      interestStartsOn: _interestStarts,
      months: _months,
      maturityDate: _finalDue,
      emi: _instalment,
      mode: _fixed == true ? LoanRepaymentMode.emi : LoanRepaymentMode.flexible,
      paidBefore: 0,
      firstDue: _fixed == true ? _firstDue : _finalDue ?? _start,
      day: _firstDue.day,
      currency: _currency,
      digits: _digits,
      existing: _existing == true,
      remind: _remind,
      interestReminderDate: _interestReminder,
      chargesMinor: _fees.text.trim().isEmpty ? 0 : _parse(_fees) ?? -1,
      chargesDeducted: _deducted,
    );
    if (validate) terms.validate();
    return terms;
  }

  /// Why Continue can't go on yet — shown when it is tapped too early, and
  /// kept up to date while the answer is fixed. Null once the step is ready.
  String? get _missing => _missingFor(_step);

  String? _missingFor(_Step step) {
    switch (step) {
      case _Step.name:
        if (_name.text.trim().isEmpty) return 'Give this loan a name.';
      case _Step.amount:
        if (_account == null) return 'Choose an account to set the currency.';
        if (_principal <= 0) return 'Enter the amount you borrowed.';
      case _Step.interest:
        if (_interestKind == null) {
          return 'Choose whether this loan charges interest.';
        }
        if (_interestKind == _InterestKind.charged) {
          if (!_rateValid) {
            return 'Enter a rate from 0% to 100% a year, or choose No.';
          }
          if (_basis == null) return 'Choose what the interest is charged on.';
        }
      case _Step.term:
        if (_start.isAfter(_today)) {
          return 'The start date can’t be in the future.';
        }
        if (!_noDuration && (_months <= 0 || _months > 600)) {
          return 'Enter how long the loan lasts (up to 50 years), or turn on “No fixed end date”.';
        }
        if (_finalDue != null && _finalDue!.isBefore(_start)) {
          return 'The end date can’t be before the start date.';
        }
      case _Step.history:
        if (_existing == null) {
          return 'Choose whether you’ve made any payments.';
        }
        if (_existing == true) {
          final left = _parse(_principalLeft);
          if (left == null || left < 0) {
            return 'Enter how much of the borrowed amount is still unpaid.';
          }
          if (left > _principal) {
            return 'The unpaid amount can’t be more than the ${_money(_principal)} borrowed.';
          }
          if (_snapshot.isBefore(_start) || _snapshot.isAfter(_today)) {
            return 'Choose an “as of” date between the start date and today.';
          }
          if (_interestPosition == _InterestPosition.entered &&
              (_parse(_interestLeft) ?? -1) < 0) {
            return 'Enter the unpaid interest, or choose None or Not sure.';
          }
        }
      case _Step.repayment:
        if (_fixed == null) return 'Choose how you repay this loan.';
        if (_fixed == true) {
          if (_instalment <= 0) return 'Enter the monthly instalment.';
          if (_firstDue.isBefore(_start)) {
            return 'The instalment date can’t be before the loan started.';
          }
        }
      case _Step.account:
        if (_account == null) return 'Choose the account you repay from.';
      case _Step.review:
        break;
    }
    return null;
  }

  bool get _ready => _step == _Step.review ? !_saving : _missing == null;

  void _go(_Step step) {
    FocusScope.of(context).unfocus();
    setState(() {
      _step = step;
      _error = null;
      _showMissing = false;
      _detailsOpen = false;
    });
  }

  void _editStep(_Step step) {
    if (!_steps.contains(step) || step == _Step.review) return;
    // A focused editor owns a temporary draft. Back and Cancel discard it.
    final controllers = [
      _name,
      _asset,
      _rate,
      _duration,
      _emi,
      _principalLeft,
      _interestLeft,
      _fees,
    ];
    final values = controllers.map((c) => c.value).toList();
    final amount = _amount, icon = _icon, assetIcon = _assetIcon;
    final account = _accountId, received = _receivedIn;
    final monthly = _monthlyRate, years = _years, noDuration = _noDuration;
    final remind = _remind, deducted = _deducted;
    final fixed = _fixed, existing = _existing;
    final kind = _interestKind, basis = _basis;
    final accrual = _accrual, chosen = _accrualChosen;
    final compounding = _compounding, position = _interestPosition;
    final start = _start, snapshot = _snapshot;
    final due = _due, maturity = _maturity;
    final interestStarts = _interestStarts,
        interestReminder = _interestReminder;
    final completed = {..._completed};
    _restoreReview = () {
      for (var i = 0; i < controllers.length; i++) {
        controllers[i].value = values[i];
      }
      _amount = amount;
      _icon = icon;
      _assetIcon = assetIcon;
      _accountId = account;
      _receivedIn = received;
      _monthlyRate = monthly;
      _years = years;
      _noDuration = noDuration;
      _remind = remind;
      _deducted = deducted;
      _fixed = fixed;
      _existing = existing;
      _interestKind = kind;
      _basis = basis;
      _accrual = accrual;
      _accrualChosen = chosen;
      _compounding = compounding;
      _interestPosition = position;
      _start = start;
      _snapshot = snapshot;
      _due = due;
      _maturity = maturity;
      _interestStarts = interestStarts;
      _interestReminder = interestReminder;
      _completed
        ..clear()
        ..addAll(completed);
    };
    _returnToReview = true;
    _go(step);
  }

  void _closeEditor({bool save = false}) {
    if (!save) _restoreReview?.call();
    _restoreReview = null;
    _returnToReview = false;
    _go(_Step.review);
  }

  Future<void> _cancel() async {
    if (_saving || _cancelAlertOpen) return;
    if (_returnToReview) {
      _closeEditor();
      return;
    }
    _cancelAlertOpen = true;
    FocusScope.of(context).unfocus();
    final discard = await showConfirmationAlert(
      context,
      title: 'Are you sure?',
      message: _editing
          ? 'Your changes to this loan will not be saved.'
          : 'The loan details you entered will not be saved.',
      cancelLabel: 'Keep editing',
      confirmLabel: 'Discard',
    );
    _cancelAlertOpen = false;
    if (discard && mounted) Navigator.pop(context);
  }

  void _back() {
    if (_saving) return;
    if (_returnToReview) {
      _closeEditor();
      return;
    }
    if (_editing && _step == _Step.review) {
      _cancel();
      return;
    }
    final index = _steps.indexOf(_step);
    if (index == 0) {
      Navigator.pop(context);
    } else {
      _go(_steps[index - 1]);
    }
  }

  void _advance() {
    if (!_ready) {
      FocusScope.of(context).unfocus();
      setState(() => _showMissing = true);
      return;
    }
    try {
      if (_returnToReview) {
        _completed.add(_step);
        _closeEditor(save: true);
        return;
      }
      if (_step == _Step.account && !_locked) _terms();
      _completed.add(_step);
      _go(_steps[_steps.indexOf(_step) + 1]);
    } catch (e) {
      setState(() => _error = loanError(e));
    }
  }

  Future<void> _save() async {
    if (_loadingReceivedAccount || _receivedAccountError != null) return;
    for (final step in _steps) {
      final missing = _missingFor(step);
      if (missing != null) {
        setState(() => _error = missing);
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      if (_locked) {
        await widget.store.save(
          () => widget.store.repository.edit(
            widget.editing!,
            lender: _name.text,
            icon: _icon,
            asset: _asset.text.trim().isEmpty ? null : _asset.text,
            assetIcon: _assetIcon,
            accountId: _accountId!,
            remind: _remind,
          ),
        );
      } else {
        final terms = _terms();
        final receivedIn = _existing == true ? null : _receivedIn;
        await widget.store.save(
          () => _editing
              ? widget.store.repository.restate(
                  widget.editing!,
                  terms,
                  _accountId!,
                  receivedIn: receivedIn,
                )
              : widget.store.repository.add(
                  terms,
                  _accountId!,
                  receivedIn: receivedIn,
                ),
        );
      }
      if (_remind) await widget.store.reminders.requestPermission();
      if (!mounted) return;
      showAppToast(context, _editing ? 'Loan updated' : 'Loan added');
      Navigator.pop(context);
      unawaited(AdGate.instance.after(AdMoment.loan));
    } catch (e) {
      if (mounted) setState(() => _error = loanError(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickIcon(bool asset) async {
    final result = await Navigator.of(context).push(
      FeatureRoute<String>(
        SelectIconScreen(selectedKey: asset ? _assetIcon : _icon),
      ),
    );
    if (result != null && mounted) {
      setState(() {
        if (asset) {
          _assetIcon = result;
        } else {
          _icon = result;
        }
      });
    }
  }

  Future<void> _date(DateTime initial, ValueChanged<DateTime> apply) async {
    final result = await showDatePickerSheet(context, initialDate: initial);
    if (result != null && mounted) setState(() => apply(result));
  }

  Future<void> _pickAccount({bool received = false}) async {
    final result = await showChoiceListSheet<int>(
      context,
      title: received ? 'Record money received' : 'Repayment account',
      selected: received ? _receivedIn ?? -1 : _accountId,
      items: [
        if (received)
          const ChoiceItem(
            value: -1,
            icon: Icon(Icons.block_outlined),
            label: 'Do not add money to an account',
          ),
        for (final a in _accounts.where(
          (a) => !received || (a.currency == _currency && a.digits == _digits),
        ))
          ChoiceItem(
            value: a.id,
            icon: AppIcon(a.icon, size: 28),
            label: '${a.name} · ${a.currency}',
          ),
      ],
      addLabel: received ? null : 'Add account',
      onAdd: received
          ? null
          : (context) async => (await addAccountAndSelect(
              context,
              widget.store.accountStore,
            ))?.id,
    );
    if (result == null || !mounted) return;
    setState(() {
      if (received) {
        _receivedIn = result == -1 ? null : result;
      } else {
        final oldCurrency = _currency, oldDigits = _digits;
        _accountId = result;
        if (_currency != oldCurrency || _digits != oldDigits) {
          _receivedIn = null;
          _amount = '';
          _emi.clear();
          _principalLeft.clear();
          _interestLeft.clear();
          _fees.clear();
          _completed.removeAll([_Step.amount, _Step.history, _Step.repayment]);
          if (!_locked && !_returnToReview) _step = _Step.amount;
        }
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving && !_returnToReview && !_editing && _step == _steps.first,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            SecondaryHeader(
              title: _returnToReview
                  ? 'Edit ${_stepNames[_step]!.toLowerCase()}'
                  : _editing
                  ? 'Edit loan'
                  : 'Add a loan',
              leading: AppBackButton(onPressed: _saving ? null : _back),
            ),
            if (!_returnToReview && !_editing) _progress(),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 620),
                  child: AbsorbPointer(
                    absorbing: _saving || _loadingReceivedAccount,
                    child: PageSlider(
                      // Review editors live after review in the navigation
                      // stack: push forward to edit, pop backward to review.
                      index: _returnToReview
                          ? _Step.values.length + _step.index
                          : _step.index,
                      pages: [
                        for (final step in _Step.values)
                          Builder(builder: (_) => _page(step)),
                        for (final step in _Step.values)
                          Builder(builder: (_) => _page(step)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 620),
              child: ActionButtonBar(
                secondaryLabel: 'Cancel',
                onSecondary: _saving ? null : _cancel,
                primaryLabel: _loadingReceivedAccount
                    ? 'Loading…'
                    : _saving
                    ? 'Saving…'
                    : _step == _steps.last
                    ? (_editing ? 'Save changes' : 'Add loan')
                    : _returnToReview
                    ? 'Save'
                    : 'Continue',
                // Continue stays tappable: an early tap says what's missing
                // rather than leaving a dead button to puzzle over.
                onPrimary:
                    _saving ||
                        _loadingReceivedAccount ||
                        _receivedAccountError != null
                    ? null
                    : _step == _steps.last
                    ? _save
                    : _advance,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  static const _stepNames = {
    _Step.name: 'Name',
    _Step.amount: 'Amount',
    _Step.interest: 'Interest',
    _Step.term: 'Loan term',
    _Step.history: 'Payments so far',
    _Step.repayment: 'Repayment',
    _Step.account: 'Accounts and reminders',
    _Step.review: 'Review',
  };

  Widget _progress() {
    final colors = SheetColors.of(context);
    final index = _steps.indexOf(_step), count = _steps.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 584),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Semantics(
              label: 'Step ${index + 1} of $count, ${_stepNames[_step]}',
              excludeSemantics: true,
              child: Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: 'Step ${index + 1} of $count',
                      style: TextStyle(color: colors.muted),
                    ),
                    TextSpan(
                      text: '  ·  ${_stepNames[_step]}',
                      style: TextStyle(
                        color: colors.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                style: Theme.of(context).textTheme.labelMedium,
              ),
            ),
            const SizedBox(height: 8),
            TweenAnimationBuilder<double>(
              tween: Tween(end: (index + 1) / count),
              duration: MediaQuery.disableAnimationsOf(context)
                  ? Duration.zero
                  : const Duration(milliseconds: 320),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => LinearProgressIndicator(
                value: value,
                minHeight: 4,
                borderRadius: BorderRadius.circular(6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _body(String question, List<Widget> children, {String? caption}) {
    final missing = _showMissing ? _missing : null;
    return SingleChildScrollView(
      key: ValueKey(_step),
      padding: const EdgeInsets.fromLTRB(18, 6, 18, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (!_returnToReview &&
              _step != _Step.name &&
              _step != _Step.review) ...[
            _summary(),
            const SizedBox(height: 24),
          ],
          Text(
            question,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          if (caption != null) ...[
            const SizedBox(height: 8),
            Text(
              caption,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 22),
          ...children,
          if (missing != null) ...[
            const SizedBox(height: 4),
            LoanNote(missing, error: true),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            LoanNote(_error!, error: true),
          ],
          if (_receivedAccountError != null)
            LoanNote(_receivedAccountError!, error: true),
        ],
      ),
    );
  }

  Widget _label(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 18, 4, 10),
    child: Text(text, style: Theme.of(context).textTheme.titleSmall),
  );
  Widget _row(
    String label,
    String value,
    VoidCallback? tap, {
    IconData icon = Icons.edit_outlined,
    String? caption,
    bool placeholder = false,
  }) => TransactionDetailRow(
    leading: SheetIconTile(icon: icon),
    label: label,
    value: value,
    caption: caption,
    placeholder: placeholder,
    maxLines: 3,
    onTap: tap,
  );
  Widget _input(
    TextEditingController c,
    String label,
    String hint, {
    VoidCallback? changed,
    IconData icon = Icons.numbers_rounded,
  }) => TransactionTextRow(
    key: ValueKey(label),
    icon: icon,
    label: label,
    hintText: hint,
    controller: c,
    maxLength: 16,
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    onChanged: (_) => setState(() {
      changed?.call();
    }),
  );
  Widget _switch(
    String title,
    String subtitle,
    bool value,
    ValueChanged<bool> changed,
  ) => SwitchListTile.adaptive(
    title: Text(title),
    subtitle: Text(subtitle),
    value: value,
    onChanged: (v) => setState(() => changed(v)),
  );
  Widget _choice(
    String title,
    String subtitle,
    bool selected,
    VoidCallback choose,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: _ChoiceCard(
      title: title,
      subtitle: subtitle,
      selected: selected,
      onTap: () => setState(choose),
    ),
  );
  Widget _segments<T extends Object>(
    T? value,
    List<(T, String)> options,
    ValueChanged<T> choose,
  ) => SegmentedPill<T>(
    segments: [
      for (final (option, label) in options) PillSegment(option, label),
    ],
    value: value,
    onChanged: (v) => setState(() => choose(v)),
  );

  String get _rateLabel => switch (_interestKind) {
    _InterestKind.unknown || null => 'Interest rate unknown',
    _InterestKind.free => 'No interest',
    _InterestKind.charged =>
      '${_rate.text.trim()}% a ${_monthlyRate ? 'month' : 'year'}',
  };
  String get _basisLabel => switch (_interestBasis) {
    LoanInterestBasis.remaining => 'on the unpaid amount',
    LoanInterestBasis.original => 'flat, on the full amount',
    LoanInterestBasis.unknown => 'calculation unknown',
  };
  String get _termLabel =>
      'From ${loanDate(_start)} · ${_noDuration ? 'No fixed end date' : '${_duration.text.trim()} ${_years ? 'years' : 'months'}'}';
  List<(_Step, String, String)> get _answers => [
    (
      _Step.name,
      'Name',
      _asset.text.trim().isEmpty
          ? _name.text
          : '${_asset.text} · ${_name.text}',
    ),
    if (_completed.contains(_Step.amount))
      (_Step.amount, 'Amount borrowed', _money(_principal)),
    if (_completed.contains(_Step.interest))
      (
        _Step.interest,
        'Interest',
        _interestKind == _InterestKind.charged
            ? '$_rateLabel, $_basisLabel'
            : _rateLabel,
      ),
    if (_completed.contains(_Step.term)) (_Step.term, 'Loan term', _termLabel),
    if (_completed.contains(_Step.history))
      (
        _Step.history,
        'Payments so far',
        _existing != true
            ? 'None yet'
            : '${_money(_parse(_principalLeft) ?? 0)} unpaid on ${loanDate(_snapshot)} · ${_openingInterest == null ? 'interest unknown' : '${_money(_openingInterest!)} interest due'}',
      ),
    if (_completed.contains(_Step.repayment))
      (
        _Step.repayment,
        'Repayment',
        switch (_fixed) {
          true => '${_money(_instalment)} a month from ${loanDate(_firstDue)}',
          false => 'Flexible payments',
          null => widget.editing?.terms.mode.label ?? '',
        },
      ),
    if (_completed.contains(_Step.account))
      (
        _Step.account,
        'Repaid from',
        '${_account?.name ?? 'Choose account'} · reminders ${_remind ? 'on' : 'off'}',
      ),
  ];
  Widget _summary() {
    final answers = _answers;
    final review = _step == _Step.review;
    return Column(
      children: [
        Row(
          children: [
            AppIcon(_assetIcon ?? _icon, size: 38),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    answers.first.$3,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  if (_principal > 0)
                    Text(
                      _money(_principal),
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                ],
              ),
            ),
            if (!review && answers.length > 1)
              IconButton(
                tooltip: 'Edit details',
                onPressed: () => setState(() => _detailsOpen = !_detailsOpen),
                icon: Icon(
                  _detailsOpen
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                ),
              ),
          ],
        ),
        if (_detailsOpen && !review) ...[
          const SizedBox(height: 10),
          _answersCard(answers),
        ],
      ],
    );
  }

  static const _stepIcons = {
    _Step.name: Icons.label_outline_rounded,
    _Step.amount: Icons.payments_outlined,
    _Step.interest: Icons.percent_rounded,
    _Step.term: Icons.date_range_outlined,
    _Step.history: Icons.history_rounded,
    _Step.repayment: Icons.event_repeat_outlined,
    _Step.account: Icons.account_balance_wallet_outlined,
  };

  Widget _answersCard(
    List<(_Step, String, String)> answers, {
    bool review = false,
  }) => TransactionDetailsCard(
    rows: [
      for (final a in answers)
        Tooltip(
          message: 'Change ${a.$2.toLowerCase()}',
          child: _row(
            a.$2,
            a.$3,
            !_steps.contains(a.$1)
                ? null
                : review
                ? () => _editStep(a.$1)
                : () => _go(a.$1),
            icon: _stepIcons[a.$1]!,
          ),
        ),
    ],
  );

  Widget _page(_Step step) => switch (step) {
    _Step.name => _namePage(),
    _Step.amount => _amountPage(),
    _Step.interest => _interestPage(),
    _Step.term => _termPage(),
    _Step.history => _historyPage(),
    _Step.repayment => _repaymentPage(),
    _Step.account => _accountPage(),
    _Step.review => _locked ? _lockedReview() : _reviewPage(),
  };
  Widget _namePage() => _body('Name your loan', [
    TransactionDetailsCard(
      rows: [
        TransactionTextRow(
          icon: Icons.account_balance_outlined,
          label: 'Lender or loan name',
          hintText: 'Type a name',
          controller: _name,
          maxLength: 40,
          onChanged: (_) => setState(() {}),
          leading: SheetIconTile(child: AppIcon(_icon, size: 30)),
          onIconTap: () => _pickIcon(false),
          iconTooltip: 'Change loan icon',
        ),
        TransactionTextRow(
          icon: Icons.shopping_bag_outlined,
          label: 'What it paid for',
          hintText: 'Optional — a car, a phone',
          controller: _asset,
          maxLength: 40,
          onChanged: (_) => setState(() {}),
          leading: _assetIcon == null
              ? null
              : SheetIconTile(child: AppIcon(_assetIcon, size: 30)),
          onIconTap: () => _pickIcon(true),
          iconTooltip: 'Change item icon',
        ),
      ],
    ),
    const LoanNote('Tap an icon to change it.'),
  ], caption: 'For example, “HDFC home loan” or “Loan from Ravi”.');
  Widget _amountPage() => _body('How much did you borrow?', [
    AmountDisplayCard(
      amount: AmountTyping.display(
        _amount,
        currency: _currency,
        decimals: _digits,
      ),
      empty: _amount.isEmpty,
    ),
    const SizedBox(height: 4),
    Center(
      child: TextButton.icon(
        onPressed: () => _pickAccount(),
        icon: const Icon(Icons.expand_more_rounded),
        iconAlignment: IconAlignment.end,
        label: Text(
          _account == null
              ? 'Choose account'
              : '$_currency · ${_account!.name}',
        ),
      ),
    ),
    NumberKeypad(
      onDigit: (d) =>
          setState(() => _amount = AmountTyping.digit(_amount, d, _digits)),
      onDecimalPoint: () =>
          setState(() => _amount = AmountTyping.point(_amount, _digits)),
      onBackspace: () =>
          setState(() => _amount = AmountTyping.backspace(_amount)),
      onClear: () => setState(() => _amount = ''),
      decimalEnabled: _digits > 0 && !_amount.contains('.'),
    ),
  ], caption: 'The original amount, before any repayments.');
  Widget _interestPage() {
    final charged = _interestKind == _InterestKind.charged;
    return _body('Does it charge interest?', [
      _segments<_InterestKind>(
        _interestKind,
        const [
          (_InterestKind.charged, 'Yes'),
          (_InterestKind.free, 'No'),
          (_InterestKind.unknown, 'Not sure'),
        ],
        (kind) {
          _interestKind = kind;
          if (kind != _InterestKind.charged) {
            _rate.clear();
            _basis = null;
          }
        },
      ),
      if (charged) ...[
        const SizedBox(height: 16),
        TransactionDetailsCard(
          rows: [
            _input(
              _rate,
              'Interest rate (%)',
              _monthlyRate ? 'e.g. 1' : 'e.g. 12',
              icon: Icons.percent_rounded,
            ),
          ],
        ),
        const SizedBox(height: 10),
        _segments<bool>(_monthlyRate, const [
          (false, 'Per year'),
          (true, 'Per month'),
        ], (monthly) => _monthlyRate = monthly),
        if (_monthlyRate && _rateValid)
          LoanNote(
            'That’s ${_annualRate.toStringAsFixed(_annualRate % 1 == 0 ? 0 : 2)}% a year.',
          ),
        _label('What is the interest charged on?'),
        _choice(
          'The amount still unpaid',
          'Reducing balance — interest falls as you repay.',
          _basis == LoanInterestBasis.remaining,
          () => _basis = LoanInterestBasis.remaining,
        ),
        _choice(
          'The full amount borrowed',
          'Flat rate — based on the original amount.',
          _basis == LoanInterestBasis.original,
          () => _basis = LoanInterestBasis.original,
        ),
        _choice(
          'Not sure how it’s worked out',
          'Payments are still tracked; interest isn’t estimated.',
          _basis == LoanInterestBasis.unknown,
          () => _basis = LoanInterestBasis.unknown,
        ),
      ],
      if (_interestKind == _InterestKind.free)
        const LoanNote('Interest-free — you only repay what you borrowed.'),
      if (_interestKind == _InterestKind.unknown)
        const LoanNote(
          'You can track payments. Interest stays unknown until confirmed.',
        ),
      if (charged) _advanced(),
    ], caption: 'Check your loan agreement or the lender’s app.');
  }

  Widget _termPage() => _body('When did it start, and for how long?', [
    TransactionDetailsCard(
      rows: [
        _row(
          'Start date',
          loanDate(_start),
          () => _date(_start, (d) {
            _start = d;
            _maturity = null;
            _due = null;
          }),
          icon: Icons.event_outlined,
          caption: 'When you got the money or made the purchase',
        ),
      ],
    ),
    _label('How long is the loan?'),
    TransactionDetailsCard(
      rows: [
        if (!_noDuration)
          _input(
            _duration,
            'Duration',
            _years ? 'e.g. 5' : 'e.g. 12',
            changed: () => _maturity = null,
            icon: Icons.timelapse_rounded,
          ),
        _switch(
          'No fixed end date',
          'For loans repaid whenever you can',
          _noDuration,
          (v) {
            _noDuration = v;
            _maturity = null;
          },
        ),
      ],
    ),
    if (!_noDuration) ...[
      const SizedBox(height: 10),
      _segments<bool>(_years, const [(false, 'Months'), (true, 'Years')], (
        years,
      ) {
        _years = years;
        _maturity = null;
      }),
      if (_months > 0 && _finalDue != null) ...[
        const SizedBox(height: 12),
        TransactionDetailsCard(
          rows: [
            _row(
              'Ends on',
              loanDate(_finalDue!),
              () => _date(_finalDue!, (d) => _maturity = d),
              icon: Icons.flag_outlined,
              caption: _maturity == null
                  ? 'Worked out from the start date — tap to change'
                  : null,
            ),
          ],
        ),
      ],
    ],
  ]);
  Widget _historyPage() => _body('Have you made any payments yet?', [
    _choice(
      'No payments yet',
      'A new loan, or one where nothing has been repaid.',
      _existing == false,
      () => _existing = false,
    ),
    _choice(
      'Yes, I have',
      'Use the remaining balance on your lender’s statement.',
      _existing == true,
      () {
        _existing = true;
        _receivedIn = null;
        _fees.clear();
      },
    ),
    if (_existing == true) ...[
      _label('What’s left to pay?'),
      TransactionDetailsCard(
        rows: [
          _input(
            _principalLeft,
            'Outstanding principal',
            'Exclude interest and fees',
          ),
          _row(
            'As of',
            loanDate(_snapshot),
            () => _date(_snapshot, (d) => _snapshot = d),
            icon: Icons.event_outlined,
          ),
        ],
      ),
      _label('Any interest due but not yet paid?'),
      _segments<_InterestPosition>(_interestPosition, const [
        (_InterestPosition.none, 'None'),
        (_InterestPosition.entered, 'Yes'),
        (_InterestPosition.unknown, 'Not sure'),
      ], (p) => _interestPosition = p),
      if (_interestPosition == _InterestPosition.entered) ...[
        const SizedBox(height: 12),
        TransactionDetailsCard(
          rows: [
            _input(
              _interestLeft,
              'Unpaid interest',
              'Interest due but not paid',
            ),
          ],
        ),
      ],
      const LoanNote(
        'Tracking starts here. Earlier payments won’t be added again.',
      ),
    ],
  ]);
  Widget _repaymentPage() => _body('How do you repay it?', [
    _choice(
      'Fixed monthly EMI',
      'The same amount every month, set by the lender.',
      _fixed == true,
      () {
        _fixed = true;
        if (!_accrualChosen) _accrual = LoanAccrual.monthly;
      },
    ),
    _choice(
      'Flexible payments',
      'No fixed monthly amount.',
      _fixed == false,
      () {
        _fixed = false;
        _emi.clear();
        if (!_accrualChosen) _accrual = LoanAccrual.daily;
      },
    ),
    if (_fixed == true) ...[
      const SizedBox(height: 8),
      if (_estimate != null) ...[
        AmountHero(
          amount: _money(_estimate!),
          caption: 'Estimated monthly EMI',
          color: SheetColors.of(context).primary,
        ),
        const SizedBox(height: 16),
      ],
      TransactionDetailsCard(
        rows: [
          _input(
            _emi,
            'Monthly instalment',
            _estimate == null
                ? 'Amount shown by the lender'
                : 'Leave blank to use the estimate',
          ),
          _row(
            _existing == true
                ? 'Next instalment date'
                : 'First instalment date',
            loanDate(_firstDue),
            () => _date(_firstDue, (d) => _due = d),
            icon: Icons.event_outlined,
            caption: 'Repeats monthly on this day',
          ),
        ],
      ),
      const LoanNote('Use your lender’s EMI if it differs from the estimate.'),
    ],
    if (_fixed == false) ...[
      const SizedBox(height: 8),
      TransactionDetailsCard(
        rows: [
          _row(
            'Monthly interest reminder',
            _interestReminder == null
                ? 'Off — tap to set'
                : 'From ${loanDate(_interestReminder!)}',
            () => _date(
              _interestReminder ?? _today,
              (d) => _interestReminder = d,
            ),
            icon: Icons.notifications_outlined,
            placeholder: _interestReminder == null,
          ),
          if (_interestReminder != null)
            _row(
              'Turn off interest reminder',
              'Remove',
              () => setState(() => _interestReminder = null),
              icon: Icons.notifications_off_outlined,
            ),
        ],
      ),
      const LoanNote(
        'Choose the interest and principal split when you record a payment.',
      ),
    ],
  ]);
  Widget _accountPage() => _body(
    _locked ? 'Account and reminders' : 'Accounts and reminders',
    [
      TransactionDetailsCard(
        rows: [
          _row(
            'Usually repaid from',
            _account?.name ?? 'Choose an account',
            () => _pickAccount(),
            icon: Icons.account_balance_wallet_outlined,
          ),
          if (!_locked && _existing != true)
            _row(
              'Record money received',
              _receivedIn == null
                  ? 'Do not add money to an account'
                  : _accounts.firstWhere((a) => a.id == _receivedIn).name,
              () => _pickAccount(received: true),
              icon: Icons.south_west_rounded,
            ),
          _switch(
            'Payment reminders',
            'Two days before, and on the day',
            _remind,
            (v) => _remind = v,
          ),
        ],
      ),
      if (!_locked && _existing != true) _feesEditor(),
      LoanNote(
        _locked
            ? 'Past terms and payments stay. Use Change rate or Record payment to update.'
            : _existing == true
            ? 'Payments you record come out of this account.'
            : _receivedIn == null
            ? 'The loan money isn’t added to any account. Pick one above if it reached your bank.'
            : 'The borrowed money is added on ${loanDate(_start)}, not counted as income.',
      ),
    ],
  );
  Widget _advanced() => ExpansionTile(
    leading: const SheetIconTile(icon: Icons.tune_rounded),
    title: const Text('Advanced interest settings'),
    subtitle: const Text('Only change these if your lender’s terms say so'),
    tilePadding: EdgeInsets.zero,
    children: [
      TransactionDetailsCard(
        rows: [
          _row(
            'Interest accrual',
            _accrual == LoanAccrual.daily
                ? 'Daily · actual days / 365'
                : 'Monthly · prorated by anniversary month',
            () => setState(() {
              _accrualChosen = true;
              _accrual = _accrual == LoanAccrual.daily
                  ? LoanAccrual.monthly
                  : LoanAccrual.daily;
            }),
          ),
          _row(
            'Compounding',
            switch (_compounding) {
              LoanCompounding.none => 'No compounding',
              LoanCompounding.monthly => 'Monthly',
              LoanCompounding.unknown => 'Other / unknown',
            },
            () async {
              final value = await showChoiceListSheet<LoanCompounding>(
                context,
                title: 'Compounding',
                selected: _compounding,
                items: [
                  const ChoiceItem(
                    value: LoanCompounding.none,
                    icon: Icon(Icons.percent),
                    label: 'No compounding',
                  ),
                  const ChoiceItem(
                    value: LoanCompounding.monthly,
                    icon: Icon(Icons.calendar_month),
                    label: 'Monthly',
                  ),
                  const ChoiceItem(
                    value: LoanCompounding.unknown,
                    icon: Icon(Icons.help_outline),
                    label: 'Other / unknown',
                  ),
                ],
              );
              if (value != null && mounted) {
                setState(() => _compounding = value);
              }
            },
          ),
          _row('Rounding', 'Currency precision · nearest minor unit', null),
          _row(
            'Interest-free period ends',
            _interestStarts == null ? 'None' : loanDate(_interestStarts!),
            () => _date(_interestStarts ?? _start, (d) => _interestStarts = d),
          ),
          if (_interestStarts != null)
            _row(
              'Remove interest-free period',
              'Interest starts at disbursement',
              () => setState(() => _interestStarts = null),
            ),
        ],
      ),
      const LoanNote(
        'Interest can still build up during a payment break. Set an interest-free period only if your lender waives it. Rate changes go in loan details.',
      ),
    ],
  );
  Widget _reviewPage() {
    Loan? loan;
    String? problem;
    try {
      final terms = _terms(validate: false);
      loan = Loan(id: 0, terms: terms, accountId: _accountId);
      for (final step in _steps) {
        problem ??= _missingFor(step);
      }
      terms.validate();
    } catch (e) {
      problem = loanError(e);
    }
    return _body(
      _editing ? 'Review your changes' : 'Review your loan',
      caption: 'Tap a detail to change it.',
      [
        if (problem == null)
          _overview(loan!, loan.unpaidInterestAt(_today))
        else ...[
          LoanNote(problem, error: true),
          const SizedBox(height: 12),
          _answersCard(_answers, review: true),
        ],
      ],
    );
  }

  Widget _feesEditor() => ExpansionTile(
    leading: const SheetIconTile(icon: Icons.receipt_long_outlined),
    title: const Text('Fees and charges'),
    subtitle: const Text('Optional · paid when the loan started'),
    tilePadding: EdgeInsets.zero,
    children: [
      TransactionDetailsCard(
        rows: [
          _input(_fees, 'Fees paid at disbursement', 'Optional'),
          _switch(
            'Deducted from money received',
            'The lender kept the fee from the loan amount',
            _deducted,
            (v) => _deducted = v,
          ),
        ],
      ),
      const LoanNote('Fees stay separate from the amount you borrowed.'),
    ],
  );

  Widget _lockedReview() {
    final loan = widget.editing!;
    return _body('Review your changes', [
      _overview(loan, loan.unpaidInterestAt(_today)),
    ], caption: 'Only the name, account and reminders can change.');
  }

  static String _termText(int months) => months % 12 == 0
      ? '${months ~/ 12} ${months == 12 ? 'year' : 'years'}'
      : '$months ${months == 1 ? 'month' : 'months'}';

  /// Everything the loan was set up with, in one card. Each fact opens the
  /// step that answers it. Progress reflects principal reduction only, never
  /// total instalments paid.
  Widget _overview(Loan loan, int? interest) {
    final text = Theme.of(context).textTheme;
    final t = loan.terms;
    final repaid = (t.principal - loan.outstanding).clamp(0, t.principal);
    final progress = t.principal > 0 ? repaid / t.principal : 0.0;
    final schedule = loan.schedule;
    final emi = t.mode == LoanRepaymentMode.emi;
    final projected = schedule.isNotEmpty && interest != null;
    final fees = t.chargesMinor;
    final received = _accounts.where((a) => a.id == _receivedIn).firstOrNull;
    final reminderDate = emi
        ? t.firstDue
        : t.interestReminderDate ?? t.maturityDate;

    Widget fact(
      String label,
      String value, {
      _Step? edit,
      String? caption,
      bool emphasized = false,
    }) {
      final editable =
          edit != null &&
          (!_locked || edit == _Step.name || edit == _Step.account);
      return LoanFactTile(
        label: label,
        value: value,
        caption: caption,
        emphasized: emphasized,
        onTap: editable ? () => _editStep(edit) : null,
        tooltip: editable ? 'Change ${label.toLowerCase()}' : null,
      );
    }

    Widget section(String title) => Padding(
      padding: const EdgeInsets.fromLTRB(4, 24, 4, 10),
      child: Text(title, style: text.titleSmall),
    );

    final interestCaption = t.rateKnown && t.rate > 0
        ? [
            switch (t.interestBasis) {
              LoanInterestBasis.remaining => 'Reducing balance',
              LoanInterestBasis.original => 'Flat rate',
              LoanInterestBasis.unknown => 'Calculation unknown',
            },
            if (t.accrual == LoanAccrual.daily) 'daily',
            if (t.compounding == LoanCompounding.monthly) 'compounds monthly',
            if (t.compounding == LoanCompounding.unknown) 'compounding unknown',
            if (t.interestStartsOn != null)
              'from ${loanDate(t.interestStartsOn!)}',
          ].join(' · ')
        : null;
    final openingInterest = t.openingInterest;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        LoanSummaryCard(
          leading: AppIcon(_assetIcon ?? _icon, size: 34),
          title: _name.text.trim(),
          subtitle: _asset.text.trim().isEmpty ? null : _asset.text.trim(),
          amount: _money(t.principal),
          progress: progress,
          repaid: _money(repaid),
          remaining: _money(loan.outstanding),
          onEditName: () => _editStep(_Step.name),
          onEditAmount: _locked ? null : () => _editStep(_Step.amount),
        ),
        section('Loan terms'),
        LoanReviewGrid(
          children: [
            fact(
              'Start date',
              loanDate(t.startDate ?? t.firstDue),
              edit: _Step.term,
            ),
            fact(
              'Duration',
              t.months == 0 ? 'No fixed term' : _termText(t.months),
              edit: _Step.term,
              caption: t.maturityDate == null
                  ? null
                  : 'Ends ${loanDate(t.maturityDate!)}',
            ),
            fact(
              'Interest',
              !t.rateKnown
                  ? 'Unknown'
                  : t.rate == 0
                  ? 'None'
                  : '${loan.rate.toStringAsFixed(loan.rate % 1 == 0 ? 0 : 2)}% a year',
              edit: _Step.interest,
              caption: interestCaption,
            ),
            t.existing
                ? fact(
                    'Balance when added',
                    _money(t.openingBalance),
                    edit: _Step.history,
                    caption: [
                      'As of ${loanDate(t.snapshotDate ?? _start)}',
                      if (openingInterest == null)
                        'interest unknown'
                      else if (openingInterest > 0)
                        '+ ${_money(openingInterest)} interest',
                    ].join(' · '),
                  )
                : fact('Payments so far', 'None', edit: _Step.history),
          ],
        ),
        section('Repayment'),
        LoanReviewGrid(
          children: [
            if (emi) ...[
              fact(
                'Monthly EMI',
                _money(loan.emi),
                edit: _Step.repayment,
                caption: !_locked && _emi.text.trim().isEmpty
                    ? 'App estimate'
                    : null,
              ),
              fact(
                t.existing ? 'Next EMI' : 'First EMI',
                loanDate(loan.nextDue),
                edit: _Step.repayment,
                caption: 'Repeats monthly',
              ),
              fact(
                'EMIs left (est.)',
                schedule.isEmpty ? 'Not available' : '${schedule.length}',
              ),
              if (schedule.isNotEmpty)
                fact('Paid off by (est.)', loanDate(schedule.last.due)),
            ] else ...[
              fact(
                'Payments',
                'Flexible',
                edit: _Step.repayment,
                caption: 'Any amount, any time',
              ),
              fact(
                'Interest reminder',
                t.interestReminderDate == null
                    ? 'Off'
                    : loanDate(t.interestReminderDate!),
                edit: _Step.repayment,
                caption: t.interestReminderDate == null
                    ? null
                    : 'Repeats monthly',
              ),
              fact(
                'Final due date',
                t.maturityDate == null ? 'Not set' : loanDate(t.maturityDate!),
                edit: _Step.term,
              ),
            ],
          ],
        ),
        section('Accounts'),
        LoanReviewGrid(
          children: [
            fact(
              'Repay from',
              _account?.name ?? 'Not set',
              edit: _Step.account,
            ),
            fact(
              'Reminders',
              _remind ? 'On' : 'Off',
              edit: _Step.account,
              caption: !_remind
                  ? null
                  : reminderDate == null
                  ? 'No date set'
                  : '2 days before + on the day',
            ),
            if (!_locked && !t.existing) ...[
              fact(
                'Money received in',
                received?.name ?? 'Not recorded',
                edit: _Step.account,
                caption: received == null
                    ? null
                    : '${_money(t.principal - (t.chargesDeducted ? fees : 0))} added',
              ),
              fact(
                'Fees at start',
                fees == 0 ? 'None' : _money(fees),
                edit: _Step.account,
                caption: fees == 0
                    ? null
                    : t.chargesDeducted
                    ? 'Deducted by lender'
                    : 'Paid from ${_account?.name ?? 'account'}',
              ),
            ],
          ],
        ),
        section('Balance on ${loanDate(_today)}'),
        LoanReviewGrid(
          children: [
            fact(
              'Unpaid interest (est.)',
              interest == null ? 'Unknown' : _money(interest),
            ),
            fact(
              'Total balance',
              interest == null
                  ? 'Unknown'
                  : _money(loan.outstanding + interest),
              emphasized: true,
            ),
            if (projected) ...[
              fact('Future interest (est.)', _money(loan.futureInterest)),
              fact(
                'Total to repay (est.)',
                _money(loan.outstanding + interest + loan.futureInterest),
                emphasized: true,
                caption: 'Excludes fees',
              ),
            ],
          ],
        ),
        if (!projected) ...[
          const SizedBox(height: 4),
          Text(
            t.mode == LoanRepaymentMode.flexible
                ? 'No payoff date. It depends on what you pay.'
                : !t.rateKnown
                ? 'No payoff estimate — the interest rate is unknown.'
                : !t.canEstimate
                ? 'No payoff estimate — the interest calculation isn’t confirmed.'
                : interest == null
                ? 'No payoff estimate — unpaid interest is unknown.'
                : 'No payoff estimate for these loan terms.',
            style: text.bodySmall,
          ),
        ],
      ],
    );
  }
}

/// One answer in a set of mutually exclusive options. A radio mark, not a
/// chevron: choosing it answers the question here rather than opening a page.
class _ChoiceCard extends StatelessWidget {
  const _ChoiceCard({
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.onTap,
  });
  final String title, subtitle;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return Semantics(
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: Material(
        color: selected
            ? Color.alphaBlend(
                colors.primary.withValues(alpha: .08),
                colors.card,
              )
            : colors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(
            color: selected ? colors.primary : colors.outline,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.radio_button_checked_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? colors.primary : colors.muted,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: selected ? colors.primary : colors.text,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        subtitle,
                        style: TextStyle(fontSize: 13, color: colors.muted),
                      ),
                    ],
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
