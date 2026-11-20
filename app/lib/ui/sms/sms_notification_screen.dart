import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../../data/db/app_database.dart';
import '../../data/realtime_sms.dart';
import '../../data/repositories/account_repository.dart';
import '../../data/repositories/category_repository.dart';
import '../../data/repositories/realtime_sms_repository.dart';
import '../../domain/account.dart';
import '../../domain/category.dart';
import '../../state/security_controller.dart';
import '../components/app_icon.dart';
import '../components/adaptive_sheet.dart';
import '../components/choice_list_sheet.dart';
import '../components/confirmation_alert.dart';
import '../transactions/quick_add_helpers.dart';
import '../transactions/transaction_widgets.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import 'sms_notification_preview.dart';
import '../components/native_modal_blur.dart';
import '../../domain/currency_digits.dart';

/// Transparent activity host, just like launcher Add Transaction.
class SmsNotificationScreen extends StatefulWidget {
  const SmsNotificationScreen({
    super.key,
    required this.database,
    required this.id,
    required this.field,
  });
  final AppDatabase database;
  final String id, field;
  @override
  State<SmsNotificationScreen> createState() => _SmsNotificationHostState();
}

class _SmsNotificationHostState extends State<SmsNotificationScreen> {
  @override
  void initState() {
    super.initState();
    NativeModalBlur.enabled = true;
  }

  @override
  void dispose() {
    NativeModalBlur.enabled = false;
    super.dispose();
  }

  bool opened = false;
  Future<void> open() async {
    if (!mounted) return;
    final security = SecurityScope.of(context);
    if (!security.ready || security.covered) {
      opened = false;
      return;
    }
    // The preview opens exactly like the bank-SMS review modal.
    await (widget.field == 'transaction'
        ? showAdaptiveSheet<void>(
            context,
            entrance: SheetEntrance.fadeRise,
            dismissible: false,
            topClearance: 62,
            builder: (_) => SmsNotificationPreview(
              database: widget.database,
              id: widget.id,
            ),
          )
        : showAdaptiveSheet<void>(
            context,
            entrance: SheetEntrance.fadeRise,
            maxHeightFactor: .85,
            builder: (_) => SmsNotificationPicker(
              database: widget.database,
              id: widget.id,
              field: widget.field,
            ),
          ));
    if (mounted) await SystemNavigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final security = SecurityScope.of(context);
    if (!opened && security.ready && !security.covered) {
      opened = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => open());
    }
    // See-through like the launcher's quick entry: the app or home screen
    // behind shows (blurred), never the theme's solid background.
    return widget.field == 'transaction'
        ? const Scaffold(
            backgroundColor: Colors.transparent,
            body: SizedBox.expand(),
          )
        : const SizedBox.expand();
  }
}

class SmsNotificationPicker extends StatefulWidget {
  const SmsNotificationPicker({
    super.key,
    required this.database,
    required this.id,
    required this.field,
  });
  final AppDatabase database;
  final String id, field;
  @override
  State<SmsNotificationPicker> createState() => _SmsNotificationScreenState();
}

class _SmsNotificationScreenState extends State<SmsNotificationPicker> {
  late final repository = RealtimeSmsRepository(widget.database);
  late String field = widget.field;
  LiveSms? live;
  late final accountStore = AccountStore(AccountRepository(widget.database));
  late final categoryStore = CategoryStore(CategoryRepository(widget.database));
  List<Account> get accounts => accountStore.accounts
      .where(
        (a) =>
            !a.isArchived &&
            a.digits == currencyDigits(a.currency) &&
            a.currency == live?.sms.currency,
      )
      .toList();
  List<Category> get categories =>
      categoryStore.categories.where((c) => c.type == categoryType).toList();
  CategoryType get categoryType =>
      live?.sms.credit == true ? CategoryType.income : CategoryType.expense;
  int? parentId;

  /// Which way the last step moved, so the slide goes the matching way.
  bool _forward = true;
  static const transferChoice = -2147483648;

  @override
  void dispose() {
    accountStore.dispose();
    categoryStore.dispose();
    super.dispose();
  }

