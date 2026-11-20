import 'package:drift/drift.dart';

/// The cloud protocol uses (table, primary key) as record identity. New rows
/// get IDs from [newRowId], so two devices never hand out the same one.
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
  'recurring_payments': ['id'],
  'recurring_payment_history': ['transaction_id'],
  // Which bank SMS are already saved or dismissed, and which account each
  // bank's messages go to: without them a restored phone saves its inbox again.
  'sms_history': ['fingerprint'],
  'sms_account_links': ['bank_key'],
  // What the app has learned from the user: merchant -> category choices and
  // the SMS formats they approved. Both are lost with the phone otherwise.
  'sms_category_memory': ['merchant'],
  'user_sms_rules': ['id'],
  // What the user said a misleading message layout really is (a loan
  // payment, not income), so every phone reads that sender the same way.
  'sms_corrections': ['sender', 'rule_id'],
  // Learned bank/UPI statement formats: column layouts, which account each
  // statement account goes to, and who the statements say the user is.
  'statement_layouts': ['signature'],
  'statement_account_links': ['statement_key'],
  'statement_owner': ['id'],
  // Brokers' holdings and every trade, so a restored phone has its portfolio.
  'holdings': ['id'],
  'holding_trades': ['id'],
};

/// The schema version whose mirrors first carry a table. A backup older than
/// that never held it, so restoring one must not wipe the phone's own rows.
const syncTableSince = {
  'sms_category_memory': 44,
  'user_sms_rules': 44,
  'sms_corrections': 47,
  'statement_layouts': 47,
  'statement_account_links': 47,
  'statement_owner': 47,
  'holdings': 52,
  'holding_trades': 52,
};

/// Unix time in milliseconds, from SQLite's clock.
const _unixMs = "CAST((julianday('now') - 2440587.5) * 86400000 AS INTEGER)";

/// Milliseconds since 2025-01-01 UTC, the time part of a row ID.
const _idMs = "CAST((julianday('now') - 2460676.5) * 86400000 AS INTEGER)";

/// The hybrid logical clock after one more local change: wall time in the
/// high bits, a counter below, never going backwards. Its value orders
/// every change to a row across devices; the newest one wins.
const _tick = 'max(clock + 1, $_unixMs << 16)';

/// An HLC value for a wall-clock time, for changes that predate the clock.
int hlcAt(DateTime time) => time.millisecondsSinceEpoch << 16;

/// SQL for a new row's ID in [table]: `(ms since 2025) << 11 | device slot`.
///
/// IDs keep growing in creation order (many queries break ties on `id`),
/// stay above every ID handed out before v47 and below 2^53, so they
/// survive JSON in any language. Two installations differ in their slot,
/// so they can't create the same ID even offline; one device creating
/// several rows in the same millisecond moves on to the next one.
String newRowId(String table) =>
    '(SELECT (max($_idMs, coalesce(max(id) >> 11, 0) + 1) << 11)'
    ' | (SELECT id_slot FROM sync_state WHERE id = 1) FROM $table)';

/// SQL that picks a new random device slot (0..2047) for [newRowId].
const _randomSlot = '(random() & 2047)';

Future<void> createSyncSchema(GeneratedDatabase db) async {
  await db.customStatement('''CREATE TABLE sync_state (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    enabled INTEGER NOT NULL DEFAULT 0,
    encryption_config TEXT,
    restore_pending INTEGER NOT NULL DEFAULT 0,
    email TEXT, subject TEXT, display_name TEXT, picture_url TEXT,
    installation_id TEXT,
    mirror_id TEXT NOT NULL,
    revision INTEGER NOT NULL DEFAULT 0,
    next_sequence INTEGER NOT NULL DEFAULT 1,
    last_synced INTEGER,
    error TEXT, retry_at INTEGER NOT NULL DEFAULT 0,
    failures INTEGER NOT NULL DEFAULT 0,
    lease TEXT, lease_until INTEGER NOT NULL DEFAULT 0,
    id_slot INTEGER NOT NULL DEFAULT 0,
    clock INTEGER NOT NULL DEFAULT 0,
    applying INTEGER NOT NULL DEFAULT 0,
    changes_token TEXT,
    peers_baseline INTEGER NOT NULL DEFAULT 1,
    device_name TEXT
  )''');
  await db.customStatement('''INSERT INTO sync_state(id, mirror_id, id_slot)
    VALUES(1, lower(hex(randomblob(16))), $_randomSlot)''');
  await db.customStatement('''CREATE TABLE sync_outbox (
    table_name TEXT NOT NULL, record_key TEXT NOT NULL,
    row_json TEXT, revision INTEGER NOT NULL,
    hlc INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(table_name, record_key)
  )''');
  await db.customStatement('''CREATE TABLE sync_batch (
    id INTEGER PRIMARY KEY CHECK(id = 1),
    file_id TEXT NOT NULL, mirror_id TEXT NOT NULL,
    sequence INTEGER NOT NULL, revision INTEGER NOT NULL,
    payload BLOB NOT NULL, checksum TEXT NOT NULL
  )''');
  await _createRowMeta(db);
  await _createPeers(db);
  for (final table in syncTables.keys) {
    await createSyncTriggers(db, table);
  }
  await upgradeSyncSchemaToV49(db);
  await upgradeSyncSchemaToV50(db);
  await upgradeSyncSchemaToV51(db);
  await seedSyncOutbox(db);
}

