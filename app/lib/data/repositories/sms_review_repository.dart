import 'dart:convert';

import 'package:drift/drift.dart';

import '../../domain/account.dart';
import '../../domain/category.dart';
import '../../domain/sms_matching.dart';
import '../../domain/transaction.dart';
import '../../domain/transaction_preview.dart';
import '../db/app_database.dart';
import 'loan_repository.dart';
import 'sms_import_repository.dart';
import 'category_repository.dart';
import '../../domain/currency_digits.dart';

class SmsReviewFilter {
  const SmsReviewFilter({
    this.search = '',
    this.type,
    this.ready,
    this.accountId,
    this.categoryId,
    this.start,
    this.end,
  });
  final String search;
  final String? type;
  final bool? ready;
  final int? accountId, categoryId;
  final DateTime? start, end;
}

class SmsReviewRow {
  const SmsReviewRow(this.sms, this.transaction, this.ready);
  final PendingSmsImport sms;
  final MoneyTransaction transaction;
  final bool ready;
}

/// Bounded SQL queries over device-local wizard data.
class SmsReviewRepository {
  SmsReviewRepository(this.database);
  final AppDatabase database;
  static const pageSize = 50;

  /// Only small reference tables participate. Balance and ledger updates do
  /// not affect matching or search and must not invalidate the SMS index.
  Future<String> contextSignature(String rules) async {
    final accounts = await database
        .customSelect(
          'SELECT id,name,currency,digits,type,archived_at FROM accounts ORDER BY id',
        )
        .get();
    final categories = await database
        .customSelect(
          'SELECT id,name,type,parent_id FROM categories ORDER BY id',
        )
        .get();
    final links = await database
        .customSelect(
          'SELECT bank_key,account_id FROM sms_account_links ORDER BY bank_key',
        )
        .get();
    final detected = await database
        .customSelect(
          'SELECT bank_key FROM sms_detected_accounts ORDER BY bank_key',
        )
        .get();
    return jsonEncode([
      'federal-history-resolution-v1-food-drafts-v2',
      detected.map((r) => r.data).toList(),
      rules,
      accounts.map((r) => r.data).toList(),
      categories.map((r) => r.data).toList(),
      links.map((r) => r.data).toList(),
    ]);
  }

  Future<bool> contextChanged(String signature) async {
    final row = await database
        .customSelect('SELECT signature FROM sms_review_context WHERE id=1')
        .getSingleOrNull();
    return row?.read<String>('signature') != signature;
  }

  Future<void> recordContext(String signature) => database.customStatement(
    'INSERT OR REPLACE INTO sms_review_context(id,signature) VALUES (1,?)',
    [signature],
  );

  Future<bool> needsSync() async {
    final row = await database.customSelect('''SELECT EXISTS(
            SELECT 1 FROM sms_imports i
            WHERE i.status='pending' AND NOT EXISTS (
              SELECT 1 FROM sms_review r WHERE r.fingerprint=i.fingerprint
            )
          ) AS needed''').getSingle();
    return row.read<int>('needed') == 1;
  }

