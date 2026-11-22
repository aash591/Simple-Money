import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:drift/drift.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

import '../../domain/account.dart';
import '../../domain/app_icons.dart';
import '../../domain/brand_icons.dart';
import '../../domain/category.dart';
import '../../domain/account_place.dart';
import '../../domain/debt.dart';
import '../../domain/holding.dart';
import '../../domain/metal.dart';
import '../../domain/loan.dart';
import '../../domain/transaction.dart';
import '../../state/sms_import_store.dart';
import '../bank_sms_parser.dart';
import '../db/app_database.dart';
import '../reportable_sms.dart';
import '../../domain/budget.dart';
import '../ledger_match.dart';
import '../repositories/account_repository.dart';
import '../repositories/budget_repository.dart';
import '../statements/statement_reconciliation.dart';
import '../repositories/category_repository.dart';
import '../prices/price_service.dart';
import '../repositories/debt_repository.dart';
import '../repositories/holding_repository.dart';
import '../repositories/loan_repository.dart';
import '../repositories/recurring_payment_repository.dart';
import '../repositories/sms_review_repository.dart';
import '../statements/statement_table.dart';
import '../statements/upi_statement.dart';
import 'agent_accounts.dart';
import 'agent_loans.dart';
import 'agent_portfolio.dart';
import 'agent_sms_saver.dart';
import 'agent_recurring.dart';
import 'agent_rules.dart';
import 'agent_suggestion_repository.dart';
import 'sms_labeler.dart';
import '../statements/pending_statement_files.dart';
import 'statement_samples.dart';

part 'agent_tool_definitions.dart';