  String? error;
  bool loading = true, saving = false;
  bool choosingMatch = false;
  int? draftAccount;
  bool transferAfterAccount = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final value = await repository.load(widget.id);
      await Future.wait([accountStore.load(), categoryStore.load()]);
      if (!mounted) return;
      if (accountStore.loadError != null || categoryStore.loadError != null) {
        throw StateError('Could not load accounts or categories.');
      }
      setState(() {
        live = value;
        loading = false;
        if (value == null) error = 'This transaction is no longer available.';
      });
      if (value != null && field == 'create_account') {
        if (value.accountId != null) {
          setState(() {
            field = 'category';
          });
        } else {
          WidgetsBinding.instance.addPostFrameCallback((_) => _createAccount());
        }
      }
      if (value != null && field == 'undo_account') {
        await repository.undoCreatedAccount(widget.id);
        final restored = await repository.load(widget.id);
        if (restored != null) {
          await showSmsNotification(widget.database, restored);
        }
        if (mounted) Navigator.pop(context);
      }
      if (value != null && field.startsWith('undo_category:')) {
        await repository.undoCategory(
          widget.id,
          field.substring('undo_category:'.length),
        );
        final restored = await repository.load(widget.id);
        if (restored != null) {
          await showSmsNotification(widget.database, restored);
        }
        if (mounted) Navigator.pop(context);
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = 'Could not load this transaction.';
        });
      }
    }
  }

  /// The account is created and the transaction saved without a form; the
  /// notification then shows it as a new account with Undo.
  Future<void> _createAccount() async {
    if (!mounted || live == null) return;
    try {
      await repository.createAccountFor(widget.id);
      final saved = await repository.load(widget.id);
      if (saved != null) await showSmsNotification(widget.database, saved);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          field = 'account';
          error = e is StateError ? e.message : 'Could not add this account.';
        });
      }
    }
  }

  Future<void> _save({int? account, int? category, int? other}) async {
    if (saving || live == null) return;
    setState(() {
      saving = true;
      error = null;
    });
    try {
      final done = await applyLiveSmsEdit(
        context,
        database: widget.database,
        live: live!,
        accounts: accountStore,
        account: account ?? draftAccount,
        category: category,
        other: other,
        onChoosingMatch: (choosing) {
          if (mounted) setState(() => choosingMatch = choosing);
        },
      );
      if (!mounted) return;
      if (!done) {
        setState(() {
          saving = false;
          choosingMatch = false;
        });
        return;
      }
      Navigator.pop(context);
    } catch (e) {
      if (mounted) {
        setState(() {
          saving = false;
          choosingMatch = false;
          error = '$e';
        });
      }
    }
  }

  /// Whether Back goes to an earlier step (subcategories → categories,
  /// transfer account → category) instead of closing the sheet.
  bool get _canStepBack =>
      parentId != null ||
      field == 'other' ||
      (transferAfterAccount && field == 'account');

  void _back() {
    if (parentId != null) {
      setState(() {
        _forward = false;
        parentId = null;
      });
    } else if (field == 'other' ||
        (transferAfterAccount && field == 'account')) {
      setState(() {
        _forward = false;
        field = 'category';
        transferAfterAccount = false;
        draftAccount = null;
      });
    } else {
      Navigator.pop(context);
    }
  }

  void _chooseCategory(int id) {
    if (id == transferChoice) {
      setState(() {
        _forward = true;
        transferAfterAccount = live!.accountId == null;
        field = transferAfterAccount ? 'account' : 'other';
      });
    } else if (parentId == null && categories.any((c) => c.parentId == id)) {
      setState(() {
        _forward = true;
        parentId = id;
      });
    } else {
      _save(category: id);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (loading || live == null || (saving && !choosingMatch)) {
      return SheetPage(
        header: const SheetHeader('SMS transaction'),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: loading || saving
              ? const Center(child: CircularProgressIndicator())
              : Text(error ?? 'Transaction unavailable.'),
        ),
      );
    }
    final selectAccount = field != 'category';
    final selectingOther = field == 'other';
    final parent = categories.where((c) => c.id == parentId).firstOrNull;
    final page = ChoicePickerPage<int>(
      key: ValueKey('$field/$parentId'),
      header: SheetHeader.flow('SMS transaction', onBack: _back),
      heading: selectAccount
          ? selectingOther
                ? (live!.sms.credit ? 'Transferred from' : 'Transferred to')
                : 'Change account'
          : parentId != null
          ? 'Choose subcategory'
          : live!.sms.credit
          ? 'Choose source'
          : 'Choose category',
      summary: error == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(error!),
            ),
      fillHeight: !selectAccount,
      items: selectAccount
          ? accountChoiceItems(
              accountStore,
              currency: live!.sms.currency,
              excludeId: selectingOther
                  ? draftAccount ?? live!.accountId
                  : live!.otherAccountId,
            )
          : [
              if (parentId == null)
                const ChoiceItem(
                  value: transferChoice,
                  icon: Icon(Icons.swap_horiz_rounded),
                  label: 'Between my accounts',
                  chevron: true,
                ),
              if (parent != null)
                ChoiceItem(
                  value: parent.id,
                  icon: AppIcon(parent.icon, size: 28),
                  label: 'Use ${parent.name} only',
                  chevron: true,
                ),
              for (final category in categories.where(
                (c) => c.parentId == parentId,
              ))
                ChoiceItem(
                  value: category.id,
                  icon: AppIcon(category.icon, size: 28),
                  label: category.name,
                  chevron: true,
                ),
            ],
      selected: selectAccount
          ? (selectingOther ? live!.otherAccountId : live!.accountId)
          : live!.otherAccountId == null
          ? live!.categoryId
          : transferChoice,
      searchHint: selectAccount
          ? 'Search accounts'
          : parentId != null
          ? 'Search subcategories'
          : live!.sms.credit
          ? 'Search sources'
          : 'Search categories',
      addLabel: selectAccount
          ? 'Add account'
          : parentId != null
          ? 'Add subcategory'
          : live!.sms.credit
          ? 'Add source'
          : 'Add category',
      onAdd: (context) async {
        final id = selectAccount
            ? (await addAccountAndSelect(
                context,
                accountStore,
                initialCurrency: live!.sms.currency,
              ))?.id
            : (await addCategoryAndSelect(
                context,
                categoryStore,
                categoryType,
                parentId: parentId,
              ))?.id;
        if (mounted) setState(() {});
        return id;
      },
      onSelected: selectAccount
          ? (id) {
              if (selectingOther) {
                _save(other: id);
              } else if (transferAfterAccount) {
                setState(() {
                  _forward = true;
                  draftAccount = id;
                  field = 'other';
                });
              } else {
                _save(account: id, other: live!.otherAccountId);
              }
            }
          : _chooseCategory,
    );
    return PopScope(
      // System back steps back like the arrow; it only closes the sheet
      // from the first page.
      canPop: !_canStepBack,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: StepSlider(
        stepKey: '$field/$parentId',
        forward: _forward,
        child: page,
      ),
    );
  }
}

