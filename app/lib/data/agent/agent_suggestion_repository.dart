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
import '../issue_report.dart';
import '../repositories/account_repository.dart';
import '../repositories/category_repository.dart';
import '../repositories/loan_repository.dart';
import '../repositories/recurring_payment_repository.dart';
import '../repositories/sms_corrections.dart';
import '../repositories/sms_import_repository.dart';
import '../repositories/statement_import_repository.dart';
import '../repositories/transaction_repository.dart';
import '../user_sms_rules.dart';
import 'agent_accounts.dart';
import 'agent_loans.dart';
import 'agent_portfolio.dart';
import 'agent_sms_saver.dart';
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
  recurringPayment('recurring_payment'),
  account('account'),
  portfolio('portfolio'),
  developerFeedback('developer_feedback');

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
          kind == AgentSuggestionKind.recurringPayment ||
          (kind == AgentSuggestionKind.account &&
              (AgentAccountAction.fromToolName(payload['action'] as String?)
                      ?.canUndo ??
                  false)) ||
          (kind == AgentSuggestionKind.portfolio &&
              (AgentPortfolioAction.fromToolName(payload['action'] as String?)
                      ?.canUndo ??
                  false)));
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
  AgentSuggestionRepository(this.database, {this.sendFeedback});
  final AppDatabase database;

  /// Delivers approved developer feedback as plain text; null sends it to the
  /// developer's Telegram channel, as Help › Send feedback does. Replaced in
  /// tests so nothing goes out to the network.
  final Future<void> Function(String text)? sendFeedback;

  static const _feedbackKinds = {
    'missing_tool': 'AI tool missing',
    'feature_request': 'Feature request',
    'bug': 'Problem',
  };

  /// A message for the developer, written by the AI app and sent only after
  /// the user reads and approves it.
  AgentSuggestionDraft prepareDeveloperFeedback({
    required String message,
    String? title,
    String kind = 'missing_tool',
    String? reason,
  }) {
    final text = message.trim();
    final heading = title?.trim() ?? '';
    if (text.length < 10 || text.length > 1500) {
      throw ArgumentError('The message must be 10–1500 characters.');
    }
    if (heading.length > 80) {
      throw ArgumentError('The title can be at most 80 characters.');
    }
    final label = _feedbackKinds[kind];
    if (label == null) {
      throw ArgumentError('kind must be ${_feedbackKinds.keys.join(', ')}.');
    }
    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.developerFeedback,
      target: jsonEncode([kind, text.toLowerCase()]),
      payload: {'kind': kind, 'title': heading, 'message': text},
      summary: 'Send feedback to the developer',
      detail: [
        if (heading.isNotEmpty) '$label: $heading' else label,
        ...text.split('\n'),
      ],
      reason: _reason(reason),
    );
  }

  /// The plain text the developer receives.
  static String feedbackText(Map<String, Object?> payload) {
    final heading = (payload['title'] as String?) ?? '';
    final label = _feedbackKinds[payload['kind']] ?? 'Feedback';
    final source = payload['source'] as String?;
    return '${source == null ? 'AI assistant' : 'AI assistant ($source)'} · '
        '$label${heading.isEmpty ? '' : ': $heading'}\n\n'
        '${payload['message']}';
  }

  Future<void> _sendFeedback(Map<String, Object?> payload) async {
    final text = feedbackText(payload);
    try {
      await (sendFeedback ?? IssueReporter().send)(text);
    } on IssueReportException catch (error) {
      throw StateError(error.message);
    }
  }

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

  /// A change to a saved transaction, made the way the transaction screen
  /// makes it: its category, accounts, title, note, amount, date or kind
  /// (an expense or income can become a transfer between the user's
  /// accounts, and back), or its removal ([delete]), as for a duplicate.
  /// What a loan, debt or recurring payment owns stays theirs.
  Future<AgentSuggestionDraft> prepareTransactionEdit({
    required int transactionId,
    int? categoryId,
    String? categoryName,
    int? accountId,
    String? title,
    String? note,
    int? loanId,
    TransactionType? type,
    int? toAccountId,
    String? amount,
    DateTime? date,
    bool delete = false,
    String? reason,
  }) async {
    final current = await _transaction(transactionId);
    final accounts = await AccountRepository(database).load();
    final categories = await CategoryRepository(database).load();
    final transactions = TransactionRepository(database);
    final changes = [
      categoryId,
      categoryName,
      accountId,
      title,
      note,
      type,
      toAccountId,
      amount,
      date,
    ].any((v) => v != null);
    if (loanId != null) {
      if (changes || delete) {
        throw ArgumentError('Give loan_id on its own.');
      }
      return _prepareLoanPayment(current, loanId, accounts, categories, reason);
    }
    final account = accounts.firstWhere((a) => a.id == current.accountId);
    final summary =
        '${formatAccountMoney(current.amountMinor, digits: account.digits, currency: account.currency)}'
        ' · ${_describe(current, accounts, categories)}'
        ' · ${_day(current.date)}';
    final link = await transactions.link(transactionId);
    if (delete) {
      if (changes) {
        throw ArgumentError(
          'delete removes the transaction: give nothing else.',
        );
      }
      if (link != null) {
        throw ArgumentError(
          'It belongs to ${link.name}. Remove it from there in the app.',
        );
      }
      return AgentSuggestionDraft(
        kind: AgentSuggestionKind.transactionEdit,
        target: '$transactionId',
        payload: const {'delete': true},
        // Undo puts it back as it was, with the same id.
        before: {..._snapshot(current), 'restore': true},
        summary: summary,
        detail: const ['Delete this transaction'],
        reason: _reason(reason),
      );
    }

    final locks = link?.locks ?? const TransactionLocks();
    final next = type ?? current.type;
    final transfer = next == TransactionType.transfer;
    final payload = <String, Object?>{};
    final detail = <String>[];
    void lock(bool locked) {
      if (locked) throw ArgumentError(_managed);
    }

    if (next != current.type) {
      lock(locks.type || (transfer && locks.transfer));
      payload['type'] = next.storageValue;
      detail.add('Type: ${current.type.name} → ${next.name}');
    }
    if (transfer &&
        (categoryId != null || categoryName != null || title != null)) {
      throw ArgumentError('A transfer has no category or title.');
    }
    if (!transfer && toAccountId != null) {
      throw ArgumentError('to_account_id is only for a transfer.');
    }

    final from = accountId ?? current.accountId;
    if (from != current.accountId) {
      lock(locks.accounts);
      final chosen = _sameCurrencyAccount(accounts, from, current);
      payload['accountId'] = chosen.id;
      detail.add(
        '${transfer ? 'From' : 'Account'}: '
        '${_accountName(accounts, current.accountId)} → ${chosen.name}',
      );
    }
    if (transfer) {
      final to = toAccountId ?? current.toAccountId;
      if (to == null) {
        throw ArgumentError('Give to_account_id: the account it went to.');
      }
      if (to == from) {
        throw ArgumentError('A transfer needs two different accounts.');
      }
      if (to != current.toAccountId) {
        lock(locks.accounts);
        final chosen = _sameCurrencyAccount(accounts, to, current);
        payload['toAccountId'] = chosen.id;
        detail.add(
          'To: ${_accountName(accounts, current.toAccountId)} → ${chosen.name}',
        );
      }
    }

    if (amount != null) {
      final minor = parseAccountAmount(
        amount.replaceAll(',', ''),
        account.digits,
      );
      if (minor == null || minor <= 0) {
        throw ArgumentError('amount must be an amount like 250.00.');
      }
      if (minor != current.amountMinor) {
        lock(locks.amount);
        payload['amountMinor'] = minor;
        String money(int m) => formatAccountMoney(
          m,
          digits: account.digits,
          currency: account.currency,
        );
        detail.add('Amount: ${money(current.amountMinor)} → ${money(minor)}');
      }
    }
    if (date != null) {
      final now = DateTime.now();
      final day = DateTime(date.year, date.month, date.day);
      if (day.isAfter(DateTime(now.year, now.month, now.day))) {
        throw ArgumentError('The date can’t be in the future.');
      }
      final was = DateTime(
        current.date.year,
        current.date.month,
        current.date.day,
      );
      if (day != was) {
        lock(locks.date);
        // The same time of day, on the new day.
        payload['date'] = DateTime(
          day.year,
          day.month,
          day.day,
          current.date.hour,
          current.date.minute,
          current.date.second,
        ).millisecondsSinceEpoch;
        detail.add('Date: ${_day(current.date)} → ${_day(day)}');
      }
    }

    if (!transfer) {
      final wanted = next == TransactionType.income
          ? CategoryType.income
          : CategoryType.expense;
      final kept = categories
          .where((c) => c.id == current.categoryId && c.type == wanted)
          .firstOrNull;
      if (categoryId != null || categoryName != null) {
        final choice = await _categoryChoice(
          categories,
          wanted,
          categoryId,
          categoryName,
        );
        if (choice.id == null || choice.id != current.categoryId) {
          lock(locks.category);
          payload.addAll(choice.payload);
          detail.add(
            'Category: ${_categoryPath(categories, current.categoryId)} → ${choice.label}',
          );
        }
      } else if (kept == null) {
        throw ArgumentError(
          'As ${next == TransactionType.income ? 'income' : 'an expense'} it '
          'needs a category: give category_id or category_name.',
        );
      }
      if (title != null) {
        final clean = title.trim();
        if (clean.length > 80) {
          throw ArgumentError('Keep the title to 80 characters.');
        }
        if (clean != (current.title ?? '')) {
          payload['title'] = clean.isEmpty ? null : clean;
          detail.add(
            'Title: ${current.title ?? '—'} → ${clean.isEmpty ? '—' : clean}',
          );
        }
      }
    }
    if (note != null && note.trim() != (current.note ?? '').trim()) {
      final clean = note.trim();
      payload['note'] = clean.isEmpty ? null : clean;
      detail.add('Note: ${clean.isEmpty ? 'removed' : 'updated'}');
    }
    if (payload.isEmpty) throw ArgumentError('Nothing would change.');
    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.transactionEdit,
      target: '$transactionId',
      payload: payload,
      // Undo puts every field back, whatever changed.
      before: _snapshot(current),
      summary: summary,
      detail: detail,
      reason: _reason(reason),
    );
  }

  /// Everything an edit can change, to put back on undo.
  static Map<String, Object?> _snapshot(MoneyTransaction t) => {
    'type': t.type.storageValue,
    'accountId': t.accountId,
    'toAccountId': t.toAccountId,
    'toAmountMinor': t.toAmountMinor,
    'amountMinor': t.amountMinor,
    'date': t.date.millisecondsSinceEpoch,
    'categoryId': t.categoryId,
    'title': t.title,
    'note': t.note,
  };

  /// "Swiggy", its category, or for a transfer "Kotak → SBI".
  static String _describe(
    MoneyTransaction t,
    List<Account> accounts,
    List<Category> categories,
  ) => t.type == TransactionType.transfer
      ? '${_accountName(accounts, t.accountId)} → '
            '${_accountName(accounts, t.toAccountId)}'
      : t.title ?? _categoryPath(categories, t.categoryId);

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
    int? toAccountId,
    String? receivedAmount,
    String? reason,
  }) async {
    if (type == TransactionType.transfer) {
      if (categoryId != null || categoryName != null || title != null) {
        throw ArgumentError('A transfer has no category or title.');
      }
      return _prepareTransferAdd(
        amount: amount,
        accountId: accountId,
        toAccountId: toAccountId,
        received: receivedAmount,
        note: note,
        date: date,
        ignoreDuplicates: ignoreDuplicates,
        reason: reason,
      );
    }
    if (toAccountId != null) {
      throw ArgumentError('to_account_id is only for a transfer.');
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

  /// Money moved between two of the user's accounts: from a bank to a
  /// broker, a card bill paid from savings. Accounts in two currencies need
  /// what reached the other side ([received]).
  Future<AgentSuggestionDraft> _prepareTransferAdd({
    required String amount,
    required int accountId,
    required int? toAccountId,
    String? received,
    String? note,
    DateTime? date,
    required bool ignoreDuplicates,
    String? reason,
  }) async {
    final accounts = await AccountRepository(database).load();
    Account active(int? id, String field) =>
        accounts.where((a) => a.id == id && !a.isArchived).firstOrNull ??
        (throw ArgumentError(
          id == null ? 'Give $field.' : 'Account $id isn’t an active account.',
        ));
    final from = active(accountId, 'account_id');
    final to = active(toAccountId, 'to_account_id: where the money went');
    if (from.id == to.id) {
      throw ArgumentError('A transfer needs two different accounts.');
    }
    final minor = parseAccountAmount(amount.replaceAll(',', ''), from.digits);
    if (minor == null || minor <= 0) {
      throw ArgumentError('amount must be an amount like 250.00.');
    }
    final sameCurrency =
        from.currency == to.currency && from.digits == to.digits;
    int? toMinor;
    if (!sameCurrency) {
      toMinor = received == null
          ? null
          : parseAccountAmount(received.replaceAll(',', ''), to.digits);
      if (toMinor == null || toMinor <= 0) {
        throw ArgumentError(
          '${to.name} is in ${to.currency}: give received_amount, what '
          'reached it.',
        );
      }
    }
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = date == null
        ? today
        : DateTime(date.year, date.month, date.day);
    if (day.isAfter(today)) {
      throw ArgumentError('The date can’t be in the future.');
    }
    final cleanNote = note?.trim() ?? '';
    if (!ignoreDuplicates) {
      final same = await database
          .customSelect(
            "SELECT id FROM transactions WHERE type = 'transfer' AND "
            'account_id = ? AND to_account_id = ? AND amount_minor = ? AND '
            'date >= ? AND date < ? LIMIT 1',
            variables: [
              Variable(from.id),
              Variable(to.id),
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
          'This transfer is already saved (id ${same.read<int>('id')}). Send '
          'ignore_duplicates true if this is a different one.',
        );
      }
    }
    String money(int m, Account a) =>
        formatAccountMoney(m, digits: a.digits, currency: a.currency);
    return AgentSuggestionDraft(
      kind: AgentSuggestionKind.transactionAdd,
      target: jsonEncode([
        'transfer',
        from.id,
        to.id,
        minor,
        day.toIso8601String(),
        cleanNote.toLowerCase(),
      ]),
      payload: {
        'type': TransactionType.transfer.storageValue,
        'amount': minor,
        'accountId': from.id,
        'toAccountId': to.id,
        'toAmount': ?toMinor,
        'note': cleanNote.isEmpty ? null : cleanNote,
        'date': day.toIso8601String(),
      },
      summary:
          'Add transfer · ${money(minor, from)} · ${from.name} → ${to.name}'
          ' · ${_day(day)}',
      detail: [
        'From ${from.name} to ${to.name}',
        if (toMinor != null) '${to.name} receives ${money(toMinor, to)}',
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
    if (type == TransactionType.transfer) {
      final id = await TransactionRepository(database).addTransfer(
        amountMinor: payload['amount'] as int,
        fromAccountId: payload['accountId'] as int,
        toAccountId: payload['toAccountId'] as int,
        toAmountMinor: payload['toAmount'] as int?,
        note: payload['note'] as String?,
        date: DateTime.parse(payload['date'] as String),
      );
      return {'transactionId': id};
    }
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
    List<int> transactionIds = const [],
    List<String> waitingSms = const [],
    List<LoanSms> unreadSms = const [],
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
    // Bank messages of its past payments: saved on approval, so none is left
    // waiting in SMS review or unread. Each keeps what the card shows.
    final messages = <Map<String, Object?>>[];
    for (final id in waitingSms.toSet()) {
      final row = await database
          .customSelect(
            '''SELECT i.status, i.transaction_id, i.received_at, i.candidate,
                r.account_id
            FROM sms_imports i
            LEFT JOIN sms_review r ON r.fingerprint = i.fingerprint
            WHERE i.fingerprint = ?''',
            variables: [Variable(id)],
          )
          .getSingleOrNull();
      if (row == null) {
        throw ArgumentError('No bank message has sms_id “$id”.');
      }
      if (row.read<String>('status') != 'pending') {
        final saved = row.readNullable<int>('transaction_id');
        throw ArgumentError(
          saved != null
              ? 'Bank message “$id” is already saved as transaction $saved: '
                    'give it in transaction_ids instead.'
              : 'Bank message “$id” was dismissed in SMS review.',
        );
      }
      final data = Map<String, dynamic>.from(
        jsonDecode(row.read<String>('candidate')) as Map,
      );
      final credit = data['direction'] == 'credit';
      if (credit != incoming || data['currencyCode'] != account.currency) {
        throw ArgumentError(
          'Bank message “$id” isn’t ${incoming ? 'money in' : 'money out'} '
          'in ${account.currency}.',
        );
      }
      // Into the account it's linked to, when that one fits; else this one.
      final linked =
          row.readNullable<int>('account_id') ??
          data['assignedAccountId'] as int?;
      final into = accounts
          .where(
            (a) =>
                a.id == linked &&
                !a.isArchived &&
                a.currency == account.currency &&
                a.digits == account.digits,
          )
          .firstOrNull;
      messages.add({
        'kind': 'review',
        'id': id,
        'date': DateTime.fromMillisecondsSinceEpoch(
          row.read<int>('received_at'),
        ).toIso8601String(),
        'amount': data['amountMinor'] as int,
        'accountId': (into ?? account).id,
      });
    }
    final rupees = RegExp(
      r'(?:rs\.?|inr|₹)\s*([\d,]+(?:\.\d{1,2})?)',
      caseSensitive: false,
    );
    for (final sms in {for (final s in unreadSms) s.id: s}.values) {
      if (account.currency != 'INR' || account.digits != 2) {
        throw ArgumentError(
          'Unparsed bank messages are only saved to rupee accounts.',
        );
      }
      final read = switch (rupees.firstMatch(sms.body)?.group(1)) {
        final text? => parseAccountAmount(text.replaceAll(',', ''), 2),
        null => null,
      };
      messages.add({
        'kind': 'unparsed',
        ...unreadSmsPayload(sms),
        'date': sms.receivedAt.toIso8601String(),
        // What the message says it was, else this payment's usual amount.
        'amount': read != null && read > 0 ? read : minor,
        'accountId': account.id,
      });
    }
    // Past payments become its history. Each must be one of this kind and
    // currency, and not already part of a loan, debt or recurring payment.
    final history = transactionIds.toSet().toList();
    if (history.isNotEmpty) {
      final rows = await database
          .customSelect(
            '''SELECT t.id, t.type, a.currency, a.digits,
              (NOT EXISTS (SELECT 1 FROM loan_events l WHERE l.transaction_id = t.id)
                AND NOT EXISTS (SELECT 1 FROM debt_entries d WHERE d.transaction_id = t.id)
                AND NOT EXISTS (SELECT 1 FROM recurring_payment_history p
                  WHERE p.transaction_id = t.id)) AS free
            FROM transactions t JOIN accounts a ON a.id = t.account_id
            WHERE t.id IN (${List.filled(history.length, '?').join(',')})''',
            variables: [for (final id in history) Variable(id)],
          )
          .get();
      final byId = {for (final r in rows) r.read<int>('id'): r};
      for (final id in history) {
        final row = byId[id];
        if (row == null) throw ArgumentError('No transaction has id $id.');
        if (row.read<String>('type') != (incoming ? 'income' : 'expense') ||
            row.read<String>('currency') != account.currency ||
            row.read<int>('digits') != account.digits) {
          throw ArgumentError(
            'Transaction $id isn’t ${incoming ? 'money in' : 'an expense'} '
            'in ${account.currency}.',
          );
        }
        if (row.read<int>('free') != 1) {
          throw ArgumentError(
            'Transaction $id already belongs to a loan, debt or recurring '
            'payment.',
          );
        }
      }
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
        if (history.isNotEmpty) 'history': history,
        if (messages.isNotEmpty) 'smsHistory': messages,
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
        if (history.isNotEmpty)
          'Links ${history.length} past '
              '${history.length == 1 ? 'payment' : 'payments'} as its history',
        if (messages.isNotEmpty)
          'Saves ${messages.length} bank '
              '${messages.length == 1 ? 'message' : 'messages'} as past '
              'payments, so none is left in SMS review or unread',
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
    // Its bank messages first: each becomes a transaction under its category
    // and joins the history below. One dismissed since is left out.
    final recurring = RecurringPaymentRepository(database);
    final saver = AgentSmsSaver(database);
    final fromSms = <int>[];
    int? filed;
    for (final sms
        in (payload['smsHistory'] as List? ?? const []).cast<Map>()) {
      filed ??= await recurring.categoryFor(category?.id, incoming);
      final type = incoming ? TransactionType.income : TransactionType.expense;
      final saved = sms['kind'] == 'unparsed'
          ? await saver.saveUnread(
              sms,
              accountId: sms['accountId'] as int,
              amountMinor: sms['amount'] as int,
              categoryId: filed,
              title: payload['name'] as String,
              currency: 'INR',
              type: type,
              ruleId: 'recurring',
            )
          : await saver.saveWaiting(
              sms['id'] as String,
              accountId: sms['accountId'] as int,
              categoryId: filed,
              type: type,
              title: payload['name'] as String,
            );
      if (saved != null) fromSms.add(saved);
    }
    // Its past payments, as marking each paid would have recorded them. One
    // claimed by something else since the suggestion was made is left out.
    for (final transactionId in [
      ...(payload['history'] as List? ?? const []),
      ...fromSms,
    ]) {
      await database.customStatement(
        '''INSERT INTO recurring_payment_history
          (transaction_id, recurring_payment_id)
        SELECT ?, ? WHERE EXISTS (SELECT 1 FROM transactions WHERE id = ?)
          AND NOT EXISTS (SELECT 1 FROM recurring_payment_history
            WHERE transaction_id = ?)
          AND NOT EXISTS (SELECT 1 FROM loan_events WHERE transaction_id = ?)
          AND NOT EXISTS (SELECT 1 FROM debt_entries WHERE transaction_id = ?)''',
        [
          transactionId, id, // the row
          transactionId, // still exists
          transactionId, transactionId, transactionId, // and nothing owns it
        ],
      );
    }
    return {'recurringPaymentId': id, 'savedSms': fromSms};
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
      // The network is used before the transaction opens, so a slow send
      // never holds the database. A failed send leaves it pending.
      final first = await _pending(id);
      if (first.kind == AgentSuggestionKind.developerFeedback) {
        await _sendFeedback(first.payload);
      }
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
          case AgentSuggestionKind.account:
            await _keepForUndo(id, {
              'action': suggestion.payload['action'],
              ...await AgentAccounts(database).apply(suggestion.payload),
            });
          case AgentSuggestionKind.portfolio:
            await _keepForUndo(id, {
              'action': suggestion.payload['action'],
              ...await AgentPortfolio(database).apply(suggestion.payload),
            });
          case AgentSuggestionKind.developerFeedback:
            break; // Already sent; there is nothing to change or undo.
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
              "SELECT kind, target, before FROM agent_suggestions WHERE id = ? AND status = 'applied' AND kind IN ('transaction_edit', 'parser_rule', 'statement_layout', 'new_loan', 'debt_entry', 'transaction_add', 'recurring_payment', 'account', 'portfolio')",
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
        if (row.read<String>('kind') == 'portfolio') {
          await AgentPortfolio(database)
              .undo(before['action'] as String, before);
        } else if (row.read<String>('kind') == 'account') {
          await AgentAccounts(database)
              .undo(before['action'] as String, before);
        } else if (row.read<String>('kind') == 'new_loan') {
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

  /// Makes an approved edit, or (undoing one) puts back what [payload]
  /// recorded. Only the fields it names change; the rest stay as they are.
  Future<void> _applyTransactionEdit(
    int id,
    Map<String, Object?> payload,
  ) async {
    final transactions = TransactionRepository(database);
    if (payload['delete'] == true) {
      if (await transactions.link(id) case final link?) {
        throw StateError(
          'It belongs to ${link.name} now. Remove it from there.',
        );
      }
      await transactions.delete(id);
      return;
    }
    if (payload['restore'] == true) {
      await _restoreTransaction(id, payload);
      return;
    }
    final current = await _transaction(id);
    final type = switch (payload['type']) {
      final String stored => TransactionTypeStorage.fromStorage(stored),
      _ => current.type,
    };
    final transfer = type == TransactionType.transfer;
    final accounts = await AccountRepository(database).load();
    var accountId = current.accountId;
    if (payload['accountId'] case final int next when next != accountId) {
      accountId = _sameCurrencyAccount(accounts, next, current).id;
    }
    int? toAccountId;
    if (transfer) {
      toAccountId = payload.containsKey('toAccountId')
          ? payload['toAccountId'] as int?
          : current.toAccountId;
      if (toAccountId != null && toAccountId != current.toAccountId) {
        toAccountId = _sameCurrencyAccount(accounts, toAccountId, current).id;
      }
    }
    int? categoryId;
    if (!transfer) {
      final wanted = type == TransactionType.income
          ? CategoryType.income
          : CategoryType.expense;
      categoryId =
          payload['categoryId'] != null || payload['categoryName'] != null
          ? (await _resolveCategory(wanted, payload)).id
          : current.categoryId;
    }
    await transactions.edit(
      id: id,
      type: type,
      amountMinor: payload['amountMinor'] as int? ?? current.amountMinor,
      accountId: accountId,
      toAccountId: toAccountId,
      categoryId: categoryId,
      title: payload.containsKey('title')
          ? payload['title'] as String?
          : current.title,
      note: payload.containsKey('note')
          ? payload['note'] as String?
          : current.note,
      date: switch (payload['date']) {
        final int ms => DateTime.fromMillisecondsSinceEpoch(ms),
        _ => current.date,
      },
    );
  }

  /// Puts a deleted transaction back as [before] recorded it, under its old
  /// id, so whatever pointed at it (the bank SMS it came from) does again.
  Future<void> _restoreTransaction(int id, Map<String, Object?> before) async {
    final taken = await database
        .customSelect(
          'SELECT 1 FROM transactions WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (taken != null) return;
    final transactions = TransactionRepository(database);
    final type = TransactionTypeStorage.fromStorage(before['type'] as String);
    final date = DateTime.fromMillisecondsSinceEpoch(before['date'] as int);
    final amount = before['amountMinor'] as int;
    final added = type == TransactionType.transfer
        ? await transactions.addTransfer(
            amountMinor: amount,
            fromAccountId: before['accountId'] as int,
            toAccountId: before['toAccountId'] as int,
            toAmountMinor: before['toAmountMinor'] as int?,
            note: before['note'] as String?,
            date: date,
          )
        : await transactions.addExpenseOrIncome(
            type: type,
            amountMinor: amount,
            accountId: before['accountId'] as int,
            categoryId:
                before['categoryId'] as int? ??
                (throw StateError('Its category was deleted.')),
            title: before['title'] as String?,
            note: before['note'] as String?,
            date: date,
          );
    await database.customUpdate(
      'UPDATE transactions SET id = ? WHERE id = ?',
      variables: [Variable(id), Variable(added)],
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
