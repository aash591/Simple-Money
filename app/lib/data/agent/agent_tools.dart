import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart';
import 'package:intl/intl.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../../domain/account.dart';
import '../../domain/app_icons.dart';
import '../../domain/brand_icons.dart';
import '../../domain/category.dart';
import '../../domain/debt.dart';
import '../../domain/loan.dart';
import '../../domain/transaction.dart';
import '../../state/sms_import_store.dart';
import '../db/app_database.dart';
import '../reportable_sms.dart';
import '../repositories/account_repository.dart';
import '../repositories/category_repository.dart';
import '../repositories/debt_repository.dart';
import '../repositories/loan_repository.dart';
import '../repositories/recurring_payment_repository.dart';
import '../repositories/sms_review_repository.dart';
import '../statements/statement_table.dart';
import '../statements/upi_statement.dart';
import 'agent_loans.dart';
import 'agent_rules.dart';
import 'agent_suggestion_repository.dart';
import 'sms_labeler.dart';
import 'statement_samples.dart';

part 'agent_tool_definitions.dart';

/// One tool an AI app can call, described the way MCP's `tools/list` wants.
class AgentTool {
  const AgentTool({
    required this.name,
    required this.title,
    required this.description,
    required this.inputSchema,
    required this.handler,
    this.readOnly = true,
  });
  final String name, title, description;
  final Map<String, Object?> inputSchema;
  final Future<Object?> Function(Map<String, Object?> args) handler;

  /// Suggestion tools are not read-only, but they change nothing the user
  /// hasn't approved, so none is destructive.
  final bool readOnly;

  Map<String, Object?> get definition => {
    'name': name,
    'title': title,
    'description': description,
    'inputSchema': inputSchema,
    'annotations': {
      'readOnlyHint': readOnly,
      'destructiveHint': false,
      'idempotentHint': readOnly,
      'openWorldHint': false,
    },
  };
}

/// The tools SimpleMoney answers for a connected AI app, run against the
/// local database. Reading tools see the ledger and the SMS review queue;
/// writing tools only create suggestions, which the user approves in the app.
///
/// [call] returns an MCP `tools/call` result, so whatever carries the call
/// (a relay, a local server, a test) passes it on unchanged.
class AgentTools {
  AgentTools(
    this.database, {
    this.onSuggestionsChanged,
    this.missedSms,
    this.canUsePro,
  });
  final AppDatabase database;

  /// Whether this user has SimpleMoney Pro; null means every tool is open.
  /// Without Pro only [freeTools] answer: teaching the app a missed SMS or a
  /// statement layout stays free, so a file or bank it can't read never
  /// leaves anyone stuck.
  final bool Function()? canUsePro;

  /// Tools that answer without Pro: teaching the app, and the lists those
  /// need.
  static const freeTools = {
    'list_accounts',
    'list_categories',
    'list_suggestions',
    'list_missed_sms',
    'label_sms',
    'list_statements_to_map',
    'map_statement',
    'get_parser_rules',
    'test_parser_rule',
    'suggest_parser_rule',
  };

  static const proNeeded =
      'Answering questions and suggesting fixes needs SimpleMoney Pro. Tell '
      'the user they can get it in SimpleMoney → More → SimpleMoney Pro. '
      'Teaching the app stays free: a missed bank SMS (list_missed_sms, '
      'label_sms) or a statement layout (list_statements_to_map, '
      'map_statement).';

  /// Called after a tool adds suggestions, so the app can show them.
  final void Function()? onSuggestionsChanged;

  /// Payment-like inbox messages no rule reads, from the last [window].
  /// Defaults to reading the phone's inbox.
  final Future<List<ReportableSms>> Function(Duration window)? missedSms;

  late final AgentRuleLab rules = AgentRuleLab(database);

  late final AgentSuggestionRepository suggestions = AgentSuggestionRepository(
    database,
  );

  late final AgentLoans loans = AgentLoans(database);

  /// The server instructions MCP's `initialize` sends.
  static const instructions =
      'SimpleMoney is the user\'s money manager, answered live by their phone. '
      'Amounts are decimal strings with a currency code: never add or compare '
      'amounts in different currencies as one number. Dates are YYYY-MM-DD in '
      'the user\'s local time. Look up ids with list_accounts and '
      'list_categories before suggesting changes. Suggestion tools change '
      'nothing by themselves: tell the user to open SimpleMoney → More → AI '
      'suggestions to approve them. To use a category that doesn\'t exist, '
      'suggest it with suggest_new_categories first, then refer to it by name. '
      'To sort "Personal" transactions: list_payees_to_categorize, then '
      'categorize_payee per payee. When a balance or total looks wrong: '
      'account_activity. Totals come exact from spending_summary (it groups '
      'by payee too) and search_transactions: never add amounts up '
      'yourself. '
      'To teach the app a bank SMS it misses: list_missed_sms, then '
      'label_sms with values copied exactly from one message. To teach it a '
      'statement layout: list_statements_to_map, then map_statement with '
      'column names. When the user shares a loan statement or sanction '
      'letter: read it, then suggest_loan with what it says and every payment '
      'from the start; the app finds those payments in the ledger so nothing '
      'is recorded twice. Money lent to or borrowed from a person: '
      'suggest_debt_entries. To add a new expense or income the user tells '
      'you about or shows you: suggest_transactions. Things that repeat, '
      'such as subscriptions, rent paid or received, premiums and SIPs: '
      'list_recurring_payments, then suggest_recurring_payments. '
      'Work these out yourself rather than asking the user '
      'which value or column is which: they approve the result in the app. '
      'Each reply\'s next says what usually comes next; follow it, or take '
      'your own route when you can see a better one. These are the simplest '
      'paths, not the only ones: combine any tools, e.g. '
      'suggest_transaction_edits for many transactions in one call, or write '
      'a full SMS format with get_parser_rules, test_parser_rule and '
      'suggest_parser_rule.';

  static const _maxItems = 200;

  late final List<AgentTool> tools = _createTools();

  late final Map<String, AgentTool> _byName = {
    for (final tool in tools) tool.name: tool,
  };

  List<Map<String, Object?>> get definitions => [
    for (final tool in tools) tool.definition,
  ];

  /// Runs [name] and returns an MCP tool result. Bad input comes back as an
  /// error result the AI app can read and correct, never as an exception.
  Future<Map<String, Object?>> call(
    String name,
    Map<String, Object?> arguments,
  ) async {
    final tool = _byName[name];
    if (tool == null) return _result('SimpleMoney has no tool $name.', true);
    if (!freeTools.contains(name) && !(canUsePro?.call() ?? true)) {
      return _result(proNeeded, true);
    }
    try {
      return _result(jsonEncode(await tool.handler(arguments)), false);
    } on _BadInput catch (error) {
      return _result(error.message, true);
    } catch (error) {
      return _result(describeAgentError(error), true);
    }
  }

  static Map<String, Object?> _result(String text, bool isError) => {
    'content': [
      {'type': 'text', 'text': text},
    ],
    'isError': isError,
  };

  // ── Reading. ──

  Future<Object?> _listAccounts(Map<String, Object?> args) async {
    final archived = _bool(args, 'include_archived') ?? false;
    return {
      'accounts': [
        for (final a in await AccountRepository(database).load())
          if (archived || !a.isArchived)
            {
              'id': a.id,
              'name': a.name,
              'type': a.type.name,
              'currency': a.currency,
              'balance': _amount(a.balanceMinor, a.digits),
              if (a.balanceReportedAt case final at?)
                'balance_from_bank_sms_on': _isoDay(at),
              'last_digits': ?a.lastDigits,
              'institution': ?a.institution,
              if (a.isArchived) 'archived': true,
            },
      ],
    };
  }

  Future<Object?> _listCategories(Map<String, Object?> args) async {
    final type = _enum(args, 'type', const ['expense', 'income', 'debt_loan']);
    final categories = await CategoryRepository(database).load();
    return {
      'categories': [
        for (final c in categoriesInDisplayOrder(categories))
          if (type == null || c.type.storageValue == type)
            {
              'id': c.id,
              'name': c.name,
              'type': c.type.storageValue,
              if (c.parentId != null) ...{
                'parent_id': c.parentId,
                'parent': categories
                    .where((p) => p.id == c.parentId)
                    .firstOrNull
                    ?.name,
              },
            },
      ],
    };
  }