/// The tables whose every add, edit and delete is kept in More > Activity
/// log, with the record as it was before and after, so each can be undone.
const historyTables = {'transactions'};

/// v48 -> v49: one Drive file per device instead of a chain of batches
/// (`drive_file_id` is this device's file), and the change history behind
/// the activity log. While `history_off` is set (a restore, an import) the
/// history isn't written; `history_device` names the phone whose changes
/// are being merged in (NULL: this phone's own edits).
Future<void> upgradeSyncSchemaToV49(GeneratedDatabase db) async {
  final columns = {
    for (final row
        in await db.customSelect('PRAGMA table_info(sync_state)').get())
      row.read<String>('name'),
  };
  if (columns.isEmpty) return;
  for (final (column, type) in const [
    ('drive_file_id', 'TEXT'),
    ('history_device', 'TEXT'),
    ('history_off', 'INTEGER NOT NULL DEFAULT 0'),
  ]) {
    if (!columns.contains(column)) {
      await db.customStatement(
        'ALTER TABLE sync_state ADD COLUMN $column $type',
      );
    }
  }
  // Batches (and how far each phone's chain was read) are replaced by one
  // file per phone: everything goes up again as this phone's first file.
  final tables = {
    for (final row in await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
        .get())
      row.read<String>('name'),
  };
  if (tables.contains('sync_batch')) {
    await db.customStatement('DELETE FROM sync_batch');
  }
  if (tables.contains('sync_outbox')) await markSyncDirty(db);
  await db.customStatement('''CREATE TABLE IF NOT EXISTS record_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at INTEGER NOT NULL,
    table_name TEXT NOT NULL,
    record_key TEXT NOT NULL,
    action TEXT NOT NULL,
    before_json TEXT,
    after_json TEXT,
    device TEXT,
    undone INTEGER NOT NULL DEFAULT 0
  )''');
  await db.customStatement(
    'CREATE INDEX IF NOT EXISTS record_history_at ON record_history(at)',
  );
  for (final table in historyTables) {
    await createHistoryTriggers(db, table);
  }
}

/// v49 -> v50: a phone's data on Drive is split into sections (see
/// sync_sections.dart), one file each. `sync_files` is this phone's: the
/// Drive file of each section, with its ID saved before the file is created
/// (`created` = 0), so a lost response never makes a second one, and the
/// upload it holds. `list_cursor` is the newest modified time seen when
/// listing the other phones' files; `listed_at` when they were last listed
/// in full.
Future<void> upgradeSyncSchemaToV50(GeneratedDatabase db) async {
  final state = {
    for (final row
        in await db.customSelect('PRAGMA table_info(sync_state)').get())
      row.read<String>('name'),
  };
  if (state.isEmpty) return;
  if (!state.contains('list_cursor')) {
    await db.customStatement(
      'ALTER TABLE sync_state ADD COLUMN list_cursor TEXT',
    );
  }
  if (!state.contains('listed_at')) {
    await db.customStatement(
      'ALTER TABLE sync_state ADD COLUMN listed_at INTEGER NOT NULL DEFAULT 0',
    );
  }
  // The newest version each merged file held (see SyncBatch.newest).
  final peers = {
    for (final row
        in await db.customSelect('PRAGMA table_info(sync_peers)').get())
      row.read<String>('name'),
  };
  if (peers.isNotEmpty && !peers.contains('newest')) {
    await db.customStatement(
      'ALTER TABLE sync_peers ADD COLUMN newest INTEGER NOT NULL DEFAULT 0',
    );
  }
  await db.customStatement('''CREATE TABLE IF NOT EXISTS sync_files (
    section TEXT PRIMARY KEY,
    file_id TEXT NOT NULL,
    created INTEGER NOT NULL DEFAULT 0,
    sequence INTEGER NOT NULL DEFAULT 0
  ) WITHOUT ROWID''');
  // Everything goes up again as sections; the single file is then deleted.
  final outbox = await db
      .customSelect(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' "
        "AND name = 'sync_outbox'",
      )
      .getSingleOrNull();
  if (outbox != null) await markSyncDirty(db);
}

