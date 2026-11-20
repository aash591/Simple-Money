import 'package:flutter/material.dart';

import '../../data/db/app_database.dart';
import '../../data/realtime_sms.dart';
import '../../data/repositories/account_repository.dart';
import '../../data/repositories/category_repository.dart';
import '../../data/repositories/loan_repository.dart';
import '../../data/repositories/realtime_sms_repository.dart';
import '../../data/repositories/sms_import_repository.dart';
import '../../data/repositories/transaction_repository.dart';
import '../../domain/account.dart';
import '../../domain/bank_institution_icon.dart';
import '../../domain/category.dart';
import '../../domain/transaction.dart';
import '../../domain/loan.dart';
import '../../state/account_store.dart';
import '../../state/category_store.dart';
import '../../state/transaction_store.dart';
import '../components/adaptive_sheet.dart';
import '../components/action_buttons.dart';
import '../components/app_icon.dart';
import '../components/choice_list_sheet.dart';
import '../components/transactions/review_pickers.dart';
import '../more/loans/loan_widgets.dart';
import '../theme/sheet_colors.dart';
import '../transactions/quick_add_helpers.dart';
import '../transactions/transaction_widgets.dart';
import '../transactions/transaction_sheet.dart';
import 'sms_notification_screen.dart';
import 'sms_preview_content.dart';
import '../../domain/currency_digits.dart';

/// The notification's SMS preview: the same modal as reviewing a bank SMS.
/// Record as, category and accounts are a draft until Save; with nothing
/// changed the primary action opens the saved transaction, and the preview
/// remains below it so Back has a real destination.
class SmsNotificationPreview extends StatefulWidget {
  const SmsNotificationPreview({
    super.key,
    required this.database,
    required this.id,
  });
  final AppDatabase database;
  final String id;

  @override
  State<SmsNotificationPreview> createState() => _SmsNotificationPreviewState();
}

class _SmsNotificationPreviewState extends State<SmsNotificationPreview> {
  late final repository = RealtimeSmsRepository(widget.database);
  late final accounts = AccountStore(AccountRepository(widget.database));
  late final categories = CategoryStore(CategoryRepository(widget.database));
  late final transactions = TransactionStore(
    TransactionRepository(widget.database),
    accounts,
  );
  LiveSms? live;
  bool loading = true;
  bool opening = false, busy = false;
  String? error;

  // The draft, seeded from [live] on every load.
  bool transfer = false;
  int? categoryId, accountId, otherAccountId;

  /// The title as edited here; null leaves the transaction's own.
  String? _title;

  /// The loan this payment goes to, chosen in place of a category.
  int? loanId;
  List<Loan> loans = const [];

  CategoryType get categoryType =>
      live?.sms.credit == true ? CategoryType.income : CategoryType.expense;

  bool get dirty {
    final value = live;
    if (value == null) return false;
    return loanId != null ||
        transfer != (value.otherAccountId != null) ||
        accountId != value.accountId ||
        (transfer
            ? otherAccountId != value.otherAccountId
            : categoryId != value.categoryId);
  }

  bool get valid =>
      accountId != null &&
      (transfer
          ? otherAccountId != null && otherAccountId != accountId
          : categoryId != null || loanId != null);