  Future<Object?> _searchTransactions(Map<String, Object?> args) async {
    final (from, to) = _range(args);
    final type = _enum(args, 'type', const ['expense', 'income', 'transfer']);
    final categoryId = _int(args, 'category_id');
    final accountId = _int(args, 'account_id');
    final query = _string(args, 'query')?.toLowerCase();
    final notes = _bool(args, 'include_notes') ?? false;
    final limit = (_int(args, 'limit') ?? 50).clamp(1, 200);
    final offset = math.max(0, _int(args, 'offset') ?? 0);
    final where = <String>['t.date >= ?', 't.date < ?'];
    final variables = <Variable>[
      Variable(from.millisecondsSinceEpoch),
      Variable(to.millisecondsSinceEpoch),
    ];
    if (type != null) {
      where.add('t.type = ?');
      variables.add(Variable(type));
    }
    if (accountId != null) {
      where.add('(t.account_id = ? OR t.to_account_id = ?)');
      variables.addAll([Variable(accountId), Variable(accountId)]);
    }
    if (categoryId != null) {
      where.add('(t.category_id = ? OR c.parent_id = ?)');
      variables.addAll([Variable(categoryId), Variable(categoryId)]);
    }
    if (query != null) {
      where.add(
        "(instr(lower(coalesce(t.title, '')), ?) > 0 "
        "OR instr(lower(coalesce(t.note, '')), ?) > 0 "
        "OR instr(lower(coalesce(c.name, '')), ?) > 0)",
      );
      variables.addAll([Variable(query), Variable(query), Variable(query)]);
    }
    const joins = '''FROM transactions t
      JOIN accounts a ON a.id = t.account_id
      LEFT JOIN accounts ta ON ta.id = t.to_account_id
      LEFT JOIN categories c ON c.id = t.category_id
      LEFT JOIN categories p ON p.id = c.parent_id''';
    final sums = await database.customSelect(
      '''SELECT t.type, a.currency, a.digits, COUNT(*) AS n,
            SUM(t.amount_minor) AS total
          $joins WHERE ${where.join(' AND ')}
          GROUP BY t.type, a.currency, a.digits''',
      variables: variables,
    ).get();
    final total = sums.fold(0, (n, r) => n + r.read<int>('n'));
    final rows = await database
        .customSelect(
          '''SELECT t.*, a.name AS account_name, a.currency, a.digits,
            ta.name AS to_account_name, ta.currency AS to_currency,
            ta.digits AS to_digits, c.name AS category_name,
            p.name AS parent_name
          $joins WHERE ${where.join(' AND ')}
          ORDER BY t.date DESC, t.id DESC LIMIT ? OFFSET ?''',
          variables: [...variables, Variable(limit), Variable(offset)],
        )
        .get();
    return {
      'total': total,
      // Exact, so an AI app never adds rows up itself.
      'totals': [
        for (final r in sums)
          {
            'type': r.read<String>('type'),
            'total': _amount(r.read<int>('total'), r.read<int>('digits')),
            'currency': r.read<String>('currency'),
            'count': r.read<int>('n'),
          },
      ],
      'offset': offset,
      'transactions': [
        for (final r in rows)
          {
            'id': r.read<int>('id'),
            'date': _isoDay(
              DateTime.fromMillisecondsSinceEpoch(r.read<int>('date')),
            ),
            'type': r.read<String>('type'),
            'amount': _amount(
              r.read<int>('amount_minor'),
              r.read<int>('digits'),
            ),
            'currency': r.read<String>('currency'),
            'title': ?r.readNullable<String>('title'),
            'account': {
              'id': r.read<int>('account_id'),
              'name': r.read<String>('account_name'),
            },
            if (r.readNullable<int>('to_account_id') case final to?) ...{
              'to_account': {
                'id': to,
                'name': r.readNullable<String>('to_account_name'),
              },
              if (r.readNullable<int>('to_amount_minor') case final received?)
                'received': {
                  'amount': _amount(received, r.read<int>('to_digits')),
                  'currency': r.read<String>('to_currency'),
                },
            },
            if (r.readNullable<int>('category_id') case final category?)
              'category': {
                'id': category,
                'name': _path(
                  r.readNullable<String>('parent_name'),
                  r.read<String>('category_name'),
                ),
              },
            if (notes) 'note': ?r.readNullable<String>('note'),
          },
      ],
    };
  }

  Future<Object?> _spendingSummary(Map<String, Object?> args) async {
    final (from, to) = _range(args);
    final type = _enum(args, 'type', const ['expense', 'income']) ?? 'expense';
    final groupBy =
        _enum(args, 'group_by', const [
          'category',
          'subcategory',
          'month',
          'account',
          'payee',
        ]) ??
        'category';
    final query = _string(args, 'query')?.toLowerCase();
    final limit = (_int(args, 'limit') ?? 25).clamp(1, 100);
    final key = switch (groupBy) {
      'subcategory' => "CASE WHEN p.name IS NULL THEN c.name ELSE p.name || ' › ' || c.name END",
      'month' => "strftime('%Y-%m', t.date / 1000, 'unixepoch', 'localtime')",
      'account' => 'a.name',
      'payee' => "coalesce(nullif(trim(t.title), ''), 'No name')",
      _ => 'coalesce(p.name, c.name)',
    };
    final rows = await database
        .customSelect(
          '''SELECT $key AS grp, a.currency, a.digits,
            SUM(t.amount_minor) AS total, COUNT(*) AS n
          FROM transactions t
          JOIN accounts a ON a.id = t.account_id
          LEFT JOIN categories c ON c.id = t.category_id
          LEFT JOIN categories p ON p.id = c.parent_id
          WHERE t.type = ? AND t.date >= ? AND t.date < ?
            AND coalesce(c.type, '') != 'debt_loan'
            ${query == null ? '' : "AND (instr(lower(coalesce(t.title, '')), ?) > 0 OR instr(lower(coalesce(c.name, '')), ?) > 0 OR instr(lower(coalesce(p.name, '')), ?) > 0)"}
          GROUP BY grp, a.currency, a.digits
          ORDER BY a.currency, ${groupBy == 'month' ? 'grp' : 'total DESC'}''',
          variables: [
            Variable(type),
            Variable(from.millisecondsSinceEpoch),
            Variable(to.millisecondsSinceEpoch),
            if (query != null) ...[
              Variable(query),
              Variable(query),
              Variable(query),
            ],
          ],
        )
        .get();
    // All of it, per currency, even when only the largest groups are shown.
    final overall = <String, (int, int, int)>{};
    for (final r in rows) {
      final (sum, n, _) = overall[r.read<String>('currency')] ?? (0, 0, 0);
      overall[r.read<String>('currency')] = (
        sum + r.read<int>('total'),
        n + r.read<int>('n'),
        r.read<int>('digits'),
      );
    }
    return {
      'type': type,
      'group_by': groupBy,
      'all': [
        for (final MapEntry(key: currency, value: (sum, n, digits))
            in overall.entries)
          {'total': _amount(sum, digits), 'currency': currency, 'count': n},
      ],
      if (rows.length > limit) 'groups_shown': '$limit of ${rows.length}',
      if (_summaryNotes(rows, overall) case final notes when notes.isNotEmpty)
        'notes': notes,
      'groups': [
        for (final r in rows.take(limit))
          {
            'group': r.readNullable<String>('grp') ?? 'Uncategorized',
            'total': _amount(r.read<int>('total'), r.read<int>('digits')),
            'currency': r.read<String>('currency'),
            'count': r.read<int>('n'),
          },
      ],
    };
  }

  /// What makes a summary's totals look wrong, plainly.
  static List<String> _summaryNotes(
    List<QueryRow> rows,
    Map<String, (int, int, int)> overall,
  ) {
    int share(bool Function(String group) test) {
      var part = 0;
      for (final r in rows) {
        if (test(r.readNullable<String>('grp') ?? '')) {
          part += r.read<int>('total');
        }
      }
      final all = overall.values.fold(0, (n, v) => n + v.$1);
      return all == 0 ? 0 : part * 100 ~/ all;
    }

    final personal = share((g) => g == 'Personal' || g.endsWith('› Personal'));
    final cards = share((g) => g.contains('Credit Card Repayment'));
    return [
      if (personal >= 30)
        '$personal% is "Personal": what SMS import uses when it can’t tell. '
            'list_payees_to_categorize and categorize_payee sort it.',
      if (cards > 0)
        'Credit Card Repayment ($cards%) is paying a card bill. The card’s '
            'own purchases are counted too, so that spending shows twice.',
    ];
  }