/// One tool an AI app can call, described the way MCP's `tools/list` wants.
/// A tool's answer with pictures for the AI to look at, sent after the
/// answer's JSON. JPEGs.
class AgentToolAnswer {
  const AgentToolAnswer(this.json, this.images);
  final Object? json;
  final List<Uint8List> images;
}

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
    'view_statement_pages',
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

  late final AgentAccounts accounts = AgentAccounts(database);

  late final AgentPortfolio portfolio = AgentPortfolio(database);

  /// Where securities are searched for; replaced in tests so nothing goes
  /// out to the network.
  PriceService? priceService;

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
      'yourself. To find money paid to or received from a phone number: '
      'find_by_phone, and tell the user its accuracy (a UPI ID based on an '
      'email or name doesn\'t show the number). '
      'To teach the app a bank SMS it misses: list_missed_sms, then '
      'label_sms with values copied exactly from one message. To teach it a '
      'statement layout: list_statements_to_map, then map_statement with '
      'column names. When the user shares a loan statement or sanction '
      'letter: read it, then suggest_loan with what it says and every payment '
      'from the start; the app finds those payments in the ledger so nothing '
      'is recorded twice. Its reply lists other bank SMS that look like the '
      'loan\'s repayments (saved, waiting for review or unparsed): ask the '
      'user whether to mark them as repayments before suggesting again with '
      'the ones they confirm. Money lent to or borrowed from a person: '
      'suggest_debt_entries. To add a new expense or income the user tells '
      'you about or shows you: suggest_transactions. Things that repeat, '
      'such as subscriptions, rent paid or received, premiums and SIPs: '
      'list_recurring_payments, then suggest_recurring_payments; to find '
      'them in the user\'s SMS and transactions, find_recurring_payments '
      'first and ask which to track. '
      'The Portfolio (stocks, ETFs, mutual funds, crypto, gold and other '
      'metals, held at a broker or in hand): list_portfolio first. To find '
      'a security\'s symbol: find_security. Then suggest_portfolio_changes '
      '(add a holding, record a buy, sell or dividend, set a price, edit, '
      'archive or delete). The broker or in-hand place itself is an '
      'account: suggest_account_changes with place. Money moved from a '
      'bank to a broker is a transfer: suggest_transactions with type '
      'transfer. To fix saved transactions (a category, the account, the '
      'amount or date, an expense or income that was really a transfer '
      'between the user\'s accounts): suggest_transaction_edits, with '
      'transaction_ids to change many at once. Duplicates and transfers '
      'saved twice: find_duplicates, then suggest_transaction_edits (delete '
      'a copy, or make one leg a transfer). Budgets: list_budgets. '
      'To add, edit, rebalance, archive, merge or delete accounts: '
      'list_accounts, then suggest_account_changes; when SMS scanning made '
      'two accounts for one (a bank account and its debit card), merge them. '
      'Work these out yourself rather than asking the user '
      'which value or column is which: they approve the result in the app. '
      'Each reply\'s next says what usually comes next; follow it, or take '
      'your own route when you can see a better one. These are the simplest '
      'paths, not the only ones: combine any tools, e.g. '
      'suggest_transaction_edits for many transactions in one call, or write '
      'a full SMS format with get_parser_rules, test_parser_rule and '
      'suggest_parser_rule.';

  static const _maxItems = 200;

  /// Transactions one bulk edit (transaction_ids) may reach.
  static const _maxBulk = 500;

  late final List<AgentTool> tools = _createTools();

  late final Map<String, AgentTool> _byName = {
    for (final tool in tools) tool.name: tool,
  };

  List<Map<String, Object?>> get definitions => [
    for (final tool in tools) tool.definition,
  ];

  /// Runs [name] and returns an MCP tool result. Bad input comes back as an
  /// error result the AI app can read and correct, never as an exception.
  ///
  /// [client] names the AI app that asked, so what it suggests can show it.
  Future<Map<String, Object?>> call(
    String name,
    Map<String, Object?> arguments, {
    String? client,
  }) async {
    final tool = _byName[name];
    if (tool == null) return _result('SimpleMoney has no tool $name.', true);
    if (!freeTools.contains(name) && !(canUsePro?.call() ?? true)) {
      return _result(proNeeded, true);
    }
    try {
      final answer = await runZoned(
        () => tool.handler(arguments),
        zoneValues: {AgentSuggestionRepository.clientKey: client},
      );
      if (answer is AgentToolAnswer) {
        return {
          'content': [
            {'type': 'text', 'text': jsonEncode(answer.json)},
            for (final image in answer.images)
              {
                'type': 'image',
                'data': base64Encode(image),
                'mimeType': 'image/jpeg',
              },
          ],
          'isError': false,
        };
      }
      return _result(jsonEncode(answer), false);
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
              'transactions': a.transactionCount,
              'last_digits': ?a.lastDigits,
              'institution': ?a.institution,
              'icon': ?a.icon,
              if (a.hasDebitCard) 'has_debit_card': true,
              if (a.isBroker) ...{
                'investment_account': true,
                'place': (a.place ?? AccountPlace.broker).toolName,
                if (a.place?.holdsCash ?? true)
                  'balance_is': 'funds waiting to be invested',
              },
              if (a.creditLimitMinor case final limit?)
                'credit_limit': _amount(limit, a.digits),
              if (a.availableCreditLimitMinor case final available?)
                'available_credit': _amount(available, a.digits),
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
            EXISTS (SELECT 1 FROM sms_imports s
              WHERE s.transaction_id = t.id) AS from_sms,
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
            if (r.read<bool>('from_sms')) 'from_bank_sms': true,
            if (notes) 'note': ?r.readNullable<String>('note'),
          },
      ],
    };
  }

  /// What finding money by phone number can't promise, said every time so
  /// the AI app passes it on.
  static const _phoneAccuracy =
      'Only entries whose text holds this number are found: a UPI ID built '
      'on it (9876543210@ybl, @paytm, @okaxis…) or an SMS quoting it. '
      'Payments are missed when the person\'s UPI ID is based on an email or '
      'name (name@okhdfcbank), a custom handle or another number, or when '
      'the bank SMS shows only a name or masks the number. Entries added by '
      'hand rarely hold a number at all.';

  /// Saved transactions, SMS waiting for review and unparsed bank SMS that
  /// mention [phone] as a number of its own, so a UPI ID like
  /// 9876543210@ybl matches and an account or reference number holding the
  /// same digits doesn't.
  Future<Object?> _findByPhone(Map<String, Object?> args) async {
    var digits = (_string(args, 'phone') ?? '').replaceAll(RegExp(r'\D'), '');
    if (digits.length > 10 && (digits.startsWith('91') || digits[0] == '0')) {
      digits = digits.substring(digits.length - 10);
    }
    if (digits.length < 7 || digits.length > 12) {
      throw const _BadInput(
        'Give a phone number, e.g. 9876543210 or +91 98765 43210.',
      );
    }
    final (from, to) = _optionalRange(args);
    final limit = (_int(args, 'limit') ?? 50).clamp(1, 200);
    // The digits as one run, maybe split by spaces or dashes, with an
    // optional +91 or 0 before them, and no digit either side.
    final spaced = digits.split('').join(r'[\s-]?');
    final number = RegExp('(?<![0-9])(?:\\+?91[\\s-]?|0)?$spaced(?![0-9])');
    String? hit(String text) {
      final m = number.firstMatch(text);
      if (m == null) return null;
      final start = math.max(0, m.start - 40);
      final end = math.min(text.length, m.end + 40);
      return text.substring(start, end).replaceAll(RegExp(r'\s+'), ' ').trim();
    }

    final upiIds = <String>{};
    final upi = RegExp(
      '(?<![0-9])$digits@[a-z][a-z0-9.]*',
      caseSensitive: false,
    );
    void collect(String text) =>
        upiIds.addAll(upi.allMatches(text).map((m) => m[0]!.toLowerCase()));

    // Saved: prefiltered in SQL on the bare digits, confirmed here.
    final rows = await database
        .customSelect(
          '''SELECT t.id, t.type, t.amount_minor, t.date, t.title, t.note,
              a.name AS account_name, a.currency, a.digits,
              c.name AS category_name, p.name AS parent_name,
              (SELECT group_concat(s.candidate, ' ') FROM sms_imports s
                WHERE s.transaction_id = t.id) AS sms
          FROM transactions t
          JOIN accounts a ON a.id = t.account_id
          LEFT JOIN categories c ON c.id = t.category_id
          LEFT JOIN categories p ON p.id = c.parent_id
          WHERE t.date >= ? AND t.date < ?
            AND instr(replace(replace(replace(
                  coalesce(t.title, '') || ' ' || coalesce(t.note, '') || ' '
                  || coalesce((SELECT group_concat(s.candidate, ' ')
                    FROM sms_imports s WHERE s.transaction_id = t.id), ''),
                ' ', ''), '-', ''), char(10), ''), ?) > 0
          ORDER BY t.date DESC, t.id DESC''',
          variables: [
            Variable(from.millisecondsSinceEpoch),
            Variable(to.millisecondsSinceEpoch),
            Variable(digits),
          ],
        )
        .get();
    final saved = <Map<String, Object?>>[];
    final totals = <(String, String, int), (int, int)>{};
    final names = <String>{};
    for (final r in rows) {
      final note = r.readNullable<String>('note') ?? '';
      final text =
          '${r.readNullable<String>('title') ?? ''}\n$note\n'
          '${r.readNullable<String>('sms') ?? ''}';
      final where = hit(text);
      if (where == null) continue;
      collect(text);
      final type = r.read<String>('type');
      final key = (type, r.read<String>('currency'), r.read<int>('digits'));
      final sum = totals[key] ?? (0, 0);
      totals[key] = (sum.$1 + r.read<int>('amount_minor'), sum.$2 + 1);
      if (r.readNullable<String>('title') case final title?
          when title.trim().isNotEmpty) {
        names.add(title.trim());
      }
      if (saved.length >= limit) continue;
      saved.add({
        'id': r.read<int>('id'),
        'date': _isoDay(
          DateTime.fromMillisecondsSinceEpoch(r.read<int>('date')),
        ),
        'type': type,
        'amount': _amount(r.read<int>('amount_minor'), r.read<int>('digits')),
        'currency': r.read<String>('currency'),
        'title': ?r.readNullable<String>('title'),
        'account': r.read<String>('account_name'),
        if (r.readNullable<String>('category_name') case final name?)
          'category': _path(r.readNullable<String>('parent_name'), name),
        'from':
            r.readNullable<String>('sms') != null || note.startsWith('Sender: ')
            ? 'bank_sms'
            : note.startsWith('UPI • ')
            ? 'upi_scan'
            : 'entered',
        'matched': where,
      });
    }

    // Waiting for review.
    final waiting = <Map<String, Object?>>[];
    for (final r
        in await database
            .customSelect(
              '''SELECT fingerprint, body, received_at, candidate FROM sms_imports
          WHERE status = 'pending' AND received_at >= ? AND received_at < ?
          ORDER BY received_at DESC''',
              variables: [
                Variable(from.millisecondsSinceEpoch),
                Variable(to.millisecondsSinceEpoch),
              ],
            )
            .get()) {
      final text =
          '${r.readNullable<String>('body') ?? ''}\n'
          '${r.read<String>('candidate')}';
      final where = hit(text);
      if (where == null) continue;
      collect(text);
      final data = Map<String, dynamic>.from(
        jsonDecode(r.read<String>('candidate')) as Map,
      );
      if (waiting.length >= limit) continue;
      waiting.add({
        'sms_id': r.read<String>('fingerprint'),
        'date': _isoDay(
          DateTime.fromMillisecondsSinceEpoch(r.read<int>('received_at')),
        ),
        if (data['amountMinor'] case final int minor)
          'amount': _amount(minor, 2),
        'currency': ?data['currencyCode'],
        'direction': ?data['direction'],
        'matched': where,
      });
    }

    // Unparsed bank SMS in the inbox, when the phone lets the app read it.
    final unparsed = <Map<String, Object?>>[];
    String? inbox;
    if (_bool(args, 'include_unparsed') ?? true) {
      final now = DateTime.now();
      final start = from.isAfter(DateTime(2000))
          ? from
          : now.subtract(const Duration(days: 180));
      try {
        final days = now.difference(start).inDays.clamp(1, 400) + 1;
        for (final m in await (missedSms ?? _readMissedSms)(
          Duration(days: days),
        )) {
          if (m.sms.receivedAt.isBefore(from) ||
              !m.sms.receivedAt.isBefore(to)) {
            continue;
          }
          final where = hit(m.sms.body);
          if (where == null) continue;
          collect(m.sms.body);
          if (unparsed.length >= limit) continue;
          unparsed.add({
            'id': _missedId(m),
            'date': _isoDay(m.sms.receivedAt),
            'sender': normalizeRuleSender(m.sms.sender) ?? m.sms.sender,
            'text': m.sms.body,
          });
        }
        inbox = 'Unparsed SMS searched from ${_isoDay(start)}.';
      } catch (_) {
        inbox =
            'Unparsed SMS not searched: SimpleMoney can’t read SMS on '
            'this phone now.';
      }
    }

    final found = saved.length + waiting.length + unparsed.length;
    return {
      'phone': digits,
      'accuracy': _phoneAccuracy,
      'upi_ids_seen': upiIds.toList()..sort(),
      'saved': {
        'count': totals.values.fold(0, (n, t) => n + t.$2),
        // Exact, so an AI app never adds rows up itself.
        'totals': [
          for (final MapEntry(key: (type, currency, digits), value: (sum, n))
              in totals.entries)
            {
              'type': type,
              'total': _amount(sum, digits),
              'currency': currency,
              'count': n,
            },
        ],
        'transactions': saved,
      },
      'sms_waiting_for_review': waiting,
      'unparsed_sms': unparsed,
      'unparsed_sms_search': ?inbox,
      if (names.isNotEmpty) 'names_seen': names.take(10).toList(),
      'next':
          '${found == 0 ? 'Nothing mentions this number. ' : ''}'
          'Tell the user what was found, and always say plainly how far it '
          'can be trusted (accuracy): payments to this person through a UPI '
          'ID not built on the number are not here. '
          '${names.isNotEmpty ? 'To catch more, search_transactions with a name from names_seen, and say those matches are by name only. ' : 'If the user knows the person\'s name or UPI ID, search_transactions with it. '}'
          'Use the saved totals as given; never add amounts up yourself.',
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

    final rows = await review.page(
      filter: filter,
      offset: offset,
      limit: limit,
    );
    // Each account once, not in every message that uses it.
    final used = {
      for (final row in rows)
        for (final id in [
          row.transaction.accountId,
          row.transaction.toAccountId,
        ])
          if (id != null && accounts.containsKey(id)) id,
    };
    return {
      'total': await review.count(filter),
      'offset': offset,
      if (used.isNotEmpty)
        'accounts': {for (final id in used) '$id': accounts[id]},
      'messages': [
        for (final row in rows) _pendingSms(row, accounts, categoryName),
      ],
    };
  }

  /// One message waiting for review, leaving out what is usual (a debit
  /// card flag that is false, a sender that is a bank) to save tokens.
  Map<String, Object?> _pendingSms(
    SmsReviewRow row,
    Map<int, String> accounts,
    String? Function(int?) categoryName,
  ) {
    final sms = row.sms;
    final t = row.transaction;
    final category = categoryName(t.categoryId);
    final hasAccount = accounts.containsKey(t.accountId);
    return {
      'sms_id': sms.id,
      'received_at': DateFormat("yyyy-MM-dd'T'HH:mm").format(sms.receivedAt),
      'sender': sms.sender,
      'text': sms.body,
      'parsed': {
        'amount': _amount(sms.amountMinor, sms.digits),
        'currency': sms.currency,
        'direction': sms.credit ? 'credit' : 'debit',
        'counterparty': ?sms.data['counterparty'],
        if (sms.holdsMoney) 'bank': sms.bankName,
        if (!sms.holdsMoney) 'sender_type': sms.data[smsSenderRoleKey],
        'account_last4': ?sms.accountLast4,
        'quoted_account_last4': ?sms.data[otherAccountKey],
        if (sms.creditCard) 'credit_card': true,
        if (sms.ambiguousAccount && sms.holdsMoney) 'account_ambiguous': true,
      },
      'current': {
        'type': t.type.storageValue,
        if (hasAccount) 'account_id': t.accountId,
        'to_account_id': ?t.toAccountId,
        if (category != null)
          'category': {'id': t.categoryId, 'name': category},
      },
      'ready': row.ready,
      if (!row.ready)
        'needs': [
          if (!hasAccount) 'account',
          if (category == null && t.toAccountId == null) 'category',
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
      direction: _enum(item, 'direction', const ['debit', 'credit']),
      loanId: _int(item, 'loan_id'),
      sameLayout: _bool(item, 'same_layout') ?? false,
      reason: _string(item, 'reason'),
    ),
  );

  Future<Object?> _suggestTransactionEdits(Map<String, Object?> args) async {
    final items = args['items'];
    if (items is! List || items.isEmpty) {
      throw const _BadInput('Give a non-empty items array.');
    }
    // One change for many transactions: an item with transaction_ids is the
    // same item for each of them. Each keeps the index of the item it came
    // from, so a rejection names the item the AI sent.
    final expanded = <(int, Map<String, Object?>)>[];
    final rejected = <Map<String, Object?>>[];
    for (final (index, item) in items.indexed) {
      if (item is! Map) {
        rejected.add({'index': index, 'error': 'Each item must be an object.'});
        continue;
      }
      final one = Map<String, Object?>.from(item);
      if (one.remove('transaction_ids') case final List ids) {
        for (final id in ids) {
          expanded.add((index, {...one, 'transaction_id': id}));
        }
      } else {
        expanded.add((index, one));
      }
    }
    if (expanded.length > _maxBulk) {
      throw const _BadInput('Send at most $_maxBulk transactions at a time.');
    }

    Future<AgentSuggestionDraft> prepare(Map<String, Object?> item) =>
        suggestions.prepareTransactionEdit(
          transactionId:
              _int(item, 'transaction_id') ??
              (throw const _BadInput(
                'Give transaction_id or transaction_ids.',
              )),
          categoryId: _int(item, 'category_id'),
          categoryName: _string(item, 'category_name'),
          accountId: _int(item, 'account_id'),
          title: _rawString(item, 'title'),
          note: _rawString(item, 'note'),
          loanId: _int(item, 'loan_id'),
          type: switch (_enum(item, 'type', const [
            'expense',
            'income',
            'transfer',
          ])) {
            final type? => TransactionTypeStorage.fromStorage(type),
            null => null,
          },
          toAccountId: _int(item, 'to_account_id'),
          amount: _money(item, 'amount'),
          date: _optionalDay(item, 'date'),
          delete: _bool(item, 'delete') ?? false,
          reason: _string(item, 'reason'),
        );
    String describe(Object error) =>
        error is _BadInput ? error.message : describeAgentError(error);

    // Each item is checked on its own. A transaction has one pending edit
    // at a time, so items for the same one (a bulk category, then its own
    // amount) become one edit, the later winning where they overlap, and
    // that edit is checked as a whole.
    final drafts = <int, (Map<String, Object?>, AgentSuggestionDraft)>{};
    for (final (index, item) in expanded) {
      try {
        final draft = await prepare(item);
        final id = _int(item, 'transaction_id')!;
        if (drafts[id] case (final earlier, _)) {
          final both = {...earlier, ...item};
          drafts[id] = (both, await prepare(both));
        } else {
          drafts[id] = (item, draft);
        }
      } catch (error) {
        rejected.add({
          'index': index,
          if (item['transaction_id'] case final id?) 'transaction_id': id,
          'error': describe(error),
        });
      }
    }
    if (drafts.isNotEmpty) {
      await suggestions.add([for (final (_, draft) in drafts.values) draft]);
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

  Future<Object?> _suggestTransactions(Map<String, Object?> args) => _suggest(
    args,
    (item) => suggestions.prepareTransactionAdd(
      type: TransactionTypeStorage.fromStorage(
        _enum(item, 'type', ['expense', 'income', 'transfer']) ?? 'expense',
      ),
      toAccountId: _int(item, 'to_account_id'),
      receivedAmount: _money(item, 'received_amount'),
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

  // ── Duplicates and budgets. ──

  /// Transactions saved twice, and transfers saved as an expense and an
  /// income, for suggest_transaction_edits to delete or join.
  Future<Object?> _findDuplicates(Map<String, Object?> args) async {
    final now = DateTime.now();
    final to = _optionalDay(args, 'to') ?? DateTime(now.year, now.month, now.day);
    final from =
        _optionalDay(args, 'from') ?? DateTime(to.year, to.month, to.day - 90);
    final accountId = _int(args, 'account_id');
    final days = (_int(args, 'days') ?? 1).clamp(0, 7);
    final ledger = [
      for (final t in await ledgerBetween(
        database,
        from,
        DateTime(to.year, to.month, to.day + 1),
      ))
        if (accountId == null ||
            t.accountId == accountId ||
            t.toAccountId == accountId)
          t,
    ];
    final accounts = {
      for (final a in await AccountRepository(database).load()) a.id: a,
    };
    final fromSms = {
      for (final r in await database
          .customSelect(
            'SELECT DISTINCT transaction_id FROM sms_imports '
            'WHERE transaction_id IS NOT NULL',
          )
          .get())
        r.read<int>('transaction_id'),
    };
    Map<String, Object?> shown(LedgerCandidate t) {
      final account = accounts[t.accountId];
      return {
        'id': t.id,
        'date': _isoDay(t.date),
        'type': t.type.storageValue,
        'amount': _amount(t.amountMinor, account?.digits ?? 2),
        'currency': account?.currency,
        'account': account?.name,
        if (t.toAccountId case final to?) 'to_account': accounts[to]?.name,
        'title': ?t.title,
        if (fromSms.contains(t.id)) 'from_bank_sms': true,
        // A loan, debt or recurring payment is built on it.
        if (!t.free) 'linked': true,
      };
    }

    // The same kind, account(s) and amount, a day or so apart.
    final same = <String, List<LedgerCandidate>>{};
    for (final t in ledger) {
      same
          .putIfAbsent(
            '${t.type.storageValue} ${t.accountId} ${t.toAccountId} '
            '${t.amountMinor}',
            () => [],
          )
          .add(t);
    }
    DateTime day(DateTime d) => DateTime.utc(d.year, d.month, d.day);
    final groups = <Map<String, Object?>>[];
    var distinct = 0;
    for (final list in same.values) {
      if (list.length < 2) continue;
      list.sort(
        (a, b) => a.date != b.date
            ? a.date.compareTo(b.date)
            : a.id.compareTo(b.id),
      );
      var run = [list.first];
      void close() {
        if (run.length < 2) return;
        final references = [for (final t in run) upiReferencesIn(t.references)];
        final shared = <String>{};
        for (var i = 0; i < references.length; i++) {
          for (var j = i + 1; j < references.length; j++) {
            shared.addAll(references[i].intersection(references[j]));
          }
        }
        // Each quoting its own reference: separate payments of one amount.
        if (shared.isEmpty && references.every((r) => r.isNotEmpty)) {
          distinct++;
          return;
        }
        groups.add({
          'evidence': shared.isNotEmpty
              ? 'same UPI reference: the same payment'
              : 'same amount and day only: may be two real payments',
          'transactions': [for (final t in run) shown(t)],
        });
      }

      for (final t in list.skip(1)) {
        if (day(t.date).difference(day(run.last.date)).inDays <= days) {
          run.add(t);
        } else {
          close();
          run = [t];
        }
      }
      close();
    }
    // Sure ones first.
    bool sure(Map<String, Object?> g) =>
        (g['evidence'] as String).startsWith('same UPI');
    groups.sort((a, b) => (sure(b) ? 1 : 0) - (sure(a) ? 1 : 0));
    final legs = recordedTransferLegs(ledger);
    return {
      'from': _isoDay(from),
      'to': _isoDay(to),
      'duplicates': groups.take(100).toList(),
      if (groups.length > 100) 'more_duplicates': groups.length - 100,
      if (distinct > 0)
        'left_out': '$distinct sets of equal amounts each quote their own '
            'UPI reference: separate payments, not duplicates.',
      'transfers_saved_twice': [
        for (final pair in legs.take(100))
          {'out': shown(pair.out), 'in': shown(pair.into)},
      ],
      'next':
          'For a duplicate, keep one (prefer the one from_bank_sms) and '
          'suggest_transaction_edits with delete for the others. When the '
          'evidence is the amount and day only, ask the user first. For a '
          'transfer saved twice, make "out" a transfer (type transfer, '
          'to_account_id the "in" account) and delete "in". Never touch a '
          'linked one: it belongs to a loan, debt or recurring payment.',
    };
  }

  Future<Object?> _listBudgets(Map<String, Object?> args) async {
    final now = DateTime.now();
    final month = switch (_string(args, 'month')) {
      final m? => DateTime.tryParse('$m-01') ??
          (throw const _BadInput('month must look like 2026-11.')),
      null => DateTime(now.year, now.month),
    };
    final categories = {
      for (final c in await CategoryRepository(database).load()) c.id: c,
    };
    final currencies = {
      for (final a in await AccountRepository(database).load())
        if (!a.isArchived) (a.currency, a.digits),
    };
    final budgets = BudgetRepository(database);
    Map<String, Object?> line(BudgetLine b, int digits) => {
      'limit': _amount(b.limit, digits),
      'spent': _amount(b.spent, digits),
      'left': _amount(b.limit - b.spent, digits),
    };
    return {
      'month': DateFormat('yyyy-MM').format(month),
      'by_currency': [
        for (final (currency, digits) in currencies)
          if (await budgets.loadMonth(month, currency, digits) case final m
              when !m.isEmpty)
            {
              'currency': currency,
              if (m.allSpending case final total?)
                'total_budget': line(total, digits),
              'budgets': [
                for (final b in m.budgets)
                  {
                    'id': b.id,
                    'name':
                        b.name ??
                        b.categoryIds
                            .map((id) => categories[id]?.name)
                            .nonNulls
                            .join(' + '),
                    'categories': [
                      for (final id in b.categoryIds)
                        {'id': id, 'name': categories[id]?.name},
                    ],
                    ...line(b, digits),
                  },
              ],
            },
      ],
      'next':
          'Spending counts expenses only, never transfers. Budgets are set '
          'in the app: SimpleMoney → Budgets.',
    };
  }

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

  /// Short ids list_missed_sms and the finders give unparsed messages.
  static final _unreadRef = RegExp(r'^m[0-9a-z]{1,8}$');

  /// The inbox's bank SMS no rule reads, from the last [days]; null when the
  /// app can't read SMS on this phone now.
  Future<List<LoanSms>?> _unreadSms(int days) async {
    try {
      return [
        for (final m in await (missedSms ?? _readMissedSms)(
          Duration(days: days.clamp(1, 400)),
        ))
          (
            ref: _missedId(m),
            id: m.id,
            sender: m.sms.sender,
            body: m.sms.body,
            receivedAt: m.sms.receivedAt,
          ),
      ];
    } catch (_) {
      return null;
    }
  }

  Future<Object?> _suggestRecurringPayments(Map<String, Object?> args) async {
    List<String> smsIds(Map<String, Object?> item) => switch (item['sms_ids']) {
      null => const [],
      final List ids when ids.every((id) => id is String) => ids.cast<String>(),
      _ => throw const _BadInput('sms_ids must be an array of ids.'),
    };
    // Unparsed messages are read from the inbox once, for every item.
    final items = args['items'];
    final wantsInbox =
        items is List &&
        items.any(
          (i) =>
              i is Map &&
              i['sms_ids'] is List &&
              (i['sms_ids'] as List).any(
                (s) => s is String && _unreadRef.hasMatch(s),
              ),
        );
    final inbox = wantsInbox ? await _unreadSms(400) : const <LoanSms>[];
    return _suggest(args, (item) {
      final unread = <LoanSms>[];
      final waiting = <String>[];
      for (final id in smsIds(item)) {
        if (!_unreadRef.hasMatch(id)) {
          waiting.add(id);
          continue;
        }
        final sms = inbox?.where((m) => m.ref == id).firstOrNull;
        if (sms == null) {
          throw _BadInput(
            inbox == null
                ? 'SimpleMoney can’t read SMS on this phone now, so unparsed '
                      'message “$id” can’t be saved. Leave it out.'
                : 'No unparsed message has sms_id “$id”. Use an id from '
                      'find_recurring_payments.',
          );
        }
        unread.add(sms);
      }
      return suggestions.prepareRecurringPayment(
        name: _rawString(item, 'name') ?? (throw const _BadInput('Give name.')),
        amount:
            _money(item, 'amount') ?? (throw const _BadInput('Give amount.')),
        accountId:
            _int(item, 'account_id') ??
            (throw const _BadInput('Give account_id.')),
        cycle:
            _enum(item, 'cycle', [
              'weekly',
              'monthly',
              'quarterly',
              'yearly',
            ]) ??
            'monthly',
        nextDue: _optionalDay(item, 'next_due'),
        incoming: _bool(item, 'incoming') ?? false,
        categoryId: _int(item, 'category_id'),
        categoryName: _string(item, 'category_name'),
        icon: _string(item, 'icon'),
        remind: _bool(item, 'remind') ?? true,
        transactionIds: switch (item['transaction_ids']) {
          null => const [],
          final List ids when ids.every((id) => id is int) => ids.cast<int>(),
          _ => throw const _BadInput(
            'transaction_ids must be an array of transaction ids.',
          ),
        },
        waitingSms: waiting,
        unreadSms: unread,
        reason: _string(item, 'reason'),
      );
    });
  }

  Future<Object?> _findRecurringPayments(Map<String, Object?> args) async {
    final months = (_int(args, 'months') ?? 12).clamp(3, 24);
    final now = DateTime.now();
    final wantsInbox = _bool(args, 'include_unparsed') ?? true;
    final unread = wantsInbox
        ? await _unreadSms(
            now.difference(DateTime(now.year, now.month - months)).inDays + 1,
          )
        : const <LoanSms>[];
    final found = await AgentRecurringFinder(database).find(
      months: months,
      income: _bool(args, 'include_income') ?? true,
      unparsed: unread ?? const [],
    );
    final limit = (_int(args, 'limit') ?? 25).clamp(1, 60);
    final fresh = found.where((c) => !c.alreadyTracked).toList();
    final tracked = found.length - fresh.length;
    final fromSms = fresh.any(
      (c) => c.payments.any((p) => p.source != RecurringSource.saved),
    );
    String sourceName(RecurringSource source) => switch (source) {
      RecurringSource.saved => 'saved',
      RecurringSource.needsReview => 'needs_review',
      RecurringSource.unparsed => 'unparsed',
    };
    return {
      'months_searched': months,
      'found': fresh.length,
      if (tracked > 0) 'already_tracked': tracked,
      'searched': [
        'saved transactions',
        'SMS waiting for review',
        if (wantsInbox && unread != null) 'unparsed bank SMS',
      ],
      if (wantsInbox && unread == null)
        'unparsed_sms':
            'Not searched: SimpleMoney can’t read SMS on this phone now.',
      'candidates': [
        for (final c in fresh.take(limit))
          {
            'name': c.name,
            'kind': c.kind,
            if (c.knownService) 'known_service': true,
            'incoming': c.incoming,
            'amount': _amount(c.amountMinor, c.digits),
            if (!c.exact) 'amount_varies': true,
            'currency': c.currency,
            'cycle': c.cycle.name,
            'account_id': c.accountId,
            if (c.accountId != null) 'account': c.account,
            'next_due': _isoDay(c.nextDue),
            'last_paid': _isoDay(c.payments.last.date),
            'times': c.payments.length,
            'seen_in': {
              for (final source in RecurringSource.values)
                if (c.from(source).isNotEmpty)
                  sourceName(source): c.from(source).length,
            },
            'confidence': c.confidence.name,
            if (c.stopped) 'may_have_stopped': true,
            'category': ?c.category,
            // The newest 24 are plenty to link as its history.
            'transaction_ids': [
              for (final t in c.payments.reversed.take(24)) ?t.transactionId,
            ],
            'sms_ids': [for (final t in c.payments.reversed.take(24)) ?t.smsId],
          },
      ],
      'next': fresh.isEmpty
          ? 'Nothing repeats steadily enough to suggest. If the user names '
                'one (rent to a person, a subscription), search_transactions '
                'for it and suggest_recurring_payments.'
          : 'Nothing has changed yet. List these for the user, grouped by '
                'kind (subscriptions, bills, rent or a person, money coming '
                'in), with amount, cycle and how many times it was seen; say '
                'which look stopped or vary in amount, and that a pattern is '
                'a guess (a friend paid the same sum monthly isn’t rent).'
                '${fromSms ? ' Say which payments were seen in bank SMS waiting for review or unparsed (seen_in): approving saves those messages as its past payments, so none is left in SMS review or unread.' : ''} '
                'Ask which to track. For those, call '
                'suggest_recurring_payments with name, amount, account_id '
                '(from list_accounts when it is null here), cycle, next_due, '
                'incoming, and transaction_ids and sms_ids as given here '
                '(they become its payment history), then ask the user to '
                'approve in SimpleMoney → More → AI suggestions.',
    };
  }

  Future<Object?> _suggestAccountChanges(Map<String, Object?> args) =>
      _suggest(args, (item) {
        final action =
            AgentAccountAction.fromToolName(
              _enum(item, 'action', [
                for (final a in AgentAccountAction.values) a.toolName,
              ]),
            ) ??
            (throw const _BadInput('Give action.'));
        final type = _enum(item, 'type', [
          for (final t in AccountType.values) t.name,
        ]);
        return accounts.prepare(
          action: action,
          accountId: _int(item, 'account_id'),
          mergeIntoId: _int(item, 'merge_into_id'),
          fields: AgentAccountFields(
            name: _rawString(item, 'name'),
            type: type == null ? null : AccountType.values.byName(type),
            currency: _string(item, 'currency'),
            lastDigits: _string(item, 'last_digits'),
            institution: _rawString(item, 'institution'),
            icon: _string(item, 'icon'),
            place: switch (_enum(item, 'place', [
              for (final p in AccountPlace.selectable) p.toolName,
            ])) {
              final id? => AccountPlace.selectable.firstWhere(
                (p) => p.toolName == id,
              ),
              null => null,
            },
            balance: _money(item, 'balance'),
            creditLimit: _money(item, 'credit_limit'),
            availableCredit: _money(item, 'available_credit'),
          ),
          reason: _string(item, 'reason'),
        );
      });

  // ── Portfolio. ──

  /// An exact decimal from a scaled integer, trailing zeros dropped.
  static String _scaledText(int value, int scale) {
    final places = scale.toString().length - 1;
    final whole = value ~/ scale;
    final fraction = (value % scale).toString().padLeft(places, '0');
    final trimmed = fraction.replaceFirst(RegExp(r'0+$'), '');
    return trimmed.isEmpty ? '$whole' : '$whole.$trimmed';
  }

  Future<Object?> _listPortfolio(Map<String, Object?> args) async {
    final archived = _bool(args, 'include_archived') ?? false;
    final onlyAccount = _int(args, 'account_id');
    final onlyHolding = _int(args, 'holding_id');
    final withTrades =
        (_bool(args, 'include_trades') ?? false) || onlyHolding != null;
    final accounts = await AccountRepository(database).load();
    final repository = HoldingRepository(database);
    final holdings = await repository.loadHoldings();
    final trades = await repository.loadTrades();
    final places = <Map<String, Object?>>[];
    for (final a in accounts) {
      if (!a.isBroker || (a.isArchived && !archived)) continue;
      if (onlyAccount != null && a.id != onlyAccount) continue;
      final rows = <Map<String, Object?>>[];
      var value = 0;
      var cost = 0;
      var valued = true;
      for (final h in holdings) {
        if (h.accountId != a.id) continue;
        if (onlyHolding != null && h.id != onlyHolding) continue;
        if (h.archivedAt != null && !archived) continue;
        final own = trades.where((t) => t.holdingId == h.id).toList();
        final position = positionOf(own, digits: a.digits);
        final code = h.currencyIn(a.currency);
        final price = h.lastPriceE4;
        final worth = price == null || code != a.currency
            ? null
            : position.valueMinor(price, a.digits);
        if (!position.isEmpty) {
          cost += position.costMinor;
          if (worth == null) {
            valued = false;
          } else {
            value += worth;
          }
        }
        final metal = h.metalDetails;
        rows.add({
          'holding_id': h.id,
          'name': h.name,
          'kind': h.kind.name,
          if (h.symbol != null) 'symbol': h.symbol,
          if (h.exchange != null) 'exchange': h.exchange,
          if (metal != null) ...{
            'metal': metal.metal.id,
            'purity': metal.purityLabel,
          },
          'units': _scaledText(position.unitsE6, unitScale),
          if (h.kind == HoldingKind.metal) 'units_are': 'grams',
          'cost': _amount(position.costMinor, a.digits),
          if (position.averagePriceE4(a.digits) case final avg?)
            'average_price': _scaledText(avg, priceScale),
          if (price != null) ...{
            'price': _scaledText(price, priceScale),
            'price_currency': code,
            if (h.priceDate != null) 'price_as_of': _isoDay(h.priceDate!),
          },
          if (worth != null) 'value': _amount(worth, a.digits),
          if (worth != null && position.costMinor > 0)
            'gain': _amount(worth - position.costMinor, a.digits),
          if (h.effectivePriceSource != null)
            'price_source': h.effectivePriceSource,
          if (position.realizedMinor != 0)
            'realized_gain': _amount(position.realizedMinor, a.digits),
          if (position.dividendsMinor != 0)
            'dividends': _amount(position.dividendsMinor, a.digits),
          if (h.archivedAt != null) 'archived': true,
          if (withTrades)
            'trades': [
              for (final t in own.reversed.take(100))
                {
                  'trade_id': t.id,
                  'type': t.type.name,
                  'date': _isoDay(t.date),
                  if (t.type != TradeType.dividend) ...{
                    'units': _scaledText(t.unitsE6, unitScale),
                    'price': _scaledText(t.priceE4, priceScale),
                  },
                  'amount': _amount(t.amountMinor, a.digits),
                  if (t.feesMinor > 0) 'fees': _amount(t.feesMinor, a.digits),
                  if (t.payAccountId != null)
                    'paid_from_account_id': t.payAccountId,
                  if (t.note != null) 'note': t.note,
                },
            ],
        });
      }
      places.add({
        'account_id': a.id,
        'name': a.name,
        'place': (a.place ?? AccountPlace.broker).toolName,
        'currency': a.currency,
        if (a.place?.holdsCash ?? true)
          'funds': _amount(a.balanceMinor, a.digits),
        if (onlyHolding == null) ...{
          'invested': _amount(cost, a.digits),
          if (valued) 'holdings_value': _amount(value, a.digits),
        },
        if (a.isArchived) 'archived': true,
        'holdings': rows,
      });
    }
    return {
      'places': places,
      'next': places.isEmpty
          ? 'No broker or in-hand place yet. Add one with '
                'suggest_account_changes (action create, place broker or '
                'in_hand), then its holdings.'
          : 'Prices are the last close or what the user typed; units of a '
                'metal are grams. Nothing changes until '
                'suggest_portfolio_changes is approved in SimpleMoney → '
                'More → AI suggestions.',
    };
  }

  Future<Object?> _findSecurity(Map<String, Object?> args) async {
    final query = _requiredString(args, 'query');
    final kind = HoldingKind.values.byName(
      _enum(args, 'kind', [for (final k in HoldingKind.selectable) k.name]) ??
          'stock',
    );
    if (kind == HoldingKind.metal) {
      final q = query.toLowerCase();
      return {
        'results': [
          for (final m in MetalType.values)
            if (m.label.toLowerCase().contains(q) || q.length < 2)
              {
                'name': m.label,
                'kind': 'metal',
                'metal': m.id,
                'common_purities': [
                  for (final f in m.purities) m.purityLabel(f),
                ],
                'price_source': PriceSourceId.metalWorld,
              },
        ],
        'next':
            'Use add_holding with kind metal, metal and purity (e.g. 22K or '
            '916). Units are grams; the price is the international one in the '
            'account\'s currency.',
      };
    }
    var currency = _string(args, 'currency')?.toUpperCase();
    if (currency == null) {
      final id = _int(args, 'account_id');
      final all = await AccountRepository(database).load();
      currency =
          all.where((a) => a.id == id).firstOrNull?.currency ??
          all.where((a) => a.isBroker).firstOrNull?.currency ??
          'USD';
    }
    final client = priceService == null ? http.Client() : null;
    try {
      final hits = await (priceService ?? PriceService(client!)).search(
        query,
        currency: currency,
        kind: kind,
      );
      return {
        'results': [
          for (final h in hits.take(15))
            {
              'name': h.name,
              'kind': h.kind.name,
              'symbol': h.symbol,
              if (h.exchange != null) 'exchange': h.exchange,
              if (h.priceSource != null) 'price_source': h.priceSource,
            },
        ],
        'next': hits.isEmpty
            ? 'Nothing found. Try another spelling, or the ticker. Funds in '
                  'India are found by name (AMFI); other funds need their '
                  'exact name.'
            : 'Use add_holding with the name, symbol, exchange and '
                  'price_source of the right one (ask the user if unsure). '
                  'kind must match what it is: stock, etf, fund or crypto.',
      };
    } finally {
      client?.close();
    }
  }

  Future<Object?> _suggestPortfolioChanges(Map<String, Object?> args) =>
      _suggest(args, (item) {
        final action =
            AgentPortfolioAction.fromToolName(
              _enum(item, 'action', [
                for (final a in AgentPortfolioAction.values) a.toolName,
              ]),
            ) ??
            (throw const _BadInput('Give action.'));
        final kind = _enum(item, 'kind', [
          for (final k in HoldingKind.selectable) k.name,
        ]);
        return portfolio.prepare(
          action: action,
          accountId: _int(item, 'account_id'),
          holdingId: _int(item, 'holding_id'),
          tradeId: _int(item, 'trade_id'),
          fields: AgentPortfolioFields(
            kind: kind == null ? null : HoldingKind.values.byName(kind),
            name: _rawString(item, 'name'),
            symbol: _string(item, 'symbol'),
            exchange: _rawString(item, 'exchange'),
            priceSource: _string(item, 'price_source'),
            currency: _string(item, 'currency'),
            metal: _string(item, 'metal'),
            purity: _string(item, 'purity'),
            icon: _string(item, 'icon'),
            units: _money(item, 'units'),
            price: _money(item, 'price'),
            amount: _money(item, 'amount'),
            fees: _money(item, 'fees'),
            date: _optionalDay(item, 'date'),
            payFromAccountId: _int(item, 'pay_from_account_id'),
            note: _string(item, 'note'),
          ),
          reason: _string(item, 'reason'),
        );
      });

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
    // Messages no rule reads, from the loan's start: the user is asked about
    // the ones that look like its payments. Without inbox access, the ledger
    // and the SMS review queue are still searched.
    final start = _day(args, 'start_date');
    final days = DateTime.now().difference(start).inDays + 4;
    final unread = await _unreadSms(days);
    final inboxRead = unread != null;
    LoanSms? unreadSms(String id) =>
        unread?.where((m) => m.ref == id).firstOrNull;
    final plan = await loans.prepareLoan(
      LoanInput(
        lender: _requiredString(args, 'lender'),
        amount:
            _money(args, 'amount') ?? (throw const _BadInput('Give amount.')),
        startDate: start,
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
                final smsId = _string(p, 'sms_id');
                final unparsed = smsId == null ? null : unreadSms(smsId);
                // Any other id is looked up in the SMS review queue.
                if (smsId != null && unparsed == null && !inboxRead) {
                  if (RegExp(r'^m[0-9a-z]{1,8}$').hasMatch(smsId)) {
                    throw _BadInput(
                      'SimpleMoney can’t read SMS on this phone now, so '
                      'unparsed message “$smsId” can’t be saved. Leave out '
                      'its sms_id.',
                    );
                  }
                }
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
                  smsId: smsId,
                  unparsed: unparsed,
                );
              }()
            else
              throw const _BadInput('Each payment must be an object.'),
        ],
      ),
      unparsed: unread ?? const [],
    );
    await suggestions.add([plan.draft]);
    onSuggestionsChanged?.call();
    return {
      'suggested': 1,
      ...plan.report,
      if (!inboxRead)
        'unparsed_sms':
            'Not searched: SimpleMoney can’t read SMS on this phone now.',
    };
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
                'offers, and messages with neither an account number nor a '
                'clear category (refund, salary…). The user picks the missing '
                'one in SMS review. Its reply says which message to label next.',
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
          'AI suggestions to approve the rule. If the SMS has no account '
          'number, tell them to choose the account (or, if it has no clear '
          'category, the category) on each future payment when they review it '
          'in the SMS review. $_shareTip',
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
    final stage = _enum(args, 'stage', _stages) ?? 'done';
    if (stage != 'done') {
      _settled.add(id);
      return {
        'suggested': false,
        'not_taught':
            'Money hasn’t moved yet ($stage), so it isn’t a payment to save. '
            'The SMS for the payment itself is the one to teach.',
        'next': _labelNext(sender, [
          for (final m in missed)
            if (m != target &&
                (normalizeRuleSender(m.sms.sender) ?? m.sms.sender) == sender &&
                !_settled.contains(_missedId(m)))
              m,
        ], 0),
      };
    }
    final role =
        SmsSenderRole.tryParse(_string(args, 'sender_type')) ??
        (throw ArgumentError(
          'Give sender_type: ${SmsSenderRole.values.map((r) => r.name).join(', ')}.',
        ));
    // A bank the app doesn't know needs a name; its SMS usually signs off
    // with one ("… -Fincare SFB"), which beats a small model's guess.
    // A shop's rule is named after the shop, which is never an account but
    // is the payee.
    final bankName =
        _string(args, 'bank_name') ??
        _signOff(target.sms.body) ??
        (role.holdsMoney ? null : sender);
    final format = buildLabeledFormat(
      text: target.sms.body,
      amount: _string(args, 'amount') ?? '',
      account: _string(args, 'account'),
      payee: _string(args, 'payee'),
      reference: _string(args, 'reference'),
      direction: _string(args, 'direction') ?? '',
      channel: _string(args, 'channel') ?? '',
      role: role,
      senderName: bankName,
      country:
          _string(args, 'country')?.toUpperCase() ??
          (throw ArgumentError(
            'Give country: where the bank or shop is, as a two-letter code '
            '(IN, AE, US…).',
          )),
      currency:
          _string(args, 'currency')?.toUpperCase() ??
          (throw ArgumentError(
            'Give currency: the three-letter code of the amount (INR, AED…).',
          )),
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
      if (AgentRuleLab.userPicks(first.result.candidate!, role) case final picks
          when picks.isNotEmpty)
        'user_picks_in_review': picks,
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
          'user to approve it in SimpleMoney → More → AI suggestions. $_shareTip';
    }
    return 'Now call label_sms with sms_id ${_missedId(unread.first)} '
        '(${unread.length} still missed from $sender). Don’t ask the user '
        'first.$skip';
  }

  static const _stages = ['done', 'pending', 'failed', 'scheduled'];

  /// Said once a rule is ready: the app asks to share it right after it is
  /// approved, so others with the same bank get it without an AI.
  static const _shareTip =
      'Also tell them: once approved, SimpleMoney asks to share it. If the '
      'messages it reads look right, tap Share so others with this bank get '
      'it too. Only the format is shared, never their messages.';

  /// The bank's name an SMS ends with, as in "… -Fincare SFB".
  static String? _signOff(String body) {
    final match = RegExp(r'[-–]\s*([A-Za-z][A-Za-z .&]{1,38}?)\.?\s*$')
        .firstMatch(body);
    return match?.group(1)?.trim();
  }

  // ── Statements. ──

  /// map_statement's columns so far, per statement, for this session.
  final _mapped = <String, Map<TableField, int>>{};

  /// map_statement's joined columns so far, per statement.
  final _joined = <String, Map<int, int>>{};

  late final _statements = StatementSampleRepository();

  /// The page pictures the user allowed for [signature]; none where the
  /// phone keeps no files (tests).
  Future<List<Uint8List>> _pagePictures(String signature) async {
    try {
      return await PendingStatementFiles().pictures(signature);
    } catch (_) {
      return const [];
    }
  }

  Future<Object?> _viewStatementPages(Map<String, Object?> args) async {
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
    final pictures = await _pagePictures(sample.signature);
    final columns = {
      'app_columns': [
        for (final c in sample.header)
          if (c.trim().isNotEmpty) c,
      ],
      'app_rows': sample.rows,
    };
    if (pictures.isEmpty) {
      return {
        ...columns,
        'pages': 0,
        'next':
            'The user hasn’t shared pictures of this file. Map it from '
            'app_rows, or ask them to tap Ask my AI on the statement and '
            'allow pictures.',
      };
    }
    return AgentToolAnswer(
      {
        ...columns,
        'pages': pictures.length,
        'next':
            'The pictures show the statement as printed. Check each printed '
            'column against app_columns: where the app split one column in '
            'two (wrapped text, an amount out of line), join them with '
            'map_statement’s join. Then map date, description and amounts.',
      },
      pictures,
    );
  }

  Future<Object?> _listStatementsToMap(Map<String, Object?> args) async {
    final samples = await _statements.load();
    // Read once for every statement listed: each file can be large.
    final kept = await _keptFiles();
    return {
      'statements': [
        for (final s in samples)
          {
            'id': s.id,
            'file': s.fileName,
            if ((await _pagePictures(s.signature)).isNotEmpty)
              'has_page_pictures': true,
            'column_names': [
              for (final c in s.header)
                if (c.trim().isNotEmpty) c,
            ],
            'example_rows': s.rows,
            // A column empty in the examples may still be used further down.
            if (_columnUse(s, kept) case final use?)
              'rows_with_value_per_column': use,
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
            'statement the app can\'t read by itself, or taps Ask my AI on '
            'a statement\'s columns screen when one reads wrong (More → '
            'Statements, then pick the file).',
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
    // Columns the PDF table split in two, read as one: {"Column 3":
    // "Description"}. Given again, they replace the ones before.
    if (args['join'] case final Map join) {
      final joins = <int, int>{};
      for (final MapEntry(:key, :value) in join.entries) {
        final from = _columnNamed(sample, '$key');
        final into = _columnNamed(sample, '$value');
        if (from == null || into == null || from == into) {
          throw ArgumentError(
            'Can’t join “$key” to “$value”. Use two different names from '
            'column_names: ${sample.header.where((c) => c.trim().isNotEmpty).join(', ')}.',
          );
        }
        joins[from] = into;
      }
      _joined[id] = joins;
    }
    final joins = _joined[id] ?? const <int, int>{};
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
      if (joins.containsKey(column)) continue;
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
      joins: joins,
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
    final whole = await _checkWholeFile(sample, mapping);
    final gaps = whole?['rows_missing_amount_or_balance'];
    // The one thing to fix next, plainly; null once it all reads.
    final fix = gaps != null
        ? '$gaps rows in the whole file have no amount or no balance in the '
              'columns you gave: their_amounts shows where those sit. Join '
              'that column with map_statement’s join, then call again.'
        : hasOut != hasIn
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
            '${e.key.label}: ${mapping.partsOf(e.value).map((c) => sample.header[c]).join(' + ')}',
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
      'whole_file': ?whole,
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

  /// The whole file [sample] came from, kept on the phone: its header row
  /// then every row under it. Null when it isn't kept (or in tests).
  Future<List<List<String>>?> _wholeTable(StatementSample sample) async =>
      _tableIn(sample, await _keptFiles());

  /// The statement files kept on the phone; none where it keeps none
  /// (tests).
  Future<List<PendingStatementFile>> _keptFiles() async {
    try {
      return await PendingStatementFiles().load();
    } catch (_) {
      return const [];
    }
  }

  static List<List<String>>? _tableIn(
    StatementSample sample,
    List<PendingStatementFile> files,
  ) {
    final file = files
        .where((f) => f.signature == sample.signature)
        .firstOrNull;
    if (file == null) return null;
    return file.rows.sublist(guessHeaderRow(file.rows));
  }

  /// How [mapping] reads the whole file, not just the sample rows: a column
  /// split by the PDF can be empty in the first rows and hold amounts later.
  /// Only amounts leave the phone, never a row's text.
  Future<Map<String, Object?>?> _checkWholeFile(
    StatementSample sample,
    TableMapping mapping,
  ) async {
    final table = await _wholeTable(sample);
    if (table == null || table.length < 2) return null;
    final header = table.first;
    bool has(List<String> row, TableField field) => switch (mapping[field]) {
      final column? => mapping
          .partsOf(column)
          .any((c) => (row.elementAtOrNull(c) ?? '').trim().isNotEmpty),
      null => false,
    };
    final dateColumn = mapping[TableField.date]!;
    var missing = 0;
    final examples = <Map<String, String>>[];
    for (final row in table.skip(1)) {
      if (parseTableDate(row.elementAtOrNull(dateColumn), mapping.dateOrder) ==
          null) {
        continue;
      }
      final money =
          has(row, TableField.amount) ||
          has(row, TableField.debit) ||
          has(row, TableField.credit);
      final balance =
          mapping[TableField.balance] == null || has(row, TableField.balance);
      if (money && balance) continue;
      missing++;
      if (examples.length < 3) {
        examples.add({
          for (final (i, cell) in row.indexed)
            if (i != dateColumn &&
                i < header.length &&
                parseTableAmount(cell) != null)
              header[i].trim().isEmpty ? 'Column ${i + 1}' : header[i]: cell,
        });
      }
    }
    final parsed = parseStatementTable(table, mapping);
    return {
      'rows': parsed.statement.rows.length,
      'balance_breaks': parsed.balanceBreaks ?? 0,
      if (missing > 0) ...{
        'rows_missing_amount_or_balance': missing,
        'their_amounts': examples,
      },
    };
  }

  /// How many rows of the whole file have something in each column.
  static Map<String, int>? _columnUse(
    StatementSample sample,
    List<PendingStatementFile> files,
  ) {
    final table = _tableIn(sample, files);
    if (table == null || table.isEmpty) return null;
    return {
      for (final (i, name) in table.first.indexed)
        if (name.trim().isNotEmpty)
          name: table
              .skip(1)
              .where((r) => (r.elementAtOrNull(i) ?? '').trim().isNotEmpty)
              .length,
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
