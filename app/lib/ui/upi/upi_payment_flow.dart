import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/upi_repository.dart';
import '../../data/repositories/upi_sms_match.dart';
import '../../data/upi_platform.dart';
import '../../domain/category.dart';
import '../../domain/account.dart';
import '../../domain/transaction.dart';
import '../../domain/upi_payment.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import '../../state/sms_import_store.dart';
import '../../state/transaction_store.dart';
import '../components/action_buttons.dart';
import '../components/confirmation_alert.dart';
import '../components/adaptive_sheet.dart';
import '../components/app_icon.dart';
import '../components/app_toast.dart';
import '../components/choice_list_sheet.dart';
import '../components/transactions/review_pickers.dart';
import '../components/transactions/transaction_review_content.dart';
import '../theme/surface_style.dart';
import '../theme/sheet_colors.dart';
import '../transactions/amount_calculator.dart';
import '../transactions/amount_typing.dart';
import '../transactions/quick_add_helpers.dart';
import '../transactions/transaction_pages.dart';
import '../transactions/transaction_widgets.dart';
import '../welcome/upi_intro.dart';

enum _Step {
  scan,
  amount,
  apps,
  result,
  categoryReview,
  category,
  subcategory,
  account,
  destination,
  accountReview,
  pending,
}

class UpiPaymentFlow extends StatefulWidget {
  const UpiPaymentFlow({
    super.key,
    required this.accountStore,
    required this.categoryStore,
    required this.transactionStore,
    required this.onBack,
    required this.onClose,
    this.platform,
    this.isActive,
    this.reviewPending = false,
  });
  final bool reviewPending;
  final AccountStore accountStore;
  final CategoryStore categoryStore;
  final TransactionStore transactionStore;
  final VoidCallback onBack, onClose;
  final UpiPlatform? platform;
  final bool Function()? isActive;

  @override
  State<UpiPaymentFlow> createState() => _UpiPaymentFlowState();
}

class _UpiPaymentFlowState extends State<UpiPaymentFlow> {
  late final _repository = UpiRepository(
    widget.transactionStore.repository.database,
  );
  late final _platform = widget.platform ?? UpiPlatform();
  var _step = _Step.scan;

  /// Null until asked of Android; the scanner waits for the camera.
  UpiPermissions? _permissions;
  var _forward = true;
  var _busy = false;
  var _loadingPending = true;
  var _directScan = false;
  var _exitAlert = false;
  var _initialReviewLoaded = false;
  String? _error;
  UpiRecipient? _recipient;
  String _amount = '';
  final _calculator = AmountCalculator();
  String _title = '';
  String _note = '';
  int? _categoryId, _accountId, _toAccountId, _subcategoryParentId;
  bool _isTransfer = false;
  PendingUpiPayment? _draft;

  /// The bank's SMS for [_draft] has arrived, so the payment went through:
  /// the flow skips asking and opens the save page with the account the SMS
  /// reports. Closing then leaves things as they are.
  var _smsArrived = false;
  UpiPaymentSms? _bankSms;
  var _checkingSms = false;
  Timer? _smsPoll;
  List<PendingUpiPayment> _pending = [];
  List<UpiApp> _apps = [];

