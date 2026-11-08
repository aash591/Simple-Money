import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart' hide Category;
import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:intl/intl.dart';

import '../../data/repositories/upi_repository.dart';
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
import '../theme/surface_style.dart';
import '../theme/sheet_colors.dart';
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
  String _title = '';
  String _note = '';
  int? _categoryId, _accountId, _toAccountId;
  bool _isTransfer = false;
  PendingUpiPayment? _draft;
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
  }

  @override
  void dispose() {
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
    if (_draft != null) {
      final previous = switch (_step) {
        _Step.amount => _Step.result,
        _Step.categoryReview => _Step.result,
        _Step.category => _Step.categoryReview,
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

  Future<void> _selectRecipient(UpiRecipient recipient) async {
    _recipient = recipient;
    _amount = recipient.amount;
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
            ? 'UPI transfer saved'
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

  Future<void> _editAmount() async {
    if (_busy) return;
    var amount = _amount;
    final edited = await showAdaptiveSheet<String>(
      context,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, update) => AmountPage(
          headerTitle: 'Payment amount',
          recipientLabel: _recipient!.name,
          type: TransactionType.expense,
          amountText: amount,
          digits: 2,
          currency: 'INR',
          onDigit: (digit) =>
              update(() => amount = AmountTyping.digit(amount, digit, 2)),
          onDecimalPoint: () =>
              update(() => amount = AmountTyping.point(amount, 2)),
          onBackspace: () =>
              update(() => amount = AmountTyping.backspace(amount)),
          onClear: () => update(() => amount = ''),
          onBack: () => Navigator.pop(sheetContext),
          onCancel: () => Navigator.pop(sheetContext),
          onContinue: upiAmountMinor(amount) == null
              ? null
              : () => Navigator.pop(sheetContext, amount),
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
    _Step.amount => AmountPage(
      headerTitle: 'Payment amount',
      recipientLabel: _recipient!.name,
      type: TransactionType.expense,
      amountText: _amount,
      digits: 2,
      currency: 'INR',
      onDigit: (digit) =>
          setState(() => _amount = AmountTyping.digit(_amount, digit, 2)),
      onDecimalPoint: () =>
          setState(() => _amount = AmountTyping.point(_amount, 2)),
      onBackspace: () =>
          setState(() => _amount = AmountTyping.backspace(_amount)),
      onClear: () => setState(() => _amount = ''),
      onBack: _back,
      onCancel: _back,
      onContinue: _busy || upiAmountMinor(_amount) == null
          ? null
          : () => _draft == null
                ? _loadApps()
                : _edited(_Step.categoryReview, forward: true),
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
              _edited(_Step.account);
            },
    ),
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
          for (final child in widget.categoryStore.categories.where(
            (c) => c.parentId == parent.id,
          ))
            ChoiceItem(
              value: child.id,
              icon: AppIcon(child.icon, size: 28),
              label: child.name,
              chevron: true,
              indent: true,
            ),
        ],
      ],
      selected: _categoryId,
      onSelected: (id) {
        if (_busy) return;
        _isTransfer = false;
        _categoryId = id;
        _edited(_Step.account, forward: true);
      },
      searchHint: 'Search categories',
      addLabel: 'Add category',
      onAdd: (context) async => (await addCategoryAndSelect(
        context,
        widget.categoryStore,
        CategoryType.expense,
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
                      ? MobileScanner(
                          key: _scannerKey,
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
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                        )
                      : ColoredBox(
                          color: Colors.black87,
                          child: Center(
                            child: !widget.isActive() ||
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
                                          child: const Text('Allow permissions'),
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
