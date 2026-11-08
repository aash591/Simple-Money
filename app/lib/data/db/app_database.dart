import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show kProfileMode;

import 'default_categories.dart';
import '../../domain/debt.dart';
import '../../domain/loan.dart';
import '../../domain/subscription.dart';
import '../backup/sync_schema.dart';

/// Initial account schema. Balances use integer minor units, never REAL.
/// QueryExecutor injection lets repository tests use a real in-memory SQLite DB.
class AppDatabase extends GeneratedDatabase {
  AppDatabase([QueryExecutor? executor, bool? seedProfileData])
    : _seedProfileData = seedProfileData ?? kProfileMode,
      super(
        executor ??
            driftDatabase(
              name: 'simple_money',
              native: const DriftNativeOptions(shareAcrossIsolates: true),
            ),
      );

  /// Profile APKs get a realistic, disposable Indian ledger for UI testing.
  /// This is false in debug and release builds; the optional override exists
  /// solely so the profile-seed behavior can be verified in tests.
  final bool _seedProfileData;
  @override
  int get schemaVersion => 40;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) async {
      await customStatement('''
      CREATE TABLE accounts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 40),
        currency TEXT NOT NULL CHECK(length(currency) = 3),
        territory TEXT,
        icon TEXT,
        digits INTEGER NOT NULL CHECK(digits BETWEEN 0 AND 4),
        balance_minor INTEGER NOT NULL,
        transaction_count INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL,
        archived_at INTEGER,
        type TEXT NOT NULL DEFAULT 'bank' CHECK(type IN ('bank','creditCard','cash')),
        last_digits TEXT,
        institution TEXT,
        credit_limit_minor INTEGER,
        available_limit_minor INTEGER,
        balance_reported_at INTEGER,
        credit_limit_reported_at INTEGER,
        available_limit_reported_at INTEGER
      )
    ''');
      await customStatement(_createCategoriesTable);
      await customStatement(_createTransactionsTable);
      await _createTransactionDateIndex();
      await customStatement(_createPendingUpiTable);
      await createSmsImportSchema();
      await _createBudgets();
      await _createDebts();
      await _createLoans();
      await customStatement(_createSubscriptionsTable);
      await customStatement(_createSubscriptionPaymentsTable);
      await customStatement(_createExchangeRatesTable);
      await customStatement(_createAgentSuggestionsTable);
      await customStatement(_createUserSmsRulesTable);
      await customStatement(_createCommunityFixesTable);
      await seedDefaultCategories();
      if (_seedProfileData) await _seedProfileSampleData();
      await createSyncSchema(this);
    },
    onUpgrade: (_, from, to) async {
      if (from < 25) await createSmsImportSchema();
      if (from < 25) {
        final columns = (await customSelect(
          'PRAGMA table_info(accounts)',
        ).get()).map((r) => r.read<String>('name')).toSet();
        for (final entry in {
          'type': "TEXT NOT NULL DEFAULT 'bank' CHECK(type IN ('bank','creditCard','cash'))",
          'last_digits': 'TEXT',
          'institution': 'TEXT',
          'credit_limit_minor': 'INTEGER',
          'available_limit_minor': 'INTEGER',
          'balance_reported_at': 'INTEGER',
          'credit_limit_reported_at': 'INTEGER',
          'available_limit_reported_at': 'INTEGER',
        }.entries) {
          if (!columns.contains(entry.key)) {
            await customStatement(
              'ALTER TABLE accounts ADD COLUMN ${entry.key} ${entry.value}',
            );
          }
        }
        await customStatement(
          "UPDATE accounts SET type='cash' WHERE lower(trim(name))='cash' AND last_digits IS NULL",
        );
      }
      if (from < 17) await customStatement(_createExchangeRatesTable);
      if (from < 11) await customStatement(_createPendingUpiTable);
      // v11 -> v12: debts (see domain/debt.dart). Created before the sync
      // schema below, which gives every synced table its triggers.
      if (from < 12) await _createDebts();
      if (from < 13) await _createLoans();
      if (from < 15) await customStatement(_createSubscriptionsTable);
      if (from < 16) {
        await customStatement(_createSubscriptionPaymentsTable);
      }
      // v13 -> v14: the transaction that paid a loan's opening charges, when
      // they were paid separately rather than netted off the disbursal.
      if (from >= 13 && from < 14) {
        await customStatement(
          'ALTER TABLE loans ADD COLUMN charges_id INTEGER',
        );
      }
      // v18 -> v19: index the columns that tie a transaction to its loan.
      // After the column above, which one of them covers.
      if (from >= 13 && from < 19) await _createLoanTransactionIndexes();
      // v1 -> v2: track which country a currency was picked for (e.g. 'IN'
      // for INR via India rather than Bhutan), so the currency picker can
      // highlight the exact account's country instead of every country that
      // happens to share its currency code. Existing accounts get NULL,
      // which the UI treats as "unknown" and falls back to matching by
      // currency code alone, same as before this column existed.
      if (from < 2) {
        await customStatement('ALTER TABLE accounts ADD COLUMN territory TEXT');
      }
      // v2 -> v3: a picked icon key (see domain/app_icons.dart). NULL for
      // existing accounts, which the UI resolves to the default wallet icon.
      if (from < 3) {
        await customStatement('ALTER TABLE accounts ADD COLUMN icon TEXT');
      }
      // v3 -> v4: categories (see domain/category.dart), never tied to an
      // account. `parent_id` names another row in this same table, letting a
      // category nest one level under a top-level category.
      if (from < 4) {
        await customStatement(_createCategoriesTable);
      }
      // v4 -> v5: transactions (see domain/transaction.dart). A transfer
      // reuses this same table (type = 'transfer', `to_account_id` set,
      // `category_id` null) rather than a separate one, since it's still
      // one entry moving money, just between two accounts instead of a
      // category and an account. Adjusting an account's balance directly
      // is not logged here — see TransactionRepository.adjustBalance.
      if (from < 5) {
        await customStatement(_createTransactionsTable);
      }
      // v17 -> v18: a transfer between accounts in different currencies
      // credits the destination its own figure, which is not the source's.
      // Null means "the same as amount_minor" — every row before this, and
      // every transfer whose two accounts agree. Asked for rather than
      // assumed: a database can sit at an older user_version while already
      // carrying the current table shape, and SQLite has no
      // "ADD COLUMN IF NOT EXISTS".
      if (from < 18 && !await _hasColumn('transactions', 'to_amount_minor')) {
        await customStatement(
          'ALTER TABLE transactions ADD COLUMN to_amount_minor INTEGER',
        );
      }
      // v19 -> v20: an account can be archived instead of deleted. Archiving
      // hides it from every picker and from the balance totals but keeps the
      // row, because a transaction stores no currency of its own — it reads
      // the currency and precision off the account that owns it, so orphaning
      // its history would leave those amounts with no way to be read. Null
      // means active; a timestamp is when it was archived. Asked for like the
      // column above, and for the same reason.
      if (from < 20 && !await _hasColumn('accounts', 'archived_at')) {
        await customStatement(
          'ALTER TABLE accounts ADD COLUMN archived_at INTEGER',
        );
      }
      // v5 -> v6: monthly budgets (see data/repositories/budget_repository
      // .dart), created straight in the v7 shape below.
      // v6 -> v7: a budget covers a set of categories rather than one, so
      // several can be combined into a custom budget. Each v6 scope — a
      // category, or all spending — becomes one budget keeping its history.
      if (from < 6) {
        await _createBudgets();
      } else if (from < 7) {
        await _upgradeBudgetsToSets();
      }
      // v9 -> v10: a budget's picked icon key; NULL shows its categories'.
      // Budgets created above already have it.
      if (from >= 7 && from < 10) {
        await customStatement('ALTER TABLE budgets ADD COLUMN icon TEXT');
      }
      if (from < 8) {
        await createSyncSchema(this);
      } else {
        if (from < 9) {
          await customStatement(
            'ALTER TABLE sync_state ADD COLUMN display_name TEXT',
          );
          await customStatement(
            'ALTER TABLE sync_state ADD COLUMN picture_url TEXT',
          );
        }
        if (from < 10) await createSyncTriggers(this, 'budgets');
        // A trigger copies the columns the table had when it was made, so
        // v14's new column means rebuilding them.
        if (from < 14) {
          await createSyncTriggers(this, 'loans');
          if (from < 13) await createSyncTriggers(this, 'loan_events');
        }
        if (from < 12) {
          await createSyncTriggers(this, 'debt_people');
          await createSyncTriggers(this, 'debt_entries');
        }
        if (from < 15) await createSyncTriggers(this, 'subscriptions');
        if (from < 16) {
          await createSyncTriggers(this, 'subscription_payments');
        }
        // A trigger copies the columns the table had when it was made, so
        // v18's to_amount_minor means rebuilding the transactions triggers.
        if (from < 18) await createSyncTriggers(this, 'transactions');
        // Likewise for v20's archived_at, so archiving reaches other devices
        // as the ordinary column change it is.
        if (from < 20) await createSyncTriggers(this, 'accounts');
        if (from >= 20 && from < 25) await createSyncTriggers(this, 'accounts');
      }
      // v15 -> v16: payments marked paid before they were linked. Run after
      // the triggers so the links sync like any other change.
      if (from == 15) await _linkEarlierSubscriptionPayments();
      if (from >= 4 && from < 27) await seedSmsPurposeCategories();
      if (from >= 4 && from < 28) await seedPublicTransportCategories();
      if (from >= 4 && from < 29) await seedLifestyleCategories();
      if (from < 30) await customStatement(_createSmsScanQueue);
      if (from < 31) await createSmsReviewSchema();
      if (from < 32) await createSmsReviewIndexes();
      if (from >= 4 && from < 33) await seedNewIconCategories();
      if (from < 34) {
        await customStatement(_createAgentSuggestionsTable);
        await customStatement(_createUserSmsRulesTable);
      }
      if (from >= 34 && from < 40) {
        // New suggestion kinds: SQLite can't change a CHECK, so the table
        // is rebuilt with its rows.
        await customStatement(
          'ALTER TABLE agent_suggestions RENAME TO agent_suggestions_old',
        );
        await customStatement(_createAgentSuggestionsTable);
        await customStatement(
          'INSERT INTO agent_suggestions SELECT * FROM agent_suggestions_old',
        );
        await customStatement('DROP TABLE agent_suggestions_old');
      }
      if (from < 36) await _createTransactionDateIndex();
      if (from < 37) await customStatement(_createCommunityFixesTable);
      if (from < 38) {
        await _createSmsHistory();
        await createSyncTriggers(this, 'sms_history');
        await createSyncTriggers(this, 'sms_account_links');
        // Through the triggers above, so the next upload carries them.
        await customStatement(
          '''INSERT OR IGNORE INTO sms_history SELECT fingerprint, sender,
            received_at, rule_id, pack_version, status, transaction_id,
            json_extract(candidate, '\$.notificationKey'),
            json_extract(candidate, '\$.isCreditCard')
          FROM sms_imports WHERE status != 'pending' ''',
        );
        await seedSyncOutbox(this, tables: ['sms_account_links']);
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA busy_timeout = 5000');
    },
  );

  // Home reads bounded month ranges and the five most recent transactions.
  // Without this index every card query scans the entire imported ledger.
  Future<void> _createTransactionDateIndex() => customStatement(
    'CREATE INDEX IF NOT EXISTS transactions_date '
    'ON transactions(date DESC, id DESC)',
  );

  Future<void> createSmsImportSchema() async {
    await customStatement(_createSmsScanQueue);
    await createSmsReviewSchema();
    await customStatement('''CREATE TABLE IF NOT EXISTS sms_detected_accounts (
      bank_key TEXT PRIMARY KEY, data TEXT NOT NULL, received_at INTEGER NOT NULL
    )''');
    await customStatement(
      '''CREATE TABLE IF NOT EXISTS sms_total_credit_limits (
      bank_key TEXT PRIMARY KEY, credit_limit_minor INTEGER NOT NULL, received_at INTEGER NOT NULL
    )''',
    );
    await customStatement('''CREATE TABLE IF NOT EXISTS sms_credit_limits (
      bank_key TEXT PRIMARY KEY,
      available_limit_minor INTEGER NOT NULL,
      received_at INTEGER NOT NULL
    )''');
    await customStatement('''CREATE TABLE IF NOT EXISTS sms_balances (
      bank_key TEXT PRIMARY KEY,
      balance_minor INTEGER NOT NULL,
      received_at INTEGER NOT NULL
    )''');
    await customStatement(
      'CREATE TABLE IF NOT EXISTS sms_account_links (bank_key TEXT PRIMARY KEY, account_id INTEGER NOT NULL)',
    );
    await customStatement('''CREATE TABLE IF NOT EXISTS sms_imports (
      fingerprint TEXT PRIMARY KEY,
      sender TEXT NOT NULL,
      body TEXT,
      received_at INTEGER NOT NULL,
      candidate TEXT NOT NULL,
      rule_id TEXT NOT NULL,
      pack_version INTEGER NOT NULL,
      status TEXT NOT NULL DEFAULT 'pending' CHECK(status IN ('pending','imported','dismissed')),
      transaction_id INTEGER
    )''');
    await customStatement(
      "CREATE INDEX IF NOT EXISTS sms_imports_pending ON sms_imports(status, received_at)",
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS sms_imports_transaction ON sms_imports(transaction_id)',
    );
    await customStatement('''CREATE TABLE IF NOT EXISTS sms_import_state (
      id INTEGER PRIMARY KEY CHECK(id = 1),
      enabled INTEGER NOT NULL DEFAULT 0,
      scanned_at INTEGER NOT NULL DEFAULT 0
    )''');
    await customStatement(
      'INSERT OR IGNORE INTO sms_import_state(id) VALUES (1)',
    );
    await createSmsReviewIndexes();
    await _createSmsHistory();
  }

  // The synced part of sms_imports: settled messages only, never their text.
  // A restore rebuilds sms_imports from it, so the inbox isn't saved twice.
  Future<void> _createSmsHistory() async {
    await customStatement('''CREATE TABLE IF NOT EXISTS sms_history (
      fingerprint TEXT PRIMARY KEY,
      sender TEXT NOT NULL,
      received_at INTEGER NOT NULL,
      rule_id TEXT NOT NULL,
      pack_version INTEGER NOT NULL,
      status TEXT NOT NULL CHECK(status IN ('imported','dismissed')),
      transaction_id INTEGER,
      notification_key TEXT,
      credit_card INTEGER
    )''');
    const key = r"json_extract(NEW.candidate, '$.notificationKey')";
    const card = r"json_extract(NEW.candidate, '$.isCreditCard')";
    // Only real changes, so rewriting candidates on cleanup uploads nothing.
    const write =
        '''
      UPDATE sms_history SET status = NEW.status,
          transaction_id = NEW.transaction_id,
          notification_key = $key, credit_card = $card
        WHERE fingerprint = NEW.fingerprint AND NEW.status != 'pending' AND (
          status IS NOT NEW.status OR transaction_id IS NOT NEW.transaction_id
          OR notification_key IS NOT $key OR credit_card IS NOT $card);
      INSERT OR IGNORE INTO sms_history SELECT NEW.fingerprint, NEW.sender,
          NEW.received_at, NEW.rule_id, NEW.pack_version, NEW.status,
          NEW.transaction_id, $key, $card
        WHERE NEW.status != 'pending';''';
    await customStatement('''CREATE TRIGGER IF NOT EXISTS sms_history_insert
      AFTER INSERT ON sms_imports BEGIN $write END''');
    await customStatement('''CREATE TRIGGER IF NOT EXISTS sms_history_update
      AFTER UPDATE OF status, transaction_id, candidate ON sms_imports BEGIN
        DELETE FROM sms_history
          WHERE fingerprint = NEW.fingerprint AND NEW.status = 'pending';
        $write
      END''');
    await customStatement('''CREATE TRIGGER IF NOT EXISTS sms_history_delete
      AFTER DELETE ON sms_imports BEGIN
        DELETE FROM sms_history WHERE fingerprint = OLD.fingerprint;
      END''');
  }

  // Device-local wizard data, never synced or inserted into the ledger.
  Future<void> createSmsReviewSchema() async {
    await customStatement('''
      CREATE TABLE IF NOT EXISTS sms_review (
        fingerprint TEXT PRIMARY KEY,
        candidate TEXT NOT NULL,
        account_id INTEGER,
        to_account_id INTEGER,
        category_id INTEGER,
        type TEXT NOT NULL,
        ready INTEGER NOT NULL,
        cash_currency TEXT,
        search_text TEXT NOT NULL
      )
    ''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS sms_review_ready ON sms_review(ready, fingerprint)',
    );
  }

  Future<void> createSmsReviewIndexes() async {
    await customStatement('''CREATE TABLE IF NOT EXISTS sms_review_context (
      id INTEGER PRIMARY KEY CHECK(id=1), signature TEXT NOT NULL
    )''');
    await customStatement(
      'CREATE INDEX IF NOT EXISTS sms_review_type ON sms_review(type, fingerprint)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS sms_review_account ON sms_review(account_id, fingerprint)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS sms_review_to_account ON sms_review(to_account_id, fingerprint)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS sms_review_category ON sms_review(category_id, fingerprint)',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS sms_imports_pending_date ON sms_imports(status, received_at DESC, fingerprint)',
    );
  }

  // Local, bounded scratch space; deliberately excluded from ledger sync.
  static const _createSmsScanQueue = '''
    CREATE TABLE IF NOT EXISTS sms_scan_queue (
      id INTEGER PRIMARY KEY,
      sender TEXT NOT NULL,
      body TEXT NOT NULL,
      received_at INTEGER NOT NULL
    )
  ''';

  Future<void> seedLifestyleCategories() async {
    await customStatement(
      "UPDATE categories SET icon='fuel' WHERE lower(trim(name))='fuel' AND type='expense' AND icon='car_battery'",
    );
    for (final category in lifestyleCategories) {
      int? parentId;
      if (category.parent != null) {
        final parents = await customSelect(
          "SELECT id FROM categories WHERE lower(trim(name))=lower(?) AND type='expense' AND parent_id IS NULL ORDER BY id LIMIT 1",
          variables: [Variable(category.parent!)],
        ).get();
        parentId = parents.isEmpty
            ? await customInsert(
                "INSERT INTO categories(name,type,icon,parent_id,sort_order) SELECT ?,'expense',?,NULL,COALESCE(MAX(sort_order),-1)+1 FROM categories",
                variables: [
                  Variable(category.parent!),
                  Variable(category.parentIcon),
                ],
              )
            : parents.first.read<int>('id');
      }
      await customStatement(
        '''INSERT INTO categories(name,type,icon,parent_id,sort_order)
        SELECT ?,'expense',?,?,(SELECT COALESCE(MAX(sort_order),-1)+1 FROM categories)
        WHERE NOT EXISTS(SELECT 1 FROM categories WHERE lower(trim(name))=lower(?) AND type='expense')''',
        [category.name, category.icon, parentId, category.name],
      );
    }
  }

  /// Promote the existing transport category without changing its ID or history.
  Future<void> seedPublicTransportCategories() async {
    final rows = await customSelect(
      "SELECT id FROM categories WHERE lower(trim(name))='public transport' AND type='expense' ORDER BY parent_id IS NOT NULL,id LIMIT 1",
    ).get();
    final int parentId;
    if (rows.isEmpty) {
      parentId = await customInsert(
        "INSERT INTO categories(name,type,icon,parent_id,sort_order) SELECT 'Public Transport','expense','bus_two',NULL,COALESCE(MAX(sort_order),-1)+1 FROM categories",
      );
    } else {
      parentId = rows.first.read<int>('id');
      await customStatement('UPDATE categories SET parent_id=NULL WHERE id=?', [
        parentId,
      ]);
    }
    for (final child in publicTransportSubcategories) {
      await customStatement(
        '''INSERT INTO categories(name,type,icon,parent_id,sort_order)
        SELECT ?,'expense',?,?,(SELECT COALESCE(MAX(sort_order),-1)+1 FROM categories)
        WHERE NOT EXISTS(SELECT 1 FROM categories WHERE lower(trim(name))=lower(?) AND type='expense' AND parent_id=?)''',
        [child.name, child.icon, parentId, child.name, parentId],
      );
    }
  }

  /// Add the new suggestions once, preserving matching user categories.
  Future<void> seedSmsPurposeCategories() async {
    for (final category in smsPurposeCategories) {
      await customStatement(
        '''INSERT INTO categories(name,type,icon,parent_id,sort_order)
        SELECT ?,?,?,NULL,(SELECT COALESCE(MAX(sort_order),-1)+1 FROM categories)
        WHERE NOT EXISTS(SELECT 1 FROM categories WHERE lower(trim(name))=lower(?) AND type=?)''',
        [
          category.name,
          category.type,
          category.icon,
          category.name,
          category.type,
        ],
      );
    }
  }

  /// Add categories introduced with the expanded illustrated icon pack while
  /// preserving any icon the user has already customized.
  Future<void> seedNewIconCategories() async {
    await customStatement(
      "UPDATE categories SET icon='person' WHERE lower(trim(name))='personal' AND icon='wallet_one'",
    );
    await customStatement(
      "UPDATE categories SET icon='salary' WHERE lower(trim(name))='salary' AND type='income' AND icon='income_one'",
    );

    final foodRows = await customSelect(
      "SELECT id FROM categories WHERE lower(trim(name))='food & beverage' AND type='expense' AND parent_id IS NULL ORDER BY id LIMIT 1",
    ).get();
    final foodId = foodRows.isEmpty ? null : foodRows.first.read<int>('id');
    await customStatement(
      '''INSERT INTO categories(name,type,icon,parent_id,sort_order)
      SELECT 'Fruits','expense','fruits',?,(SELECT COALESCE(MAX(sort_order),-1)+1 FROM categories)
      WHERE NOT EXISTS(SELECT 1 FROM categories WHERE lower(trim(name))='fruits' AND type='expense')''',
      [foodId],
    );
    await customStatement(
      '''INSERT INTO categories(name,type,icon,parent_id,sort_order)
      SELECT 'Charity','expense','charity',NULL,(SELECT COALESCE(MAX(sort_order),-1)+1 FROM categories)
      WHERE NOT EXISTS(SELECT 1 FROM categories WHERE lower(trim(name))='charity' AND type='expense')''',
    );
  }

  /// `next_due` is a local date (YYYY-MM-DD); `day` is the day of the month
  /// it renews on, which `next_due` can fall short of in a shorter month.
  static const _createSubscriptionsTable =
      '''CREATE TABLE IF NOT EXISTS subscriptions (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 40),
    icon TEXT,
    amount_minor INTEGER NOT NULL CHECK(amount_minor > 0),
    currency TEXT NOT NULL CHECK(length(currency) = 3),
    digits INTEGER NOT NULL CHECK(digits BETWEEN 0 AND 4),
    cycle TEXT NOT NULL CHECK(cycle IN ('weekly', 'monthly', 'quarterly', 'yearly')),
    next_due TEXT NOT NULL,
    day INTEGER NOT NULL CHECK(day BETWEEN 1 AND 31),
    account_id INTEGER,
    category_id INTEGER,
    remind INTEGER NOT NULL DEFAULT 1,
    paused INTEGER NOT NULL DEFAULT 0
  )''';

  /// The expense each "Mark paid" logged, so the transaction can wear its
  /// subscription's artwork.
  static const _createSubscriptionPaymentsTable =
      '''CREATE TABLE IF NOT EXISTS subscription_payments (
    transaction_id INTEGER PRIMARY KEY NOT NULL,
    subscription_id INTEGER NOT NULL
  )''';

  /// Before v16 a payment was only recognisable by what it copied from its
  /// subscription: an expense with its name, amount and account.
  Future<void> _linkEarlierSubscriptionPayments() => customStatement('''INSERT OR IGNORE INTO subscription_payments (transaction_id, subscription_id)
    SELECT t.id, s.id FROM transactions t JOIN subscriptions s
      ON t.type = 'expense' AND t.title = s.name
     AND t.amount_minor = s.amount_minor AND t.account_id = s.account_id''');

  static const _createPendingUpiTable =
      '''CREATE TABLE IF NOT EXISTS pending_upi_payments (
    id TEXT PRIMARY KEY NOT NULL,
    payload TEXT NOT NULL
  )''';

  /// `budgets` holds what a budget is — the total, or one over the
  /// categories in `budget_categories` — and `budget_amounts` what it was
  /// set to from each month on. One total per currency.
  Future<void> _createBudgets() async {
    await customStatement(_createBudgetsTable);
    await customStatement(_createBudgetsTotalIndex);
    await customStatement(_createBudgetCategoriesTable);
    await customStatement(_createBudgetAmountsTable);
  }

  /// Immutable opening terms and append-only repayment/term-change events.
  /// JSON payloads are versioned with the database and included in backups.
  Future<void> _createLoans() async {
    await customStatement('''CREATE TABLE IF NOT EXISTS loans (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      payload TEXT NOT NULL CHECK(json_valid(payload)),
      account_id INTEGER, disbursal_id INTEGER, charges_id INTEGER
    )''');
    await customStatement('''CREATE TABLE IF NOT EXISTS loan_events (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      loan_id INTEGER NOT NULL,
      kind TEXT NOT NULL CHECK(kind IN ('emi', 'partPayment', 'rateChange', 'closure')),
      installment INTEGER,
      payload TEXT NOT NULL CHECK(json_valid(payload)),
      account_id INTEGER, transaction_id INTEGER
    )''');
    await customStatement(
      "CREATE UNIQUE INDEX IF NOT EXISTS loan_installment ON loan_events(loan_id, installment) WHERE kind = 'emi'",
    );
    await _createLoanTransactionIndexes();
  }

  /// Loading the ledger asks, per transaction, which loan it belongs to.
  /// Partial so they cover only the few rows that actually link one.
  Future<void> _createLoanTransactionIndexes() async {
    await customStatement(
      'CREATE INDEX IF NOT EXISTS loan_disbursal ON loans(disbursal_id) '
      'WHERE disbursal_id IS NOT NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS loan_charges ON loans(charges_id) '
      'WHERE charges_id IS NOT NULL',
    );
    await customStatement(
      'CREATE INDEX IF NOT EXISTS loan_event_transaction '
      'ON loan_events(transaction_id) WHERE transaction_id IS NOT NULL',
    );
  }

  /// Whether [table] already has [column]. A migration that adds a column can
  /// meet a database that was created with it rather than upgraded into it,
  /// and SQLite has no conditional ADD COLUMN.
  Future<bool> _hasColumn(String table, String column) async =>
      (await customSelect(
        'PRAGMA table_info($table)',
      ).get()).any((row) => row.read<String>('name') == column);

  Future<void> _createDebts() async {
    await customStatement(_createDebtPeopleTable);
    await customStatement(_createDebtEntriesTable);
  }

  Future<void> _upgradeBudgetsToSets() => transaction(() async {
    await customStatement('DROP INDEX budgets_scope');
    await customStatement('ALTER TABLE budgets RENAME TO budgets_v6');
    await _createBudgets();
    final scopes = await customSelect(
      'SELECT DISTINCT category_id, currency, digits FROM budgets_v6',
    ).get();
    for (final scope in scopes) {
      final categoryId = scope.readNullable<int>('category_id');
      final currency = scope.read<String>('currency');
      final digits = scope.read<int>('digits');
      final id = await customInsert(
        'INSERT INTO budgets (kind, currency, digits) VALUES (?, ?, ?)',
        variables: [
          Variable(categoryId == null ? 'total' : 'categories'),
          Variable(currency),
          Variable(digits),
        ],
      );
      if (categoryId != null) {
        await customInsert(
          'INSERT INTO budget_categories (budget_id, category_id) VALUES (?, ?)',
          variables: [Variable(id), Variable(categoryId)],
        );
      }
      await customInsert(
        '''INSERT INTO budget_amounts (budget_id, start_month, amount_minor)
        SELECT ?, start_month, amount_minor FROM budgets_v6
        WHERE category_id IS ? AND currency = ? AND digits = ?''',
        variables: [
          Variable(id),
          Variable(categoryId),
          Variable(currency),
          Variable(digits),
        ],
      );
    }
    await customStatement('DROP TABLE budgets_v6');
  });

  /// Fresh installs (see `onCreate` above) and "Delete data on this phone" —
  /// an upgrading install's `categories` table starts empty, same as before
  /// this feature existed.
  Future<void> seedDefaultCategories() async {
    var order = 0;
    Future<int> insert(String name, String type, String icon, int? parentId) =>
        customInsert(
          'INSERT INTO categories (name, type, icon, parent_id, sort_order) VALUES (?, ?, ?, ?, ?)',
          variables: [
            Variable(name),
            Variable(type),
            Variable(icon),
            Variable(parentId),
            Variable(order++),
          ],
        );
    for (final group in defaultCategoryGroups) {
      for (final category in group.categories) {
        final parentId = await insert(
          category.name,
          group.type,
          category.icon,
          null,
        );
        for (final child in category.children) {
          await insert(child.name, group.type, child.icon, parentId);
        }
      }
    }
  }

  /// A fresh profile install starts with February--September 2026 entries.
  /// Amounts are INR paise and every account balance is derived from this
  /// ledger, so the sample remains useful when testing reports and balances.
  Future<void> _seedProfileSampleData() async {
    await transaction(() async {
      final accountIds = <String, int>{};
      Future<void> addAccount(String name, String icon) async {
        accountIds[name] = await customInsert(
          '''INSERT INTO accounts
          (name, currency, territory, icon, digits, balance_minor, sort_order)
          VALUES (?, 'INR', 'IN', ?, 2, 0, ?)''',
          variables: [
            Variable(name),
            Variable(icon),
            Variable(accountIds.length),
          ],
        );
      }

      await addAccount('HDFC Bank', 'bank');
      await addAccount('UPI Wallet', 'bank_card');
      await addAccount('Cash', 'wallet_one');

      final categoryRows = await customSelect(
        'SELECT id, name, type FROM categories',
      ).get();
      final categoryIds = <String, int>{
        for (final row in categoryRows)
          '${row.read<String>('type')}:${row.read<String>('name')}': row
              .read<int>('id'),
      };

      Future<void> addEntry(_ProfileEntry entry) async {
        final accountId = accountIds[entry.account]!;
        final date = DateTime(2026, entry.month, entry.day, entry.hour);
        if (entry.type == 'transfer') {
          final toAccountId = accountIds[entry.toAccount]!;
          await customInsert(
            '''INSERT INTO transactions
            (type, amount_minor, account_id, to_account_id, note, date, created_at)
            VALUES ('transfer', ?, ?, ?, ?, ?, ?)''',
            variables: [
              Variable(entry.amountMinor),
              Variable(accountId),
              Variable(toAccountId),
              Variable(entry.note),
              Variable(date.millisecondsSinceEpoch),
              Variable(date.millisecondsSinceEpoch),
            ],
          );
          await _applyProfileBalanceChange(accountId, -entry.amountMinor);
          await _applyProfileBalanceChange(toAccountId, entry.amountMinor);
          return;
        }

        await customInsert(
          '''INSERT INTO transactions
          (type, amount_minor, account_id, category_id, title, note, date, created_at)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
          variables: [
            Variable(entry.type),
            Variable(entry.amountMinor),
            Variable(accountId),
            Variable(categoryIds['${entry.type}:${entry.category}']!),
            Variable(entry.title),
            Variable(entry.note),
            Variable(date.millisecondsSinceEpoch),
            Variable(date.millisecondsSinceEpoch),
          ],
        );
        await _applyProfileBalanceChange(
          accountId,
          entry.type == 'income' ? entry.amountMinor : -entry.amountMinor,
        );
      }

      for (final entry in _profileEntries) {
        await addEntry(entry);
      }

      await _seedProfileLoans(accountIds);
      await _seedProfileDebts(accountIds);
      await _seedProfileSubscriptions(accountIds);

      for (final budget in _profileBudgets) {
        final budgetId = await customInsert(
          '''INSERT INTO budgets (kind, name, currency, digits)
          VALUES ('categories', ?, 'INR', 2)''',
          variables: [Variable(budget.name)],
        );
        for (final category in budget.categories) {
          await customInsert(
            'INSERT INTO budget_categories (budget_id, category_id) VALUES (?, ?)',
            variables: [
              Variable(budgetId),
              Variable(categoryIds['expense:$category']!),
            ],
          );
        }
        for (final (startMonth, amountMinor) in budget.amounts) {
          await customInsert(
            '''INSERT INTO budget_amounts (budget_id, start_month, amount_minor)
            VALUES (?, ?, ?)''',
            variables: [
              Variable(budgetId),
              Variable(startMonth),
              Variable(amountMinor),
            ],
          );
        }
      }
    });
  }

  /// One loan of every shape the feature supports, so a profile build has
  /// something in each state: an imported home loan the lender paid the
  /// builder for, a car loan part-way through, a personal loan disbursed
  /// with its charges deducted and an EMI now overdue, an interest-only
  /// education loan, a gold loan due in one payment next year, a bike and a
  /// phone on consumer EMIs, and a no-cost credit-card EMI already closed.
  ///
  /// Payments land on days the seeded ledger already uses, so no day ends up
  /// with a single entry on it.
  Future<void> _seedProfileLoans(Map<String, int> accountIds) async {
    Future<int> categoryFor(String name, String type) async {
      final row = await customSelect(
        '''SELECT id FROM categories
        WHERE name = ? AND type = ? AND parent_id IS NULL ORDER BY id LIMIT 1''',
        variables: [Variable(name), Variable(type)],
      ).getSingleOrNull();
      return row?.read<int>('id') ??
          await customInsert(
            '''INSERT INTO categories (name, type, icon, sort_order)
            VALUES (?, ?, 'bank',
              (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories))''',
            variables: [Variable(name), Variable(type)],
          );
    }

    /// Records the loan, the money it moved, and [payments] installments
    /// paid on time from [account] — with a late fee on any of them named
    /// in [fees], by their position.
    Future<void> addLoan(
      LoanTerms terms, {
      required String account,
      required DateTime openedOn,
      String? receivedIn,
      int payments = 0,
      Map<int, int> fees = const {},
    }) async {
      terms.validate();
      final accountId = accountIds[account]!;
      int? disbursalId, chargesId;
      if (receivedIn != null) {
        disbursalId = await _logProfileTransaction(
          type: 'income',
          amountMinor: terms.chargesDeducted
              ? terms.principal - terms.chargesMinor
              : terms.principal,
          accountId: accountIds[receivedIn]!,
          categoryId: await categoryFor('Loan disbursal', 'debt_loan'),
          title: '${terms.lender} loan disbursal',
          date: openedOn,
        );
      }
      if (terms.chargesMinor > 0 && !terms.chargesDeducted) {
        chargesId = await _logProfileTransaction(
          type: 'expense',
          amountMinor: terms.chargesMinor,
          accountId: accountId,
          categoryId: await categoryFor('Loan charges', 'expense'),
          title: '${terms.lender} loan charges',
          date: openedOn,
        );
      }
      final loanId = await customInsert(
        '''INSERT INTO loans (payload, account_id, disbursal_id, charges_id)
        VALUES (?, ?, ?, ?)''',
        variables: [
          Variable(jsonEncode(terms.toJson())),
          Variable(accountId),
          Variable(disbursalId),
          Variable(chargesId),
        ],
      );
      final emiCategory = await categoryFor('Loan EMI', 'expense');
      final events = <LoanEvent>[];
      for (var i = 0; i < payments; i++) {
        // Each installment's split comes from the loan as it stands, exactly
        // as recording a payment in the app would work it out.
        final current = Loan(
          id: loanId,
          terms: terms,
          accountId: accountId,
          events: [...events],
        );
        final due = current.schedule.first;
        final fee = fees[i] ?? 0;
        final paidOn = DateTime(due.due.year, due.due.month, due.due.day, 10);
        LoanEvent event(int id) => LoanEvent(
          id: id,
          kind: LoanEventKind.emi,
          date: paidOn,
          principal: due.principal,
          interest: due.interest,
          fee: fee,
          accountName: account,
        );
        final transactionId = await _logProfileTransaction(
          type: 'expense',
          amountMinor: due.amount + fee,
          accountId: accountId,
          categoryId: emiCategory,
          title: current.title,
          date: paidOn,
        );
        events.add(
          event(
            await customInsert(
              '''INSERT INTO loan_events
              (loan_id, kind, installment, payload, account_id, transaction_id)
              VALUES (?, 'emi', ?, ?, ?, ?)''',
              variables: [
                Variable(loanId),
                Variable(current.paid + 1),
                Variable(jsonEncode(event(0).toJson())),
                Variable(accountId),
                Variable(transactionId),
              ],
            ),
          ),
        );
      }
    }

    /// What is left after [paid] EMIs of the opening schedule — where a loan
    /// imported with history starts from.
    int carried(int principal, double rate, int months, int paid) =>
        loanSchedule(
          principal: principal,
          rate: rate,
          emi: loanEmi(principal, rate, months),
          first: DateTime(2026),
          day: 1,
        )[paid - 1].balance;

    await addLoan(
      LoanTerms(
        lender: 'HDFC Bank',
        kind: LoanKind.home,
        icon: 'bank',
        principal: 220000000,
        openingBalance: carried(220000000, 8.5, 240, 18),
        rate: 8.5,
        months: 240,
        emi: loanEmi(220000000, 8.5, 240),
        paidBefore: 18,
        firstDue: DateTime(2026, 8, 5),
        day: 5,
        currency: 'INR',
        digits: 2,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 8, 5),
      payments: 2,
    );
    await addLoan(
      LoanTerms(
        lender: 'SBI',
        kind: LoanKind.car,
        icon: 'brand:sbi',
        assetIcon: 'car',
        asset: 'Swift Dzire',
        principal: 70000000,
        openingBalance: carried(70000000, 9.2, 60, 6),
        rate: 9.2,
        months: 60,
        emi: loanEmi(70000000, 9.2, 60),
        paidBefore: 6,
        firstDue: DateTime(2026, 8, 6),
        day: 6,
        currency: 'INR',
        digits: 2,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 8, 6),
      payments: 2,
    );
    await addLoan(
      LoanTerms(
        lender: 'Bajaj Finserv',
        kind: LoanKind.personal,
        icon: 'credit',
        principal: 30000000,
        openingBalance: 30000000,
        rate: 14,
        months: 36,
        emi: loanEmi(30000000, 14, 36),
        paidBefore: 0,
        firstDue: DateTime(2026, 4, 3),
        day: 3,
        currency: 'INR',
        digits: 2,
        chargesMinor: 531000,
        chargesDeducted: true,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 3, 3),
      receivedIn: 'HDFC Bank',
      payments: 5,
      // July's EMI bounced and was charged for it.
      fees: const {3: 59000},
    );
    await addLoan(
      LoanTerms(
        lender: 'SBI',
        kind: LoanKind.education,
        icon: 'bank',
        principal: 60000000,
        openingBalance: 60000000,
        rate: 9.5,
        months: 24,
        emi: 0,
        paidBefore: 0,
        firstDue: DateTime(2026, 6),
        day: 1,
        currency: 'INR',
        digits: 2,
        mode: LoanRepaymentMode.interestOnly,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 5),
      receivedIn: 'HDFC Bank',
      payments: 4,
    );
    await addLoan(
      LoanTerms(
        lender: 'Muthoot Finance',
        kind: LoanKind.gold,
        icon: 'bank',
        principal: 15000000,
        openingBalance: 15000000,
        rate: 11,
        months: 12,
        emi: 0,
        paidBefore: 0,
        firstDue: DateTime(2027, 6, 6),
        day: 6,
        currency: 'INR',
        digits: 2,
        mode: LoanRepaymentMode.bullet,
        chargesMinor: 118000,
      ),
      account: 'Cash',
      openedOn: DateTime(2026, 6, 6),
      receivedIn: 'Cash',
    );
    // Bought at the showroom on finance: the dealer was paid, not us.
    await addLoan(
      LoanTerms(
        lender: 'TVS Credit',
        kind: LoanKind.twoWheeler,
        icon: 'bank',
        assetIcon: 'bicycle',
        asset: 'Jupiter 125',
        principal: 12000000,
        openingBalance: 12000000,
        rate: 9.7,
        months: 36,
        emi: loanEmi(12000000, 9.7, 36),
        paidBefore: 0,
        firstDue: DateTime(2026, 5, 6),
        day: 6,
        currency: 'INR',
        digits: 2,
        chargesMinor: 236000,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 4, 6),
      payments: 5,
    );
    // A phone on a no-cost EMI: interest free, but the card still charged
    // a conversion fee for it.
    await addLoan(
      LoanTerms(
        lender: 'ICICI Bank',
        kind: LoanKind.creditCard,
        icon: 'brand:icicibank',
        assetIcon: 'phone',
        asset: 'iPhone 16',
        principal: 7200000,
        openingBalance: 7200000,
        rate: 0,
        months: 9,
        emi: loanEmi(7200000, 0, 9),
        paidBefore: 0,
        firstDue: DateTime(2026, 5, 5),
        day: 5,
        currency: 'INR',
        digits: 2,
        chargesMinor: 59000,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 4, 5),
      payments: 5,
    );
    await addLoan(
      LoanTerms(
        lender: 'HDFC Bank',
        kind: LoanKind.creditCard,
        icon: 'brand:hdfcbank',
        assetIcon: 'washing_machine',
        asset: 'Washing machine',
        principal: 4800000,
        openingBalance: 4800000,
        rate: 0,
        months: 6,
        emi: loanEmi(4800000, 0, 6),
        paidBefore: 0,
        firstDue: DateTime(2026, 4, 5),
        day: 5,
        currency: 'INR',
        digits: 2,
        chargesMinor: 59000,
      ),
      account: 'HDFC Bank',
      openedOn: DateTime(2026, 3, 5),
      payments: 6,
    );
    // The current flow's flexible contract: the snapshot separates principal
    // from interest, and no hypothetical payment schedule is manufactured.
    await addLoan(
      LoanTerms(
        lender: 'Flexible gold loan',
        kind: LoanKind.other,
        icon: 'bank',
        principal: 10000000,
        openingBalance: 7000000,
        openingInterest: 350000,
        existing: true,
        startDate: DateTime(2026, 6, 6),
        snapshotDate: DateTime(2026, 9, 1),
        maturityDate: DateTime(2027, 6, 6),
        rate: 12,
        accrual: LoanAccrual.daily,
        months: 12,
        emi: 0,
        paidBefore: 0,
        firstDue: DateTime(2027, 6, 6),
        day: 6,
        currency: 'INR',
        digits: 2,
        mode: LoanRepaymentMode.flexible,
      ),
      account: 'Cash',
      openedOn: DateTime(2026, 6, 6),
    );
  }

  /// An overdue loan-out, a soon-due borrow already part paid back, a
  /// longer-overdue loan-out from cash, a borrow settled in full, and a
  /// record-only loan with no account behind it — one example of each shape
  /// Debts supports.
  Future<void> _seedProfileDebts(Map<String, int> accountIds) async {
    Future<int> addPerson(String name) => customInsert(
      'INSERT INTO debt_people (name, created_at) VALUES (?, ?)',
      variables: [
        Variable(name),
        Variable(DateTime.now().millisecondsSinceEpoch),
      ],
    );

    Future<int> categoryFor(DebtKind kind) async {
      final name = switch (kind) {
        DebtKind.lend => 'Loan',
        DebtKind.borrow => 'Debt',
        DebtKind.collect => 'Debt Collection',
        DebtKind.repay => 'Repayment',
      };
      final row = await customSelect(
        '''SELECT id FROM categories
        WHERE type = 'debt_loan' AND parent_id IS NULL AND name = ?
        ORDER BY id LIMIT 1''',
        variables: [Variable(name)],
      ).getSingleOrNull();
      return row!.read<int>('id');
    }

    Future<void> addEntry({
      required int personId,
      required String personName,
      required DebtKind kind,
      required int amountMinor,
      String? account,
      required DateTime date,
      DateTime? dueDate,
      String? note,
    }) async {
      int? accountId;
      int? transactionId;
      if (account != null) {
        accountId = accountIds[account]!;
        final title = switch (kind) {
          DebtKind.lend => 'Lent to $personName',
          DebtKind.borrow => 'Borrowed from $personName',
          DebtKind.collect => 'Paid back by $personName',
          DebtKind.repay => 'Paid back $personName',
        };
        transactionId = await _logProfileTransaction(
          type: kind.paysOut ? 'expense' : 'income',
          amountMinor: amountMinor,
          accountId: accountId,
          categoryId: await categoryFor(kind),
          title: title,
          date: date,
        );
      }
      final due = dueDate == null
          ? null
          : DateTime(dueDate.year, dueDate.month, dueDate.day);
      await customInsert(
        '''INSERT INTO debt_entries
        (person_id, kind, amount_minor, currency, digits, account_id,
         transaction_id, note, date, due_date, created_at)
        VALUES (?, ?, ?, 'INR', 2, ?, ?, ?, ?, ?, ?)''',
        variables: [
          Variable(personId),
          Variable(kind.storageValue),
          Variable(amountMinor),
          Variable(accountId),
          Variable(transactionId),
          Variable(note),
          Variable(date.millisecondsSinceEpoch),
          Variable(due?.millisecondsSinceEpoch),
          Variable(DateTime.now().millisecondsSinceEpoch),
        ],
      );
    }

    final rahul = await addPerson('Rahul Sharma');
    await addEntry(
      personId: rahul,
      personName: 'Rahul Sharma',
      kind: DebtKind.lend,
      amountMinor: 1500000,
      account: 'HDFC Bank',
      date: DateTime(2026, 8, 18),
      dueDate: DateTime(2026, 9, 12),
    );

    final priya = await addPerson('Priya Nair');
    await addEntry(
      personId: priya,
      personName: 'Priya Nair',
      kind: DebtKind.borrow,
      amountMinor: 800000,
      account: 'UPI Wallet',
      date: DateTime(2026, 8, 23),
      dueDate: DateTime(2026, 9, 20),
    );
    await addEntry(
      personId: priya,
      personName: 'Priya Nair',
      kind: DebtKind.repay,
      amountMinor: 300000,
      account: 'UPI Wallet',
      date: DateTime(2026, 9, 5),
    );

    final amit = await addPerson('Amit Verma');
    await addEntry(
      personId: amit,
      personName: 'Amit Verma',
      kind: DebtKind.lend,
      amountMinor: 2500000,
      account: 'Cash',
      date: DateTime(2026, 7, 15),
      dueDate: DateTime(2026, 8, 15),
    );

    final sneha = await addPerson('Sneha Iyer');
    await addEntry(
      personId: sneha,
      personName: 'Sneha Iyer',
      kind: DebtKind.borrow,
      amountMinor: 1200000,
      account: 'HDFC Bank',
      date: DateTime(2026, 8, 5),
      dueDate: DateTime(2026, 9, 5),
    );
    await addEntry(
      personId: sneha,
      personName: 'Sneha Iyer',
      kind: DebtKind.repay,
      amountMinor: 1200000,
      account: 'HDFC Bank',
      date: DateTime(2026, 8, 27),
    );

    final karan = await addPerson('Karan Mehta');
    await addEntry(
      personId: karan,
      personName: 'Karan Mehta',
      kind: DebtKind.lend,
      amountMinor: 500000,
      date: DateTime(2026, 9, 1),
      dueDate: DateTime(2026, 10, 1),
      note: 'Cash, off the books',
    );
  }

  /// A renewal due this week, one already overdue, a quarterly one due next
  /// month, a cheap one with reminders off, and a paused one — one example
  /// of each state Subscriptions shows.
  Future<void> _seedProfileSubscriptions(Map<String, int> accountIds) async {
    Future<int> categoryId(String name) async {
      final row = await customSelect(
        '''SELECT id FROM categories
        WHERE name = ? AND type = 'expense' ORDER BY parent_id IS NOT NULL, id LIMIT 1''',
        variables: [Variable(name)],
      ).getSingleOrNull();
      return row!.read<int>('id');
    }

    Future<void> addSubscription({
      required String name,
      required String icon,
      required int amountMinor,
      required BillingCycle cycle,
      required DateTime nextDue,
      required String account,
      required String category,
      bool remind = true,
      bool paused = false,
    }) async {
      await customInsert(
        '''INSERT INTO subscriptions
        (name, icon, amount_minor, currency, digits, cycle, next_due, day,
         account_id, category_id, remind, paused)
        VALUES (?, ?, ?, 'INR', 2, ?, ?, ?, ?, ?, ?, ?)''',
        variables: [
          Variable(name),
          Variable(icon),
          Variable(amountMinor),
          Variable(cycle.name),
          Variable(dateToStorage(nextDue)),
          Variable(nextDue.day),
          Variable(accountIds[account]!),
          Variable(await categoryId(category)),
          Variable(remind ? 1 : 0),
          Variable(paused ? 1 : 0),
        ],
      );
    }

    await addSubscription(
      name: 'Netflix',
      icon: 'brand:netflix',
      amountMinor: 64900,
      cycle: BillingCycle.monthly,
      nextDue: DateTime(2026, 9, 20),
      account: 'UPI Wallet',
      category: 'Subscriptions',
    );
    await addSubscription(
      name: 'Spotify',
      icon: 'brand:spotify',
      amountMinor: 11900,
      cycle: BillingCycle.monthly,
      nextDue: DateTime(2026, 9, 12),
      account: 'HDFC Bank',
      category: 'Subscriptions',
    );
    await addSubscription(
      name: "Gold's Gym",
      icon: 'gym',
      amountMinor: 450000,
      cycle: BillingCycle.quarterly,
      nextDue: DateTime(2026, 10, 1),
      account: 'HDFC Bank',
      category: 'Gym & Sports',
    );
    await addSubscription(
      name: 'iCloud storage',
      icon: 'brand:icloud',
      amountMinor: 7500,
      cycle: BillingCycle.monthly,
      nextDue: DateTime(2026, 9, 25),
      account: 'HDFC Bank',
      category: 'Subscriptions',
      remind: false,
    );
    await addSubscription(
      name: 'Crunchyroll',
      icon: 'brand:crunchyroll',
      amountMinor: 29900,
      cycle: BillingCycle.monthly,
      nextDue: DateTime(2026, 8, 5),
      account: 'UPI Wallet',
      category: 'Subscriptions',
      paused: true,
    );
  }

  /// Inserts one seeded transaction and moves its account's balance the way
  /// its [type] implies. Returns the new row's id.
  Future<int> _logProfileTransaction({
    required String type,
    required int amountMinor,
    required int accountId,
    required int categoryId,
    required String title,
    required DateTime date,
  }) async {
    final id = await customInsert(
      '''INSERT INTO transactions
        (type, amount_minor, account_id, category_id, title, date, created_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)''',
      variables: [
        Variable(type),
        Variable(amountMinor),
        Variable(accountId),
        Variable(categoryId),
        Variable(title),
        Variable(date.millisecondsSinceEpoch),
        Variable(date.millisecondsSinceEpoch),
      ],
    );
    await _applyProfileBalanceChange(
      accountId,
      type == 'income' ? amountMinor : -amountMinor,
    );
    return id;
  }

  Future<void> _applyProfileBalanceChange(int accountId, int amountMinor) =>
      customUpdate(
        '''UPDATE accounts
        SET balance_minor = balance_minor + ?,
            transaction_count = transaction_count + 1
        WHERE id = ?''',
        variables: [Variable(amountMinor), Variable(accountId)],
      );
}

