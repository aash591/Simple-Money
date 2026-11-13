import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:intl/intl.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart'
    show normalizeRuleSender;

import '../../domain/account.dart';
import '../../domain/app_icons.dart';
import '../../domain/category.dart';
import '../../domain/recurring_payment.dart';
import '../../domain/recurring_suggestions.dart';
import '../../domain/service_icon.dart';
import '../../domain/transaction.dart';
import '../db/app_database.dart';
import '../repositories/account_repository.dart';
import '../repositories/category_repository.dart';
import '../repositories/loan_repository.dart';
import '../repositories/recurring_payment_repository.dart';
import '../repositories/sms_corrections.dart';
import '../repositories/sms_import_repository.dart';
import '../repositories/statement_import_repository.dart';
import '../repositories/transaction_repository.dart';
import '../user_sms_rules.dart';
import 'agent_loans.dart';
import 'statement_samples.dart';

/// What an AI app asked to change. Nothing here touches the ledger until the
/// user approves it, and every change goes through the same repository the
/// app's own screens use, so it is checked exactly like a manual edit.
enum AgentSuggestionKind {
  newCategory('new_category'),
  smsCorrection('sms_correction'),
  transactionEdit('transaction_edit'),
  parserRule('parser_rule'),
  statementLayout('statement_layout'),
  newLoan('new_loan'),
  debtEntry('debt_entry'),
  transactionAdd('transaction_add'),
  recurringPayment('recurring_payment');

  const AgentSuggestionKind(this.storageValue);
  final String storageValue;

  static AgentSuggestionKind fromStorage(String value) =>
      values.firstWhere((kind) => kind.storageValue == value);
}

enum AgentSuggestionStatus { pending, applied, rejected, undone }

class AgentSuggestion {
  const AgentSuggestion({
    required this.id,
    required this.batchId,
    required this.kind,
    required this.target,
    required this.payload,
    required this.before,
    required this.summary,
    required this.detail,
    required this.reason,
    required this.status,
    required this.error,
    required this.createdAt,
    required this.decidedAt,
  });
  final int id;

  /// Suggestions made by one tool call share a batch.
  final String batchId;
  final AgentSuggestionKind kind;

  /// What it changes: an SMS fingerprint, a transaction id, or a new
  /// category's identity. A newer suggestion for the same target replaces a
  /// pending older one.
  final String target;
  final Map<String, Object?> payload;

  /// The fields' values when it was suggested, for display and undo.
  final Map<String, Object?>? before;

  /// One line naming what it is about, and one line per changed field.
  final String summary;
  final List<String> detail;

  /// Why the AI app suggested it, in its own words.
  final String? reason;

  /// The AI app that made it (Claude, ChatGPT), when known.
  String? get source => payload['source'] as String?;
  final AgentSuggestionStatus status;

  /// Why the last attempt to apply it failed. It stays pending so the user
  /// can try again (after approving a category it needs, say) or reject it.
  final String? error;
  final DateTime createdAt;
  final DateTime? decidedAt;

  /// An edit to a saved transaction can be put back, an SMS rule taken out
  /// (what it already imported stays), and a loan or debt entry taken back.
  /// A category may already be in use, and a reviewed SMS is already in the
  /// ledger.
  bool get canUndo =>
      status == AgentSuggestionStatus.applied &&
      (kind == AgentSuggestionKind.transactionEdit ||
          kind == AgentSuggestionKind.parserRule ||
          kind == AgentSuggestionKind.statementLayout ||
          kind == AgentSuggestionKind.newLoan ||
          kind == AgentSuggestionKind.debtEntry ||
          kind == AgentSuggestionKind.transactionAdd ||
          kind == AgentSuggestionKind.recurringPayment);
}

class AgentSuggestionDraft {
  const AgentSuggestionDraft({
    required this.kind,
    required this.target,
    required this.payload,
    this.before,
    required this.summary,
    required this.detail,
    this.reason,
  });
  final AgentSuggestionKind kind;
  final String target;
  final Map<String, Object?> payload;
  final Map<String, Object?>? before;
  final String summary;
  final List<String> detail;
  final String? reason;
}

/// The message to show for a failed suggestion or tool call. Repositories
/// throw [StateError] and [ArgumentError] with user-facing text.
String describeAgentError(Object error) => switch (error) {
  StateError(:final message) => message,
  ArgumentError(:final message) => '$message',
  _ => 'Something went wrong. Try again.',
};

class AgentSuggestionRepository {
  AgentSuggestionRepository(this.database);
  final AppDatabase database;

  /// How long approved and rejected suggestions stay visible.
  static const _history = Duration(days: 30);

  late final AgentLoans _loans = AgentLoans(database);

  // ── Preparing: check against the ledger as it is now, and describe. ──