  Future<void> put(
    PendingSmsImport sms,
    List<Account> accounts,
    List<Category> categories,
    Map<String, int> links,
    int? selected, {
    List<PendingSmsImport>? detected,
  }) async {
    sms = resolveSmsAccount(
      sms,
      detected ?? await SmsImportRepository(database).detectedAccounts(),
    );
    final account = accounts
        .where(
          (a) =>
              a.id ==
                  (sms.data['assignedAccountId'] ??
                      (sms.holdsMoney ? links[sms.bankKey] : null)) &&
              a.currency == sms.currency &&
              a.digits == currencyDigits(a.currency) &&
              !a.isArchived,
        )
        .firstOrNull;
    final cash = smsCashAccount(sms, accounts);
    // A choice made this session wins over one saved with the message (an
    // approved AI suggestion), which wins over the rule pack's guess.
    selected ??= sms.data['assignedCategoryId'] as int?;
    final category = sms.requiresTransfer
        ? null
        : categories
                  .where(
                    (c) =>
                        c.id == selected &&
                        c.type ==
                            (sms.credit
                                ? CategoryType.income
                                : CategoryType.expense),
                  )
                  .firstOrNull ??
              smsCategory(sms, categories);
    final ready =
        account != null &&
        (sms.isAtmCashMovement
            ? account.type == AccountType.bank && cash != null
            : category != null);
    final from = sms.isAtmDeposit
        ? cash?.id
        : sms.isCreditCardRepayment && sms.credit
        ? null
        : account?.id;
    final to = sms.isAtmDeposit || (sms.isCreditCardRepayment && sms.credit)
        ? account?.id
        : sms.isAtmCashMovement
        ? cash?.id
        : null;
    await database.customStatement(
      'INSERT OR REPLACE INTO sms_review '
      '(fingerprint,candidate,account_id,to_account_id,category_id,type,ready,cash_currency,search_text) '
      'VALUES (?,?,?,?,?,?,?,?,?)',
      [
        sms.id,
        jsonEncode(sms.data),
        from,
        to,
        category?.id,
        sms.requiresTransfer
            ? 'transfer'
            : sms.credit
            ? 'income'
            : 'expense',
        ready ? 1 : 0,
        sms.isAtmCashMovement ? sms.currency : null,
        [
          sms.title,
          sms.body,
          sms.sender,
          sms.bankName,
          sms.currency,
          account?.name,
          category?.name,
          categories.where((c) => c.id == category?.parentId).firstOrNull?.name,
          if (sms.isAtmCashMovement) cash?.name,
          formatAccountMoney(
            sms.amountMinor,
            currency: sms.currency,
            digits: sms.digits,
          ),
          formatAccountMoney(
            sms.amountMinor,
            currency: sms.currency,
            digits: sms.digits,
          ).replaceAll(',', ''),
          sms.amountMinor / const [1, 10, 100, 1000][sms.digits],
        ].join(' ').toLowerCase(),
      ],
    );
  }

  /// Records a message which the current rule pack no longer considers a
  /// transaction. A sentinel prevents every ordinary refresh from reparsing
  /// it; a deliberate rebuild can still reconsider it after rules change.
  Future<void> putIgnored(PendingSmsImport sms) => database.customStatement(
    'INSERT OR REPLACE INTO sms_review '
    '(fingerprint,candidate,account_id,to_account_id,category_id,type,ready,cash_currency,search_text) '
    "VALUES (?,?,NULL,NULL,NULL,'ignored',0,NULL,'')",
    [sms.id, jsonEncode(sms.data)],
  );

  (String, List<Variable>) _where(SmsReviewFilter filter) {
    final clauses = <String>["i.status='pending'", "r.type!='ignored'"];
    final variables = <Variable>[];
    void add(String clause, Object value) {
      clauses.add(clause);
      variables.add(value is int ? Variable(value) : Variable(value as String));
    }

    if (filter.search.trim().isNotEmpty) {
      add('instr(r.search_text, ?) > 0', filter.search.trim().toLowerCase());
    }
    if (filter.type != null) add('r.type=?', filter.type!);
    if (filter.ready != null) add('r.ready=?', filter.ready! ? 1 : 0);
    if (filter.accountId != null) {
      add('(r.account_id=? OR r.to_account_id=?)', filter.accountId!);
      variables.add(Variable(filter.accountId!));
    }
    if (filter.categoryId != null) {
      add(
        "(r.category_id=? OR r.category_id IN (SELECT id FROM categories WHERE parent_id=?) "
        "OR (r.category_id IN (-1001,-1002) AND EXISTS (SELECT 1 FROM categories "
        "WHERE id=? AND parent_id IS NULL AND type='expense' "
        "AND lower(name) IN ('food','food & beverage'))))",
        filter.categoryId!,
      );
      variables.add(Variable(filter.categoryId!));
      variables.add(Variable(filter.categoryId!));
    }
    if (filter.start != null) {
      add('i.received_at>=?', filter.start!.millisecondsSinceEpoch);
    }
    if (filter.end != null) {
      add('i.received_at<?', filter.end!.millisecondsSinceEpoch);
    }
    return (clauses.join(' AND '), variables);
  }