  Future<Object?> _listPendingSms(Map<String, Object?> args) async {
    final review = SmsReviewRepository(database);
    final filter = SmsReviewFilter(
      search: _string(args, 'search') ?? '',
      ready: _bool(args, 'ready'),
    );
    final limit = (_int(args, 'limit') ?? 25).clamp(1, 100);
    final offset = math.max(0, _int(args, 'offset') ?? 0);
    final accounts = {
      for (final a in await AccountRepository(database).load()) a.id: a.name,
    };
    final categories = await CategoryRepository(database)
        .load(includeDrafts: true);
    String? categoryName(int? id) {
      final c = categories.where((c) => c.id == id).firstOrNull;
      if (c == null) return null;
      return _path(
        categories.where((p) => p.id == c.parentId).firstOrNull?.name,
        c.name,
      );
    }

    return {
      'total': await review.count(filter),
      'offset': offset,
      'messages': [
        for (final row in await review.page(
          filter: filter,
          offset: offset,
          limit: limit,
        ))
          {
            'sms_id': row.sms.id,
            'received_at': DateFormat("yyyy-MM-dd'T'HH:mm")
                .format(row.sms.receivedAt),
            'sender': row.sms.sender,
            'text': row.sms.body,
            'parsed': {
              'amount': _amount(row.sms.amountMinor, 2),
              'currency': row.sms.currency,
              'direction': row.sms.credit ? 'credit' : 'debit',
              'counterparty': ?row.sms.data['counterparty'],
              'bank': row.sms.bankName,
              'account_last4': ?row.sms.accountLast4,
              'credit_card': row.sms.creditCard,
              if (row.sms.ambiguousAccount) 'account_ambiguous': true,
            },
            'current': {
              'type': row.transaction.type.storageValue,
              if (accounts[row.transaction.accountId] case final name?)
                'account': {'id': row.transaction.accountId, 'name': name},
              if (row.transaction.toAccountId case final to?)
                'to_account': {'id': to, 'name': accounts[to]},
              if (categoryName(row.transaction.categoryId) case final name?)
                'category': {'id': row.transaction.categoryId, 'name': name},
            },
            'ready': row.ready,
          },
      ],
    };
  }

  Future<Object?> _listSuggestions(Map<String, Object?> args) async {
    final status = AgentSuggestionStatus.values.byName(
      _enum(args, 'status', [
            for (final s in AgentSuggestionStatus.values) s.name,
          ]) ??
          'pending',
    );
    return {
      'suggestions': [
        for (final s in await suggestions.load(statuses: {status}, limit: 100))
          {
            'id': s.id,
            'kind': s.kind.storageValue,
            'about': s.summary,
            'changes': s.detail,
            'reason': ?s.reason,
            'error': ?s.error,
            'suggested_at': DateFormat("yyyy-MM-dd'T'HH:mm")
                .format(s.createdAt),
          },
      ],
    };
  }

  // ── Suggesting. ──

  Future<Object?> _suggestNewCategories(Map<String, Object?> args) => _suggest(
    args,
    (item) => suggestions.prepareNewCategory(
      name: _requiredString(item, 'name'),
      type: CategoryTypeStorage.fromStorage(
        _enum(item, 'type', const ['expense', 'income']) ??
            (throw const _BadInput('Give type: expense or income.')),
      ),
      parentId: _int(item, 'parent_id'),
      parentName: _string(item, 'parent_name'),
      reason: _string(item, 'reason'),
    ),
  );

  Future<Object?> _suggestSmsCorrections(Map<String, Object?> args) => _suggest(
    args,
    (item) => suggestions.prepareSmsCorrection(
      smsId: _requiredString(item, 'sms_id'),
      accountId: _int(item, 'account_id'),
      categoryId: _int(item, 'category_id'),
      categoryName: _string(item, 'category_name'),
      dismiss: _bool(item, 'dismiss') ?? false,
      reason: _string(item, 'reason'),
    ),
  );

  Future<Object?> _suggestTransactionEdits(Map<String, Object?> args) =>
      _suggest(
        args,
        (item) => suggestions.prepareTransactionEdit(
          transactionId:
              _int(item, 'transaction_id') ??
              (throw const _BadInput('Give transaction_id.')),
          categoryId: _int(item, 'category_id'),
          categoryName: _string(item, 'category_name'),
          accountId: _int(item, 'account_id'),
          title: _rawString(item, 'title'),
          note: _rawString(item, 'note'),
          reason: _string(item, 'reason'),
        ),
      );

  Future<Object?> _suggestTransactions(Map<String, Object?> args) => _suggest(
    args,
    (item) => suggestions.prepareTransactionAdd(
      type: TransactionTypeStorage.fromStorage(
        _enum(item, 'type', ['expense', 'income']) ?? 'expense',
      ),
      amount: _money(item, 'amount') ?? (throw const _BadInput('Give amount.')),
      accountId:
          _int(item, 'account_id') ??
          (throw const _BadInput('Give account_id.')),
      categoryId: _int(item, 'category_id'),
      categoryName: _string(item, 'category_name'),
      title: _rawString(item, 'title'),
      note: _rawString(item, 'note'),
      date: _optionalDay(item, 'date'),
      ignoreDuplicates: _bool(item, 'ignore_duplicates') ?? false,
      reason: _string(item, 'reason'),
    ),
  );

  // ── Loans and debts. ──

  Future<Object?> _listLoans(Map<String, Object?> args) async {
    final closed = _bool(args, 'include_closed') ?? false;
    final accounts = await AccountRepository(database).load();
    return {
      'loans': [
        for (final l in await LoanRepository(database).load())
          if (closed || !l.closed)
            {
              'id': l.id,
              'title': l.title,
              'lender': l.terms.lender,
              'currency': l.terms.currency,
              'amount': _amount(l.terms.principal, l.terms.digits),
              'left': _amount(l.outstanding, l.terms.digits),
              if (l.emi > 0) 'emi': _amount(l.emi, l.terms.digits),
              if (!l.closed && l.emi > 0) 'next_due': _isoDay(l.nextDue),
              'paid_from': ?accounts
                  .where((a) => a.id == l.accountId)
                  .firstOrNull
                  ?.name,
              if (l.closed) 'closed': true,
            },
      ],
    };
  }

  Future<Object?> _listDebts(Map<String, Object?> args) async {
    final settled = _bool(args, 'include_settled') ?? false;
    return {
      'people': [
        for (final p in await DebtRepository(database).load())
          if (settled || !p.settled)
            {
              'id': p.person.id,
              'name': p.person.name,
              'outstanding': [
                for (final balance in p.balances)
                  {
                    balance.amountMinor > 0 ? 'owes_you' : 'you_owe': _amount(
                      balance.amountMinor.abs(),
                      balance.digits,
                    ),
                    'currency': balance.currency,
                  },
              ],
              'entries': p.entries.length,
              if (p.dueDate case final due?) 'due': _isoDay(due),
            },
      ],
    };
  }

  Future<Object?> _listRecurringPayments(Map<String, Object?> args) async {
    final paused = _bool(args, 'include_paused') ?? true;
    final accounts = await AccountRepository(database).load();
    final categories = await CategoryRepository(database).load();
    return {
      'recurring_payments': [
        for (final r in await RecurringPaymentRepository(database).load())
          if (paused || !r.paused)
            {
              'id': r.id,
              'name': r.name,
              'direction': r.incoming ? 'in' : 'out',
              'amount': _amount(r.amountMinor, r.digits),
              'currency': r.currency,
              'cycle': r.cycle.name,
              'next_due': _isoDay(r.nextDue),
              'account': ?accounts
                  .where((a) => a.id == r.accountId)
                  .firstOrNull
                  ?.name,
              'category': ?categories
                  .where((c) => c.id == r.categoryId)
                  .firstOrNull
                  ?.name,
              if (r.paused) 'paused': true,
            },
      ],
    };
  }

  Future<Object?> _suggestRecurringPayments(
    Map<String, Object?> args,
  ) => _suggest(
    args,
    (item) => suggestions.prepareRecurringPayment(
      name: _rawString(item, 'name') ?? (throw const _BadInput('Give name.')),
      amount: _money(item, 'amount') ?? (throw const _BadInput('Give amount.')),
      accountId:
          _int(item, 'account_id') ??
          (throw const _BadInput('Give account_id.')),
      cycle:
          _enum(item, 'cycle', ['weekly', 'monthly', 'quarterly', 'yearly']) ??
          'monthly',
      nextDue: _optionalDay(item, 'next_due'),
      incoming: _bool(item, 'incoming') ?? false,
      categoryId: _int(item, 'category_id'),
      categoryName: _string(item, 'category_name'),
      icon: _string(item, 'icon'),
      remind: _bool(item, 'remind') ?? true,
      reason: _string(item, 'reason'),
    ),
  );

  Future<Object?> _listIcons(Map<String, Object?> args) async {
    final query = _string(args, 'query')?.toLowerCase() ?? '';
    return {
      'icons': [
        for (final key in appIconKeys)
          if (key.contains(query)) key,
        if (query.isNotEmpty)
          for (final brand in brandIcons)
            if (brand.title.toLowerCase().contains(query) ||
                brand.key.contains(query))
              brandIconKey(brand.key),
      ],
    };
  }