/// v50 -> v51: encryption is one setting for all of an account's phones.
/// `encryption_at` is when this phone's setting was chosen (here, or on the
/// phone it was taken from); the newest choice among the phones wins. A
/// newer choice of encryption this phone has no key for waits in
/// `peer_encryption` (chosen at `peer_encryption_at`) until its PIN is
/// entered.
Future<void> upgradeSyncSchemaToV51(GeneratedDatabase db) async {
  final state = {
    for (final row
        in await db.customSelect('PRAGMA table_info(sync_state)').get())
      row.read<String>('name'),
  };
  if (state.isEmpty) return;
  for (final (column, type) in const [
    ('encryption_at', 'INTEGER NOT NULL DEFAULT 0'),
    ('peer_encryption', 'TEXT'),
    ('peer_encryption_at', 'INTEGER NOT NULL DEFAULT 0'),
  ]) {
    if (!state.contains(column)) {
      await db.customStatement(
        'ALTER TABLE sync_state ADD COLUMN $column $type',
      );
    }
  }
}

/// Makes the next sync upload every section of this phone's data, even with
/// no edits queued (a new account, a restore, changed encryption): the
/// queue's '' row asks for it.
Future<void> markSyncDirty(GeneratedDatabase db) async {
  await db.customStatement(
    'UPDATE sync_state SET revision = revision + 1 WHERE id = 1',
  );
  await db.customStatement('''INSERT OR REPLACE INTO sync_outbox
      (table_name, record_key, row_json, revision, hlc)
    SELECT '', '[]', NULL, revision, 0 FROM sync_state WHERE id = 1''');
}

/// (Re)creates [table]'s history triggers; like [createSyncTriggers], rerun
/// after adding a column. Does nothing before the history table exists.
Future<void> createHistoryTriggers(GeneratedDatabase db, String table) async {
  final ready = await db
      .customSelect(
        "SELECT 1 FROM sqlite_master WHERE type = 'table' "
        "AND name = 'record_history'",
      )
      .getSingleOrNull();
  final columns = await db.customSelect('PRAGMA table_info($table)').get();
  if (ready == null || columns.isEmpty) return;
  final keyColumns = syncTables[table]!;
  String json(String alias) =>
      'json_object(${columns.map((c) {
        final name = c.read<String>('name');
        return "'$name', $alias.$name";
      }).join(', ')})';
  String key(String alias) =>
      'json_array(${keyColumns.map((c) => '$alias.$c').join(', ')})';
  for (final (operation, action, before, after, record) in [
    ('INSERT', 'added', 'NULL', json('NEW'), key('NEW')),
    ('UPDATE', 'edited', json('OLD'), json('NEW'), key('NEW')),
    ('DELETE', 'deleted', json('OLD'), 'NULL', key('OLD')),
  ]) {
    final trigger = 'history_${table}_${operation.toLowerCase()}';
    await db.customStatement('DROP TRIGGER IF EXISTS $trigger');
    await db.customStatement('''CREATE TRIGGER $trigger
      AFTER $operation ON $table
      WHEN (SELECT history_off FROM sync_state WHERE id = 1) = 0
        ${operation == 'UPDATE' ? 'AND $before IS NOT $after' : ''}
      BEGIN
        INSERT INTO record_history
          (at, table_name, record_key, action, before_json, after_json, device)
        SELECT $_unixMs, '$table', $record, '$action', $before, $after,
          history_device FROM sync_state WHERE id = 1;
      END''');
  }
}

/// The HLC of the latest change this device knows of per record, its own or
/// another device's, deletions included. A change from another device
/// applies only when it is newer than this.
Future<void> _createRowMeta(GeneratedDatabase db) =>
    db.customStatement('''CREATE TABLE IF NOT EXISTS sync_row_meta (
    table_name TEXT NOT NULL, record_key TEXT NOT NULL,
    hlc INTEGER NOT NULL,
    PRIMARY KEY(table_name, record_key)
  ) WITHOUT ROWID''');