class _ProfileEntry {
  const _ProfileEntry({
    required this.month,
    required this.day,
    required this.type,
    required this.amountMinor,
    required this.account,
    this.hour = 12,
    this.toAccount,
    this.category,
    this.title,
    this.note,
  });

  final int month;
  final int day;
  final String type;
  final int amountMinor;
  final String account;
  final int hour;
  final String? toAccount;
  final String? category;
  final String? title;
  final String? note;
}

/// Every seeded date has its scheduled entry plus a small, everyday purchase.
/// This makes the profile ledger useful for verifying grouped transaction rows
/// instead of showing one-item groups only.
final _profileEntries = <_ProfileEntry>[
  for (final entry in _profileScheduledEntries) ...[
    entry,
    _profileEverydayPurchase(entry),
  ],
];

_ProfileEntry _profileEverydayPurchase(_ProfileEntry entry) {
  const purchases = <({String category, String title, int amountMinor})>[
    (category: 'Cafe', title: 'Filter coffee', amountMinor: 14500),
    (
      category: 'Public Transport',
      title: 'Namma Metro ride',
      amountMinor: 5200,
    ),
    (category: 'Restaurants', title: 'Evening snack', amountMinor: 9800),
    (category: 'Pharmacy', title: 'Pharmacy essentials', amountMinor: 18700),
    (
      category: 'Groceries',
      title: 'Neighbourhood groceries',
      amountMinor: 23600,
    ),
  ];
  final purchase = purchases[(entry.month + entry.day) % purchases.length];
  return _ProfileEntry(
    month: entry.month,
    day: entry.day,
    hour: 19,
    type: 'expense',
    amountMinor: purchase.amountMinor,
    // Cash purchases stay in cash; the other accounts share the UPI wallet
    // for the kind of small day-to-day spend this entry represents.
    account: entry.account == 'Cash' ? 'Cash' : 'UPI Wallet',
    category: purchase.category,
    title: purchase.title,
  );
}

