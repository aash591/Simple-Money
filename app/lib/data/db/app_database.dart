import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:flutter/foundation.dart' show kProfileMode;

import 'default_categories.dart';
import '../../domain/debt.dart';
import '../../domain/loan.dart';
import '../../domain/recurring_payment.dart';
import '../backup/sync_schema.dart';

part 'database_schema.dart';
part 'profile_sample_data.dart';
part 'profile_sample_entries.dart';

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
  int get schemaVersion => 44;
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
      await customStatement(_createRecurringPaymentsTable);
      await customStatement(_createRecurringPaymentHistoryTable);
      await customStatement(_createExchangeRatesTable);
      await customStatement(_createAgentSuggestionsTable);
      await customStatement(_createUserSmsRulesTable);
      await customStatement(_createSmsCategoryMemoryTable);
      await customStatement(_createCommunityFixesTable);
      await seedDefaultCategories();
      if (_seedProfileData) await _seedProfileSampleData();
      await createSyncSchema(this);
    },
    onUpgrade: (_, from, to) async {
      // v40 -> v41: recurring payments became recurring payments, which can also
      // be money coming in. Before every other step, which use the new names.
      if (from >= 15 && from < 41) await _recurringPayments(from);
      // v43 -> v44: these two are synced now, so they must exist before the
      // sync schema below (which, for old databases, triggers every table).
      if (from < 44) {
        await customStatement(_createUserSmsRulesTable);
        await customStatement(_createSmsCategoryMemoryTable);
      }
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
      if (from < 15) await customStatement(_createRecurringPaymentsTable);
      if (from < 16) {
        await customStatement(_createRecurringPaymentHistoryTable);
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
        if (from < 15) await createSyncTriggers(this, 'recurring_payments');
        if (from < 16) {
          await createSyncTriggers(this, 'recurring_payment_history');
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
      if (from == 15) await _linkEarlierRecurringPaymentHistory();
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
      if (from >= 34 && from < 42) {
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
      if (from < 43) {
        if (!await _hasColumn('sync_state', 'encryption_config')) {
          await customStatement(
            'ALTER TABLE sync_state ADD COLUMN encryption_config TEXT',
          );
        }
        if (!await _hasColumn('sync_state', 'restore_pending')) {
          await customStatement(
            'ALTER TABLE sync_state ADD COLUMN restore_pending INTEGER NOT NULL DEFAULT 0',
          );
        }
      }
      // Databases older than v8 got every trigger from createSyncSchema.
      if (from >= 8 && from < 44) {
        const learned = ['sms_category_memory', 'user_sms_rules'];
        for (final table in learned) {
          await createSyncTriggers(this, table);
        }
        // Through the triggers' table, so the next upload carries what the
        // app has already learned.
        await seedSyncOutbox(this, tables: learned);
      }
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA busy_timeout = 5000');
    },
  );

  /// Renames the recurring payment tables, adds the direction column, and moves
  /// the sync triggers and queued changes over to the new names.
  Future<void> _recurringPayments(int from) async {
    final tables = {
      for (final row in await customSelect(
        "SELECT name FROM sqlite_master WHERE type = 'table'",
      ).get())
        row.read<String>('name'),
    };
    if (tables.contains('subscriptions')) {
      await customStatement(
        'ALTER TABLE subscriptions RENAME TO recurring_payments',
      );
      await customStatement(
        'ALTER TABLE recurring_payments ADD COLUMN incoming INTEGER NOT NULL DEFAULT 0',
      );
      await _dropSyncTriggers('subscriptions');
      await customStatement(
        "UPDATE sync_outbox SET table_name = 'recurring_payments' WHERE table_name = 'subscriptions'",
      );
      await createSyncTriggers(this, 'recurring_payments');
    }
    if (tables.contains('subscription_payments')) {
      await customStatement(
        'ALTER TABLE subscription_payments RENAME TO recurring_payment_history',
      );
      await customStatement(
        'ALTER TABLE recurring_payment_history RENAME COLUMN subscription_id TO recurring_payment_id',
      );
      await _dropSyncTriggers('subscription_payments');
      await customStatement(
        "UPDATE sync_outbox SET table_name = 'recurring_payment_history' WHERE table_name = 'subscription_payments'",
      );
      await createSyncTriggers(this, 'recurring_payment_history');
    }
  }

  Future<void> _dropSyncTriggers(String table) async {
    for (final operation in ['insert', 'update', 'delete']) {
      await customStatement('DROP TRIGGER IF EXISTS sync_${table}_$operation');
    }
  }

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
  static const _createRecurringPaymentsTable =
      '''CREATE TABLE IF NOT EXISTS recurring_payments (
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
    paused INTEGER NOT NULL DEFAULT 0,
    incoming INTEGER NOT NULL DEFAULT 0
  )''';

  /// The expense each "Mark paid" logged, so the transaction can wear its
  /// recurring payment's artwork.
  static const _createRecurringPaymentHistoryTable =
      '''CREATE TABLE IF NOT EXISTS recurring_payment_history (
    transaction_id INTEGER PRIMARY KEY NOT NULL,
    recurring_payment_id INTEGER NOT NULL
  )''';

  /// Before v16 a payment was only recognisable by what it copied from its
  /// recurring payment: an expense with its name, amount and account.
  Future<void> _linkEarlierRecurringPaymentHistory() => customStatement('''INSERT OR IGNORE INTO recurring_payment_history (transaction_id, recurring_payment_id)
    SELECT t.id, s.id FROM transactions t JOIN recurring_payments s
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
}