/// How far this device has applied each other installation's mirror:
/// `applied` is the last batch sequence merged in. A mirror missing here is
/// read from its first batch. `sync_state.peers_baseline` = 1 means the
/// next pull first records every mirror already on Drive as fully applied
/// (this device started on its own data, so their past isn't merged in).
Future<void> _createPeers(GeneratedDatabase db) async {
  await db.customStatement('''CREATE TABLE IF NOT EXISTS sync_peers (
    mirror_id TEXT PRIMARY KEY, applied INTEGER NOT NULL
  ) WITHOUT ROWID''');
  // What sync did, newest last, for More › History. This phone only;
  // the latest few hundred entries are kept. `items` is a JSON list of what
  // arrived ({action, kind, label, amount, currency, digits}). `undo`, for
  // what arrived, is every record it changed as it was here before, and the
  // affected accounts' bases ({rows: [{t, k, b, h}], bases: {id: [before,
  // its hlc, after]}}); null when too big to keep or nothing to undo.
  await db.customStatement('''CREATE TABLE IF NOT EXISTS sync_activity (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    at INTEGER NOT NULL,
    kind TEXT NOT NULL,
    device TEXT,
    count INTEGER NOT NULL DEFAULT 0,
    items TEXT NOT NULL DEFAULT '[]',
    message TEXT,
    undo TEXT,
    undone INTEGER NOT NULL DEFAULT 0
  )''');
  // Each account's base (balance less what its transactions add) as last
  // known here, and the HLC of the change that set it. A transaction rewrites
  // its account's row without changing the base, so the base is versioned on
  // its own: only a newer opening balance, adjustment or bank-reported
  // balance replaces it.
  await db.customStatement('''CREATE TABLE IF NOT EXISTS sync_account_base (
    account_id INTEGER PRIMARY KEY, anchor INTEGER NOT NULL,
    hlc INTEGER NOT NULL
  )''');
}

/// SQL for what an account's transactions add to its balance, with the
/// account ID as its one parameter. A balance is its base (opening balance,
/// adjustments, balances banks report) plus this, so merging another phone's
/// transactions recomputes it instead of overwriting it.
const accountEffectSql = '''SELECT coalesce(sum(CASE
    WHEN t.account_id = p.a AND t.type = 'income' THEN t.amount_minor
    WHEN t.account_id = p.a THEN -t.amount_minor
    ELSE 0 END), 0)
  + coalesce(sum(CASE WHEN t.type = 'transfer' AND t.to_account_id = p.a
      THEN coalesce(t.to_amount_minor, t.amount_minor) ELSE 0 END), 0)
    AS effect,
  count(t.id) AS count
  FROM (SELECT ? AS a) p
  LEFT JOIN transactions t ON t.account_id = p.a OR t.to_account_id = p.a''';

/// v46 -> v47: device slots for [newRowId], the change clock, and per-record
/// versions. Runs before any other upgrade step that rebuilds triggers, as
/// those read these columns. A database may already carry some of them.
/// v47 -> v48: undo for what arrived from other phones. Databases from before
/// v47 make the activity log with these columns already.
Future<void> upgradeSyncSchemaToV48(GeneratedDatabase db) async {
  final columns = {
    for (final row
        in await db.customSelect('PRAGMA table_info(sync_activity)').get())
      row.read<String>('name'),
  };
  if (columns.isEmpty) return;
  if (!columns.contains('undo')) {
    await db.customStatement('ALTER TABLE sync_activity ADD COLUMN undo TEXT');
  }
  if (!columns.contains('undone')) {
    await db.customStatement(
      'ALTER TABLE sync_activity ADD COLUMN undone INTEGER NOT NULL DEFAULT 0',
    );
  }
}

Future<void> upgradeSyncSchemaToV47(GeneratedDatabase db) async {
  Future<void> add(String table, String column, String type) async {
    final exists = (await db.customSelect('PRAGMA table_info($table)').get())
        .any((row) => row.read<String>('name') == column);
    if (!exists) {
      await db.customStatement('ALTER TABLE $table ADD COLUMN $column $type');
    }
  }

  await add('sync_state', 'id_slot', 'INTEGER NOT NULL DEFAULT 0');
  await add('sync_state', 'clock', 'INTEGER NOT NULL DEFAULT 0');
  await add('sync_state', 'applying', 'INTEGER NOT NULL DEFAULT 0');
  await add('sync_state', 'changes_token', 'TEXT');
  await add('sync_state', 'peers_baseline', 'INTEGER NOT NULL DEFAULT 1');
  await add('sync_state', 'device_name', 'TEXT');
  await add('sync_outbox', 'hlc', 'INTEGER NOT NULL DEFAULT 0');
  await _createRowMeta(db);
  await _createPeers(db);
  await db.customStatement(
    '''UPDATE sync_state SET id_slot = $_randomSlot, applying = 0,
    clock = $_tick WHERE id = 1''',
  );
  // Edits made before this version and not uploaded yet are the newest this
  // device has; when exactly they happened was never recorded.
  await db.customStatement(
    'UPDATE sync_outbox SET hlc = (SELECT clock FROM sync_state WHERE id = 1) '
    'WHERE hlc = 0',
  );
  await db.customStatement('''INSERT OR REPLACE INTO sync_row_meta
    SELECT table_name, record_key, hlc FROM sync_outbox''');
}