  @override
  void initState() {
    super.initState();
    widget.accountStore.addListener(_storesChanged);
    widget.categoryStore.addListener(_storesChanged);
    _loadPending();
    unawaited(_loadPermissions());
    if (!widget.reviewPending) {
      unawaited(_platform.preparePlace());
      WidgetsBinding.instance.addPostFrameCallback((_) => _showIntro());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AdaptiveSheetRoute.of(context)?.avoidKeyboard = true;
    });
    // The SMS can arrive while the question is on screen, or while the app
    // is still reading the inbox after coming back from Google Pay.
    _smsPoll = Timer.periodic(
      const Duration(seconds: 3),
      (_) => unawaited(_checkBankSms()),
    );
  }

  @override
  void dispose() {
    _smsPoll?.cancel();
    widget.accountStore.removeListener(_storesChanged);
    widget.categoryStore.removeListener(_storesChanged);
    super.dispose();
  }

  void _storesChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _loadPermissions() async {
    final permissions = await _platform.permissions();
    if (mounted) setState(() => _permissions = permissions);
  }

  /// The scanner's own button: nothing is asked until it is pressed.
  Future<void> _allowPermissions() async {
    final permissions = await _platform.requestPermissions();
    if (!mounted) return;
    setState(() => _permissions = permissions);
    if (permissions.location != 'denied') unawaited(_platform.preparePlace());
  }

  /// The first time, the Google Pay intro covers the screen before the scanner.
  Future<void> _showIntro() async {
    try {
      if (await _platform.introSeen() || !mounted) return;
      await Navigator.of(context, rootNavigator: true).push(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => UpiIntroScreen(platform: _platform),
        ),
      );
      await _loadPermissions();
    } catch (_) {
      /* The scanner opens without it. */
    }
  }

  Future<void> _loadPending() async {
    try {
      final payments = await _repository.load();
      if (!mounted) return;
      setState(() {
        _pending = payments;
        _loadingPending = false;
      });
      if (widget.reviewPending &&
          !_initialReviewLoaded &&
          payments.isNotEmpty) {
        _initialReviewLoaded = true;
        _resume(payments.first);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loadingPending = false;
          _error = 'Could not load pending payments. Close and try again.';
        });
      }
    }
  }

  void _go(_Step step, {bool? forward}) {
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _forward = forward ?? step.index > _step.index;
      _step = step;
      _error = null;
    });
    AdaptiveSheetRoute.of(context)?.avoidKeyboard = step != _Step.amount;
    if (step == _Step.scan) _loadPending();
  }

  Future<void> _back() async {
    if (_busy || _exitAlert) return;
    if (_draft != null && _smsArrived) {
      final previous = switch (_step) {
        _Step.categoryReview => _Step.accountReview,
        _Step.category => _Step.categoryReview,
        _Step.subcategory => _Step.category,
        _Step.account => _Step.accountReview,
        _Step.destination => _Step.account,
        _ => null,
      };
      if (previous != null) {
        await _edited(previous);
      } else {
        await _closeMatched();
      }
      return;
    }
    if (_draft != null) {
      final previous = switch (_step) {
        _Step.amount => _Step.result,
        _Step.categoryReview => _Step.result,
        _Step.category => _Step.categoryReview,
        _Step.subcategory => _Step.category,
        _Step.accountReview => _isTransfer ? _Step.destination : _Step.account,
        _Step.destination => _Step.account,
        _Step.account => _Step.categoryReview,
        _ => null,
      };
      if (previous != null) {
        await _edited(previous);
        return;
      }
      _exitAlert = true;
      var reviewNext = false;
      final leave = await showConfirmationAlert(
        context,
        title: 'Review payments later?',
        message:
            'Unsaved payments stay in the queue, even if you close the app.',
        confirmLabel: 'Review later',
        cancelLabel: 'Keep reviewing',
        extraActionLabel: _hasNextPending ? 'Review next' : null,
        onExtraAction: () => reviewNext = true,
        destructive: false,
      );
      _exitAlert = false;
      if (reviewNext && mounted) {
        await _reviewNextPending();
        return;
      }
      if (leave && mounted) widget.onClose();
      return;
    }
    if (_step == _Step.amount) {
      _go(_Step.scan);
      return;
    }
    widget.onBack();
  }

  Category? _categoryOf(int? id) {
    for (final c in widget.categoryStore.categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  void _pickCategory(int id) {
    _isTransfer = false;
    _categoryId = id;
    _edited(_afterCategory, forward: true);
  }

  /// Once the bank SMS has named the account, a category goes straight back
  /// to the save page.
  _Step get _afterCategory =>
      _smsArrived && _account != null ? _Step.accountReview : _Step.account;

  Future<void> _selectRecipient(UpiRecipient recipient) async {
    _recipient = recipient;
    _amount = recipient.amount;
    _calculator.clear();
    _title = '';
    _note = '';
    _draft = null;
    _isTransfer = false;
    _toAccountId = null;
    _directScan = false;
    _categoryId = null;
    _accountId = null;
    _go(upiAmountMinor(_amount) == null ? _Step.amount : _Step.apps);
    setState(() => _busy = true);
    try {
      final remembered = await _repository.remembered(recipient);
      if (!mounted) return;
      _categoryId = remembered.categoryId;
      if (_categoryId == null) unawaited(_suggestCategory(recipient));
      _accountId = remembered.accountId;
      // A title you've typed before for this address wins; failing that, a
      // QR-supplied name worth showing (not "PhonePe Merchant" and the
      // like) is a reasonable starting point.
      _title =
          remembered.title ??
          (recipient.hasMeaningfulName ? recipient.name : '');
      final accounts = widget.accountStore.accounts.where(
        (a) => a.currency == 'INR' && a.digits == 2,
      );
      if (_accountId == null && accounts.length == 1) {
        _accountId = accounts.single.id;
      }
      if (upiAmountMinor(_amount) == null) {
        setState(() => _busy = false);
        _go(_Step.amount, forward: true);
      } else {
        await _loadApps();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not prepare payment. Please try again.';
        });
      }
    }
  }

  /// Trimmed [_title], or null when it's blank — the title is optional.
  static String? _optionalTitle(String text) {
    final trimmed = text.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _persistEdits() async {
    final old = _draft;
    if (old == null) return;
    final next = old.copyWith(
      amountText: _amount,
      isTransfer: _isTransfer,
      toAccountId: _toAccountId,
      categoryId: _categoryId,
      accountId: _accountId,
      title: _optionalTitle(_title),
      note: _note.trim().isEmpty ? null : _note.trim(),
    );
    await _repository.put(next);
    if (_draft?.id == old.id) {
      _draft = next.copyWith(place: _draft?.place);
    }
  }

  Future<void> _loadApps({bool directScan = false}) async {
    _directScan = directScan;
    _go(_Step.apps);
    setState(() => _busy = true);
    List<UpiApp> apps;
    try {
      apps = await _platform.apps();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = 'Could not find UPI apps. Please try again.';
        });
      }
      return;
    }
    if (!mounted) return;
    final exceedsQrLimit = (upiAmountMinor(_amount) ?? 0) > 200000;
    final matched = directScan
        ? apps
        : apps
              .where(
                (app) =>
                    app.canShareQr ||
                    (exceedsQrLimit &&
                        app.packageName ==
                            'com.google.android.apps.nbu.paisa.user'),
              )
              .toList();
    setState(() => _apps = matched);
    if (!directScan && exceedsQrLimit) {
      final proceed = await showConfirmationAlert(
        context,
        title: 'Open Google Pay scanner',
        message: 'Over ₹2,000. Opening Google Pay: tap Scan any QR code and scan the original QR.',
        confirmLabel: 'Open Google Pay',
        cancelLabel: 'Cancel',
        destructive: false,
      );
      if (!mounted) return;
      if (!proceed) {
        setState(() => _busy = false);
        return;
      }
      _directScan = true;
    }
    if (matched.isNotEmpty && !directScan) {
      await _performLaunch(matched.first);
    } else {
      setState(() => _busy = false);
    }
  }

  String _newId() => List.generate(
    16,
    (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  Future<void> _launch(UpiApp app) async {
    if (!_busy) await _performLaunch(app);
  }

  Future<void> _performLaunch(UpiApp app) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final recipient = _recipient!;
      final isNewPayment = _draft == null;
      final uri = _directScan
          ? null
          : (_amount.isEmpty
                ? recipient.rawQr!
                : recipient.paymentUri(_amount));
      final payment = PendingUpiPayment(
        id: _draft?.id ?? _newId(),
        recipient: recipient,
        amountText: _amount,
        categoryId: _categoryId,
        accountId: _accountId,
        date: _draft?.date ?? DateTime.now(),
        place: _draft?.place,
        title: _optionalTitle(_title),
        note: _note.trim().isEmpty ? null : _note.trim(),
      );
      await _repository.put(payment);
      _draft = payment;
      if (isNewPayment) _pending = [payment, ..._pending];
      unawaited(_platform.scheduleReminder(payment.id));
      if (isNewPayment) unawaited(_capturePlace(payment.id));
      if (!mounted) return;
      _go(_Step.result);
      if (_directScan) {
        await _platform.openApp(app);
      } else {
        await _platform.shareQr(app, payload: uri!);
      }
    } catch (_) {
      if (mounted) {
        _go(_Step.apps);
        setState(
          () => _error =
              'Couldn’t open the payment. Your draft is kept. Try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _capturePlace(String id) async {
    try {
      final place = await _platform.paymentPlace();
      if (place == null || place.trim().isEmpty) return;
      await _repository.attachPlace(id, place);
      if (mounted && _draft?.id == id) {
        setState(() => _draft = _draft!.copyWith(place: place));
      }
    } catch (_) {
      /* Place is optional; payment and saving remain available. */
    }
  }

  Category? get _category => widget.categoryStore.categories
      .where((c) => c.id == _categoryId && c.type == CategoryType.expense)
      .firstOrNull;
  Account? get _account => widget.accountStore.accounts
      .where((a) => a.id == _accountId && a.currency == 'INR' && a.digits == 2)
      .firstOrNull;
  Account? get _destination => widget.accountStore.accounts
      .where(
        (a) => a.id == _toAccountId && a.currency == 'INR' && a.digits == 2,
      )
      .firstOrNull;
  bool get _detailsValid =>
      upiAmountMinor(_amount) != null &&
      (_isTransfer
          ? _destination != null && _toAccountId != _accountId
          : _category != null) &&
      widget.accountStore.accounts.any(
        (a) => a.id == _accountId && a.currency == 'INR' && a.digits == 2,
      );
  void _resume(PendingUpiPayment payment) {
    _draft = payment;
    _smsArrived = false;
    _isTransfer = payment.isTransfer;
    _toAccountId = payment.toAccountId;
    _recipient = payment.recipient;
    _amount = payment.amountText.isEmpty
        ? payment.recipient.amount
        : payment.amountText;
    _accountId = payment.accountId;
    _categoryId = payment.categoryId;
    _title = payment.title ?? '';
    _note = payment.note ?? '';
    final accounts = widget.accountStore.accounts.where(
      (a) => a.currency == 'INR' && a.digits == 2,
    );
    if (_accountId == null && accounts.length == 1) {
      _accountId = accounts.single.id;
    }
    _go(_Step.result);
    unawaited(_restoreRemembered(payment));
  }

  Future<void> _restoreRemembered(PendingUpiPayment payment) async {
    try {
      final remembered = await _repository.remembered(payment.recipient);
      if (!mounted || _draft?.id != payment.id) return;
      if (_categoryId == null && remembered.categoryId == null) {
        unawaited(_suggestCategory(payment.recipient));
      }
      setState(() {
        _categoryId ??= remembered.categoryId;
        _accountId ??= remembered.accountId;
        if (_title.trim().isEmpty) {
          final recipient = payment.recipient;
          _title =
              remembered.title ??
              (recipient.hasMeaningfulName ? recipient.name : '');
        }
      });
    } catch (_) {}
    await _checkBankSms();
  }

  /// When the bank's SMS for the payment on screen has come, there's no need
  /// to ask whether it went through: the save page opens with the category
  /// resolved and the account the SMS names, ready to change or save.
  Future<void> _checkBankSms() async {
    final draft = _draft;
    if (draft == null ||
        _smsArrived ||
        _checkingSms ||
        _busy ||
        _exitAlert ||
        _step != _Step.result) {
      return;
    }
    _checkingSms = true;
    try {
      final sms = await _repository.bankSms(
        draft.copyWith(amountText: _amount, isTransfer: _isTransfer),
      );
      if (sms == null ||
          !mounted ||
          _draft?.id != draft.id ||
          _busy ||
          _exitAlert ||
          _step != _Step.result) {
        return;
      }
      _smsArrived = true;
      _bankSms = sms;
      _isTransfer = false;
      if (sms.accountId != null) _accountId = sms.accountId;
      _categoryId ??= sms.categoryId;
      _go(
        upiAmountMinor(_amount) == null ? _Step.amount : _Step.accountReview,
        forward: true,
      );
    } catch (_) {
      // The question stays; answering it works as before.
    } finally {
      _checkingSms = false;
    }
  }

  /// Closing a payment the bank SMS confirmed changes nothing: the expense
  /// the SMS saved, or the SMS waiting for review, stays as it is. Only the
  /// draft (and its reminder) goes, so it isn't asked about again.
  Future<void> _closeMatched() async {
    final draft = _draft;
    if (draft == null || _busy) return;
    setState(() => _busy = true);
    try {
      await _repository.delete(draft.id);
      unawaited(_platform.cancelReminder(draft.id));
    } catch (_) {
      // Left in the queue, it's simply offered again later.
    }
    if (!mounted) return;
    setState(() => _busy = false);
    widget.onClose();
  }

  /// Fills in a first payment to [recipient]'s category by the shared rules:
  /// its name ("MINA MEDICALS" is Pharmacy) and its UPI id. The payment
  /// doesn't wait for the rules to load, and a category chosen by then stays.
  Future<void> _suggestCategory(UpiRecipient recipient) async {
    try {
      final categorizer = await loadBundledCategorizer();
      final category = categorizer.category(
        recipient.hasMeaningfulName ? recipient.name : '',
        widget.categoryStore.categories,
        credit: false,
        detail: recipient.isLegacyPhone ? null : recipient.address,
      );
      if (category == null ||
          !mounted ||
          _categoryId != null ||
          !identical(_recipient, recipient)) {
        return;
      }
      setState(() => _categoryId = category.id);
    } catch (_) {
      // Without the rules the payment simply has no category yet.
    }
  }

  Future<void> _confirm() async {
    if (_busy || _draft == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final matchedSms = await _repository.confirm(
        _draft!.id,
        details: _draft!.copyWith(
          amountText: _amount,
          isTransfer: _isTransfer,
          toAccountId: _toAccountId,
          categoryId: _categoryId,
          accountId: _accountId,
          title: _optionalTitle(_title),
          note: _note.trim().isEmpty ? null : _note.trim(),
        ),
      );
      await Future.wait([
        widget.transactionStore.load(),
        widget.accountStore.load(),
      ]);
      if (!mounted) return;
      unawaited(_platform.cancelReminder(_draft!.id));
      showAppToast(
        context,
        _isTransfer
            ? matchedSms
                  ? 'UPI transfer saved. Matched with your bank SMS.'
                  : 'UPI transfer saved'
            : matchedSms
            ? 'UPI expense saved. Matched with your bank SMS.'
            : 'UPI expense saved',
      );
      await _nextPending();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Couldn’t save. Check the accounts and details, then try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    if (_busy || _exitAlert || _draft == null) return;
    _exitAlert = true;
    final confirmed = await showConfirmationAlert(
      context,
      title: 'Delete this draft?',
      message: 'Deletes this draft for good. Your balance doesn’t change.',
      confirmLabel: 'Yes, delete',
      cancelLabel: 'Cancel',
      confirmFirst: true,
    );
    _exitAlert = false;
    if (!mounted || !confirmed) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _repository.delete(_draft!.id);
      unawaited(_platform.cancelReminder(_draft!.id));
      if (!mounted) return;
      showAppToast(context, 'Payment draft deleted');
      await _nextPending();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not delete this draft. Try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _paymentNotCompleted() async {
    if (_busy || _exitAlert) return;
    _exitAlert = true;
    var keepPending = false;
    var scanDirectly = false;
    var reviewNext = false;
    final delete = await showConfirmationAlert(
      context,
      title: 'Payment not completed',
      content: Builder(
        builder: (alertContext) => Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Keep it if the payment is still processing. Delete it if you didn’t pay. Your balance doesn’t change.',
            ),
            if (!_recipient!.isLegacyPhone) ...[
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () {
                  scanDirectly = true;
                  Navigator.pop(alertContext, false);
                },
                icon: const Icon(Icons.qr_code_scanner_rounded),
                label: const Text('Scan directly in a UPI app'),
              ),
            ],
          ],
        ),
      ),
      cancelLabel: 'Keep pending',
      onCancel: () => keepPending = true,
      extraActionLabel: _hasNextPending ? 'Review next' : null,
      onExtraAction: () => reviewNext = true,
      confirmLabel: 'Delete draft',
    );
    _exitAlert = false;
    if (!mounted) return;
    if (delete) {
      await _delete();
    } else if (reviewNext) {
      await _reviewNextPending();
    } else if (scanDirectly) {
      await _loadApps(directScan: true);
    } else if (keepPending) {
      widget.onClose();
    }
  }

  bool get _hasNextPending =>
      _pending.any((payment) => payment.id != _draft?.id);

  Future<void> _reviewNextPending() async {
    if (_busy || _draft == null) return;
    setState(() => _busy = true);
    try {
      await _persistEdits();
      final payments = await _repository.load();
      if (!mounted) return;
      _pending = payments;
      if (payments.isEmpty) {
        widget.onClose();
        return;
      }
      final index = payments.indexWhere((payment) => payment.id == _draft!.id);
      _resume(payments[(index + 1) % payments.length]);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not load the next payment. Please try again.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _nextPending() async {
    final remaining = await _repository.load();
    if (!mounted) return;
    _pending = remaining;
    if (remaining.isEmpty) {
      widget.onClose();
    } else {
      _resume(remaining.first);
    }
  }

  Future<void> _edited(_Step next, {bool? forward}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _persistEdits();
      if (mounted) _go(next, forward: forward);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save changes. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _paymentDateLabel(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (DateUtils.isSameDay(date, today)) return 'Today';
    final yesterday = DateTime(today.year, today.month, today.day - 1);
    if (DateUtils.isSameDay(date, yesterday)) return 'Yesterday';
    return DateFormat('d MMM yyyy').format(date);
  }

  /// The amount keypad page, identical to add-transaction's (calculator
  /// included). [onContinue] receives the final, calculated amount.
  Widget _amountPage({
    required AmountCalculator calculator,
    required String amount,
    required void Function(VoidCallback) update,
    required void Function(String) setAmount,
    required VoidCallback onBack,
    required VoidCallback onCancel,
    required void Function(String amount)? onContinue,
  }) {
    void edit(String Function(String) change) =>
        update(() => setAmount(change(amount)));
    VoidCallback? continueAction;
    if (onContinue != null &&
        (upiAmountMinor(amount) != null || calculator.operation != null)) {
      continueAction = () {
        var result = amount;
        update(() {
          result = calculator.press('=', amount, 2);
          setAmount(result);
        });
        if (calculator.error == null && upiAmountMinor(result) != null) {
          onContinue(result);
        }
      };
    }
    return AmountPage(
      headerTitle: 'Payment amount',
      recipientLabel: _recipient!.name,
      type: TransactionType.expense,
      amountText: amount,
      calculatedAmount: calculator.resultFor(amount, 2),
      digits: 2,
      currency: 'INR',
      onDigit: (d) => edit((a) => calculator.digit(a, d, 2)),
      onDecimalPoint: () => edit((a) => calculator.point(a, 2)),
      onBackspace: () => edit((a) => calculator.backspace(a, 2)),
      onClear: () => update(() {
        calculator.clear();
        setAmount('');
      }),
      onOperation: (k) => edit((a) => calculator.press(k, a, 2)),
      replaceAmount: calculator.replace,
      decimalAllowed: calculator.enteringPercent
          ? calculator.percentDecimalEnabled
          : null,
      calculatorStatus: calculator.error ?? calculator.expressionFor(amount),
      onBack: onBack,
      onCancel: onCancel,
      onContinue: continueAction,
    );
  }

  Future<void> _editAmount() async {
    if (_busy) return;
    var amount = _amount;
    final calculator = AmountCalculator();
    final edited = await showAdaptiveSheet<String>(
      context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) => _amountPage(
          calculator: calculator,
          amount: amount,
          update: update,
          setAmount: (v) => amount = v,
          onBack: () => Navigator.pop(sheetContext),
          onCancel: () => Navigator.pop(sheetContext),
          onContinue: (value) => Navigator.pop(sheetContext, value),
        ),
      ),
    );
    if (!mounted || edited == null) return;
    setState(() {
      _amount = edited;
      _busy = true;
    });
    try {
      await _persistEdits();
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save the amount. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _paymentReviewCard() {
    final colors = SheetColors.of(context);
    final date = _draft?.date.toLocal();
    return SheetCard(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'PAYMENT AMOUNT',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.2,
                color: colors.muted,
              ),
            ),
            const SizedBox(height: 8),
            Semantics(
              button: true,
              label: 'Edit payment amount',
              child: InkWell(
                onTap: _busy ? null : _editAmount,
                borderRadius: BorderRadius.circular(16),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    children: [
                      Text(
                        upiAmountMinor(_amount) == null
                            ? 'Add amount'
                            : AmountTyping.display(
                                _amount,
                                currency: 'INR',
                                decimals: 2,
                              ),
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 38,
                          height: 1.15,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -1,
                          color: colors.text,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.edit_outlined,
                            size: 14,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              'Tap to edit amount',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 12,
                                color: colors.primary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              _recipient!.name,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                height: 1.25,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
            if (_recipient!.name != _recipient!.address) ...[
              const SizedBox(height: 6),
              Text(
                _recipient!.address,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  color: colors.muted,
                ),
              ),
            ],
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Divider(height: 1, color: colors.divider),
            ),
            if (date != null)
              Text(
                '${_paymentDateLabel(date)} · ${DateFormat('h:mm a').format(date)}',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: colors.primary,
                ),
              ),
            if (_draft?.place != null) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.place_outlined, size: 16, color: colors.muted),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      'Near ${_draft!.place}',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 12,
                        height: 1.4,
                        color: colors.muted,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _paymentContext({bool showAmount = false}) {
    final date = _draft?.date.toLocal();
    final content = Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Text(
            _recipient!.name,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          if (_recipient!.name != _recipient!.address) ...[
            const SizedBox(height: 4),
            Text(
              _recipient!.address,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 18),
          if (date != null)
            Text(
              '${_paymentDateLabel(date)} · ${DateFormat('h:mm a').format(date)}',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
          if (_draft?.place != null) ...[
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.place_outlined, size: 18),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Near ${_draft!.place}',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ],
          if (showAmount) ...[
            const SizedBox(height: 18),
            InkWell(
              onTap: _busy ? null : _editAmount,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Text(
                  upiAmountMinor(_amount) == null
                      ? 'Add amount'
                      : AmountTyping.display(
                          _amount,
                          currency: 'INR',
                          decimals: 2,
                        ),
                  style: Theme.of(context).textTheme.headlineMedium,
                ),
              ),
            ),
          ],
        ],
      ),
    );
    return SheetCard(child: content);
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: false,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _back();
    },
    child: StepSlider(stepKey: _step, forward: _forward, child: _page()),
  );
  Widget _page() => switch (_step) {
    _Step.scan when widget.reviewPending && !_initialReviewLoaded => _simple(
      'Loading pending payments',
      [if (_loadingPending) const Center(child: CircularProgressIndicator())],
      primary: _loadingPending ? null : 'Try again',
      onPrimary: _loadPending,
    ),
    _Step.scan => _ScanPage(
      isActive: () =>
          mounted && _step == _Step.scan && (widget.isActive?.call() ?? true),
      onBack: _back,
      onRecipient: _selectRecipient,
      pendingCount: _pending.length,
      cameraAllowed: _permissions?.camera,
      onAllowCamera: _allowPermissions,
      loadingPending: _loadingPending,
      error: _error,
      onPending: () {
        _go(_Step.pending);
        _loadPending();
      },
    ),
    _Step.amount => _amountPage(
      calculator: _calculator,
      amount: _amount,
      update: setState,
      setAmount: (v) => _amount = v,
      onBack: _back,
      onCancel: _back,
      onContinue: _busy
          ? null
          : (amount) {
              if (_draft == null) {
                _loadApps();
              } else {
                _edited(
                  _smsArrived ? _Step.accountReview : _Step.categoryReview,
                  forward: true,
                );
              }
            },
    ),
    _Step.categoryReview => _simple(
      'Expense category',
      [
        _paymentContext(showAmount: true),
        const SizedBox(height: appCardGap),
        TransactionDetailsCard(
          rows: [
            TransactionDetailRow(
              leading: SheetIconTile(
                child: _category == null
                    ? const Icon(Icons.category_outlined)
                    : AppIcon(_category!.icon, size: 28),
              ),
              label: 'Category',
              value: _category?.name ?? 'Choose category',
              placeholder: _category == null,
              caption: _category == null ? null : 'Tap to change',
              onTap: _busy ? null : () => _go(_Step.category),
            ),
          ],
        ),
        const SizedBox(height: appCardGap),
        SheetCard(
          child: ListTile(
            leading: const Icon(Icons.swap_horiz_rounded),
            title: const Text('Transfer between accounts'),
            subtitle: const Text('Mark this payment as a transfer'),
            trailing: const Icon(Icons.chevron_right_rounded),
            onTap: _busy
                ? null
                : () {
                    _isTransfer = true;
                    _edited(_Step.account, forward: true);
                  },
          ),
        ),
      ],
      primary: 'Next',
      onPrimary: _category == null
          ? null
          : () {
              _isTransfer = false;
              _edited(_afterCategory);
            },
    ),
    _Step.accountReview when _smsArrived => _smsReviewPage(),
    _Step.accountReview => _simple(
      _isTransfer ? 'Save this transfer' : 'Save this expense',
      [
        _paymentContext(showAmount: true),
        const SizedBox(height: appCardGap),
        TransactionDetailsCard(
          rows: [
            TransactionTextRow(
              icon: Icons.edit_outlined,
              label: 'Title',
              hintText: 'Add a title',
              initialValue: _title,
              maxLength: 50,
              enabled: !_busy,
              onChanged: (text) => _title = text,
              suggestions: (text) =>
                  widget.transactionStore.titleSuggestions.suggest(
                    text,
                    type: TransactionType.expense,
                    categoryId: _categoryId,
                  ),
            ),
            if (!_isTransfer)
              TransactionDetailRow(
                leading: SheetIconTile(
                  child: _category == null
                      ? const Icon(Icons.category_outlined)
                      : AppIcon(_category!.icon, size: 28),
                ),
                label: 'Category',
                value: _category?.name ?? 'Choose category',
                onTap: _busy ? null : () => _go(_Step.categoryReview),
              ),
            TransactionDetailRow(
              leading: SheetIconTile(
                child: _account == null
                    ? const Icon(Icons.account_balance_wallet_outlined)
                    : AppIcon(_account!.icon, size: 28),
              ),
              label: _isTransfer ? 'From account' : 'Paid from',
              value: _account?.name ?? 'Choose INR account',
              onTap: _busy ? null : () => _go(_Step.account),
            ),
            if (_isTransfer)
              TransactionDetailRow(
                leading: SheetIconTile(
                  child: _destination == null
                      ? const Icon(Icons.account_balance_wallet_outlined)
                      : AppIcon(_destination!.icon, size: 28),
                ),
                label: 'To account',
                value: _destination?.name ?? 'Choose destination account',
                onTap: _busy ? null : () => _go(_Step.destination),
              ),
            TransactionTextRow(
              icon: Icons.notes_rounded,
              label: 'Note',
              hintText: 'Add a note',
              initialValue: _note,
              maxLength: 200,
              multiline: true,
              enabled: !_busy,
              onChanged: (text) => _note = text,
            ),
          ],
        ),
      ],
      primary: _isTransfer ? 'Save transfer' : 'Save expense',
      onPrimary: _detailsValid ? _confirm : null,
    ),
    _Step.category => ChoicePickerPage<int>(
      header: SheetHeader.flow('Pay with UPI', onBack: _back),
      heading: 'Choose expense category',
      items: [
        for (final parent in widget.categoryStore.categories.where(
          (c) => c.type == CategoryType.expense && c.parentId == null,
        )) ...[
          ChoiceItem(
            value: parent.id,
            icon: AppIcon(parent.icon, size: 28),
            label: parent.name,
            chevron: true,
          ),
          // Subcategories show only while searching (e.g. "fuel").
          for (final child in widget.categoryStore.categories.where(
            (c) => c.parentId == parent.id,
          ))
            ChoiceItem(
              value: child.id,
              icon: AppIcon(child.icon, size: 28),
              label: child.name,
              chevron: true,
              indent: true,
              searchOnly: true,
            ),
        ],
      ],
      selected: null,
      onSelected: (id) {
        if (_busy) return;
        final category = _categoryOf(id);
        if (category == null) return;
        if (category.parentId != null) {
          _pickCategory(id);
          return;
        }
        _subcategoryParentId = id;
        _go(_Step.subcategory);
      },
      searchHint: 'Search categories',
      addLabel: 'Add category',
      onAdd: (context) async => (await addCategoryAndSelect(
        context,
        widget.categoryStore,
        CategoryType.expense,
      ))?.id,
    ),
    _Step.subcategory => ChoicePickerPage<int>(
      header: SheetHeader.flow('Pay with UPI', onBack: _back),
      heading: 'Choose subcategory',
      items: [
        if (_categoryOf(_subcategoryParentId) case final parent?)
          ChoiceItem(
            value: parent.id,
            icon: AppIcon(parent.icon, size: 28),
            label: 'Use ${parent.name} only',
            chevron: true,
          ),
        for (final child in widget.categoryStore.categories.where(
          (c) => c.parentId == _subcategoryParentId,
        ))
          ChoiceItem(
            value: child.id,
            icon: AppIcon(child.icon, size: 28),
            label: child.name,
            chevron: true,
          ),
      ],
      selected: null,
      onSelected: (id) {
        if (_busy) return;
        _pickCategory(id);
      },
      searchHint: 'Search subcategories',
      addLabel: 'Add subcategory',
      onAdd: (context) async => (await addCategoryAndSelect(
        context,
        widget.categoryStore,
        CategoryType.expense,
        parentId: _subcategoryParentId,
      ))?.id,
    ),
    _Step.account => ChoicePickerPage<int>(
      header: SheetHeader.flow('Pay with UPI', onBack: _back),
      heading: _isTransfer ? 'From account' : 'Record expense in',
      items: [
        for (final account in widget.accountStore.accounts.where(
          (a) => a.currency == 'INR' && a.digits == 2,
        ))
          ChoiceItem(
            value: account.id,
            icon: AppIcon(account.icon, size: 28),
            label: account.name,
            chevron: true,
          ),
      ],
      selected: null,
      onSelected: (id) {
        if (_busy) return;
        _accountId = id;
        if (_toAccountId == id) _toAccountId = null;
        _edited(
          _isTransfer ? _Step.destination : _Step.accountReview,
          forward: true,
        );
      },
      searchHint: 'Search INR accounts',
      addLabel: 'Add INR account',
      onAdd: (context) async {
        final account = await addAccountAndSelect(context, widget.accountStore);
        return account?.currency == 'INR' && account?.digits == 2
            ? account?.id
            : null;
      },
    ),
    _Step.destination => ChoicePickerPage<int>(
      header: SheetHeader.flow('Pay with UPI', onBack: _back),
      heading: 'To account',
      items: [
        for (final account in widget.accountStore.accounts.where(
          (a) => a.currency == 'INR' && a.digits == 2 && a.id != _accountId,
        ))
          ChoiceItem(
            value: account.id,
            icon: AppIcon(account.icon, size: 28),
            label: account.name,
            chevron: true,
          ),
      ],
      selected: null,
      onSelected: (id) {
        if (_busy) return;
        _toAccountId = id;
        _edited(_Step.accountReview, forward: true);
      },
      searchHint: 'Search INR accounts',
      addLabel: 'Add INR account',
      onAdd: (context) async {
        final account = await addAccountAndSelect(context, widget.accountStore);
        return account?.currency == 'INR' && account?.digits == 2
            ? account?.id
            : null;
      },
    ),
    _Step.apps => _simple(
      _directScan ? 'Scan in your UPI app' : 'Opening Google Pay',
      [
        _recipientCard(),
        Text('₹$_amount', style: Theme.of(context).textTheme.headlineMedium),
        const Text('Pay in Google Pay, then come back to save it.'),
        if (_directScan)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Open an app below and scan the original QR. Enter the amount shown. Your draft stays here.',
            ),
          ),
        if (!_directScan)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 12),
            child: Text(
              'Sending the QR to Google Pay. Check the name and amount there, then come back.',
            ),
          ),
        if (!_directScan && (upiAmountMinor(_amount) ?? 0) > 200000)
          const Text(
            'Google Pay allows gallery QR payments up to ₹2,000. If it’s rejected, scan the original QR in the app.',
          ),
        if (_busy) const Center(child: CircularProgressIndicator()),
        if (!_busy && _apps.isEmpty) ...[
          Padding(
            padding: EdgeInsets.symmetric(vertical: 20),
            child: Text(
              _directScan
                  ? 'No UPI app found. Install and set one up, then try again.'
                  : 'Can’t share to Google Pay. Install or update it, or scan in a UPI app.',
            ),
          ),
          TextButton(
            onPressed: () => _loadApps(directScan: _directScan),
            child: const Text('Refresh apps'),
          ),
        ],
        if (_directScan)
          for (final app in _apps)
            ListTile(
              leading: app.icon == null
                  ? const Icon(Icons.account_balance_wallet_outlined)
                  : Image.memory(app.icon!, width: 40, height: 40),
              title: Text(app.name),
              trailing: const Icon(Icons.chevron_right),
              onTap: _busy ? null : () => _launch(app),
            ),

        if (_draft != null)
          TextButton(
            onPressed: _busy ? null : () => _go(_Step.result),
            child: const Text('Review payment'),
          ),
        if (!_directScan)
          TextButton.icon(
            onPressed: _busy ? null : () => _loadApps(directScan: true),
            icon: const Icon(Icons.qr_code_scanner),
            label: const Text('Scan directly in a UPI app instead'),
          ),
      ],
    ),
    _Step.result => _simple(
      'Is the payment completed?',
      [
        _paymentReviewCard(),
        if (_pending.length > 1)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Text(
              '${_pending.indexWhere((payment) => payment.id == _draft?.id) + 1} / ${_pending.length} payments to review',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        const SizedBox(height: 20),
        Center(
          child: TextButton(
            onPressed: _busy ? null : widget.onClose,
            child: const Text('Review later'),
          ),
        ),
        Center(
          child: TextButton.icon(
            onPressed: _busy
                ? null
                : () {
                    _draft = null;
                    _go(_Step.scan);
                  },
            icon: const Icon(Icons.qr_code_scanner_rounded, size: 18),
            label: const Text('Scan another QR'),
          ),
        ),
      ],
      primary: 'Yes',
      onPrimary: () => _go(
        upiAmountMinor(_amount) == null ? _Step.amount : _Step.categoryReview,
        forward: true,
      ),
      secondary: 'No',
      onSecondary: _paymentNotCompleted,
    ),
    _Step.pending => _simple('Pending UPI payments', [
      if (_loadingPending) const Center(child: CircularProgressIndicator()),
      if (!_loadingPending && _pending.isEmpty)
        const Text('No pending payments.'),
      for (final payment in _pending)
        ListTile(
          leading: const Icon(Icons.schedule),
          title: Text(payment.recipient.name),
          subtitle: Text(
            '${payment.recipient.address}\n₹${payment.amountText}',
          ),
          isThreeLine: true,
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _resume(payment),
        ),
    ]),
  };

  Iterable<Account> get _inrAccounts => widget.accountStore.accounts.where(
    (a) => a.currency == 'INR' && a.digits == 2 && a.archivedAt == null,
  );

  Future<void> _smsPickCategory() async {
    final pick = await showReviewCategoryPicker(
      context,
      title: 'Pay with UPI',
      categories: widget.categoryStore.categories,
      store: widget.categoryStore,
      type: CategoryType.expense,
      selected: _categoryId,
      shortcuts: const CategoryShortcuts(transfer: true),
    );
    if (!mounted || pick == null) return;
    setState(() {
      if (pick.transfer) {
        _isTransfer = true;
      } else if (pick.categoryId case final id?) {
        _categoryId = id;
      }
    });
  }

  Future<void> _smsPickAccount({bool destination = false}) async {
    final id = await showReviewAccountPicker(
      context,
      title: 'Pay with UPI',
      heading: destination
          ? 'Transferred to'
          : _isTransfer
          ? 'Transferred from'
          : 'Paid from',
      selected: destination ? _toAccountId : _accountId,
      items: [
        for (final a in _inrAccounts)
          if (!_isTransfer || a.id != (destination ? _accountId : _toAccountId))
            ChoiceItem(
              value: a.id,
              icon: AppIcon(a.icon, size: 28),
              label: a.name,
              subtitle: formatTransactionMoney(a.balanceMinor, a),
              chevron: true,
            ),
      ],
      onAdd: (context) async {
        final account = await addAccountAndSelect(context, widget.accountStore);
        return account?.currency == 'INR' && account?.digits == 2
            ? account?.id
            : null;
      },
    );
    if (!mounted || id == null) return;
    setState(() => destination ? _toAccountId = id : _accountId = id);
  }

  /// The payment once its bank SMS has come, laid out like the SMS preview:
  /// it is one payment, so Save records one transaction and Cancel changes
  /// nothing.
  Widget _smsReviewPage() {
    final colors = SheetColors.of(context);
    final sms = _bankSms;
    final date = _draft?.date.toLocal() ?? DateTime.now();
    final place = _draft?.place;
    return SheetPage(
      header: SheetHeader.flow('Pay with UPI', onBack: _busy ? null : _back),
      body: TransactionReviewContent<bool>(
        badge: 'Money paid',
        color: Colors.red,
        badgeIcon: Icons.north_east_rounded,
        amount: upiAmountMinor(_amount) == null
            ? 'Add amount'
            : formatAccountMoney(
                upiAmountMinor(_amount)!,
                currency: 'INR',
                digits: 2,
              ),
        onEditAmount: _busy ? null : _editAmount,
        title: _title.trim().isEmpty ? _recipient!.name : _title,
        titleText: _isTransfer ? null : _title,
        onTitleChanged: _busy || _isTransfer ? null : (text) => _title = text,
        titleSuggestions: (text) =>
            widget.transactionStore.titleSuggestions.suggest(
              text,
              type: TransactionType.expense,
              categoryId: _categoryId,
            ),
        date:
            '${formatTransactionDate(date)} · ${DateFormat('h:mm a').format(date)}',
        kinds: const [
          ReviewKind(false, 'Expense', Icons.category_outlined),
          ReviewKind(true, 'Transfer', Icons.swap_horiz),
        ],
        kind: _isTransfer,
        onKindChanged: _busy
            ? null
            : (value) => setState(() {
                _isTransfer = value;
                if (_toAccountId == _accountId) _toAccountId = null;
              }),
        helper: [
          'Paid to ${_recipient!.address}. Your bank’s SMS confirmed it.',
          if (place != null) 'Near $place.',
        ].join(' '),
        rows: [
          if (!_isTransfer) ...[
            ReviewChoiceRow(
              label: 'Category',
              value: _category?.name ?? 'Choose category',
              icon: AppIcon(_category?.icon, size: 30),
              onTap: _busy ? null : _smsPickCategory,
            ),
            Divider(height: 1, indent: 64, color: colors.divider),
          ],
          ReviewChoiceRow(
            label: _isTransfer ? 'Transferred from' : 'Paid from',
            value: _account?.name ?? 'Choose INR account',
            icon: AppIcon(_account?.icon ?? 'bank_transfer', size: 30),
            onTap: _busy ? null : () => _smsPickAccount(),
          ),
          if (_isTransfer) ...[
            Divider(height: 1, indent: 64, color: colors.divider),
            ReviewChoiceRow(
              label: 'Transferred to',
              value: _destination?.name ?? 'Choose INR account',
              icon: AppIcon(_destination?.icon ?? 'bank_transfer', size: 30),
              onTap: _busy ? null : () => _smsPickAccount(destination: true),
            ),
          ],
        ],
        sourceDetail: sms == null || sms.sender.trim().isEmpty
            ? null
            : sms.sender,
        sourceText: sms?.text,
        error: _error,
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: _busy ? null : _closeMatched,
        primaryLabel: _busy ? 'Saving...' : 'Save',
        onPrimary: _detailsValid && !_busy ? _confirm : null,
      ),
    );
  }

  Widget _recipientCard() => Padding(
    padding: const EdgeInsets.symmetric(vertical: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(_recipient!.name, style: Theme.of(context).textTheme.titleLarge),
        if (_recipient!.name != _recipient!.address) Text(_recipient!.address),
        if (!_recipient!.isLegacyPhone)
          const Text('Verify the recipient name in your UPI app.'),
      ],
    ),
  );

  Widget _simple(
    String title,
    List<Widget> children, {
    String? primary,
    VoidCallback? onPrimary,
    String? secondary,
    VoidCallback? onSecondary,
  }) => SheetPage(
    header: SheetHeader.flow('Pay with UPI', onBack: _busy ? null : _back),
    body: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SheetStepHeading(title),
        const SizedBox(height: 14),
        ...children,
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
    actions: primary == null && secondary == null
        ? null
        : ActionButtonBar(
            primaryLabel: _busy ? 'Please wait…' : primary,
            onPrimary: _busy ? null : onPrimary,
            secondaryLabel: secondary,
            onSecondary: _busy ? null : onSecondary,
          ),
  );
}

