import 'package:drift/drift.dart';

/// The cloud protocol uses (mirrorId, table, primary key) as record identity.
/// Local integer IDs remain stable inside one device's independently owned mirror.
const syncTables = {
  'accounts': ['id'],
  'categories': ['id'],
  'transactions': ['id'],
  'budgets': ['id'],
  'budget_categories': ['budget_id', 'category_id'],
  'budget_amounts': ['budget_id', 'start_month'],
  'debt_people': ['id'],
  'debt_entries': ['id'],
  'loans': ['id'],
  'loan_events': ['id'],
  'subscriptions': ['id'],
  'subscription_payments': ['transaction_id'],
  // Which bank SMS are already saved or dismissed, and which account each
  // bank's messages go to: without them a restored phone saves its inbox again.
  'sms_history': ['fingerprint'],
  'sms_account_links': ['bank_key'],
};

Future<void> createSyncSchema(GeneratedDatabase db) async {
  await db.customStatement('''CREATE TABLE sync_state (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    enabled INTEGER NOT NULL DEFAULT 0,
    email TEXT, subject TEXT, display_name TEXT, picture_url TEXT,
    installation_id TEXT,
    mirror_id TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 0,
    next_sequence INTEGER NOT NULL DEFAULT 1,
    last_synced INTEGER,
    error TEXT, retry_at INTEGER NOT NULL DEFAULT 0,
    failures INTEGER NOT NULL DEFAULT 0,
    lease TEXT, lease_until INTEGER NOT NULL DEFAULT 0
  )''');
  await db.customStatement('''INSERT INTO sync_state(id, mirror_id)
    VALUES(1, lower(hex(randomblob(16))))''');
  await db.customStatement('''CREATE TABLE sync_outbox (
    table_name TEXT NOT NULL, record_key TEXT NOT NULL,
    row_json TEXT, revision INTEGER NOT NULL,
    PRIMARY KEY(table_name, record_key)
  )''');
  await db.customStatement('''CREATE TABLE sync_batch (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    file_id TEXT NOT NULL, mirror_id TEXT NOT NULL,
    sequence INTEGER NOT NULL, revision INTEGER NOT NULL,
    payload BLOB NOT NULL, checksum TEXT NOT NULL
  )''');
  for (final table in syncTables.keys) {
    await createSyncTriggers(db, table);
  }
  await seedSyncOutbox(db);
}

/// (Re)creates [table]'s change triggers. They copy the columns it has now,
/// so rerun this after adding a column to a synced table.
Future<void> createSyncTriggers(GeneratedDatabase db, String table) async {
  final keyColumns = syncTables[table]!;
  final columns = await db.customSelect('PRAGMA table_info($table)').get();
  String key(String alias) =>
      'json_array(${keyColumns.map((c) => '$alias.$c').join(', ')})';
  final json =
      'json_object(${columns.map((c) {
        final name = c.read<String>('name');
        return "'$name', NEW.$name";
      }).join(', ')})';
  for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
    final deleted = operation == 'DELETE';
    final trigger = 'sync_${table}_${operation.toLowerCase()}';
    await db.customStatement('DROP TRIGGER IF EXISTS $trigger');
    // Coalesce repeated offline edits, but never discard a deletion marker.
    // These writes commit or roll back together with the ledger mutation.
    await db.customStatement('''CREATE TRIGGER $trigger
      AFTER $operation ON $table BEGIN
        UPDATE sync_state SET revision = revision + 1 WHERE id = 1;
        ${operation == 'UPDATE' ? '''INSERT OR REPLACE INTO sync_outbox
          SELECT '$table', ${key('OLD')}, NULL, revision FROM sync_state
          WHERE id = 1 AND ${key('OLD')} != ${key('NEW')};''' : ''}
        INSERT OR REPLACE INTO sync_outbox
          SELECT '$table', ${key(deleted ? 'OLD' : 'NEW')},
            ${deleted ? 'NULL' : json}, revision FROM sync_state WHERE id = 1;
      END''');
  }
}

/// Queue a consistent initial copy when opting in or changing Google accounts.
/// Call within the caller's database transaction.
Future<void> seedSyncOutbox(
  GeneratedDatabase db, {
  Iterable<String>? tables,
}) async {
  for (final entry in syncTables.entries) {
    if (tables != null && !tables.contains(entry.key)) continue;
    final columns = await db
        .customSelect('PRAGMA table_info(${entry.key})')
        .get();
    final json = columns
        .map((c) {
          final name = c.read<String>('name');
          return "'$name', $name";
        })
        .join(', ');
    await db.customStatement(
      'UPDATE sync_state SET revision = revision + 1 WHERE id = 1',
    );
    await db.customStatement('''INSERT OR REPLACE INTO sync_outbox
      SELECT '${entry.key}', json_array(${entry.value.join(', ')}),
        json_object($json), (SELECT revision FROM sync_state WHERE id = 1)
      FROM ${entry.key}''');
  }
}