  Loan? get _loan => loans.where((l) => l.id == loanId).firstOrNull;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      await Future.wait([
        accounts.load(),
        categories.load(),
        transactions.load(),
      ]);
      final value = await repository.load(widget.id);
      final open = await _openLoans(value);
      if (!mounted) return;
      setState(() {
        live = value;
        loans = open;
        loanId = null;
        loading = false;
        error = value == null
            ? 'This transaction is no longer available.'
            : null;
        transfer = value?.otherAccountId != null;
        categoryId = value?.categoryId;
        accountId = value?.accountId;
        otherAccountId = value?.otherAccountId;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          loading = false;
          error = 'Could not load this transaction.';
        });
      }
    }
  }

  /// Open loans this message's money can go to: none when its transaction
  /// isn't a plain one yet, or something already owns it.
  Future<List<Loan>> _openLoans(LiveSms? value) async {
    final id = value?.transactionId;
    if (value == null || id == null || value.sms.credit) return const [];
    if (await transactions.repository.link(id) != null) return const [];
    return [
      for (final loan in await LoanRepository(widget.database).load())
        if (!loan.closed && loan.terms.currency == value.sms.currency) loan,
    ];
  }

  Future<void> _openTransaction() async {
    if (!mounted || opening || live == null) return;
    final before = live!;
    final transaction = transactions.transactions
        .where((t) => t.id == before.transactionId)
        .firstOrNull;
    if (transaction == null) return;
    opening = true;
    try {
      await showViewTransactionSheet(
        context,
        transaction: transaction,
        accountStore: accounts,
        categoryStore: categories,
        transactionStore: transactions,
      );
      final updated = await repository.load(widget.id);
      if (updated != null) {
        if (before.otherAccountId == null &&
            updated.otherAccountId == null &&
            updated.categoryId != null &&
            updated.categoryId != before.categoryId) {
          await repository.selectCategory(
            widget.id,
            updated.categoryId!,
            previousCategoryId: before.categoryId,
          );
        }
        await showSmsNotification(widget.database, updated);
      }
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() => error = 'Could not refresh this transaction.');
      }
    } finally {
      opening = false;
    }
  }

  Future<void> pickCategory() async {
    final sms = live!.sms;
    final cards = repayableCards(accounts.accounts, sms.currency, sms.digits);
    final pick = await showSmsCategoryPicker(
      context,
      categories: categories.categories,
      store: categories,
      type: categoryType,
      selected: categoryId,
      shortcuts: CategoryShortcuts(
        transfer: true,
        cardRepayment: !sms.credit && cards.isNotEmpty,
        loans: loans,
      ),
    );
    if (!mounted || pick == null) return;
    if (pick.transfer) {
      setState(() {
        transfer = true;
        loanId = null;
      });
    } else if (pick.cardRepayment) {
      final other = cards.where((c) => c.id != accountId).toList();
      setState(() {
        transfer = true;
        loanId = null;
        if (other.length == 1) otherAccountId = other.single.id;
      });
      if (other.length != 1) await pickAccount(other: true, cardsOnly: true);
    } else {
      setState(() {
        loanId = pick.loanId;
        categoryId = pick.categoryId ?? categoryId;
      });
    }
  }

  /// This SMS's own account, or with [other] the transfer's other side.
  Future<void> pickAccount({bool other = false, bool cardsOnly = false}) async {
    final sms = live!.sms;
    final id = await showSmsAccountPicker(
      context,
      heading: other
          ? (sms.credit ? 'Transferred from' : 'Transferred to')
          : transfer
          ? (sms.credit ? 'Transferred to' : 'Transferred from')
          : sms.credit
          ? 'Received in'
          : 'Paid from',
      selected: other ? otherAccountId : accountId,
      items: [
        for (final a in accounts.accounts)
          if (a.currency == sms.currency &&
              a.archivedAt == null &&
              a.digits == currencyDigits(a.currency) &&
              (!cardsOnly || a.type == AccountType.creditCard) &&
              (!transfer || a.id != (other ? accountId : otherAccountId)))
            ChoiceItem(
              value: a.id,
              icon: AppIcon(a.icon, size: 28),
              label: a.name,
              subtitle: formatTransactionMoney(a.balanceMinor, a),
              chevron: true,
            ),
      ],
      onAdd: (context) async {
        final created = await addAccountAndSelect(
          context,
          accounts,
          initialName: other ? null : sms.bankName,
          initialIcon: other
              ? null
              : bankInstitutionIcon(sms.bankName, creditCard: sms.creditCard),
          initialLastDigits: other ? null : sms.accountLast4,
          initialInstitution: other ? null : sms.bankName,
          initialType: !other && sms.creditCard
              ? AccountType.creditCard
              : AccountType.bank,
          initialCurrency: sms.currency,
        );
        if (created == null ||
            created.currency != sms.currency ||
            created.digits != 2) {
          return null;
        }
        // Keep the new bank account linked for this card's future messages.
        if (!other &&
            created.type != AccountType.cash &&
            (!sms.creditCard || created.type == AccountType.creditCard)) {
          await SmsImportRepository(widget.database)
              .linkAccount(sms, created.id);
        }
        return created.id;
      },
    );
    if (mounted && id != null) {
      setState(() => other ? otherAccountId = id : accountId = id);
    }
  }

  Future<void> save() async {
    final value = live;
    if (value == null || !valid || busy) return;
    setState(() {
      busy = true;
      error = null;
    });
    final loan = transfer ? null : loanId;
    final loanRepository = LoanRepository(widget.database);
    try {
      final paymentCategory = loan != null
          ? await loanRepository.paymentCategory()
          : !transfer &&
                (categoryId != value.categoryId || value.otherAccountId != null)
          ? categoryId
          : null;
      if (!mounted) return;
      final done = await applyLiveSmsEdit(
        context,
        database: widget.database,
        live: value,
        accounts: accounts,
        account: accountId,
        other: transfer ? otherAccountId : null,
        // An unchanged category is left alone, so changing only the account
        // doesn't also teach the merchant a category.
        category: paymentCategory,
      );
      if (done && loan != null) {
        // Editing can replace the transaction, so ask for it again.
        final saved = await repository.load(widget.id);
        await loanRepository.payWith(loan, saved!.transactionId!);
      }
      if (done && !transfer) await _saveTitle(value);
      if (!mounted) return;
      if (done) {
        Navigator.pop(context);
      } else {
        setState(() => busy = false);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = loan != null
              ? loanError(e)
              : 'Could not save this transaction. Try again.';
        });
      }
    }
  }

  /// Puts an edited title on the saved transaction.
  Future<void> _saveTitle(LiveSms value) async {
    final typed = _title?.trim();
    if (typed == null || typed.isEmpty) return;
    final id = (await repository.load(widget.id))?.transactionId;
    if (id == null) return;
    await transactions.load();
    final t = transactions.transactions.where((t) => t.id == id).firstOrNull;
    if (t == null ||
        t.type == TransactionType.transfer ||
        (t.title ?? '') == typed) {
      return;
    }
    await transactions.edit(
      id: t.id,
      type: t.type,
      amountMinor: t.amountMinor,
      accountId: t.accountId,
      toAccountId: t.toAccountId,
      categoryId: t.categoryId,
      title: typed,
      note: t.note,
      date: t.date,
    );
  }

  /// The SMS text. Once saved its body is dropped from the SMS table and
  /// survives only in the transaction's note, as "Sender: …" then the text.
  String _message(LiveSms value) {
    if (value.sms.body.trim().isNotEmpty) return value.sms.body;
    final note = transactions.transactions
        .where((t) => t.id == value.transactionId)
        .firstOrNull
        ?.note;
    if (note == null) return '';
    final split = note.indexOf('\n\n');
    return note.startsWith('Sender: ') && split >= 0
        ? note.substring(split + 2)
        : note;
  }

  @override
  void dispose() {
    transactions.dispose();
    categories.dispose();
    accounts.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final value = live;
    final colors = SheetColors.of(context);
    final header = SheetHeader.flow(
      'SMS preview',
      onBack: busy ? null : () => Navigator.pop(context),
    );
    if (loading || value == null) {
      return SheetPage(
        header: header,
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: loading
              ? const Center(child: CircularProgressIndicator())
              : Text(error ?? 'Transaction unavailable.'),
        ),
      );
    }
    final sms = value.sms;
    final category = categories.categories
        .where((c) => c.id == categoryId)
        .firstOrNull;
    final mine = accounts.byId(accountId);
    final other = accounts.byId(otherAccountId);
    final digits = sms.accountLast4 == null
        ? null
        : 'Account ending ${sms.accountLast4}';
    final viewOnly = !dirty && value.transactionId != null;
    return SheetPage(
      header: header,
      body: SmsPreviewContent(
        sms: sms,
        transfer: transfer,
        title: _title,
        onTitleChanged: busy ? null : (text) => _title = text,
        titleSuggestions: (text) => transactions.titleSuggestions.suggest(
          text,
          type: sms.credit ? TransactionType.income : TransactionType.expense,
          categoryId: categoryId,
        ),
        onTransferChanged: busy ? null : (v) => setState(() => transfer = v),
        message: _message(value),
        error: error,
        rows: [
          if (!transfer) ...[
            SmsPreviewChoice(
              label: 'Category',
              value: _loan?.title ?? category?.name ?? 'Choose category',
              icon: AppIcon(_loan?.icon ?? category?.icon, size: 30),
              onTap: busy ? null : pickCategory,
            ),
            Divider(height: 1, indent: 64, color: colors.divider),
          ],
          SmsPreviewChoice(
            label: transfer
                ? (sms.credit ? 'Transferred to' : 'Transferred from')
                : sms.credit
                ? 'Received in'
                : 'Paid from',
            value: mine?.name ?? 'Choose ${sms.currency} account',
            detail: digits,
            icon: AppIcon(
              mine?.icon ??
                  bankInstitutionIcon(sms.bankName, creditCard: sms.creditCard),
              size: 30,
            ),
            onTap: busy ? null : () => pickAccount(),
          ),
          if (transfer) ...[
            Divider(height: 1, indent: 64, color: colors.divider),
            SmsPreviewChoice(
              label: sms.credit ? 'Transferred from' : 'Transferred to',
              value: other?.name ?? 'Choose ${sms.currency} account',
              icon: AppIcon(other?.icon ?? 'bank_transfer', size: 30),
              onTap: busy ? null : () => pickAccount(other: true),
            ),
          ],
        ],
      ),
      actions: ActionButtonBar(
        secondaryLabel: 'Cancel',
        onSecondary: busy ? null : () => Navigator.pop(context),
        primaryLabel: viewOnly
            ? 'View transaction'
            : busy
            ? 'Saving...'
            : 'Save',
        onPrimary: viewOnly
            ? _openTransaction
            : valid && !busy
            ? save
            : null,
      ),
    );
  }
}