  static const _join =
      'sms_review r JOIN sms_imports i ON i.fingerprint=r.fingerprint';

  Future<int> count([SmsReviewFilter filter = const SmsReviewFilter()]) async {
    final where = _where(filter);
    final row = await database
        .customSelect(
          'SELECT COUNT(*) AS n FROM $_join WHERE ${where.$1}',
          variables: where.$2,
        )
        .getSingle();
    return row.read<int>('n');
  }

  Future<Set<String>> cashCurrencies() async => {
    for (final row
        in await database
            .customSelect(
              "SELECT DISTINCT cash_currency FROM $_join WHERE i.status='pending' AND cash_currency IS NOT NULL",
            )
            .get())
      row.read<String>('cash_currency'),
  };

  Future<Map<String, int>> cashCurrencyMessageCounts() async => {
    for (final row
        in await database
            .customSelect(
              "SELECT cash_currency,COUNT(*) AS n FROM $_join WHERE i.status='pending' AND cash_currency IS NOT NULL GROUP BY cash_currency",
            )
            .get())
      row.read<String>('cash_currency'): row.read<int>('n'),
  };

  Future<List<SmsReviewRow>> page({
    SmsReviewFilter filter = const SmsReviewFilter(),
    int offset = 0,
    int limit = pageSize,
  }) async {
    final where = _where(filter);
    final rows = await database
        .customSelect(
          'SELECT i.fingerprint,i.sender,i.body,i.received_at,r.*,i.rowid AS preview_id '
          'FROM $_join WHERE ${where.$1} ORDER BY i.received_at DESC,i.fingerprint LIMIT ? OFFSET ?',
          variables: [...where.$2, Variable(limit), Variable(offset)],
        )
        .get();
    return [for (final row in rows) _row(row)];
  }

  SmsReviewRow _row(QueryRow row) {
    final sms = PendingSmsImport(
      id: row.read<String>('fingerprint'),
      sender: row.read<String>('sender'),
      body: row.readNullable<String>('body') ?? '',
      data: Map<String, dynamic>.from(
        jsonDecode(row.read<String>('candidate')) as Map,
      ),
      receivedAt: DateTime.fromMillisecondsSinceEpoch(
        row.read<int>('received_at'),
      ),
    );
    return SmsReviewRow(
      sms,
      MoneyTransaction(
        id: row.read<int>('preview_id'),
        type: TransactionType.values.firstWhere(
          (t) => t.storageValue == row.read<String>('type'),
        ),
        amountMinor: sms.amountMinor,
        accountId: row.readNullable<int>('account_id') ?? 0,
        toAccountId: row.readNullable<int>('to_account_id'),
        categoryId: row.readNullable<int>('category_id'),
        title: sms.title,
        note: sms.originalSmsNote,
        date: sms.receivedAt,
        isCreditCard: sms.creditCard,
      ),
      row.read<int>('ready') == 1,
    );
  }