const _profileScheduledEntries = <_ProfileEntry>[
  // February 2026
  _ProfileEntry(
    month: 2,
    day: 1,
    type: 'income',
    amountMinor: 7800000,
    account: 'HDFC Bank',
    category: 'Salary',
    title: 'February salary',
    note: 'Salary credit',
  ),
  _ProfileEntry(
    month: 2,
    day: 3,
    type: 'expense',
    amountMinor: 2200000,
    account: 'HDFC Bank',
    category: 'Housing',
    title: 'House rent',
  ),
  _ProfileEntry(
    month: 2,
    day: 5,
    type: 'expense',
    amountMinor: 146800,
    account: 'HDFC Bank',
    category: 'Electricity',
    title: 'BESCOM electricity bill',
  ),
  _ProfileEntry(
    month: 2,
    day: 6,
    type: 'transfer',
    amountMinor: 900000,
    account: 'HDFC Bank',
    toAccount: 'UPI Wallet',
    note: 'Monthly UPI spend',
  ),
  _ProfileEntry(
    month: 2,
    day: 8,
    type: 'expense',
    amountMinor: 324560,
    account: 'UPI Wallet',
    category: 'Groceries',
    title: 'BigBasket groceries',
  ),
  _ProfileEntry(
    month: 2,
    day: 14,
    type: 'expense',
    amountMinor: 68500,
    account: 'UPI Wallet',
    category: 'Restaurants',
    title: 'Lunch with colleagues',
  ),
  _ProfileEntry(
    month: 2,
    day: 18,
    type: 'transfer',
    amountMinor: 300000,
    account: 'HDFC Bank',
    toAccount: 'Cash',
    note: 'ATM withdrawal',
  ),
  _ProfileEntry(
    month: 2,
    day: 22,
    type: 'expense',
    amountMinor: 59900,
    account: 'HDFC Bank',
    category: 'Mobile',
    title: 'Jio prepaid recharge',
  ),
  _ProfileEntry(
    month: 2,
    day: 26,
    type: 'expense',
    amountMinor: 125000,
    account: 'Cash',
    category: 'Fuel',
    title: 'Petrol',
  ),

  // March 2026
  _ProfileEntry(
    month: 3,
    day: 1,
    type: 'income',
    amountMinor: 7800000,
    account: 'HDFC Bank',
    category: 'Salary',
    title: 'March salary',
    note: 'Salary credit',
  ),
  _ProfileEntry(
    month: 3,
    day: 3,
    type: 'expense',
    amountMinor: 2200000,
    account: 'HDFC Bank',
    category: 'Housing',
    title: 'House rent',
  ),
  _ProfileEntry(
    month: 3,
    day: 5,
    type: 'expense',
    amountMinor: 139200,
    account: 'HDFC Bank',
    category: 'Electricity',
    title: 'BESCOM electricity bill',
  ),
  _ProfileEntry(
    month: 3,
    day: 6,
    type: 'transfer',
    amountMinor: 850000,
    account: 'HDFC Bank',
    toAccount: 'UPI Wallet',
    note: 'Monthly UPI spend',
  ),
  _ProfileEntry(
    month: 3,
    day: 9,
    type: 'expense',
    amountMinor: 287430,
    account: 'UPI Wallet',
    category: 'Groceries',
    title: 'DMart groceries',
  ),
  _ProfileEntry(
    month: 3,
    day: 15,
    type: 'expense',
    amountMinor: 32000,
    account: 'UPI Wallet',
    category: 'Cab',
    title: 'Namma Yatri ride',
  ),
  _ProfileEntry(
    month: 3,
    day: 20,
    type: 'expense',
    amountMinor: 56000,
    account: 'UPI Wallet',
    category: 'Movies',
    title: 'PVR cinema tickets',
  ),
  _ProfileEntry(
    month: 3,
    day: 23,
    type: 'transfer',
    amountMinor: 300000,
    account: 'HDFC Bank',
    toAccount: 'Cash',
    note: 'ATM withdrawal',
  ),
  _ProfileEntry(
    month: 3,
    day: 27,
    type: 'expense',
    amountMinor: 118000,
    account: 'Cash',
    category: 'Fuel',
    title: 'Petrol',
  ),

  // April 2026
  _ProfileEntry(
    month: 4,
    day: 1,
    type: 'income',
    amountMinor: 7800000,
    account: 'HDFC Bank',
    category: 'Salary',
    title: 'April salary',
    note: 'Salary credit',
  ),
  _ProfileEntry(
    month: 4,
    day: 3,
    type: 'expense',
    amountMinor: 2200000,
    account: 'HDFC Bank',
    category: 'Housing',
    title: 'House rent',
  ),
  _ProfileEntry(
    month: 4,
    day: 5,
    type: 'expense',
    amountMinor: 152600,
    account: 'HDFC Bank',
    category: 'Electricity',
    title: 'BESCOM electricity bill',
  ),
  _ProfileEntry(
    month: 4,
    day: 6,
    type: 'transfer',
    amountMinor: 900000,
    account: 'HDFC Bank',
    toAccount: 'UPI Wallet',
    note: 'Monthly UPI spend',
  ),
  _ProfileEntry(
    month: 4,
    day: 10,
    type: 'expense',
    amountMinor: 341890,
    account: 'UPI Wallet',
    category: 'Groceries',
    title: 'BigBasket groceries',
  ),
  _ProfileEntry(
    month: 4,
    day: 14,
    type: 'expense',
    amountMinor: 74200,
    account: 'UPI Wallet',
    category: 'Restaurants',
    title: 'Dinner at Nagarjuna',
  ),
  _ProfileEntry(
    month: 4,
    day: 18,
    type: 'expense',
    amountMinor: 79900,
    account: 'HDFC Bank',
    category: 'Internet',
    title: 'JioFiber broadband',
  ),
  _ProfileEntry(
    month: 4,
    day: 23,
    type: 'transfer',
    amountMinor: 300000,
    account: 'HDFC Bank',
    toAccount: 'Cash',
    note: 'ATM withdrawal',
  ),
  _ProfileEntry(
    month: 4,
    day: 27,
    type: 'expense',
    amountMinor: 132000,
    account: 'Cash',
    category: 'Fuel',
    title: 'Petrol',
  ),

  // May 2026
  _ProfileEntry(
    month: 5,
    day: 1,
    type: 'income',
    amountMinor: 7800000,
    account: 'HDFC Bank',
    category: 'Salary',
    title: 'May salary',
    note: 'Salary credit',
  ),
  _ProfileEntry(
    month: 5,
    day: 3,
    type: 'expense',
    amountMinor: 2200000,
    account: 'HDFC Bank',
    category: 'Housing',
    title: 'House rent',
  ),
  _ProfileEntry(
    month: 5,
    day: 5,
    type: 'expense',
    amountMinor: 168400,
    account: 'HDFC Bank',
    category: 'Electricity',
    title: 'BESCOM electricity bill',
  ),
  _ProfileEntry(
    month: 5,
    day: 6,
    type: 'transfer',
    amountMinor: 950000,
    account: 'HDFC Bank',
    toAccount: 'UPI Wallet',
    note: 'Monthly UPI spend',
  ),
  _ProfileEntry(
    month: 5,
    day: 9,
    type: 'expense',
    amountMinor: 305670,
    account: 'UPI Wallet',
    category: 'Groceries',
    title: 'Reliance Smart groceries',
  ),
  _ProfileEntry(
    month: 5,
    day: 13,
    type: 'expense',
    amountMinor: 49900,
    account: 'HDFC Bank',
    category: 'Mobile',
    title: 'Airtel prepaid recharge',
  ),
  _ProfileEntry(
    month: 5,
    day: 17,
    type: 'expense',
    amountMinor: 45000,
    account: 'UPI Wallet',
    category: 'Public Transport',
    title: 'Namma Metro card',
  ),
  _ProfileEntry(
    month: 5,
    day: 23,
    type: 'transfer',
    amountMinor: 300000,
    account: 'HDFC Bank',
    toAccount: 'Cash',
    note: 'ATM withdrawal',
  ),
  _ProfileEntry(
    month: 5,
    day: 26,
    type: 'expense',
    amountMinor: 120000,
    account: 'Cash',
    category: 'Fuel',
    title: 'Petrol',
  ),

  // June 2026
  _ProfileEntry(
    month: 6,
    day: 1,
    type: 'income',
    amountMinor: 7800000,
    account: 'HDFC Bank',
    category: 'Salary',
    title: 'June salary',
    note: 'Salary credit',
  ),
  _ProfileEntry(
    month: 6,
    day: 3,
    type: 'expense',
    amountMinor: 2200000,
    account: 'HDFC Bank',
    category: 'Housing',
    title: 'House rent',
  ),
  _ProfileEntry(
    month: 6,
    day: 5,
    type: 'expense',
    amountMinor: 145300,
    account: 'HDFC Bank',
    category: 'Electricity',
    title: 'BESCOM electricity bill',
  ),
  _ProfileEntry(
    month: 6,
    day: 6,
    type: 'transfer',
    amountMinor: 900000,
    account: 'HDFC Bank',
    toAccount: 'UPI Wallet',
    note: 'Monthly UPI spend',
  ),
  _ProfileEntry(
    month: 6,
    day: 9,
    type: 'expense',
    amountMinor: 367820,
    account: 'UPI Wallet',
    category: 'Groceries',
    title: 'BigBasket groceries',
  ),
  _ProfileEntry(
    month: 6,
    day: 14,
    type: 'expense',
    amountMinor: 124000,
    account: 'UPI Wallet',
    category: 'Restaurants',
    title: 'Sunday brunch',
  ),
  _ProfileEntry(
    month: 6,
    day: 18,
    type: 'expense',
    amountMinor: 184500,
    account: 'HDFC Bank',
    category: 'Travel',
    title: 'IRCTC train tickets',
  ),
  _ProfileEntry(
    month: 6,
    day: 23,
    type: 'transfer',
    amountMinor: 300000,
    account: 'HDFC Bank',
    toAccount: 'Cash',
    note: 'ATM withdrawal',
  ),
  _ProfileEntry(
    month: 6,
    day: 27,
    type: 'expense',
    amountMinor: 130000,
    account: 'Cash',
    category: 'Fuel',
    title: 'Petrol',
  ),

  // July 2026
  _ProfileEntry(
    month: 7,
    day: 1,
    type: 'income',
    amountMinor: 7800000,
    account: 'HDFC Bank',
    category: 'Salary',
    title: 'July salary',
    note: 'Salary credit',
  ),
  _ProfileEntry(
    month: 7,
    day: 3,
    type: 'expense',
    amountMinor: 2200000,
    account: 'HDFC Bank',
    category: 'Housing',
    title: 'House rent',
  ),
  _ProfileEntry(
    month: 7,
    day: 5,
    type: 'expense',
    amountMinor: 158700,
    account: 'HDFC Bank',
    category: 'Electricity',
    title: 'BESCOM electricity bill',
  ),
  _ProfileEntry(
    month: 7,
    day: 6,
    type: 'transfer',
    amountMinor: 950000,
    account: 'HDFC Bank',
    toAccount: 'UPI Wallet',
    note: 'Monthly UPI spend',
  ),
  _ProfileEntry(
    month: 7,
    day: 9,
    type: 'expense',
    amountMinor: 314220,
    account: 'UPI Wallet',
    category: 'Groceries',
    title: 'DMart groceries',
  ),
  _ProfileEntry(
    month: 7,
    day: 15,
    type: 'expense',
    amountMinor: 89900,
    account: 'HDFC Bank',
    category: 'Internet',
    title: 'JioFiber broadband',
  ),
  _ProfileEntry(
    month: 7,
    day: 19,
    type: 'expense',
    amountMinor: 93600,
    account: 'UPI Wallet',
    category: 'Pharmacy',
    title: 'Apollo Pharmacy',
  ),
  _ProfileEntry(
    month: 7,
    day: 23,
    type: 'transfer',
    amountMinor: 300000,
    account: 'HDFC Bank',
    toAccount: 'Cash',
    note: 'ATM withdrawal',
  ),
  _ProfileEntry(
    month: 7,
    day: 27,
    type: 'expense',
    amountMinor: 128000,
    account: 'Cash',
    category: 'Fuel',
    title: 'Petrol',
  ),

  // August 2026
  _ProfileEntry(
    month: 8,
    day: 1,
    type: 'income',
    amountMinor: 7800000,
    account: 'HDFC Bank',
    category: 'Salary',
    title: 'August salary',
    note: 'Salary credit',
  ),
  _ProfileEntry(
    month: 8,
    day: 3,
    type: 'expense',
    amountMinor: 2200000,
    account: 'HDFC Bank',
    category: 'Housing',
    title: 'House rent',
  ),
  _ProfileEntry(
    month: 8,
    day: 5,
    type: 'expense',
    amountMinor: 162100,
    account: 'HDFC Bank',
    category: 'Electricity',
    title: 'BESCOM electricity bill',
  ),
  _ProfileEntry(
    month: 8,
    day: 6,
    type: 'transfer',
    amountMinor: 950000,
    account: 'HDFC Bank',
    toAccount: 'UPI Wallet',
    note: 'Monthly UPI spend',
  ),
  _ProfileEntry(
    month: 8,
    day: 9,
    type: 'expense',
    amountMinor: 352460,
    account: 'UPI Wallet',
    category: 'Groceries',
    title: 'BigBasket groceries',
  ),
  _ProfileEntry(
    month: 8,
    day: 14,
    type: 'expense',
    amountMinor: 108500,
    account: 'UPI Wallet',
    category: 'Restaurants',
    title: 'Family dinner',
  ),
  _ProfileEntry(
    month: 8,
    day: 18,
    type: 'expense',
    amountMinor: 96000,
    account: 'UPI Wallet',
    category: 'Clothing',
    title: 'Myntra order',
  ),
  _ProfileEntry(
    month: 8,
    day: 23,
    type: 'transfer',
    amountMinor: 300000,
    account: 'HDFC Bank',
    toAccount: 'Cash',
    note: 'ATM withdrawal',
  ),
  _ProfileEntry(
    month: 8,
    day: 27,
    type: 'expense',
    amountMinor: 135000,
    account: 'Cash',
    category: 'Fuel',
    title: 'Petrol',
  ),

  // September 2026 (entries through 9 September, the test-data cut-off).
  _ProfileEntry(
    month: 9,
    day: 1,
    type: 'income',
    amountMinor: 7800000,
    account: 'HDFC Bank',
    category: 'Salary',
    title: 'September salary',
    note: 'Salary credit',
  ),
  _ProfileEntry(
    month: 9,
    day: 3,
    type: 'expense',
    amountMinor: 2200000,
    account: 'HDFC Bank',
    category: 'Housing',
    title: 'House rent',
  ),
  _ProfileEntry(
    month: 9,
    day: 5,
    type: 'expense',
    amountMinor: 149800,
    account: 'HDFC Bank',
    category: 'Electricity',
    title: 'BESCOM electricity bill',
  ),
  _ProfileEntry(
    month: 9,
    day: 6,
    type: 'transfer',
    amountMinor: 900000,
    account: 'HDFC Bank',
    toAccount: 'UPI Wallet',
    note: 'Monthly UPI spend',
  ),
  _ProfileEntry(
    month: 9,
    day: 8,
    type: 'expense',
    amountMinor: 298750,
    account: 'UPI Wallet',
    category: 'Groceries',
    title: 'Reliance Smart groceries',
  ),
  _ProfileEntry(
    month: 9,
    day: 9,
    type: 'expense',
    amountMinor: 37800,
    account: 'UPI Wallet',
    category: 'Cab',
    title: 'Namma Yatri ride',
  ),
];