/// Zoom factor shown at full zoom; the camera's real range varies by phone.
const _maxZoomFactor = 5.0;

/// A camera-style lens ruler: drag it sideways and the ticks slide under a
/// fixed marker while the zoom factor shows above.
class _ZoomDial extends StatelessWidget {
  const _ZoomDial({required this.zoom, required this.onChanged});
  final double zoom;
  final ValueChanged<double> onChanged;

  static const _tickGap = 8.0;
  static const _factorPerTick = 0.1;

  @override
  Widget build(BuildContext context) {
    final factor = 1 + zoom * (_maxZoomFactor - 1);
    return Center(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (d) {
          // Each pixel moves the zoom three times as far as the ticks slide.
          final next = factor - d.delta.dx * 3 / _tickGap * _factorPerTick;
          onChanged((next - 1) / (_maxZoomFactor - 1));
        },
        child: SizedBox(
          width: 160,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${factor.toStringAsFixed(1)}x',
                style: const TextStyle(
                  color: Color(0xFFFFD60A),
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              ShaderMask(
                blendMode: BlendMode.dstIn,
                shaderCallback: (rect) => const LinearGradient(
                  colors: [
                    Colors.transparent,
                    Colors.black,
                    Colors.black,
                    Colors.transparent,
                  ],
                  stops: [0, 0.3, 0.7, 1],
                ).createShader(rect),
                child: SizedBox(
                  height: 36,
                  width: double.infinity,
                  child: CustomPaint(painter: _RulerPainter(factor)),
                ),
              ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }
}

class _RulerPainter extends CustomPainter {
  _RulerPainter(this.factor);
  final double factor;

  @override
  void paint(Canvas canvas, Size size) {
    const gap = _ZoomDial._tickGap, step = _ZoomDial._factorPerTick;
    final centre = size.width / 2;
    final half = centre / gap * step;
    final paint = Paint()..strokeWidth = 1.5;
    for (
      var i = ((factor - half) / step).floor();
      i <= ((factor + half) / step).ceil();
      i++
    ) {
      final value = i * step;
      if (value < 1 - 1e-9 || value > _maxZoomFactor + 1e-9) continue;
      final x = centre + (value - factor) / step * gap;
      final major = i % 10 == 0;
      paint.color = major ? Colors.white : Colors.white70;
      canvas.drawLine(
        Offset(x, size.height * (major ? 0.15 : 0.3)),
        Offset(x, size.height * (major ? 0.85 : 0.7)),
        paint,
      );
    }
    canvas.drawLine(
      Offset(centre, 0),
      Offset(centre, size.height),
      Paint()
        ..color = const Color(0xFFFFD60A)
        ..strokeWidth = 2.5,
    );
  }

  @override
  bool shouldRepaint(_RulerPainter old) => old.factor != factor;
}

class _ScanPage extends StatefulWidget {
  const _ScanPage({
    required this.isActive,
    required this.onBack,
    required this.onRecipient,
    required this.pendingCount,
    required this.cameraAllowed,
    required this.onAllowCamera,
    required this.onPending,
    required this.loadingPending,
    this.error,
  });
  final VoidCallback onBack, onPending, onAllowCamera;

  /// Null while it is being checked.
  final bool? cameraAllowed;
  final bool Function() isActive;
  final ValueChanged<UpiRecipient> onRecipient;
  final int pendingCount;
  final bool loadingPending;
  final String? error;

  @override
  State<_ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<_ScanPage> {
  String? _error;
  bool _detected = false;
  final _scannerKey = GlobalKey();
  final _controller = MobileScannerController();

  /// Camera zoom from 0 (none) to 1 (maximum), driven by pinching.
  double _zoom = 0, _zoomAtStart = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _pinch(ScaleUpdateDetails details) {
    if (details.pointerCount < 2) return;
    _setZoom(_zoomAtStart + (details.scale - 1) * 1.5);
  }

  void _setZoom(double value) {
    final zoom = value.clamp(0.0, 1.0);
    if ((zoom - _zoom).abs() < 0.002) return;
    setState(() => _zoom = zoom);
    unawaited(_controller.setZoomScale(zoom).catchError((_) {}));
  }

  void _scan(BarcodeCapture capture) {
    if (_detected || !widget.isActive()) return;
    for (final barcode in capture.barcodes) {
      final text = barcode.rawValue;
      if (text == null) continue;
      try {
        final recipient = UpiRecipient.parse(text);
        _detected = true;
        widget.onRecipient(recipient);
        return;
      } on FormatException catch (error) {
        setState(() => _error = error.message);
      }
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      return SizedBox(
        height: constraints.maxHeight,
        child: Column(
          children: [
            SheetHeader.flow('Pay with UPI', onBack: widget.onBack),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 4, 16, 16),
              child: SheetStepHeading('Scan a UPI QR code'),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(24),
                  child:
                      widget.isActive() &&
                          widget.cameraAllowed == true &&
                          !kIsWeb &&
                          defaultTargetPlatform == TargetPlatform.android
                      ? GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onScaleStart: (_) => _zoomAtStart = _zoom,
                          onScaleUpdate: _pinch,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              MobileScanner(
                                key: _scannerKey,
                                controller: _controller,
                                onDetect: _scan,
                                errorBuilder: (context, error) => ColoredBox(
                                  color: Colors.black87,
                                  child: Center(
                                    child: Padding(
                                      padding: const EdgeInsets.all(24),
                                      child: Text(
                                        error.errorCode ==
                                                MobileScannerErrorCode
                                                    .permissionDenied
                                            ? 'Allow camera access in Settings to scan a UPI QR code.'
                                            : 'Camera unavailable. Check camera access in Settings and reopen this scanner.',
                                        textAlign: TextAlign.center,
                                        style: const TextStyle(
                                          color: Colors.white,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: _ZoomDial(
                                  zoom: _zoom,
                                  onChanged: _setZoom,
                                ),
                              ),
                            ],
                          ),
                        )
                      : ColoredBox(
                          color: Colors.black87,
                          child: Center(
                            child:
                                !widget.isActive() ||
                                    widget.cameraAllowed == null
                                ? const SizedBox.shrink()
                                : widget.cameraAllowed == false
                                ? Padding(
                                    padding: const EdgeInsets.all(24),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        const Text(
                                          'Allow the camera to scan a UPI QR code. If nothing appears, allow Camera in Android Settings.',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(color: Colors.white),
                                        ),
                                        const SizedBox(height: 16),
                                        FilledButton(
                                          onPressed: widget.onAllowCamera,
                                          child: const Text(
                                            'Allow permissions',
                                          ),
                                        ),
                                      ],
                                    ),
                                  )
                                : const Text(
                                    'UPI scanning is available on Android.',
                                    style: TextStyle(color: Colors.white),
                                  ),
                          ),
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                _error ?? widget.error ?? 'Scan to open Google Pay. Add payment details when you return.',
                textAlign: TextAlign.center,
                style: _error != null || widget.error != null
                    ? TextStyle(color: Theme.of(context).colorScheme.error)
                    : null,
              ),
            ),
            if (widget.pendingCount > 0)
              TextButton.icon(
                onPressed: widget.onPending,
                icon: const Icon(Icons.schedule),
                label: Text('Pending UPI payments (${widget.pendingCount})'),
              ),
            ActionButtonBar(secondaryLabel: 'Back', onSecondary: widget.onBack),
          ],
        ),
      );
    },
  );
}