  Future<AgentSuggestionDraft> prepareNewCategory({
    required String name,
    required CategoryType type,
    int? parentId,
    String? parentName,
    String? icon,
    String? reason,
  }) async {
    final clean = name.trim();
    if (clean.isEmpty || clean.length > 40) {
      throw ArgumentError('A category name must be 1–40 characters.');
    }
    if (type == CategoryType.debtLoan) {
      throw ArgumentError('Only expense and income categories can be added.');
    }
    final categories = await CategoryRepository(database).load();
    final parent = parentId == null && parentName == null
        ? null
        : _parent(categories, type, parentId, parentName);
    if (categories.any(
      (c) =>
          c.type == type &&
          c.parentId == parent?.id &&
          c.name.toLowerCase() == clean.toLowerCase(),
    )) {
      throw ArgumentError('“$clean” already exists; use its id.');
    }
    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.newCategory,
      target: jsonEncode([type.storageValue, parent?.id, clean.toLowerCase()]),
      payload: {
        'name': clean,
        'type': type.storageValue,
        'parentId': parent?.id,
        'icon': appIconKeys.contains(icon) ? icon : null,
      },
      summary: 'New ${type.label.toLowerCase()} category',
      detail: [parent == null ? clean : '${parent.name} › $clean'],
      reason: _reason(reason),
    );
  }

  /// [categoryName] may name a category that a pending suggestion adds; it
  /// then needs approving first.
  Future<AgentSuggestionDraft> prepareSmsCorrection({
    required String smsId,
    int? accountId,
    int? categoryId,
    String? categoryName,
    bool dismiss = false,
    String? direction,
    int? loanId,
    bool sameLayout = false,
    String? reason,
  }) async {
    final row = await database
        .customSelect(
          '''SELECT i.sender, i.body, i.received_at, i.rule_id,
            coalesce(r.candidate, i.candidate) AS candidate,
            coalesce(r.account_id, r.to_account_id) AS account_id,
            r.category_id
          FROM sms_imports i
          LEFT JOIN sms_review r ON r.fingerprint = i.fingerprint
          WHERE i.fingerprint = ? AND i.status = 'pending' ''',
          variables: [Variable(smsId)],
        )
        .getSingleOrNull();
    if (row == null) {
      throw ArgumentError('No message waiting for review has id $smsId.');
    }
    final sms = PendingSmsImport(
      id: smsId,
      sender: row.read<String>('sender'),
      body: row.readNullable<String>('body') ?? '',
      data: Map<String, dynamic>.from(
        jsonDecode(row.read<String>('candidate')) as Map,
      ),
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('received_at'),
      ),
    );
    final summary =
        '${formatAccountMoney(sms.amountMinor, digits: sms.digits, currency: sms.currency)}'
        ' ${sms.credit ? 'received' : 'spent'} · ${sms.title}'
        ' · ${_day(sms.receivedAt)}';
    if (dismiss) {
      return AgentSuggestionDraft(
        kind: AgentSuggestionKind.smsCorrection,
        target: smsId,
        payload: const {'dismiss': true},
        summary: summary,
        detail: const ['Dismiss: not a transaction'],
        reason: _reason(reason),
      );
    }
    if (direction != null && !const {'debit', 'credit'}.contains(direction)) {
      throw ArgumentError('direction must be debit or credit.');
    }
    if (accountId == null &&
        categoryId == null &&
        categoryName == null &&
        direction == null &&
        loanId == null) {
      throw ArgumentError(
        'Give an account, a category, a direction, a loan, or dismiss.',
      );
    }
    final accounts = await AccountRepository(database).load();
    final categories = await CategoryRepository(database).load();
    final payload = <String, Object?>{};
    final detail = <String>[];
    // What the message really is, for this one and, with sameLayout, every
    // message of its layout: the ones waiting and the ones to come.
    if (direction != null || loanId != null) {
      final loan = loanId == null
          ? null
          : (await LoanRepository(
              database,
            ).load()).where((l) => l.id == loanId).firstOrNull;
      if (loanId != null) {
        if (loan == null || loan.closed) {
          throw ArgumentError(
            'No open loan has id $loanId. Use an id from list_loans.',
          );
        }
        if (loan.terms.currency != sms.currency) {
          throw ArgumentError('That loan is in ${loan.terms.currency}.');
        }
        if (categoryId != null || categoryName != null) {
          throw ArgumentError(
            'A loan payment goes under the loan’s category; leave category '
            'out.',
          );
        }
      }
      final really = loan != null ? 'debit' : direction!;
      if ((really == 'credit') == sms.credit && loan == null) {
        throw ArgumentError('The message already reads as $really.');
      }
      final sender = normalizeRuleSender(sms.sender) ?? sms.sender;
      final ruleId = row.readNullable<String>('rule_id');
      final ids = [smsId];
      if (sameLayout && ruleId != null) {
        for (final other
            in await database
                .customSelect(
                  "SELECT fingerprint, sender FROM sms_imports WHERE status='pending' "
                  'AND rule_id=? AND fingerprint<>?',
                  variables: [Variable(ruleId), Variable(smsId)],
                )
                .get()) {
          if ((normalizeRuleSender(other.read<String>('sender')) ??
                  other.read<String>('sender')) ==
              sender) {
            ids.add(other.read<String>('fingerprint'));
          }
        }
      }
      payload.addAll({
        'direction': really,
        'loanId': ?loan?.id,
        'smsIds': ids,
        if (sameLayout && ruleId != null) ...{
          'remember': true,
          'sender': sender,
          'ruleId': ruleId,
        },
      });
      detail.add(
        loan != null
            ? 'Is: a payment to ${loan.title}, from '
                  '${_accountName(accounts, loan.accountId)}'
            : 'Is: money ${really == 'credit' ? 'received' : 'paid'}, not '
                  '${really == 'credit' ? 'paid' : 'received'}',
      );
      if (ids.length > 1) detail.add('Also ${ids.length - 1} more like it');
      if (payload['remember'] == true) {
        detail.add('Future $sender messages like this too');
      }
    }
    final oldAccount = row.readNullable<int>('account_id');
    final oldCategory = row.readNullable<int>('category_id');
    if (accountId != null) {
      final account = _smsAccount(accounts, accountId, sms);
      if (account.id != oldAccount) {
        payload['accountId'] = account.id;
        detail.add(
          'Account: ${_accountName(accounts, oldAccount)} → ${account.name}',
        );
      }
    }
    if (categoryId != null || categoryName != null) {
      if (sms.requiresTransfer) {
        throw ArgumentError(
          'This message is a transfer between accounts, so it has no category.',
        );
      }
      final choice = await _categoryChoice(
        categories,
        sms.credit ? CategoryType.income : CategoryType.expense,
        categoryId,
        categoryName,
      );
      if (choice.id == null || choice.id != oldCategory) {
        payload.addAll(choice.payload);
        detail.add(
          'Category: ${_categoryPath(categories, oldCategory)} → ${choice.label}',
        );
      }
    }
    if (payload.isEmpty) throw ArgumentError('Nothing would change.');
    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.smsCorrection,
      target: smsId,
      payload: payload,
      before: {'accountId': oldAccount, 'categoryId': oldCategory},
      summary: summary,
      detail: detail,
      reason: _reason(reason),
    );
  }

  Future<AgentSuggestionDraft> prepareTransactionEdit({
    required int transactionId,
    int? categoryId,
    String? categoryName,
    int? accountId,
    String? title,
    String? note,
    int? loanId,
    String? reason,
  }) async {
    final current = await _transaction(transactionId);
    final accounts = await AccountRepository(database).load();
    final categories = await CategoryRepository(database).load();
    final transfer = current.type == TransactionType.transfer;
    if (loanId != null) {
      return _prepareLoanPayment(current, loanId, accounts, categories, reason);
    }
    if (transfer &&
        (categoryId != null ||
            categoryName != null ||
            accountId != null ||
            title != null)) {
      throw ArgumentError(
        'A transfer has no category or title, and its accounts can only be '
        'changed in the app. Only its note can be suggested.',
      );
    }
    final locks =
        (await TransactionRepository(database).link(transactionId))?.locks ??
        const TransactionLocks();
    final payload = <String, Object?>{};
    final before = <String, Object?>{};
    final detail = <String>[];
    if (categoryId != null || categoryName != null) {
      final choice = await _categoryChoice(
        categories,
        current.type == TransactionType.income
            ? CategoryType.income
            : CategoryType.expense,
        categoryId,
        categoryName,
      );
      if (choice.id == null || choice.id != current.categoryId) {
        if (locks.category) throw ArgumentError(_managed);
        payload.addAll(choice.payload);
        before['categoryId'] = current.categoryId;
        detail.add(
          'Category: ${_categoryPath(categories, current.categoryId)} → ${choice.label}',
        );
      }
    }
    if (accountId != null && accountId != current.accountId) {
      if (locks.accounts) throw ArgumentError(_managed);
      final account = _sameCurrencyAccount(accounts, accountId, current);
      payload['accountId'] = account.id;
      before['accountId'] = current.accountId;
      detail.add(
        'Account: ${_accountName(accounts, current.accountId)} → ${account.name}',
      );
    }
    if (title != null) {
      final clean = title.trim();
      if (clean.length > 80) {
        throw ArgumentError('Keep the title to 80 characters.');
      }
      if (clean != (current.title ?? '')) {
        payload['title'] = clean.isEmpty ? null : clean;
        before['title'] = current.title;
        detail.add(
          'Title: ${current.title ?? '—'} → ${clean.isEmpty ? '—' : clean}',
        );
      }
    }
    if (note != null && note.trim() != (current.note ?? '').trim()) {
      final clean = note.trim();
      payload['note'] = clean.isEmpty ? null : clean;
      before['note'] = current.note;
      detail.add('Note: ${clean.isEmpty ? 'removed' : 'updated'}');
    }
    if (payload.isEmpty) throw ArgumentError('Nothing would change.');
    final account = accounts.firstWhere((a) => a.id == current.accountId);
    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.transactionEdit,
      target: '$transactionId',
      payload: payload,
      before: before,
      summary:
          '${formatAccountMoney(current.amountMinor, digits: account.digits, currency: account.currency)}'
          ' · ${current.title ?? _categoryPath(categories, current.categoryId)}'
          ' · ${_day(current.date)}',
      detail: detail,
      reason: _reason(reason),
    );
  }

  /// A saved transaction that is really a payment to loan [loanId]: a bank
  /// SMS that said "credited to your loan account" and went in as income.
  /// It becomes an expense under the loan's category, from the loan's paying
  /// account, and the loan's next payment.
  Future<AgentSuggestionDraft> _prepareLoanPayment(
    MoneyTransaction current,
    int loanId,
    List<Account> accounts,
    List<Category> categories,
    String? reason,
  ) async {
    if (current.type == TransactionType.transfer) {
      throw ArgumentError('A transfer can’t be a loan payment.');
    }
    final loan = (await LoanRepository(
      database,
    ).load()).where((l) => l.id == loanId).firstOrNull;
    if (loan == null || loan.closed) {
      throw ArgumentError(
        'No open loan has id $loanId. Use an id from list_loans.',
      );
    }
    final account = accounts.firstWhere((a) => a.id == current.accountId);
    if (loan.terms.currency != account.currency) {
      throw ArgumentError('That loan is in ${loan.terms.currency}.');
    }
    final locks =
        (await TransactionRepository(database).link(current.id))?.locks ??
        const TransactionLocks();
    if (locks.category || locks.accounts) throw ArgumentError(_managed);
    final payer = accounts
        .where((a) => a.id == loan.accountId && a.currency == account.currency)
        .firstOrNull;
    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.transactionEdit,
      target: '${current.id}',
      payload: {'loanId': loan.id, 'accountId': ?payer?.id},
      // A payment on a loan is taken back from the loan's screen.
      before: {'loanId': loan.id},
      summary:
          '${formatAccountMoney(current.amountMinor, digits: account.digits, currency: account.currency)}'
          ' · ${current.title ?? _categoryPath(categories, current.categoryId)}'
          ' · ${_day(current.date)}',
      detail: [
        if (current.type == TransactionType.income) 'Type: income → payment',
        'Is: a payment to ${loan.title}',
        if (payer != null && payer.id != account.id)
          'Account: ${account.name} → ${payer.name}',
      ],
      reason: _reason(reason),
    );
  }

  Future<void> _applyLoanPayment(int id, Map<String, Object?> payload) async {
    final current = await _transaction(id);
    final loans = LoanRepository(database);
    await TransactionRepository(database).edit(
      id: id,
      type: TransactionType.expense,
      amountMinor: current.amountMinor,
      accountId: payload['accountId'] as int? ?? current.accountId,
      categoryId: await loans.paymentCategory(),
      title: current.title,
      note: current.note,
      date: current.date,
    );
    await loans.payWith(payload['loanId'] as int, id);
  }

  /// A new expense or income. [categoryId] or [categoryName] is required;
  /// the date defaults to today and can't be in the future.
  Future<AgentSuggestionDraft> prepareTransactionAdd({
    required TransactionType type,
    required String amount,
    required int accountId,
    int? categoryId,
    String? categoryName,
    String? title,
    String? note,
    DateTime? date,
    bool ignoreDuplicates = false,
    String? reason,
  }) async {
    if (type == TransactionType.transfer) {
      throw ArgumentError('Only expenses and income can be added this way.');
    }
    final accounts = await AccountRepository(database).load();
    final account = accounts.where((a) => a.id == accountId).firstOrNull;
    if (account == null || account.isArchived) {
      throw ArgumentError('Account $accountId isn’t an active account.');
    }
    final minor = parseAccountAmount(
      amount.replaceAll(',', ''),
      account.digits,
    );
    if (minor == null || minor <= 0) {
      throw ArgumentError('amount must be an amount like 250.00.');
    }
    if (categoryId == null && categoryName == null) {
      throw ArgumentError('Give category_id or category_name.');
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = date == null
        ? today
        : DateTime(date.year, date.month, date.day);
    if (day.isAfter(today)) {
      throw ArgumentError('The date can’t be in the future.');
    }
    final cleanTitle = title?.trim() ?? '';
    if (cleanTitle.length > 80) {
      throw ArgumentError('Keep the title to 80 characters.');
    }
    final cleanNote = note?.trim() ?? '';
    final categories = await CategoryRepository(database).load();
    final choice = await _categoryChoice(
      categories,
      type == TransactionType.income
          ? CategoryType.income
          : CategoryType.expense,
      categoryId,
      categoryName,
    );
    if (!ignoreDuplicates) {
      final same = await database
          .customSelect(
            'SELECT id FROM transactions WHERE type = ? AND account_id = ? AND amount_minor = ? AND date >= ? AND date < ? LIMIT 1',
            variables: [
              Variable(type.storageValue),
              Variable(accountId),
              Variable(minor),
              Variable(day.millisecondsSinceEpoch),
              Variable(
                DateTime(
                  day.year,
                  day.month,
                  day.day + 1,
                ).millisecondsSinceEpoch,
              ),
            ],
          )
          .getSingleOrNull();
      if (same != null) {
        throw ArgumentError(
          'A transaction with this type, account, amount and date is already '
          'saved (id ${same.read<int>('id')}). Send ignore_duplicates true if '
          'this is a different one.',
        );
      }
    }
    final shown = formatAccountMoney(
      minor,
      digits: account.digits,
      currency: account.currency,
    );
    final income = type == TransactionType.income;
    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.transactionAdd,
      target: jsonEncode([
        type.storageValue,
        accountId,
        minor,
        day.toIso8601String(),
        cleanTitle.toLowerCase(),
        cleanNote.toLowerCase(),
      ]),
      payload: {
        'type': type.storageValue,
        'amount': minor,
        'accountId': accountId,
        ...choice.payload,
        'title': cleanTitle.isEmpty ? null : cleanTitle,
        'note': cleanNote.isEmpty ? null : cleanNote,
        'date': day.toIso8601String(),
      },
      summary:
          '${income ? 'Add income' : 'Add expense'} · $shown'
          ' · ${cleanTitle.isEmpty ? choice.label : cleanTitle}'
          ' · ${_day(day)}',
      detail: [
        'Category: ${choice.label}',
        '${income ? 'Adds to' : 'Takes out of'} ${account.name}',
        if (cleanNote.isNotEmpty) 'Note: $cleanNote',
      ],
      reason: _reason(reason),
    );
  }

  /// Adds the transaction. Returns what undoing needs.
  Future<Map<String, Object?>> _applyTransactionAdd(
    Map<String, Object?> payload,
  ) async {
    final type = TransactionTypeStorage.fromStorage(payload['type'] as String);
    final category = await _resolveCategory(
      type == TransactionType.income
          ? CategoryType.income
          : CategoryType.expense,
      payload,
    );
    final accountId = payload['accountId'] as int;
    final account = (await AccountRepository(
      database,
    ).load()).where((a) => a.id == accountId && !a.isArchived).firstOrNull;
    if (account == null) throw StateError('That account is no longer active.');
    final id = await TransactionRepository(database).addExpenseOrIncome(
      type: type,
      amountMinor: payload['amount'] as int,
      accountId: accountId,
      categoryId: category.id,
      title: payload['title'] as String?,
      note: payload['note'] as String?,
      date: DateTime.parse(payload['date'] as String),
    );
    return {'transactionId': id};
  }

  /// A recurring payment to set up, in or out: rent, a subscription, a
  /// premium. The icon and category follow its name when not given.
  Future<AgentSuggestionDraft> prepareRecurringPayment({
    required String name,
    required String amount,
    required int accountId,
    String cycle = 'monthly',
    DateTime? nextDue,
    bool incoming = false,
    int? categoryId,
    String? categoryName,
    String? icon,
    bool remind = true,
    String? reason,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty || cleanName.length > 40) {
      throw ArgumentError('Give a name of up to 40 characters.');
    }
    final billing = BillingCycle.values
        .where((c) => c.name == cycle)
        .firstOrNull;
    if (billing == null) {
      throw ArgumentError(
        'cycle must be one of ${[for (final c in BillingCycle.values) c.name].join(', ')}.',
      );
    }
    final accounts = await AccountRepository(database).load();
    final account = accounts.where((a) => a.id == accountId).firstOrNull;
    if (account == null || account.isArchived) {
      throw ArgumentError('Account $accountId isn’t an active account.');
    }
    final minor = parseAccountAmount(
      amount.replaceAll(',', ''),
      account.digits,
    );
    if (minor == null || minor <= 0) {
      throw ArgumentError('amount must be an amount like 250.00.');
    }
    final existing = await database
        .customSelect(
          'SELECT id FROM recurring_payments WHERE lower(name) = ? AND incoming = ? LIMIT 1',
          variables: [
            Variable(cleanName.toLowerCase()),
            Variable(incoming ? 1 : 0),
          ],
        )
        .getSingleOrNull();
    if (existing != null) {
      throw ArgumentError(
        '“$cleanName” is already set up (id ${existing.read<int>('id')}). '
        'Check list_recurring_payments before suggesting another.',
      );
    }
    final suggested = suggestRecurring(cleanName, incoming: incoming);
    final categories = await CategoryRepository(database).load();
    final type = incoming ? CategoryType.income : CategoryType.expense;
    // Asked for by id or name, it must exist. Otherwise the name decides, if
    // the user still has a category by that name.
    final automatic =
        suggested?.category ?? (incoming ? 'Rental Income' : 'Subscriptions');
    final choice = categoryId != null || categoryName != null
        ? await _categoryChoice(categories, type, categoryId, categoryName)
        : _byName(categories, type, automatic) == null
        ? null
        : await _categoryChoice(categories, type, null, automatic);
    final day = nextDue == null ? dateOnly(DateTime.now()) : dateOnly(nextDue);
    final shown = formatAccountMoney(
      minor,
      digits: account.digits,
      currency: account.currency,
    );
    final artwork =
        icon ??
        serviceIcon(cleanName) ??
        suggested?.icon ??
        (incoming ? 'rent' : 'subscriptions');
    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.recurringPayment,
      target: jsonEncode([cleanName.toLowerCase(), incoming]),
      payload: {
        'name': cleanName,
        'icon': artwork,
        'amount': minor,
        'accountId': accountId,
        'cycle': billing.name,
        'nextDue': day.toIso8601String(),
        'incoming': incoming,
        'remind': remind,
        ...?choice?.payload,
      },
      summary:
          '${incoming ? 'Add money coming in' : 'Add recurring payment'}'
          ' · $cleanName · $shown ${billing.label.toLowerCase()}',
      detail: [
        'Next due ${_day(day)}',
        '${incoming ? 'Paid into' : 'Paid from'} ${account.name}',
        if (choice != null) 'Category: ${choice.label}',
        if (remind) 'Reminds two days before and on the day',
      ],
      reason: _reason(reason),
    );
  }

  /// Sets the recurring payment up. Returns what undoing needs.
  Future<Map<String, Object?>> _applyRecurringPayment(
    Map<String, Object?> payload,
  ) async {
    final incoming = payload['incoming'] == true;
    final category =
        payload.containsKey('categoryId') || payload.containsKey('categoryName')
        ? await _resolveCategory(
            incoming ? CategoryType.income : CategoryType.expense,
            payload,
          )
        : null;
    final id = await RecurringPaymentRepository(database).add(
      RecurringPaymentDraft(
        name: payload['name'] as String,
        icon: payload['icon'] as String?,
        amountMinor: payload['amount'] as int,
        cycle: BillingCycleLabels.fromStorage(payload['cycle'] as String),
        nextDue: DateTime.parse(payload['nextDue'] as String),
        accountId: payload['accountId'] as int,
        categoryId: category?.id,
        remind: payload['remind'] != false,
        incoming: incoming,
      ),
    );
    return {'recurringPaymentId': id};
  }

  // ── Storing and reading. ──

  /// Stores [drafts] as one batch and returns its id. Each replaces any
  /// pending suggestion for the same target.
  /// Zone key for the AI app whose tool call is running, so each suggestion
  /// it makes records who made it (under `source` in its payload).
  static const clientKey = #simpleMoneyAiClient;

  Future<String> add(List<AgentSuggestionDraft> drafts) async {
    final source = Zone.current[clientKey] as String?;
    final now = DateTime.now().millisecondsSinceEpoch;
    final batchId = now.toRadixString(36);
    await database.transaction(() async {
      for (final draft in drafts) {
        await database.customStatement(
          "DELETE FROM agent_suggestions WHERE kind = ? AND target = ? AND status = 'pending'",
          [draft.kind.storageValue, draft.target],
        );
        await database.customStatement(
          '''INSERT INTO agent_suggestions
          (batch_id, kind, target, payload, before, summary, detail, reason, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)''',
          [
            batchId,
            draft.kind.storageValue,
            draft.target,
            jsonEncode(
              source == null
                  ? draft.payload
                  : {...draft.payload, 'source': source},
            ),
            draft.before == null ? null : jsonEncode(draft.before),
            draft.summary,
            draft.detail.join('\n'),
            draft.reason,
            now,
          ],
        );
      }
    });
    return batchId;
  }

  /// Pending suggestions first (new categories ahead of what may need them),
  /// then recent decisions, newest first.
  Future<List<AgentSuggestion>> load({
    Set<AgentSuggestionStatus>? statuses,
    int limit = 200,
  }) async {
    await _tidy();
    final names = (statuses ?? AgentSuggestionStatus.values.toSet())
        .map((s) => "'${s.name}'")
        .join(',');
    final rows = await database
        .customSelect(
          '''SELECT * FROM agent_suggestions WHERE status IN ($names)
          ORDER BY status != 'pending', kind != 'new_category',
            coalesce(decided_at, created_at) DESC, id
          LIMIT ?''',
          variables: [Variable(limit)],
        )
        .get();
    return [
      for (final r in rows)
        AgentSuggestion(
          id: r.read<int>('id'),
          batchId: r.read<String>('batch_id'),
          kind: AgentSuggestionKind.fromStorage(r.read<String>('kind')),
          target: r.read<String>('target'),
          payload: Map<String, Object?>.from(
            jsonDecode(r.read<String>('payload')) as Map,
          ),
          before: switch (r.readNullable<String>('before')) {
            final json? => Map<String, Object?>.from(jsonDecode(json) as Map),
            null => null,
          },
          summary: r.read<String>('summary'),
          detail: r.read<String>('detail').split('\n'),
          reason: r.readNullable<String>('reason'),
          status: AgentSuggestionStatus.values.byName(r.read<String>('status')),
          error: r.readNullable<String>('error'),
          createdAt: DateTime.fromMillisecondsSinceEpoch(
            r.read<int>('created_at'),
          ),
          decidedAt: switch (r.readNullable<int>('decided_at')) {
            final at? => DateTime.fromMillisecondsSinceEpoch(at),
            null => null,
          },
        ),
    ];
  }

  Future<int> pendingCount() async {
    await _tidy();
    return (await database
            .customSelect(
              "SELECT COUNT(*) AS n FROM agent_suggestions WHERE status = 'pending'",
            )
            .getSingle())
        .read<int>('n');
  }

  /// A message the user reviewed themselves no longer needs its suggestion,
  /// and old decisions are forgotten.
  Future<void> _tidy() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await database.customStatement(
      '''UPDATE agent_suggestions
      SET status = 'rejected', decided_at = ?, error = 'You reviewed this message yourself.'
      WHERE kind = 'sms_correction' AND status = 'pending'
        AND target NOT IN (SELECT fingerprint FROM sms_imports WHERE status = 'pending')''',
      [now],
    );
    await database.customStatement(
      "DELETE FROM agent_suggestions WHERE status != 'pending' AND decided_at < ?",
      [now - _history.inMilliseconds],
    );
  }

  // ── Deciding. ──

  /// Applies one pending suggestion, or a rejected or undone one the user
  /// has come back to. Returns why it failed, or null. A failed suggestion
  /// stays as it was, with its error.
  Future<String?> apply(int id) async {
    try {
      await database.transaction(() async {
        final suggestion = await _pending(id);
        switch (suggestion.kind) {
          case AgentSuggestionKind.newCategory:
            await _applyNewCategory(suggestion.payload);
          case AgentSuggestionKind.smsCorrection:
            await _applySmsCorrection(suggestion.target, suggestion.payload);
          case AgentSuggestionKind.transactionEdit:
            suggestion.payload.containsKey('loanId')
                ? await _applyLoanPayment(
                    int.parse(suggestion.target),
                    suggestion.payload,
                  )
                : await _applyTransactionEdit(
                    int.parse(suggestion.target),
                    suggestion.payload,
                  );
          case AgentSuggestionKind.parserRule:
            final p = suggestion.payload;
            final ruleId = await UserSmsRuleRepository(database).add(
              bankName: p['bankName'] as String,
              senders: (p['senders'] as List).cast(),
              format: Map<String, dynamic>.from(p['format'] as Map),
              samples: (p['samples'] as List).cast(),
            );
            // Undo removes this rule.
            await database.customStatement(
              'UPDATE agent_suggestions SET before = ? WHERE id = ?',
              [
                jsonEncode({'ruleId': ruleId}),
                id,
              ],
            );
          case AgentSuggestionKind.statementLayout:
            final p = suggestion.payload;
            final signature = p['signature'] as String;
            final layouts = StatementImportRepository(database);
            final previous = (await layouts.columnMappings())[signature];
            await layouts.saveColumnMapping(signature, p['mapping'] as Object);
            await StatementSampleRepository().remove(signature);
            // Undo puts back what this layout was read with before.
            await database.customStatement(
              'UPDATE agent_suggestions SET before = ? WHERE id = ?',
              [
                jsonEncode({'signature': signature, 'previous': previous}),
                id,
              ],
            );
          case AgentSuggestionKind.newLoan:
            await _keepForUndo(id, await _loans.applyLoan(suggestion.payload));
          case AgentSuggestionKind.debtEntry:
            await _keepForUndo(
              id,
              await _loans.applyDebtEntry(suggestion.payload),
            );
          case AgentSuggestionKind.transactionAdd:
            await _keepForUndo(
              id,
              await _applyTransactionAdd(suggestion.payload),
            );
          case AgentSuggestionKind.recurringPayment:
            await _keepForUndo(
              id,
              await _applyRecurringPayment(suggestion.payload),
            );
        }
        await _decide(id, AgentSuggestionStatus.applied);
      });
      return null;
    } catch (error) {
      final message = describeAgentError(error);
      await database.customStatement(
        "UPDATE agent_suggestions SET error = ? WHERE id = ? AND status IN ('pending', 'rejected', 'undone')",
        [message, id],
      );
      return message;
    }
  }

  /// Applies every pending suggestion, new categories first so the changes
  /// that use them find them. Returns how many applied and how many failed.
  Future<(int, int)> applyAll() async {
    var applied = 0, failed = 0;
    for (final suggestion in await load(
      statuses: {AgentSuggestionStatus.pending},
      limit: -1,
    )) {
      if (await apply(suggestion.id) == null) {
        applied++;
      } else {
        failed++;
      }
    }
    return (applied, failed);
  }

  /// Whether the payments a suggested loan found no transaction for come out
  /// of its paying account, or only count towards the loan — the same choice
  /// as "Update account balance" on a past debt. Kept on the suggestion, so
  /// approving all follows it too.
  Future<void> setUpdatesBalance(int id, bool on) async {
    final row = await database
        .customSelect(
          "SELECT payload, detail FROM agent_suggestions WHERE id = ? AND kind = 'new_loan' AND status = 'pending'",
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) return;
    final payload = Map<String, Object?>.from(
      jsonDecode(row.read<String>('payload')) as Map,
    );
    for (final payment in payload['payments'] as List) {
      final p = payment as Map;
      if (p['transactionId'] == null) p['offLedger'] = !on;
    }
    final adds = '→ adds to ${payload['paidFrom']}';
    const counted = '→ counted as paid';
    final detail = row.read<String>('detail');
    await database.customStatement(
      'UPDATE agent_suggestions SET payload = ?, detail = ? WHERE id = ?',
      [
        jsonEncode(payload),
        on
            ? detail.replaceAll(counted, adds)
            : detail.replaceAll(adds, counted),
        id,
      ],
    );
  }

  /// Replaces what a not-yet-approved "add transaction" suggestion will add,
  /// after the user edited it, and rewrites its summary and details to match.
  /// Saves the payment a new SMS rule's sample shows, once the user picked
  /// what the SMS doesn't say (an account, a category). The sample message is
  /// marked saved, so reading the inbox with the rule doesn't queue it again.
  Future<int> saveRuleSample(
    int id, {
    required TransactionType type,
    required int amountMinor,
    required int accountId,
    required int categoryId,
    String? title,
    String? note,
    required DateTime date,
  }) async {
    final row = await database
        .customSelect(
          "SELECT payload FROM agent_suggestions WHERE id = ? AND kind = 'parser_rule'",
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (row == null) throw StateError('This suggestion is gone.');
    final payload = Map<String, Object?>.from(
      jsonDecode(row.read<String>('payload')) as Map,
    );
    if (payload['savedTransactionId'] != null) {
      throw StateError('This payment is already saved.');
    }
    final samples = (payload['samples'] as List?)?.cast<String>() ?? const [];
    final senders = (payload['senders'] as List?)?.cast<String>() ?? const [];
    return database.transaction(() async {
      final transactionId = await TransactionRepository(database)
          .addExpenseOrIncome(
            type: type,
            amountMinor: amountMinor,
            accountId: accountId,
            categoryId: categoryId,
            title: title,
            note: note,
            date: date,
          );
      if (samples.isNotEmpty) {
        await SmsImportRepository(database).markSampleSaved(
          sender: senders.firstOrNull ?? '',
          body: samples.first,
          transactionId: transactionId,
        );
      }
      await database.customStatement(
        'UPDATE agent_suggestions SET payload = ? WHERE id = ?',
        [
          jsonEncode({
            ...payload,
            'savedTransactionId': transactionId,
            // The category the user filed it under: what the rule's messages
            // are, for sharing the rule.
            'savedCategory': ?(await CategoryRepository(
              database,
            ).load()).where((c) => c.id == categoryId).firstOrNull?.name,
          }),
          id,
        ],
      );
      return transactionId;
    });
  }

  Future<void> editTransactionAdd(
    int id, {
    required TransactionType type,
    required int amountMinor,
    required int accountId,
    required int categoryId,
    String? title,
    String? note,
    required DateTime date,
  }) async {
    final account = (await AccountRepository(
      database,
    ).load()).where((a) => a.id == accountId).firstOrNull;
    if (account == null) throw ArgumentError('Pick an account.');
    final categories = await CategoryRepository(database).load();
    final choice = await _categoryChoice(
      categories,
      type == TransactionType.income
          ? CategoryType.income
          : CategoryType.expense,
      categoryId,
      null,
    );
    final day = DateTime(date.year, date.month, date.day);
    final cleanTitle = title?.trim() ?? '';
    final cleanNote = note?.trim() ?? '';
    final income = type == TransactionType.income;
    final shown = formatAccountMoney(
      amountMinor,
      digits: account.digits,
      currency: account.currency,
    );
    final kept = await database
        .customSelect(
          'SELECT payload FROM agent_suggestions WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    final source = kept == null
        ? null
        : (jsonDecode(kept.read<String>('payload')) as Map)['source'];
    await database.customStatement(
      "UPDATE agent_suggestions SET payload = ?, summary = ?, detail = ?, error = NULL WHERE id = ? AND kind = 'transaction_add' AND status != 'applied'",
      [
        jsonEncode({
          'type': type.storageValue,
          'amount': amountMinor,
          'accountId': accountId,
          ...choice.payload,
          'title': cleanTitle.isEmpty ? null : cleanTitle,
          'note': cleanNote.isEmpty ? null : cleanNote,
          'date': date.toIso8601String(),
          'source': ?source,
        }),
        '${income ? 'Add income' : 'Add expense'} · $shown'
            ' · ${cleanTitle.isEmpty ? choice.label : cleanTitle}'
            ' · ${_day(day)}',
        [
          'Category: ${choice.label}',
          '${income ? 'Adds to' : 'Takes out of'} ${account.name}',
          if (cleanNote.isNotEmpty) 'Note: $cleanNote',
        ].join('\n'),
        id,
      ],
    );
  }

  Future<void> reject(int id) => database.customStatement(
    "UPDATE agent_suggestions SET status = 'rejected', decided_at = ? WHERE id = ? AND status = 'pending'",
    [DateTime.now().millisecondsSinceEpoch, id],
  );

  Future<void> rejectAll() => database.customStatement(
    "UPDATE agent_suggestions SET status = 'rejected', decided_at = ? WHERE status = 'pending'",
    [DateTime.now().millisecondsSinceEpoch],
  );

  /// Puts back the fields an applied transaction edit changed, or takes back
  /// an applied SMS rule, loan or debt entry.
  Future<String?> undo(int id) async {
    try {
      await database.transaction(() async {
        final row = await database
            .customSelect(
              "SELECT kind, target, before FROM agent_suggestions WHERE id = ? AND status = 'applied' AND kind IN ('transaction_edit', 'parser_rule', 'statement_layout', 'new_loan', 'debt_entry', 'transaction_add', 'recurring_payment')",
              variables: [Variable(id)],
            )
            .getSingleOrNull();
        if (row == null) throw StateError('This change can’t be undone.');
        final before = Map<String, Object?>.from(
          jsonDecode(row.read<String>('before')) as Map,
        );
        if (row.read<String>('kind') == 'transaction_edit' &&
            before.containsKey('loanId')) {
          throw StateError(
            'This is a loan payment now. Remove it from the loan’s screen.',
          );
        }
        if (row.read<String>('kind') == 'new_loan') {
          await _loans.undoLoan(before);
        } else if (row.read<String>('kind') == 'debt_entry') {
          await _loans.undoDebtEntry(before);
        } else if (row.read<String>('kind') == 'recurring_payment') {
          await RecurringPaymentRepository(database)
              .delete(before['recurringPaymentId'] as int);
        } else if (row.read<String>('kind') == 'transaction_add') {
          await TransactionRepository(database)
              .delete(before['transactionId'] as int);
        } else if (row.read<String>('kind') == 'parser_rule') {
          await UserSmsRuleRepository(database).delete(before['ruleId'] as int);
        } else if (row.read<String>('kind') == 'statement_layout') {
          await StatementImportRepository(database).restoreColumnMapping(
            before['signature'] as String,
            before['previous'],
          );
        } else {
          await _applyTransactionEdit(
            int.parse(row.read<String>('target')),
            before,
          );
        }
        await _decide(id, AgentSuggestionStatus.undone);
      });
      return null;
    } catch (error) {
      return describeAgentError(error);
    }
  }

  Future<AgentSuggestion> _pending(int id) async {
    final match = (await load(
      statuses: {
        AgentSuggestionStatus.pending,
        AgentSuggestionStatus.rejected,
        AgentSuggestionStatus.undone,
      },
      limit: -1,
    )).where((s) => s.id == id).firstOrNull;
    if (match == null) throw StateError('This suggestion was already decided.');
    return match;
  }

  Future<void> _keepForUndo(int id, Map<String, Object?> before) =>
      database.customStatement(
        'UPDATE agent_suggestions SET before = ? WHERE id = ?',
        [jsonEncode(before), id],
      );

  Future<void> _decide(int id, AgentSuggestionStatus status) =>
      database.customStatement(
        'UPDATE agent_suggestions SET status = ?, decided_at = ?, error = NULL WHERE id = ?',
        [status.name, DateTime.now().millisecondsSinceEpoch, id],
      );

  Future<void> _applyNewCategory(Map<String, Object?> payload) async {
    final type = CategoryTypeStorage.fromStorage(payload['type'] as String);
    final name = payload['name'] as String;
    final parentId = payload['parentId'] as int?;
    final repository = CategoryRepository(database);
    // Added by hand since: nothing left to do.
    if ((await repository.load()).any(
      (c) =>
          c.type == type &&
          c.parentId == parentId &&
          c.name.toLowerCase() == name.toLowerCase(),
    )) {
      return;
    }
    await repository.save(
      name: name,
      type: type,
      parentId: parentId,
      icon: payload['icon'] as String?,
    );
  }

  Future<void> _applySmsCorrection(
    String smsId,
    Map<String, Object?> payload,
  ) async {
    final imports = SmsImportRepository(database);
    Future<QueryRow?> pending(String id) => database
        .customSelect(
          "SELECT candidate FROM sms_imports WHERE fingerprint = ? AND status = 'pending'",
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (await pending(smsId) == null) {
      throw StateError('This message has already been reviewed.');
    }
    if (payload['dismiss'] == true) {
      await imports.dismiss(smsId);
      return;
    }
    if (payload['smsIds'] case final List ids) {
      final corrections = SmsCorrectionRepository(database);
      final correction = SmsCorrection(
        sender: payload['sender'] as String? ?? '',
        ruleId: payload['ruleId'] as String? ?? '',
        direction: payload['direction'] as String?,
        loanId: payload['loanId'] as int?,
      );
      for (final id in ids.cast<String>()) {
        // Reviewed since it was suggested: leave it.
        final current = await pending(id);
        if (current == null) continue;
        final data = Map<String, dynamic>.from(
          jsonDecode(current.read<String>('candidate')) as Map,
        );
        await corrections.apply(data, correction);
        await database.customStatement(
          'UPDATE sms_imports SET candidate = ? WHERE fingerprint = ?',
          [jsonEncode(data), id],
        );
        await database.customStatement(
          'DELETE FROM sms_review WHERE fingerprint = ?',
          [id],
        );
      }
      if (payload['remember'] == true) await corrections.save(correction);
    }
    final row = (await pending(smsId))!;
    if (payload['accountId'] case final int accountId) {
      await imports.assignAccounts({smsId}, accountId);
    }
    if (payload.containsKey('categoryId') ||
        payload.containsKey('categoryName')) {
      final sms = PendingSmsImport(
        id: smsId,
        sender: '',
        body: '',
        data: Map<String, dynamic>.from(
          jsonDecode(row.read<String>('candidate')) as Map,
        ),
        receivedAt: DateTime.now(),
      );
      if (sms.requiresTransfer) {
        throw StateError('This message is a transfer, so it has no category.');
      }
      final category = await _resolveCategory(
        sms.credit ? CategoryType.income : CategoryType.expense,
        payload,
      );
      await database.customStatement(
        "UPDATE sms_imports SET candidate = json_set(candidate, '\$.assignedCategoryId', ?) WHERE fingerprint = ?",
        [category.id, smsId],
      );
    }
    // The review index rebuilds this row from the saved choices.
    await database.customStatement(
      'DELETE FROM sms_review WHERE fingerprint = ?',
      [smsId],
    );
  }

  Future<void> _applyTransactionEdit(
    int id,
    Map<String, Object?> payload,
  ) async {
    final current = await _transaction(id);
    var categoryId = current.categoryId;
    if (payload.containsKey('categoryId') ||
        payload.containsKey('categoryName')) {
      categoryId = (await _resolveCategory(
        current.type == TransactionType.income
            ? CategoryType.income
            : CategoryType.expense,
        payload,
      )).id;
    }
    var accountId = current.accountId;
    if (payload['accountId'] case final int next when next != accountId) {
      accountId = _sameCurrencyAccount(
        await AccountRepository(database).load(),
        next,
        current,
      ).id;
    }
    await TransactionRepository(database).edit(
      id: id,
      type: current.type,
      amountMinor: current.amountMinor,
      accountId: accountId,
      toAccountId: current.toAccountId,
      categoryId: categoryId,
      title: payload.containsKey('title')
          ? payload['title'] as String?
          : current.title,
      note: payload.containsKey('note')
          ? payload['note'] as String?
          : current.note,
      date: current.date,
    );
  }

  // ── Shared checks. ──

  static const _managed =
      'Part of this transaction is managed by its loan, debt or recurring payment. '
      'Change it from there.';

  Future<MoneyTransaction> _transaction(int id) async {
    final r = await database
        .customSelect(
          'SELECT * FROM transactions WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (r == null) throw ArgumentError('No transaction has id $id.');
    return MoneyTransaction(
      id: id,
      type: TransactionTypeStorage.fromStorage(r.read<String>('type')),
      amountMinor: r.read<int>('amount_minor'),
      accountId: r.read<int>('account_id'),
      toAccountId: r.readNullable<int>('to_account_id'),
      toAmountMinor: r.readNullable<int>('to_amount_minor'),
      categoryId: r.readNullable<int>('category_id'),
      title: r.readNullable<String>('title'),
      note: r.readNullable<String>('note'),
      date: DateTime.fromMillisecondsSinceEpoch(r.read<int>('date')),
    );
  }

  /// The same rules as assigning a message's account by hand.
  Account _smsAccount(List<Account> accounts, int id, PendingSmsImport sms) {
    final account = accounts.where((a) => a.id == id).firstOrNull;
    if (account == null ||
        account.isArchived ||
        account.type == AccountType.cash) {
      throw ArgumentError('Account $id isn’t an active bank account or card.');
    }
    if (account.currency != sms.currency ||
        account.digits != 2 ||
        (sms.creditCard && account.type != AccountType.creditCard)) {
      throw ArgumentError(
        '${account.name} doesn’t match this message’s currency or account type.',
      );
    }
    return account;
  }

  /// A transaction stores no currency of its own, so moving it to an account
  /// in another currency would change what its amount means.
  Account _sameCurrencyAccount(
    List<Account> accounts,
    int id,
    MoneyTransaction transaction,
  ) {
    final from = accounts.firstWhere((a) => a.id == transaction.accountId);
    final account = accounts.where((a) => a.id == id).firstOrNull;
    if (account == null || account.isArchived) {
      throw ArgumentError('Account $id isn’t an active account.');
    }
    if (account.currency != from.currency || account.digits != from.digits) {
      throw ArgumentError(
        '${account.name} uses a different currency from ${from.name}.',
      );
    }
    return account;
  }

  Category _parent(
    List<Category> categories,
    CategoryType type,
    int? id,
    String? name,
  ) {
    final matches = categories.where(
      (c) =>
          c.type == type &&
          c.parentId == null &&
          (id != null
              ? c.id == id
              : c.name.toLowerCase() == name!.trim().toLowerCase()),
    );
    if (matches.isEmpty) {
      throw ArgumentError(
        'The parent must be a top-level ${type.label.toLowerCase()} category.',
      );
    }
    return matches.first;
  }

  /// A category by id, or by name ("Swiggy" or "Food › Swiggy"). A name no
  /// category has yet may belong to a pending new-category suggestion.
  Future<({int? id, String label, Map<String, Object?> payload})>
  _categoryChoice(
    List<Category> categories,
    CategoryType type,
    int? id,
    String? name,
  ) async {
    if (id != null) {
      final category = categories.where((c) => c.id == id).firstOrNull;
      if (category == null || category.type != type) {
        throw ArgumentError(
          'Category $id isn’t ${type == CategoryType.income ? 'an income' : 'an expense'} category.',
        );
      }
      return (
        id: id,
        label: _categoryPath(categories, id),
        payload: <String, Object?>{'categoryId': id},
      );
    }
    final found = _byName(categories, type, name!);
    if (found != null) {
      return (
        id: found.id,
        label: _categoryPath(categories, found.id),
        payload: <String, Object?>{'categoryId': found.id},
      );
    }
    final pending = await database
        .customSelect(
          "SELECT payload FROM agent_suggestions WHERE kind = 'new_category' AND status = 'pending'",
        )
        .get();
    final leaf = _leafName(name);
    final waiting = pending.any((r) {
      final p = jsonDecode(r.read<String>('payload')) as Map;
      return p['type'] == type.storageValue &&
          (p['name'] as String).toLowerCase() == leaf.toLowerCase();
    });
    if (!waiting) {
      throw ArgumentError(
        'No ${type.label.toLowerCase()} category is called “$name”. '
        'Suggest it as a new category first.',
      );
    }
    return (
      id: null,
      label: '$leaf (new)',
      payload: <String, Object?>{
        'categoryName': leaf,
        'categoryType': type.storageValue,
      },
    );
  }

  Future<Category> _resolveCategory(
    CategoryType type,
    Map<String, Object?> payload,
  ) async {
    final categories = await CategoryRepository(database).load();
    if (payload['categoryId'] case final int id) {
      final category = categories.where((c) => c.id == id).firstOrNull;
      if (category == null || category.type != type) {
        throw StateError('That category no longer exists.');
      }
      return category;
    }
    final name = payload['categoryName'] as String;
    return _byName(categories, type, name) ??
        (throw StateError('Approve the new category “$name” first.'));
  }

  static Category? _byName(
    List<Category> categories,
    CategoryType type,
    String name,
  ) {
    final parts = name
        .split(RegExp(r'\s*[›>/]\s*'))
        .map((p) => p.trim().toLowerCase())
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    final matches = categories.where((c) {
      if (c.type != type || c.name.toLowerCase() != parts.last) return false;
      if (parts.length == 1) return true;
      final parent = categories.where((p) => p.id == c.parentId).firstOrNull;
      return parent?.name.toLowerCase() == parts[parts.length - 2];
    }).toList();
    if (matches.length > 1) {
      throw ArgumentError(
        'Several categories are called “$name”; use the category id.',
      );
    }
    return matches.firstOrNull;
  }

  static String _leafName(String name) =>
      name.split(RegExp(r'\s*[›>/]\s*')).last.trim();

  static String _categoryPath(List<Category> categories, int? id) {
    final category = categories.where((c) => c.id == id).firstOrNull;
    if (category == null) return '—';
    final parent = categories
        .where((c) => c.id == category.parentId)
        .firstOrNull;
    return parent == null ? category.name : '${parent.name} › ${category.name}';
  }

  static String _accountName(List<Account> accounts, int? id) =>
      accounts.where((a) => a.id == id).firstOrNull?.name ?? '—';

  static String _day(DateTime date) => DateFormat('d MMM yyyy').format(date);

  static String? _reason(String? reason) {
    final clean = reason?.trim() ?? '';
    if (clean.isEmpty) return null;
    return clean.length > 280 ? '${clean.substring(0, 279)}…' : clean;
  }
}