  Future<Object?> _suggestLoan(Map<String, Object?> args) async {
    final kind = _enum(args, 'kind', [for (final k in LoanKind.values) k.name]);
    final rate = args['rate'];
    if (rate != null && rate is! num) {
      throw const _BadInput('rate must be a number, e.g. 12.5.');
    }
    final payments = args['payments'];
    if (payments != null && payments is! List) {
      throw const _BadInput('Give payments as an array.');
    }
    final plan = await loans.prepareLoan(
      LoanInput(
        lender: _requiredString(args, 'lender'),
        amount:
            _money(args, 'amount') ?? (throw const _BadInput('Give amount.')),
        startDate: _day(args, 'start_date'),
        asset: _string(args, 'asset'),
        assetIcon: _string(args, 'asset_icon'),
        lenderIcon: _string(args, 'lender_icon'),
        kind: kind == null ? LoanKind.other : LoanKind.values.byName(kind),
        rate: (rate as num?)?.toDouble(),
        months: _int(args, 'months') ?? 0,
        emi: _money(args, 'emi'),
        firstDue: _optionalDay(args, 'first_due'),
        endDate: _optionalDay(args, 'end_date'),
        outstanding: _money(args, 'outstanding'),
        unpaidInterest: _money(args, 'unpaid_interest'),
        asOf: _optionalDay(args, 'as_of'),
        paidFromAccountId: _int(args, 'paid_from_account_id'),
        paidFromLastDigits: _string(
          args,
          'paid_from_last_digits',
        )?.replaceAll(RegExp(r'\D'), ''),
        receivedInAccountId: _int(args, 'received_in_account_id'),
        charges: _money(args, 'charges'),
        chargesDeducted: _bool(args, 'charges_deducted') ?? false,
        addMissingToAccount: _bool(args, 'add_missing_to_account') ?? false,
        reason: _string(args, 'reason'),
        payments: [
          for (final item in (payments as List?) ?? const [])
            if (item is Map)
              () {
                final p = Map<String, Object?>.from(item);
                return LoanPaymentInput(
                  date: _day(p, 'date'),
                  amount:
                      _money(p, 'amount') ??
                      (throw const _BadInput('Give each payment an amount.')),
                  fee: _money(p, 'fee'),
                  interest: _money(p, 'interest'),
                  transactionId: _int(p, 'transaction_id'),
                  notInLedger: _bool(p, 'not_in_ledger') ?? false,
                  partPayment: _bool(p, 'part_payment') ?? false,
                );
              }()
            else
              throw const _BadInput('Each payment must be an object.'),
        ],
      ),
    );
    await suggestions.add([plan.draft]);
    onSuggestionsChanged?.call();
    return {'suggested': 1, ...plan.report};
  }

  Future<Object?> _suggestDebtEntries(Map<String, Object?> args) => _suggest(
    args,
    (item) => loans.prepareDebtEntry(
      personId: _int(item, 'person_id'),
      personName: _string(item, 'person'),
      kind: DebtKindStorage.fromStorage(
        _enum(item, 'kind', [for (final k in DebtKind.values) k.name]) ??
            (throw const _BadInput(
              'Give kind: lend, borrow, collect or repay.',
            )),
      ),
      amount: _money(item, 'amount') ?? (throw const _BadInput('Give amount.')),
      date: _day(item, 'date'),
      dueDate: _optionalDay(item, 'due_date'),
      accountId: _int(item, 'account_id'),
      currency: _string(item, 'currency')?.toUpperCase(),
      note: _string(item, 'note'),
      transactionId: _int(item, 'transaction_id'),
      ignoreMatches: _bool(item, 'ignore_matches') ?? false,
      reason: _string(item, 'reason'),
    ),
  );

  // ── Payees and accounts. ──

  /// Transactions an import left without a real category.
  static const _fallbackWhere =
      "t.type IN ('expense', 'income') "
      "AND (t.category_id IS NULL OR c.name = 'Personal')";

  /// Payees categorize_payee has suggested a category for this session.
  final _categorized = <String>{};

  static String _payeeKey(String title) => title.trim().toLowerCase();

  Future<Object?> _listPayeesToCategorize(Map<String, Object?> args) async {
    final (from, to) = _optionalRange(args);
    final limit = (_int(args, 'limit') ?? 10).clamp(1, 100);
    final categories = await CategoryRepository(database).load();
    // Names to choose from, so a small model needn't list them separately.
    List<String> names(String type) => [
      for (final c in categoriesInDisplayOrder(categories))
        if (c.type.storageValue == type && c.name != 'Personal')
          _path(
            categories.where((p) => p.id == c.parentId).firstOrNull?.name,
            c.name,
          ),
    ];
    final rows = await database
        .customSelect(
          '''SELECT lower(trim(t.title)) AS k, MIN(t.title) AS title, t.type,
            a.currency, a.digits, COUNT(*) AS n, SUM(t.amount_minor) AS total,
            MAX(t.date) AS last,
            (SELECT substr(s.note, 1, 200) FROM transactions s
              WHERE lower(trim(s.title)) = lower(trim(t.title))
                AND s.note IS NOT NULL ORDER BY s.date DESC LIMIT 1) AS sms
          FROM transactions t
          JOIN accounts a ON a.id = t.account_id
          LEFT JOIN categories c ON c.id = t.category_id
          WHERE $_fallbackWhere AND t.date >= ? AND t.date < ?
            AND nullif(trim(t.title), '') IS NOT NULL
          GROUP BY k, t.type, a.currency, a.digits
          ORDER BY total DESC''',
          variables: [
            Variable(from.millisecondsSinceEpoch),
            Variable(to.millisecondsSinceEpoch),
          ],
        )
        .get();
    final left = [
      for (final r in rows)
        if (!_categorized.contains(r.read<String>('k'))) r,
    ];
    return {
      'payees_left': left.length,
      'payees': [
        for (final r in left.take(limit))
          {
            'payee': r.read<String>('title'),
            'type': r.read<String>('type'),
            'count': r.read<int>('n'),
            'total': _amount(r.read<int>('total'), r.read<int>('digits')),
            'currency': r.read<String>('currency'),
            'last': _isoDay(
              DateTime.fromMillisecondsSinceEpoch(r.read<int>('last')),
            ),
            if (r.readNullable<String>('sms') case final sms?)
              'sms': _clip(sms.replaceAll(RegExp(r'\s+'), ' '), 140),
          },
      ],
      if (left.isNotEmpty) ...{
        'expense_categories': names('expense'),
        if (left.any((r) => r.read<String>('type') == 'income'))
          'income_categories': names('income'),
      },
      'next': left.isEmpty
          ? 'Done: nothing is left as "Personal".'
          : 'For each payee whose kind of spending is clear (a shop, fuel, '
                'food, a bill, an app), call categorize_payee with a name '
                'from expense_categories. Credit Card Repayment is only '
                'paying a card’s bill (e.g. to CRED); something bought with a '
                'card goes by what was bought. Skip a person’s name when '
                'nothing says what it was for.',
    };
  }

  Future<Object?> _categorizePayee(Map<String, Object?> args) async {
    final payee =
        _string(args, 'payee') ??
        (throw const _BadInput(
          'Give payee, as list_payees_to_categorize shows it.',
        ));
    if (_int(args, 'category_id') == null &&
        _string(args, 'category_name') == null) {
      throw const _BadInput('Give category_name, e.g. Fuel.');
    }
    final (from, to) = _optionalRange(args);
    Future<List<int>> ids(String where, Object value) async => [
      for (final r
          in await database
              .customSelect(
                '''SELECT t.id FROM transactions t
            LEFT JOIN categories c ON c.id = t.category_id
            WHERE $_fallbackWhere AND $where AND t.date >= ? AND t.date < ?
            ORDER BY t.date DESC LIMIT $_maxItems''',
                variables: [
                  Variable(value),
                  Variable(from.millisecondsSinceEpoch),
                  Variable(to.millisecondsSinceEpoch),
                ],
              )
              .get())
        r.read<int>('id'),
    ];
    var found = await ids('lower(trim(t.title)) = ?', _payeeKey(payee));
    if (found.isEmpty) {
      // Part of the name, when it points at one payee.
      final names = await database
          .customSelect(
            '''SELECT DISTINCT lower(trim(t.title)) AS k FROM transactions t
            LEFT JOIN categories c ON c.id = t.category_id
            WHERE $_fallbackWhere AND instr(lower(t.title), ?) > 0''',
            variables: [Variable(_payeeKey(payee))],
          )
          .get();
      if (names.length == 1) {
        found = await ids('lower(trim(t.title)) = ?', names.single.read('k'));
      }
    }
    if (found.isEmpty) {
      throw _BadInput(
        'No "Personal" transaction is paid to “$payee”. Use a payee from '
        'list_payees_to_categorize.',
      );
    }
    // A card bill is paid from a bank; spending on the card is a purchase.
    final name = _string(args, 'category_name')?.toLowerCase() ?? '';
    if (name.contains('credit card repayment')) {
      final onCards = await database.customSelect(
        '''SELECT COUNT(*) AS n FROM transactions t
            JOIN accounts a ON a.id = t.account_id
            WHERE a.type = 'creditCard' AND t.type = 'expense'
              AND t.id IN (${found.join(',')})''',
      ).getSingle();
      if (onCards.read<int>('n') == found.length) {
        throw _BadInput(
          'These are purchases made with a credit card at “$payee”, not a '
          'card bill. Pick what was bought, e.g. Restaurants or Shopping.',
        );
      }
    }
    final drafts = <AgentSuggestionDraft>[];
    Object? firstError;
    for (final id in found) {
      try {
        drafts.add(
          await suggestions.prepareTransactionEdit(
            transactionId: id,
            categoryId: _int(args, 'category_id'),
            categoryName: _string(args, 'category_name'),
            reason: _string(args, 'reason') ?? 'Paid to $payee',
          ),
        );
      } catch (error) {
        // An income from a payee whose spending is categorized, or the
        // other way round, keeps its category.
        firstError ??= error;
      }
    }
    if (drafts.isEmpty) {
      throw _BadInput(
        firstError is ArgumentError
            ? '${firstError.message}'
            : describeAgentError(firstError!),
      );
    }
    await suggestions.add(drafts);
    onSuggestionsChanged?.call();
    _categorized.add(_payeeKey(payee));
    return {
      'suggested': drafts.length,
      if (drafts.length < found.length)
        'kept': '${found.length - drafts.length} of another type',
      'next':
          'Call categorize_payee for the next payee from '
          'list_payees_to_categorize, or stop and ask the user to approve '
          'them in SimpleMoney → More → AI suggestions.',
    };
  }