/// Budgets from February, as (start month, amount) changes: Food & Beverage
/// is lowered in July so both the carry-forward and an over-budget month
/// show up in profile builds, and Shopping and Entertainment are combined
/// into one custom budget.
const _profileBudgets =
    <({String? name, List<String> categories, List<(int, int)> amounts})>[
      (
        name: null,
        categories: ['Food & Beverage'],
        amounts: [(202602, 800000), (202607, 500000)],
      ),
      (
        name: 'Fun & shopping',
        categories: ['Shopping', 'Entertainment'],
        amounts: [(202602, 250000)],
      ),
      (name: null, categories: ['Transportation'], amounts: [(202602, 300000)]),
      (
        name: null,
        categories: ['Bills & Utilities'],
        amounts: [(202602, 350000)],
      ),
      (
        name: null,
        categories: ['Health & Fitness'],
        amounts: [(202602, 150000)],
      ),
      (name: null, categories: ['Housing'], amounts: [(202602, 2200000)]),
    ];

const _createBudgetsTable = '''
CREATE TABLE budgets (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  kind TEXT NOT NULL CHECK(kind IN ('total', 'categories')),
  name TEXT CHECK(name IS NULL OR length(trim(name)) BETWEEN 1 AND 40),
  currency TEXT NOT NULL CHECK(length(currency) = 3),
  digits INTEGER NOT NULL CHECK(digits BETWEEN 0 AND 4),
  icon TEXT
)
''';