  Future<SmsReviewRow?> byPreviewId(int id) async {
    final row = await database
        .customSelect(
          'SELECT i.fingerprint,i.sender,i.body,i.received_at,r.*,i.rowid AS preview_id '
          "FROM $_join WHERE i.rowid=? AND i.status='pending'",
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    return row == null ? null : _row(row);
  }

  /// Counts and totals stay in SQLite; the browser receives only each group's
  /// ten visible rows. Expanding a category explicitly requests that group.
  Future<TransactionPreviewData> browse(
    TransactionPreviewQuery query, {
    PendingSmsImport? accountGroup,
  }) => database.transaction(() async {
    final period = SmsReviewFilter(
      start: query.start,
      end: query.end,
      accountId: query.accountId,
    );
    final filtered = SmsReviewFilter(
      start: query.start,
      end: query.end,
      accountId: query.accountId,
      categoryId: query.categoryId,
      search: query.search,
      type: query.type,
      ready: query.ready,
    );
    var periodWhere = _where(period);
    var visibleWhere = _where(filtered);
    if (accountGroup != null) {
      final condition =
          " AND json_extract(r.candidate,'\$.bankName')=? AND json_extract(r.candidate,'\$.accountLast4')=? AND coalesce(json_extract(r.candidate,'\$.isCreditCard'),0)=?";
      // Apply the same identity to both totals and visible rows.
      final values = <Variable>[
        Variable(accountGroup.bankName),
        Variable(accountGroup.accountLast4!),
        Variable(accountGroup.creditCard ? 1 : 0),
      ];
      periodWhere = (
        periodWhere.$1 + condition,
        [...periodWhere.$2, ...values],
      );
      visibleWhere = (
        visibleWhere.$1 + condition,
        [...visibleWhere.$2, ...values],
      );
    }
    final draftCategories = (await CategoryRepository(
      database,
    ).load(includeDrafts: true)).where((c) => c.id < 0);
    final draftUnion = draftCategories
        .map((c) => " UNION ALL SELECT ${c.id},${c.parentId},'expense'")
        .join();
    final categoryTable = 'SELECT id,parent_id,type FROM categories$draftUnion';
    final joins =
        ' LEFT JOIN accounts a ON a.id=r.account_id '
        'LEFT JOIN accounts b ON b.id=r.to_account_id '
        'LEFT JOIN ($categoryTable) c ON c.id=r.category_id ';
    const amount =
        "CAST(json_extract(r.candidate,'\$.amountMinor') AS INTEGER)";
    final accountScope = query.accountId == null
        ? ''
        : ' AND r.account_id=${query.accountId}';
    String sum(String type, {bool debts = true}) =>
        "COALESCE(SUM(CASE WHEN r.type='$type'$accountScope"
        "${debts ? '' : " AND COALESCE(c.type,'')!='debt_loan'"} THEN $amount ELSE 0 END),0)";

    Future<Map<(String, int), (int, int)>> totals(
      (String, List<Variable>) where, {
      bool debts = false,
    }) async => {
      for (final row
          in await database
              .customSelect(
                'SELECT a.currency,a.digits,${sum('income', debts: debts)} AS income,${sum('expense', debts: debts)} AS expenses '
                'FROM $_join $joins WHERE ${where.$1} AND a.currency IS NOT NULL GROUP BY a.currency,a.digits',
                variables: where.$2,
              )
              .get())
        (row.read<String>('currency'), row.read<int>('digits')): (
          row.read<int>('income'),
          row.read<int>('expenses'),
        ),
    };

    Future<(Map<(String, int), (int, int)>, Map<(String, int), (int, int)>)>
    filteredTotals((String, List<Variable>) where) async {
      final regular = <(String, int), (int, int)>{};
      final includingDebts = <(String, int), (int, int)>{};
      final rows = await database
          .customSelect(
            'SELECT a.currency,a.digits,'
            "${sum('income', debts: false)} AS income,"
            "${sum('expense', debts: false)} AS expenses,"
            "${sum('income')} AS all_income,"
            "${sum('expense')} AS all_expenses "
            'FROM $_join $joins WHERE ${where.$1} AND a.currency IS NOT NULL '
            'GROUP BY a.currency,a.digits',
            variables: where.$2,
          )
          .get();
      for (final row in rows) {
        final key = (row.read<String>('currency'), row.read<int>('digits'));
        regular[key] = (row.read<int>('income'), row.read<int>('expenses'));
        includingDebts[key] = (
          row.read<int>('all_income'),
          row.read<int>('all_expenses'),
        );
      }
      return (regular, includingDebts);
    }

    final currencyRows = await database
        .customSelect(
          'SELECT currency,digits,COUNT(*) AS n FROM ('
          'SELECT DISTINCT i.fingerprint,a.currency,a.digits FROM $_join $joins WHERE ${periodWhere.$1} AND a.currency IS NOT NULL '
          'UNION SELECT DISTINCT i.fingerprint,b.currency,b.digits FROM $_join $joins WHERE ${periodWhere.$1} AND b.currency IS NOT NULL'
          ') GROUP BY currency,digits ORDER BY currency,digits',
          variables: [...periodWhere.$2, ...periodWhere.$2],
        )
        .get();
    final groupKey = query.byCategory
        ? query.categoryId == null
              ? 'COALESCE(c.parent_id,c.id,-1)'
              : 'COALESCE(c.id,-1)'
        : "date(i.received_at / 1000,'unixepoch','localtime')";
    final aggregates = await database
        .customSelect(
          'SELECT $groupKey AS group_key,a.currency,a.digits,COUNT(*) AS n,'
          "${sum('income', debts: query.byCategory)} AS income,${sum('expense', debts: query.byCategory)} AS expenses "
          'FROM $_join $joins WHERE ${visibleWhere.$1} GROUP BY group_key,a.currency,a.digits',
          variables: visibleWhere.$2,
        )
        .get();
    final counts = <Object, int>{};
    final groupTotals = <Object, Map<(String, int), (int, int)>>{};
    for (final row in aggregates) {
      final Object key = query.byCategory
          ? row.read<int>('group_key')
          : row.read<String>('group_key');
      counts.update(
        key,
        (n) => n + row.read<int>('n'),
        ifAbsent: () => row.read<int>('n'),
      );
      final currency = row.readNullable<String>('currency');
      if (currency != null) {
        groupTotals.putIfAbsent(key, () => {})[(
          currency,
          row.read<int>('digits'),
        )] = (
          row.read<int>('income'),
          row.read<int>('expenses'),
        );
      }
    }
    final expanded = query.expandedGroups;
    final expansion = expanded.isEmpty
        ? ''
        : ' OR group_key IN (${List.filled(expanded.length, '?').join(',')})';
    final rowSql =
        'SELECT i.fingerprint,i.sender,i.body,i.received_at,r.*,i.rowid AS preview_id,$groupKey AS group_key '
        'FROM $_join $joins WHERE ${visibleWhere.$1}';
    // Rank only keys and timestamps. Carrying SMS bodies/candidate JSON
    // through the window function materializes the entire filtered inbox.
    final rankedKeys =
        'SELECT i.rowid AS preview_id,i.fingerprint,i.received_at,$groupKey AS group_key '
        'FROM $_join $joins WHERE ${visibleWhere.$1}';
    final rows = await database
        .customSelect(
          query.byCategory
              ? 'WITH candidates AS ($rankedKeys),ranked AS (SELECT *,ROW_NUMBER() OVER (PARTITION BY group_key ORDER BY received_at DESC,fingerprint) AS position FROM candidates),'
                    'visible AS (SELECT preview_id,group_key FROM ranked WHERE position<=10$expansion) '
                    'SELECT i.fingerprint,i.sender,i.body,i.received_at,r.*,i.rowid AS preview_id,v.group_key '
                    'FROM visible v JOIN sms_imports i ON i.rowid=v.preview_id '
                    'JOIN sms_review r ON r.fingerprint=i.fingerprint '
                    'ORDER BY i.received_at DESC,i.fingerprint'
              : '$rowSql ORDER BY i.received_at DESC,i.fingerprint LIMIT ?',
          variables: [
            ...visibleWhere.$2,
            if (query.byCategory)
              ...expanded.map(Variable.new)
            else
              Variable(query.limit),
          ],
        )
        .get();
    final groupedRows = <Object, List<MoneyTransaction>>{};
    for (final row in rows) {
      final Object key = query.byCategory
          ? row.read<int>('group_key')
          : row.read<String>('group_key');
      groupedRows.putIfAbsent(key, () => []).add(_row(row).transaction);
    }
    final visibleTotals = await filteredTotals(visibleWhere);
    final periodTotals = await totals(periodWhere);
    return TransactionPreviewData(
      count: counts.values.fold(0, (a, b) => a + b),
      currencies: {
        for (final row in currencyRows)
          (row.read<String>('currency'), row.read<int>('digits')): row
              .read<int>('n'),
      },
      summary: periodTotals,
      filteredSummary: visibleTotals.$1,
      categoryTotals: visibleTotals.$2,
      groups: [
        for (final key in counts.keys)
          if (query.byCategory || groupedRows.containsKey(key))
            TransactionPreviewGroup(
              categoryId: query.byCategory && key != -1 ? key as int : null,
              date: query.byCategory ? null : DateTime.parse(key as String),
              count: counts[key]!,
              transactions: groupedRows[key] ?? const [],
              totals: groupTotals[key] ?? const {},
            ),
      ],
    );
  });

  Future<int> cleanReviewed({bool compact = true}) async {
    await database.customStatement(
      "DELETE FROM sms_review WHERE NOT EXISTS (SELECT 1 FROM sms_imports i WHERE i.fingerprint=sms_review.fingerprint AND i.status='pending')",
    );
    final removed =
        (await database.customSelect('SELECT changes() AS n').getSingle())
            .read<int>('n');
    // Keep only deduplication metadata after consuming temporary scanned data.
    if (compact || removed > 0) {
      await database.customStatement(
        "UPDATE sms_imports SET candidate=json_object('notificationKey',json_extract(candidate,'\$.notificationKey'),'isCreditCard',json_extract(candidate,'\$.isCreditCard')),body=NULL WHERE status!='pending' AND json_extract(candidate,'\$.amountMinor') IS NOT NULL",
      );
    }
    return removed;
  }

  /// One atomic save, performed in the database worker. The UI holds no batch.
  Future<int> saveReady() => database.transaction(() async {
    var saved = 0;
    final imports = SmsImportRepository(database);
    // Loan payments a loan refused: left for review, not tried again.
    final refused = <String>{};
    while (true) {
      final rows = [
        for (final row in await page(
          filter: const SmsReviewFilter(ready: true),
        ))
          if (!refused.contains(row.sms.id)) row,
      ];
      if (rows.isEmpty) break;
      for (final row in rows) {
        // A repeated notification may have been consumed by an earlier row.
        final pending = await database
            .customSelect(
              "SELECT 1 FROM sms_imports WHERE fingerprint=? AND status='pending'",
              variables: [Variable(row.sms.id)],
            )
            .getSingleOrNull();
        if (pending == null) continue;
        final t = row.transaction;
        Future<void> save() => imports.save(
          row.sms,
          type: t.type,
          amountMinor: t.amountMinor,
          accountId: t.accountId,
          toAccountId: t.toAccountId,
          categoryId: t.categoryId,
          title: t.title,
          note: t.note,
          date: t.date,
        );
        if (row.sms.assignedLoanId case final loanId?) {
          // Together: a payment the loan refuses leaves the message to review.
          try {
            await database.transaction(() async {
              await save();
              await LoanRepository(database)
                  .payWith(loanId, (await imports.transactionOf(row.sms.id))!);
            });
          } catch (_) {
            refused.add(row.sms.id);
            continue;
          }
        } else {
          await save();
        }
        saved++;
      }
    }
    await cleanReviewed();
    return saved;
  });
}