  Future<Object?> _accountActivity(Map<String, Object?> args) async {
    final id =
        _int(args, 'account_id') ??
        (throw const _BadInput('Give account_id from list_accounts.'));
    final account =
        (await AccountRepository(
          database,
        ).load()).where((a) => a.id == id).firstOrNull ??
        (throw _BadInput('No account has id $id. Use one from list_accounts.'));
    final (from, to) = _optionalRange(args);
    final range = [
      Variable(from.millisecondsSinceEpoch),
      Variable(to.millisecondsSinceEpoch),
    ];
    // Every movement of this account, signed by its side.
    const moves = '''
      SELECT CASE t.type WHEN 'expense' THEN 'spent'
          WHEN 'income' THEN 'received' ELSE 'transfer_out' END AS kind,
        t.amount_minor AS amount, t.date, t.title,
        o.name AS other, t.note
      FROM transactions t LEFT JOIN accounts o ON o.id = t.to_account_id
      WHERE t.account_id = ? AND t.date >= ? AND t.date < ?
      UNION ALL
      SELECT 'transfer_in', coalesce(t.to_amount_minor, t.amount_minor),
        t.date, t.title, o.name, t.note
      FROM transactions t JOIN accounts o ON o.id = t.account_id
      WHERE t.type = 'transfer' AND t.to_account_id = ?
        AND t.date >= ? AND t.date < ?''';
    final variables = [Variable(id), ...range, Variable(id), ...range];
    final kinds = await database.customSelect(
      '''SELECT kind, COUNT(*) AS n, SUM(amount) AS total,
            MIN(date) AS first, MAX(date) AS last
          FROM ($moves) GROUP BY kind''',
      variables: variables,
    ).get();
    final largest = await database
        .customSelect(
          'SELECT * FROM ($moves) ORDER BY amount DESC LIMIT 5',
          variables: variables,
        )
        .get();
    String money(int minor) => _amount(minor, account.digits);
    final byKind = {
      for (final r in kinds) r.read<String>('kind'): r.read<int>('total'),
    };
    final moneyIn = (byKind['received'] ?? 0) + (byKind['transfer_in'] ?? 0);
    final moneyOut = (byKind['spent'] ?? 0) + (byKind['transfer_out'] ?? 0);
    final card = account.type == AccountType.creditCard;
    final where = 'SimpleMoney → More → Accounts → ${account.name}';
    final notes = [
      if (!card && account.balanceMinor < 0)
        account.type == AccountType.cash
            ? 'Cash can’t be below zero. More cash went out (into a bank, '
                  'or spent) than the app saw come in, so the cash the user '
                  'already had isn’t known to it. To fix it, the user opens '
                  '$where and sets the balance.'
            : 'A bank balance below zero usually means money came in that '
                  'no SMS showed. To fix it, the user opens $where and sets the '
                  'balance.',
      if (card && account.balanceMinor < 0)
        'For a credit card, below zero is what’s owed.',
      if (account.balanceReportedAt case final at?)
        'The balance is the bank’s own figure from its SMS on '
            '${_isoDay(at)}; transactions before then don’t change it.',
      if (kinds.isEmpty) 'Nothing moved in this account in these dates.',
    ];
    return {
      'account': {
        'id': account.id,
        'name': account.name,
        'type': account.type.name,
        'balance': money(account.balanceMinor),
        'currency': account.currency,
      },
      'money_in': money(moneyIn),
      'money_out': money(moneyOut),
      'by_kind': [
        for (final r in kinds)
          {
            'kind': r.read<String>('kind'),
            'total': money(r.read<int>('total')),
            'count': r.read<int>('n'),
            'first': _isoDay(
              DateTime.fromMillisecondsSinceEpoch(r.read<int>('first')),
            ),
            'last': _isoDay(
              DateTime.fromMillisecondsSinceEpoch(r.read<int>('last')),
            ),
          },
      ],
      'largest': [
        for (final r in largest)
          {
            'date': _isoDay(
              DateTime.fromMillisecondsSinceEpoch(r.read<int>('date')),
            ),
            'kind': r.read<String>('kind'),
            'amount': money(r.read<int>('amount')),
            'title': ?r.readNullable<String>('title'),
            'other_account': ?r.readNullable<String>('other'),
            if (r.readNullable<String>('note') case final note?)
              'sms': _clip(note.replaceAll(RegExp(r'\s+'), ' '), 140),
          },
      ],
      if (notes.isNotEmpty) 'notes': notes,
    };
  }

  /// from/to when given; all dates otherwise.
  static (DateTime, DateTime) _optionalRange(Map<String, Object?> args) {
    final from = _string(args, 'from') == null
        ? DateTime(1970)
        : _day(args, 'from');
    if (_string(args, 'to') == null) return (from, DateTime(9999));
    final (_, to) = _range({...args, 'from': '1970-01-01'});
    if (to.isBefore(from)) throw const _BadInput('to is before from.');
    return (from, to);
  }

  /// Checks every item, stores the good ones as one batch, and reports each
  /// bad one by index so the AI app can fix and resend just those.
  Future<Object?> _suggest(
    Map<String, Object?> args,
    Future<AgentSuggestionDraft> Function(Map<String, Object?> item) prepare,
  ) async {
    final items = args['items'];
    if (items is! List || items.isEmpty) {
      throw const _BadInput('Give a non-empty items array.');
    }
    if (items.length > _maxItems) {
      throw const _BadInput('Send at most $_maxItems items at a time.');
    }
    final drafts = <AgentSuggestionDraft>[];
    final rejected = <Map<String, Object?>>[];
    for (final (index, item) in items.indexed) {
      try {
        if (item is! Map) throw const _BadInput('Each item must be an object.');
        drafts.add(await prepare(Map<String, Object?>.from(item)));
      } catch (error) {
        rejected.add({
          'index': index,
          'error': error is _BadInput
              ? error.message
              : describeAgentError(error),
        });
      }
    }
    if (drafts.isNotEmpty) {
      await suggestions.add(drafts);
      onSuggestionsChanged?.call();
    }
    return {
      'suggested': drafts.length,
      if (rejected.isNotEmpty) 'rejected': rejected,
      'next': drafts.isEmpty
          ? 'Nothing was suggested. Fix the rejected items and try again.'
          : 'Nothing has changed yet. Ask the user to open SimpleMoney → '
                'More → AI suggestions to approve or reject these.',
    };
  }

  // ── SMS rules. ──

  Future<Object?> _listMissedSms(Map<String, Object?> args) async {
    final days = (_int(args, 'days') ?? 60).clamp(1, 180);
    final limit = (_int(args, 'limit') ?? 30).clamp(1, 100);
    final sender = switch (_string(args, 'sender')) {
      final s? => normalizeRuleSender(s) ?? s,
      null => null,
    };
    String senderOf(ReportableSms m) =>
        normalizeRuleSender(m.sms.sender) ?? m.sms.sender;
    final all = await (missedSms ?? _readMissedSms)(Duration(days: days));
    _missed = all;
    final missed = [
      for (final m in all)
        if ((sender == null || senderOf(m) == sender) &&
            !_settled.contains(_missedId(m)))
          m,
    ]..sort((a, b) => b.sms.receivedAt.compareTo(a.sms.receivedAt));
    final handled = all.where((m) => _settled.contains(_missedId(m))).length;
    final bySender = <String, int>{};
    for (final m in missed) {
      bySender[senderOf(m)] = (bySender[senderOf(m)] ?? 0) + 1;
    }
    final top = bySender.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return {
      'total': missed.length,
      if (handled > 0) 'already_handled': handled,
      'by_sender': {for (final e in top.take(20)) e.key: e.value},
      'messages': [
        for (final m in missed.take(limit))
          {
            'id': _missedId(m),
            'sender': senderOf(m),
            'received_at': DateFormat("yyyy-MM-dd'T'HH:mm")
                .format(m.sms.receivedAt),
            'text': m.sms.body,
            'reason': m.reason,
          },
      ],
      'next': missed.isEmpty
          ? 'Done: no missed bank SMS left to teach.'
          : 'Call label_sms with one payment message\'s id. Skip OTPs and '
                'offers. Its reply says which message to label next.',
    };
  }