const _createBudgetsTotalIndex = '''
CREATE UNIQUE INDEX budgets_total ON budgets(currency, digits)
WHERE kind = 'total'
''';

const _createBudgetCategoriesTable = '''
CREATE TABLE budget_categories (
  budget_id INTEGER NOT NULL,
  category_id INTEGER NOT NULL,
  PRIMARY KEY (budget_id, category_id)
)
''';

const _createBudgetAmountsTable = '''
CREATE TABLE budget_amounts (
  budget_id INTEGER NOT NULL,
  start_month INTEGER NOT NULL,
  amount_minor INTEGER CHECK(amount_minor IS NULL OR amount_minor > 0),
  PRIMARY KEY (budget_id, start_month)
)
''';

const _createDebtPeopleTable = '''
CREATE TABLE IF NOT EXISTS debt_people (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 40),
  phone TEXT,
  created_at INTEGER NOT NULL
)
''';

const _createDebtEntriesTable = '''
CREATE TABLE IF NOT EXISTS debt_entries (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  person_id INTEGER NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('lend', 'borrow', 'collect', 'repay')),
  amount_minor INTEGER NOT NULL CHECK(amount_minor > 0),
  currency TEXT NOT NULL CHECK(length(currency) = 3),
  digits INTEGER NOT NULL CHECK(digits BETWEEN 0 AND 4),
  account_id INTEGER,
  transaction_id INTEGER,
  note TEXT,
  date INTEGER NOT NULL,
  due_date INTEGER,
  created_at INTEGER NOT NULL
)
''';