/// A new installation of an OS-restored database: another device may
/// already use the slot this one came with.
Future<void> newDeviceSlot(GeneratedDatabase db) => db.customStatement(
  'UPDATE sync_state SET id_slot = $_randomSlot WHERE id = 1',
);

/// (Re)creates [table]'s change triggers. They copy the columns it has now,
/// so rerun this after adding a column to a synced table.
///
/// While `sync_state.applying` is set, the ledger is being written from
/// another device's changes (or a restore); those are not this device's
/// edits, so they are neither queued for upload nor restamped.
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
  // Delete, then a plain insert, rather than INSERT OR REPLACE: SQLite runs a
  // trigger's statements with the conflict handling of the statement that
  // fired it, so an `INSERT … ON CONFLICT DO UPDATE` on a synced table would
  // turn OR REPLACE into a failure here. A plain insert can't conflict.
  String queue(String recordKey, String row, {String where = ''}) =>
      '''DELETE FROM sync_outbox
        WHERE table_name = '$table' AND record_key = $recordKey $where;
      INSERT INTO sync_outbox
          (table_name, record_key, row_json, revision, hlc)
        SELECT '$table', $recordKey, $row, revision, clock FROM sync_state
        WHERE id = 1 $where;
      DELETE FROM sync_row_meta
        WHERE table_name = '$table' AND record_key = $recordKey $where;
      INSERT INTO sync_row_meta (table_name, record_key, hlc)
        SELECT '$table', $recordKey, clock FROM sync_state
        WHERE id = 1 $where;''';
  for (final operation in ['INSERT', 'UPDATE', 'DELETE']) {
    final deleted = operation == 'DELETE';
    final trigger = 'sync_${table}_${operation.toLowerCase()}';
    await db.customStatement('DROP TRIGGER IF EXISTS $trigger');
    // Coalesce repeated offline edits, but never discard a deletion marker.
    // These writes commit or roll back together with the ledger mutation.
    await db.customStatement('''CREATE TRIGGER $trigger
      AFTER $operation ON $table
      WHEN (SELECT applying FROM sync_state WHERE id = 1) = 0 BEGIN
        UPDATE sync_state SET revision = revision + 1, clock = $_tick
          WHERE id = 1;
        ${operation == 'UPDATE' ? queue(key('OLD'), 'NULL', where: "AND ${key('OLD')} != ${key('NEW')}") : ''}
        ${queue(key(deleted ? 'OLD' : 'NEW'), deleted ? 'NULL' : json)}
      END''');
  }
  if (historyTables.contains(table)) await createHistoryTriggers(db, table);
}

/// Queue a consistent initial copy when opting in or changing Google accounts.
/// Each row keeps the version this device knows it at (0 when it never
/// changed since v47). Call within the caller's database transaction.
Future<void> seedSyncOutbox(
  GeneratedDatabase db, {
  Iterable<String>? tables,
}) async {
  for (final entry in syncTables.entries) {
    if (tables != null && !tables.contains(entry.key)) continue;
    final table = entry.key;
    final columns = await db.customSelect('PRAGMA table_info($table)').get();
    final json = columns
        .map((c) {
          final name = c.read<String>('name');
          return "'$name', $table.$name";
        })
        .join(', ');
    final key = 'json_array(${entry.value.map((c) => '$table.$c').join(', ')})';
    await db.customStatement(
      'UPDATE sync_state SET revision = revision + 1 WHERE id = 1',
    );
    await db.customStatement('''INSERT OR REPLACE INTO sync_outbox
        (table_name, record_key, row_json, revision, hlc)
      SELECT '$table', $key, json_object($json),
        (SELECT revision FROM sync_state WHERE id = 1),
        coalesce((SELECT hlc FROM sync_row_meta m
          WHERE m.table_name = '$table' AND m.record_key = $key), 0)
      FROM $table''');
  }
}