  /// Reads the inbox with the user's rules too, so a message an approved
  /// rule reads is no longer missed.
  Future<List<ReportableSms>> _readMissedSms(Duration window) async {
    final repository = ReportableSmsRepository(
      engineLoader: () => loadSmsEngine(database),
    );
    if (!repository.inbox.supported ||
        !await repository.inbox.hasPermission()) {
      throw StateError(
        'SimpleMoney can’t read SMS on this phone. Ask the user to turn on '
        'bank SMS import in the app.',
      );
    }
    return [
      await for (final page in repository.scan(window: window))
        for (final m in page)
          if (m.kind == ReportableKind.missed) m,
    ];
  }

  Future<Object?> _getParserRules(Map<String, Object?> args) => rules.rules(
    sender: _string(args, 'sender'),
    limit: (_int(args, 'limit') ?? 12).clamp(1, 40),
  );

  Future<Object?> _testParserRule(Map<String, Object?> args) async =>
      (await rules.trial(
        bankName: _string(args, 'bank_name'),
        senders: _senders(args),
        format: _format(args),
        samples: _samples(args),
      )).toJson();

  Future<Object?> _suggestParserRule(Map<String, Object?> args) async {
    final draft = await rules.prepare(
      bankName: _string(args, 'bank_name'),
      senders: _senders(args),
      format: _format(args),
      samples: _samples(args),
      reason: _string(args, 'reason'),
    );
    await suggestions.add([draft]);
    onSuggestionsChanged?.call();
    return {
      'suggested': 1,
      'next':
          'Nothing has changed yet. Ask the user to open SimpleMoney → More → '
          'AI suggestions to approve the rule.',
    };
  }

  /// The missed messages list_missed_sms last read, for label_sms.
  List<ReportableSms>? _missed;

  /// A short, stable id a small model can copy back.
  static String _missedId(ReportableSms m) =>
      'm${Object.hash(m.sms.sender, m.sms.body, m.sms.receivedAt).toUnsigned(32).toRadixString(36)}';

  Future<Object?> _labelSms(Map<String, Object?> args) async {
    final id = _string(args, 'sms_id') ?? '';
    var missed =
        _missed ??
        await (missedSms ?? _readMissedSms)(const Duration(days: 60));
    _missed = missed;
    var target = missed.where((m) => _missedId(m) == id).firstOrNull;
    if (target == null) {
      missed = await (missedSms ?? _readMissedSms)(const Duration(days: 180));
      _missed = missed;
      target = missed.where((m) => _missedId(m) == id).firstOrNull;
    }
    if (target == null) {
      throw ArgumentError(
        'No missed SMS has the id “$id”. Call list_missed_sms and use an id '
        'from it.',
      );
    }
    final sender = normalizeRuleSender(target.sms.sender) ?? target.sms.sender;
    if (_settled.contains(id)) {
      // A rule already suggested reads it: another would only replace it.
      final unread = [
        for (final m in missed)
          if ((normalizeRuleSender(m.sms.sender) ?? m.sms.sender) == sender &&
              !_settled.contains(_missedId(m)))
            m,
      ];
      return {
        'suggested': false,
        'already_handled':
            'Nothing more to do for this message: a rule you suggested reads '
            'it, or it isn’t a payment.',
        'next': unread.isEmpty
            ? 'Done. Ask the user to approve it in SimpleMoney → More → AI '
                  'suggestions.'
            : 'Label a message no rule reads yet, or stop if the rest aren’t '
                  'payments: ${[for (final m in unread.take(3)) _missedId(m)].join(', ')}.',
      };
    }
    final format = buildLabeledFormat(
      text: target.sms.body,
      amount: _string(args, 'amount') ?? '',
      account: _string(args, 'account'),
      payee: _string(args, 'payee'),
      reference: _string(args, 'reference'),
      direction: _string(args, 'direction') ?? '',
      channel: _string(args, 'channel') ?? '',
    );
    // The labelled message first, then others from the same sender.
    final others = [
      for (final m in missed)
        if (m != target &&
            (normalizeRuleSender(m.sms.sender) ?? m.sms.sender) == sender)
          m,
    ]..sort((a, b) => b.sms.receivedAt.compareTo(a.sms.receivedAt));
    final samples = [
      RuleSample(target.sms.body, sender: sender),
      for (final m in others.take(19)) RuleSample(m.sms.body, sender: sender),
    ];
    // A bank the app doesn't know needs a name; its SMS usually signs off
    // with one ("… -Fincare SFB"), which beats a small model's guess.
    final bankName = _string(args, 'bank_name') ?? _signOff(target.sms.body);
    final trial = await rules.trial(
      bankName: bankName,
      senders: [sender],
      format: format,
      samples: samples,
    );
    final first = trial.results.first;
    if (!first.matched) {
      throw ArgumentError(
        'The rule didn’t read this message (${first.result.reason}). Check '
        'the values are copied exactly, then try again.',
      );
    }
    final pool = [target, ...others.take(19)];
    // Each other message: read by this rule, read by the bank's other
    // rules once its sender is known, not a payment (an OTP, an offer), or
    // still missed.
    final read = <RuleSample>[], alsoRead = <ReportableSms>[];
    final notPayments = <ReportableSms>[], unread = <ReportableSms>[];
    for (final (i, r) in trial.results.indexed) {
      if (r.matched) {
        read.add(samples[i]);
      } else if (r.result.candidate != null) {
        alsoRead.add(pool[i]);
      } else if (r.result.classification != RuleClassification.completed &&
          r.result.classification != RuleClassification.unknown) {
        notPayments.add(pool[i]);
      } else {
        unread.add(pool[i]);
        continue;
      }
      _settled.add(_missedId(pool[i]));
    }
    final draft = await rules.prepare(
      bankName: bankName,
      senders: [sender],
      format: format,
      samples: read,
      reason: 'Taught from a missed $sender message.',
    );
    await suggestions.add([draft]);
    onSuggestionsChanged?.call();
    return {
      'suggested': true,
      'read_by_this_rule': read.length,
      if (alsoRead.isNotEmpty) 'read_by_other_rules': alsoRead.length,
      if (notPayments.isNotEmpty) 'not_payments': notPayments.length,
      'still_missed': [
        for (final m in unread.take(3))
          {'sms_id': _missedId(m), 'text': _clip(m.sms.body, 160)},
      ],
      'read_from_this_sms': RuleTrial.readCandidate(first.result.candidate!),
      'next': _labelNext(sender, unread, notPayments.length),
    };
  }

  /// Missed messages that need no more teaching this session: a suggested
  /// rule reads them, the bank's other rules do once it's known, or they
  /// aren't payments.
  final _settled = <String>{};

  /// What to do after label_sms: the next message to label, or done.
  static String _labelNext(
    String sender,
    List<ReportableSms> unread,
    int notPayments,
  ) {
    final skip = notPayments == 0
        ? ''
        : ' Skip the $notPayments that aren’t payments (OTPs, offers).';
    if (unread.isEmpty) {
      return 'Done: every missed payment from $sender is read.$skip Ask the '
          'user to approve it in SimpleMoney → More → AI suggestions.';
    }
    return 'Now call label_sms with sms_id ${_missedId(unread.first)} '
        '(${unread.length} still missed from $sender). Don’t ask the user '
        'first.$skip';
  }

  /// The bank's name an SMS ends with, as in "… -Fincare SFB".
  static String? _signOff(String body) {
    final match = RegExp(r'[-–]\s*([A-Za-z][A-Za-z .&]{1,38}?)\.?\s*$')
        .firstMatch(body);
    return match?.group(1)?.trim();
  }

  // ── Statements. ──

  /// map_statement's columns so far, per statement, for this session.
  final _mapped = <String, Map<TableField, int>>{};

  late final _statements = StatementSampleRepository();