const _createCategoriesTable = '''
CREATE TABLE categories (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL CHECK(length(trim(name)) BETWEEN 1 AND 40),
  type TEXT NOT NULL CHECK(type IN ('expense', 'income', 'debt_loan')),
  icon TEXT,
  parent_id INTEGER,
  sort_order INTEGER NOT NULL
)
''';

const _createTransactionsTable = '''
CREATE TABLE transactions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  type TEXT NOT NULL CHECK(type IN ('expense', 'income', 'transfer')),
  amount_minor INTEGER NOT NULL CHECK(amount_minor > 0),
  account_id INTEGER NOT NULL,
  to_account_id INTEGER,
  -- What actually landed in to_account_id, when that differs from the amount
  -- sent: a transfer across currencies, or one a charge was taken from.
  -- Null means the destination received amount_minor unchanged.
  to_amount_minor INTEGER CHECK(to_amount_minor IS NULL OR to_amount_minor > 0),
  category_id INTEGER,
  title TEXT,
  note TEXT,
  date INTEGER NOT NULL,
  created_at INTEGER NOT NULL
)
''';

// Changes an AI app proposed, waiting for the user to approve them (see
// data/agent/agent_suggestion_repository.dart). Device-local like the SMS
// review index: targets are local IDs, so it is excluded from syncTables and
// cleared by a restore.
const _createAgentSuggestionsTable = '''
CREATE TABLE IF NOT EXISTS agent_suggestions (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  batch_id TEXT NOT NULL,
  kind TEXT NOT NULL
    CHECK(kind IN ('new_category', 'sms_correction', 'transaction_edit',
      'parser_rule', 'statement_layout', 'new_loan', 'debt_entry',
      'transaction_add')),
  target TEXT NOT NULL,
  payload TEXT NOT NULL,
  before TEXT,
  summary TEXT NOT NULL,
  detail TEXT NOT NULL,
  reason TEXT,
  status TEXT NOT NULL DEFAULT 'pending'
    CHECK(status IN ('pending', 'applied', 'rejected', 'undone')),
  error TEXT,
  created_at INTEGER NOT NULL,
  decided_at INTEGER
)
''';