/// Saves an edit to live SMS [live] — its account, its category, or the
/// other account of a transfer — and refreshes its notification. Before
/// making a transfer it offers any possible matching transaction from the
/// other account; returns false if the user backs out of that choice.
Future<bool> applyLiveSmsEdit(
  BuildContext context, {
  required AppDatabase database,
  required LiveSms live,
  required AccountStore accounts,
  int? account,
  int? category,
  int? other,
  ValueChanged<bool>? onChoosingMatch,
}) async {
  final repository = RealtimeSmsRepository(database);
  final id = live.sms.id;
  final selectedAccount = account ?? live.accountId;
  String? confirmedMatchId;
  var autoMatch = true;
  if (other != null &&
      selectedAccount != null &&
      !await repository.hasExactTransferMatch(
        id,
        accountId: selectedAccount,
        otherAccountId: other,
      )) {
    final matches = await repository.possibleTransferMatches(
      id,
      accountId: selectedAccount,
      otherAccountId: other,
    );
    if (!context.mounted) return false;
    if (matches.isNotEmpty) {
      onChoosingMatch?.call(true);
      final picked = await showChoiceListSheet<String>(
        context,
        title: 'Possible matching transaction',
        selected: null,
        items: [
          for (final match in matches)
            ChoiceItem(
              value: match.sms.id,
              icon: const Icon(Icons.swap_horiz_rounded),
              label:
                  '${match.sms.credit ? '+' : '−'}${currencyPrefix(match.sms.currency)}${formatAccountAmount(match.sms.amountMinor, digits: match.sms.digits, currency: match.sms.currency)} · ${accounts.byId(match.accountId)?.name ?? match.sms.bankName}',
              subtitle:
                  '${DateFormat('d MMM, h:mm a').format(match.sms.receivedAt)} · ${match.sms.reference ?? 'No reference'}${match.otherAccountId != null ? ' · Already a transfer' : ''}',
              chevron: true,
            ),
          const ChoiceItem(
            value: '',
            icon: Icon(Icons.add_rounded),
            label: 'Keep separate',
            subtitle: 'Save this transfer without combining another entry',
          ),
        ],
      );
      if (!context.mounted || picked == null) return false;
      if (picked.isNotEmpty) {
        final match = matches.firstWhere((m) => m.sms.id == picked);
        final confirmed = await showConfirmationAlert(
          context,
          title: 'Combine these bank messages?',
          destructive: false,
          message:
              '${accounts.byId(selectedAccount)?.name} ↔ ${accounts.byId(other)?.name}\n'
              '${currencyPrefix(match.sms.currency)}${formatAccountAmount(match.sms.amountMinor, digits: match.sms.digits, currency: match.sms.currency)} · ${DateFormat('d MMM, h:mm a').format(match.sms.receivedAt)}\n'
              'Both SMS become one transfer. The duplicate is removed and balances fixed.',
          confirmLabel: 'Combine as transfer',
        );
        if (!context.mounted || !confirmed) return false;
        confirmedMatchId = picked;
      } else {
        autoMatch = false;
      }
      onChoosingMatch?.call(false);
    }
  }
  if (category != null && other == null) {
    await repository.selectCategory(id, category, accountId: selectedAccount);
  } else {
    await repository.edit(
      id,
      accountId: selectedAccount!,
      categoryId: category ?? live.categoryId,
      otherAccountId: other,
      confirmedMatchId: confirmedMatchId,
      autoMatch: autoMatch,
    );
  }
  final updated = await repository.load(id);
  if (updated != null) await showSmsNotification(database, updated);
  return true;
}