  Future<Object?> _listStatementsToMap(Map<String, Object?> args) async {
    final samples = await _statements.load();
    return {
      'statements': [
        for (final s in samples)
          {
            'id': s.id,
            'file': s.fileName,
            'column_names': [
              for (final c in s.header)
                if (c.trim().isNotEmpty) c,
            ],
            'example_rows': s.rows,
            'app_guess': {
              for (final e in guessMapping([
                s.header,
                ...s.rows,
              ], 0).columns.entries)
                if (_mapArgs.containsKey(e.key))
                  _mapArgs[e.key]!: s.header[e.value],
            },
          },
      ],
      if (samples.isNotEmpty)
        'next':
            'app_guess is the app\'s own guess. Check it against '
            'example_rows, fix anything wrong, then call map_statement with '
            'names from column_names. Don\'t ask the user which column is '
            'which: they approve the result in the app.',
      if (samples.isEmpty)
        'next':
            'Nothing to map. A file shows up here when the user imports a '
            'statement the app can\'t read by itself (More → Statements).',
    };
  }

  Future<Object?> _mapStatement(Map<String, Object?> args) async {
    final id = _string(args, 'statement_id') ?? '';
    final sample = (await _statements.load())
        .where((s) => s.id == id)
        .firstOrNull;
    if (sample == null) {
      throw ArgumentError(
        'No statement has the id “$id”. Call list_statements_to_map and use '
        'an id from it.',
      );
    }
    // Each call adds to the ones before for this statement, so a small
    // model can give it a piece at a time; "none" clears a field. Read in
    // this order: a column serves one field, and debit/credit columns make
    // amount and direction unneeded.
    var current = TableMapping(headerRow: 0, columns: {..._mapped[id] ?? {}});
    final ignored = <String, String>{};
    final thisCall = <TableField, int>{};
    final table = [sample.header, ...sample.rows];
    final guess = guessMapping(table, 0);
    bool named(String key) => switch (_string(args, key)) {
      final v? => !_noColumn.contains(v.toLowerCase()),
      null => false,
    };
    final sides = named('debit') || named('credit');
    for (final MapEntry(key: field, value: key) in _mapArgs.entries) {
      final name = _string(args, key);
      if (name == null) continue;
      if (_noColumn.contains(name.toLowerCase())) {
        current = current.withColumn(field, null);
        continue;
      }
      final at = _columnNamed(sample, name, preferred: guess[field]);
      if (at == null) {
        final closest = _closestColumn(sample, name);
        final hint =
            'There’s no column “$name”.'
            '${closest == null ? '' : ' Did you mean “$closest”?'}';
        if (_moneyFields.contains(field)) {
          _mapped[id] = current.columns;
          throw ArgumentError(
            '$hint Use one of: ${sample.header.where((c) => c.trim().isNotEmpty).join(', ')}.',
          );
        }
        ignored[key] = hint;
      } else if ((field == TableField.amount ||
              field == TableField.direction) &&
          sides) {
        ignored[key] = 'Not needed with debit and credit.';
      } else if (thisCall.entries.where((e) => e.value == at).firstOrNull
          case final taken?) {
        ignored[key] =
            '“${sample.header[at]}” is already ${_mapArgs[taken.key]}.';
      } else {
        current = current.withColumn(field, at);
        thisCall[field] = at;
      }
    }
    final given = {...current.columns};
    // What the model left out, the app's own guess fills in: the other half
    // of money out / money in, a Dr/Cr column, the description, the
    // balance.
    // An "amount" column that is only one side of separate money-out and
    // money-in columns: read both sides.
    if ((
          given[TableField.amount],
          guess[TableField.debit],
          guess[TableField.credit],
        )
        case (final amount?, final out?, final into?)
        when (amount == out || amount == into) &&
            !given.containsKey(TableField.debit) &&
            !given.containsKey(TableField.credit) &&
            !given.containsValue(amount == out ? into : out)) {
      given
        ..remove(TableField.amount)
        ..remove(TableField.direction)
        ..[TableField.debit] = out
        ..[TableField.credit] = into;
      ignored['amount'] =
          '“${sample.header[amount]}” is only money ${amount == out ? 'out' : 'in'}: '
          'read as debit “${sample.header[out]}” and credit “${sample.header[into]}”.';
    }
    _mapped[id] = {...given};
    final filled = <TableField, int>{};
    final halves =
        given.containsKey(TableField.debit) ||
        given.containsKey(TableField.credit);
    for (final field in [
      if (halves) ...[TableField.debit, TableField.credit],
      if (!halves && given.containsKey(TableField.amount)) TableField.direction,
      TableField.description,
      TableField.balance,
    ]) {
      final column = guess[field];
      if (given.containsKey(field) || column == null) continue;
      if (given.containsValue(column) || filled.containsValue(column)) continue;
      filled[field] = column;
    }
    final mapping = TableMapping(
      headerRow: 0,
      columns: {...given, ...filled},
      dateOrder: switch (_string(args, 'date_order')) {
        'day_first' => DateOrder.dayFirst,
        'month_first' => DateOrder.monthFirst,
        'year_first' => DateOrder.yearFirst,
        _ => DateOrder.auto,
      },
    );
    if (!mapping.isComplete) {
      final missing = [
        if (!mapping.columns.containsKey(TableField.date)) 'date',
        if (!mapping.columns.containsKey(TableField.amount) &&
            !mapping.usesDebitCredit)
          'amount (or debit and credit)',
      ];
      throw ArgumentError(
        'Still needed: ${missing.join(', ')}. What you gave is kept: call '
        'map_statement again with just ${missing.length == 1 ? 'that' : 'those'}.',
      );
    }
    final parsed = parseStatementTable(table, mapping);
    final rows = parsed.statement.rows;
    if (rows.isEmpty) {
      throw ArgumentError(
        'No row could be read with these columns. Check date and amount.',
      );
    }
    String row(UpiStatementRow r) =>
        '${DateFormat('yyyy-MM-dd').format(r.date)} · '
        '${(r.amountMinor / 100).toStringAsFixed(2)} ${r.direction.name} · '
        '${r.counterparty}';
    final preview = [for (final r in rows.take(3)) row(r)];
    final noDescription = !mapping.columns.containsKey(TableField.description);
    // Rows with a date that didn't read; a footer ("Closing balance") has
    // none.
    final dated = sample.rows
        .where(
          (r) => (r.elementAtOrNull(mapping[TableField.date]!) ?? '')
              .trim()
              .isNotEmpty,
        )
        .length;
    final unread = dated - rows.length;
    // A description column of short codes, when another holds the
    // narration.
    double width(int column) =>
        sample.rows
            .map((r) => (r.elementAtOrNull(column) ?? '').trim().length)
            .fold(0, (a, b) => a + b) /
        sample.rows.length;
    final narration = guess[TableField.description];
    final described = mapping[TableField.description];
    final betterDescription =
        narration != null &&
            described != null &&
            narration != described &&
            width(narration) > width(described) * 1.5
        ? sample.header[narration]
        : null;
    final hasOut = mapping.columns.containsKey(TableField.debit);
    final hasIn = mapping.columns.containsKey(TableField.credit);
    // The one thing to fix next, plainly; null once it all reads.
    final fix = hasOut != hasIn
        ? 'Call map_statement again with just '
              '${hasOut ? 'credit: the money-in' : 'debit: the money-out'} '
              'column. The rest is kept.'
        : unread > 0
        ? '$unread row${unread == 1 ? '' : 's'} weren\'t read. Check the date '
              'and amount columns, then call map_statement again.'
        : noDescription
        ? 'Rows show "Unknown" as who was paid. Call map_statement again with '
              'description set to the narration or particulars column.'
        : betterDescription != null
        ? 'description “${sample.header[described!]}” holds short codes; '
              '“$betterDescription” looks like the narration. Call '
              'map_statement again with description “$betterDescription”.'
        : null;
    final reason = _string(args, 'reason');
    await suggestions.add([
      AgentSuggestionDraft(
        kind: AgentSuggestionKind.statementLayout,
        target: sample.signature,
        payload: {
          'signature': sample.signature,
          'mapping': mapping.toJson(),
          'fileName': sample.fileName,
        },
        summary: 'Statement layout · ${sample.fileName}',
        detail: [
          for (final e in mapping.columns.entries)
            '${e.key.label}: ${sample.header[e.value]}',
          'Reads ${rows.length} of $dated sample rows, e.g. ${preview.first}',
        ],
        reason: reason,
      ),
    ]);
    onSuggestionsChanged?.call();
    return {
      'suggested': true,
      'reads': '${rows.length} of $dated sample rows',
      if (sample.rows.length > dated)
        'skipped':
            '${sample.rows.length - dated} without a date (totals, notes)',
      'preview': preview,
      if (filled.isNotEmpty)
        'filled_in': {
          for (final e in filled.entries) e.key.name: sample.header[e.value],
        },
      if (ignored.isNotEmpty) 'ignored': ignored,
      'next':
          fix ??
          'Done. Ask the user to approve it in SimpleMoney → More → AI '
              'suggestions, then import the file again.',
    };
  }