// SMS formats the user approved, added to the bundled rule packs (see
// data/user_sms_rules.dart). One row is one format of the portable rule
// spec. Device-local: kept by a restore, removed by a device wipe.
const _createUserSmsRulesTable = '''
CREATE TABLE IF NOT EXISTS user_sms_rules (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  bank_name TEXT NOT NULL,
  senders TEXT NOT NULL,
  format TEXT NOT NULL,
  samples TEXT NOT NULL,
  created_at INTEGER NOT NULL
)
''';

// Shared fixes from other users (see data/community/community_fixes.dart):
// SMS formats and statement layouts, as last downloaded. Device-local,
// rebuildable cache, excluded from syncTables. `off` marks one the user
// turned off, kept so a new download doesn't bring it back.
const _createCommunityFixesTable = '''
CREATE TABLE IF NOT EXISTS community_fixes (
  hash TEXT PRIMARY KEY,
  kind TEXT NOT NULL CHECK(kind IN ('sms_rule', 'statement_layout')),
  payload TEXT NOT NULL,
  off INTEGER NOT NULL DEFAULT 0
)
''';

// Device-local, rebuildable cache. Deliberately excluded from syncTables.
const _createExchangeRatesTable = '''
CREATE TABLE IF NOT EXISTS exchange_rates (
  base TEXT NOT NULL,
  quote TEXT NOT NULL,
  rate REAL NOT NULL CHECK(rate > 0),
  fetched_on TEXT NOT NULL,
  rate_date TEXT NOT NULL,
  PRIMARY KEY(base, quote)
)
''';