  /// map_statement's arguments, in the order they're read.
  static const _mapArgs = {
    TableField.date: 'date',
    TableField.debit: 'debit',
    TableField.credit: 'credit',
    TableField.amount: 'amount',
    TableField.direction: 'direction',
    TableField.description: 'description',
    TableField.reference: 'reference',
    TableField.balance: 'balance',
  };

  /// The fields a statement can't be read without.
  static const _moneyFields = {
    TableField.date,
    TableField.amount,
    TableField.debit,
    TableField.credit,
  };

  /// What a small model writes for a field it leaves out.
  static const _noColumn = {'none', 'null', 'n/a', 'na', '-', 'no', 'empty'};

  static String _bare(String c) =>
      c.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

  /// [name]'s column: the column so named, near enough ("Particular" for
  /// "Particulars", "chq ref" for "Chq/Ref", "Withdrawal" for "Withdrawal
  /// Amt (INR)"), or the one column holding it as a value. Null when none
  /// or several fit. A value in several columns is [preferred]'s, the
  /// app's own guess for the field, when that is one of them.
  static int? _columnNamed(
    StatementSample sample,
    String name, {
    int? preferred,
  }) {
    final want = _bare(name);
    int? only(bool Function(String bare) test) {
      final hits = [
        for (final (i, c) in sample.header.indexed)
          if (_bare(c).isNotEmpty && test(_bare(c))) i,
      ];
      return hits.length == 1 ? hits.single : null;
    }

    // The value, or its date part ("28-10-2026" of "28-10-2026 10:21").
    int? holding() {
      final value = name.trim().toLowerCase();
      final hits = {
        for (final row in sample.rows)
          for (final (i, cell) in row.indexed)
            if (_bare(cell).isNotEmpty &&
                (_bare(cell) == want ||
                    cell.trim().toLowerCase().startsWith('$value ')))
              i,
      };
      if (hits.length == 1) return hits.single;
      return hits.contains(preferred) ? preferred : null;
    }

    final exact = sample.header.indexWhere(
      (c) => c.trim().toLowerCase() == name.trim().toLowerCase(),
    );
    if (exact >= 0) return exact;
    if (want.isEmpty) return null;
    return only((c) => c == want) ??
        (want.length < 4
            ? null
            : only(
                (c) => c.contains(want) || (c.length >= 4 && want.contains(c)),
              )) ??
        holding() ??
        (want.length < 5 ? null : only((c) => _distance(c, want) <= 2));
  }

  /// The column name nearest [name], for a "did you mean".
  static String? _closestColumn(StatementSample sample, String name) {
    final want = _bare(name);
    String? best;
    var bestDistance = 1 << 30;
    for (final c in sample.header) {
      if (_bare(c).isEmpty) continue;
      final d = _distance(_bare(c), want);
      if (d < bestDistance) (best, bestDistance) = (c, d);
    }
    return best != null && bestDistance <= (want.length / 2).ceil()
        ? best
        : null;
  }

  /// Edits (insert, delete, change a letter) from [a] to [b].
  static int _distance(String a, String b) {
    var before = List<int>.generate(b.length + 1, (i) => i);
    for (var i = 1; i <= a.length; i++) {
      final row = [i, ...List.filled(b.length, 0)];
      for (var j = 1; j <= b.length; j++) {
        row[j] = math.min(
          math.min(row[j - 1] + 1, before[j] + 1),
          before[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
        );
      }
      before = row;
    }
    return before[b.length];
  }

  static String _clip(String text, int max) =>
      text.length <= max ? text : '${text.substring(0, max - 1)}…';

  static Map<String, Object?> _ruleSchema({bool reason = false}) => _schema(
    {
      'bank_name': {'type': 'string', 'maxLength': 40},
      'senders': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 16,
        'items': {'type': 'string'},
        'description':
            'Sender IDs such as HDFCBK (routing prefixes like VM- are removed)',
      },
      'format': {
        'type': 'object',
        'description':
            'direction, channel, tokens, output and optional requires, as '
            'described above',
      },
      'samples': {
        'type': 'array',
        'minItems': 1,
        'maxItems': 20,
        'items': _schema(
          {
            'text': {'type': 'string'},
            'sender': {'type': 'string'},
          },
          required: ['text'],
        ),
      },
      if (reason) 'reason': _reasonField,
    },
    required: ['senders', 'format', 'samples'],
  );

  static List<String> _senders(Map<String, Object?> args) =>
      switch (args['senders']) {
        final List list
            when list.isNotEmpty && list.every((s) => s is String) =>
          list.cast(),
        _ => throw const _BadInput('Give senders as an array of sender IDs.'),
      };

  static Map<String, dynamic> _format(Map<String, Object?> args) =>
      switch (args['format']) {
        final Map map => Map<String, dynamic>.from(map),
        _ => throw const _BadInput('Give format as an object.'),
      };

  static List<RuleSample> _samples(Map<String, Object?> args) {
    final list = args['samples'];
    if (list is! List || list.isEmpty) {
      throw const _BadInput('Give samples as an array of {text, sender}.');
    }
    return [
      for (final item in list)
        switch (item) {
          {'text': final String text} => RuleSample(
            text,
            sender: _string(Map<String, Object?>.from(item), 'sender'),
          ),
          final String text => RuleSample(text),
          _ => throw const _BadInput('Each sample needs a text.'),
        },
    ];
  }

  // ── Arguments. ──

  static const _date = {'type': 'string', 'description': 'Date as YYYY-MM-DD'};

  static const _reasonField = {
    'type': 'string',
    'maxLength': 280,
    'description': 'Why, in a few words the user will read',
  };

  static Map<String, Object?> _schema(
    Map<String, Object?> properties, {
    List<String> required = const [],
  }) => {
    'type': 'object',
    'properties': properties,
    if (required.isNotEmpty) 'required': required,
  };

  static Map<String, Object?> _items(
    Map<String, Object?> properties, {
    required List<String> required,
  }) => _schema(
    {
      'items': {
        'type': 'array',
        'minItems': 1,
        'maxItems': _maxItems,
        'items': _schema(properties, required: required),
      },
    },
    required: ['items'],
  );

  static (DateTime, DateTime) _range(Map<String, Object?> args) {
    final from = _day(args, 'from');
    final to = _day(args, 'to');
    if (to.isBefore(from)) throw const _BadInput('to is before from.');
    // `to` is inclusive.
    return (from, DateTime(to.year, to.month, to.day + 1));
  }

  static DateTime _day(Map<String, Object?> args, String key) {
    final value = _string(args, key);
    final match = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(value ?? '');
    if (match == null) throw _BadInput('Give $key as YYYY-MM-DD.');
    return DateTime(
      int.parse(match[1]!),
      int.parse(match[2]!),
      int.parse(match[3]!),
    );
  }

  static DateTime? _optionalDay(Map<String, Object?> args, String key) =>
      _string(args, key) == null ? null : _day(args, key);

  /// An amount, as a string or a plain number.
  static String? _money(Map<String, Object?> args, String key) =>
      switch (args[key]) {
        final num value => '$value',
        _ => _string(args, key),
      };

  /// Trimmed, and null when blank.
  static String? _string(Map<String, Object?> args, String key) {
    final value = _rawString(args, key)?.trim();
    return value == null || value.isEmpty ? null : value;
  }

  /// As given, so an empty string can clear a field.
  static String? _rawString(Map<String, Object?> args, String key) =>
      switch (args[key]) {
        final String value => value,
        null => null,
        _ => throw _BadInput('$key must be a string.'),
      };

  static String _requiredString(Map<String, Object?> args, String key) =>
      _string(args, key) ?? (throw _BadInput('Give $key.'));

  static int? _int(Map<String, Object?> args, String key) =>
      switch (args[key]) {
        final int value => value,
        final double value when value == value.roundToDouble() => value.toInt(),
        null => null,
        _ => throw _BadInput('$key must be a whole number.'),
      };

  static bool? _bool(Map<String, Object?> args, String key) =>
      switch (args[key]) {
        final bool value => value,
        null => null,
        _ => throw _BadInput('$key must be true or false.'),
      };

  static String? _enum(
    Map<String, Object?> args,
    String key,
    List<String> allowed,
  ) {
    final value = _string(args, key);
    if (value == null || allowed.contains(value)) return value;
    throw _BadInput('$key must be one of: ${allowed.join(', ')}.');
  }

  /// Minor units as an exact decimal string, e.g. 45050 → "450.50".
  static String _amount(int minor, int digits) {
    if (digits == 0) return '$minor';
    final scale = math.pow(10, digits).toInt();
    final abs = minor.abs();
    return '${minor < 0 ? '-' : ''}${abs ~/ scale}.'
        '${(abs % scale).toString().padLeft(digits, '0')}';
  }

  static String _isoDay(DateTime date) => DateFormat('yyyy-MM-dd').format(date);

  static String _path(String? parent, String name) =>
      parent == null ? name : '$parent › $name';
}

class _BadInput implements Exception {
  const _BadInput(this.message);
  final String message;
}
