import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../db/app_database.dart';
import 'sync_restore.dart';
import 'sync_schema.dart';

String newSyncId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

class SyncStatus {
  const SyncStatus({
    required this.enabled,
    required this.pending,
    this.email,
    this.displayName,
    this.pictureUrl,
    this.lastSynced,
    this.error,
    this.retryAt = 0,
    this.busy = false,
  });
  final bool enabled, busy;
  final int pending, retryAt;
  final String? email, displayName, pictureUrl, error;
  final DateTime? lastSynced;

  @override
  bool operator ==(Object other) =>
      other is SyncStatus &&
      enabled == other.enabled &&
      busy == other.busy &&
      pending == other.pending &&
      retryAt == other.retryAt &&
      email == other.email &&
      displayName == other.displayName &&
      pictureUrl == other.pictureUrl &&
      error == other.error &&
      lastSynced == other.lastSynced;

  @override
  int get hashCode => Object.hash(
    enabled,
    busy,
    pending,
    retryAt,
    email,
    displayName,
    pictureUrl,
    error,
    lastSynced,
  );
}

class SyncBatch {
  const SyncBatch({
    required this.fileId,
    required this.mirrorId,
    required this.sequence,
    required this.revision,
    required this.payload,
    required this.checksum,
  });
  final String fileId, mirrorId, checksum;
  final int sequence, revision;
  final Uint8List payload;
  factory SyncBatch.fromRow(QueryRow row) => SyncBatch(
    fileId: row.read<String>('file_id'),
    mirrorId: row.read<String>('mirror_id'),
    sequence: row.read<int>('sequence'),
    revision: row.read<int>('revision'),
    payload: row.read<Uint8List>('payload'),
    checksum: row.read<String>('checksum'),
  );
}

class SyncRepository {
  SyncRepository(this.db);
  final AppDatabase db;
  int get _now => DateTime.now().millisecondsSinceEpoch;

  Future<void> bindInstallation(
    String installationId,
  ) => db.transaction(() async {
    final state = await db
        .customSelect('SELECT installation_id FROM sync_state WHERE id = 1')
        .getSingle();
    final previous = state.readNullable<String>('installation_id');
    if (previous == installationId) return;
    if (previous != null) {
      // An OS-restored database belongs to a different installation. Never let
      // two devices append different batches to the same mirror sequence.
      await db.customStatement('DELETE FROM sync_batch');
      await db.customStatement('DELETE FROM sync_outbox');
      await db.customStatement(
        '''UPDATE sync_state SET enabled = 0, mirror_id = ?,
        next_sequence = 1, last_synced = NULL, error = NULL, retry_at = 0,
        failures = 0, lease = NULL, lease_until = 0 WHERE id = 1''',
        [newSyncId()],
      );
      await seedSyncOutbox(db);
    }
    await db.customStatement(
      'UPDATE sync_state SET installation_id = ? WHERE id = 1',
      [installationId],
    );
  });

  Future<SyncStatus> status() async {
    final row = await db.customSelect('''SELECT *,
      (SELECT COUNT(*) FROM sync_outbox) AS pending
      FROM sync_state WHERE id = 1''').getSingle();
    final last = row.readNullable<int>('last_synced');
    return SyncStatus(
      enabled: row.read<int>('enabled') == 1,
      pending: row.read<int>('pending'),
      email: row.readNullable<String>('email'),
      displayName: row.readNullable<String>('display_name'),
      pictureUrl: row.readNullable<String>('picture_url'),
      lastSynced: last == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(last),
      error: row.readNullable<String>('error'),
      retryAt: row.read<int>('retry_at'),
      busy: row.read<int>('lease_until') > _now,
    );
  }

  Future<String> mirrorId() async =>
      (await db
              .customSelect('SELECT mirror_id FROM sync_state WHERE id = 1')
              .getSingle())
          .read<String>('mirror_id');

  /// Whether the user has entered anything; default categories don't count.
  Future<bool> hasLedgerData() async =>
      (await db.customSelect(
        '''SELECT EXISTS(SELECT 1 FROM accounts)
            OR EXISTS(SELECT 1 FROM transactions)
            OR EXISTS(SELECT 1 FROM budgets) AS present''',
      ).getSingle()).read<int>('present') ==
      1;

  /// True when this database was not already linked to [subject], i.e. it
  /// starts a new mirror — the moment to offer an existing backup.
  Future<bool> connect(
    String email,
    String subject, {
    String? displayName,
    String? pictureUrl,
  }) => db.transaction(() async {
    final state = await db
        .customSelect('SELECT * FROM sync_state WHERE id = 1')
        .getSingle();
    if (state.read<int>('lease_until') > _now) {
      throw StateError('An upload is finishing. Try again shortly.');
    }
    final linked = state.readNullable<String>('subject') != subject;
    if (linked) {
      await db.customStatement('DELETE FROM sync_batch');
      await db.customStatement('DELETE FROM sync_outbox');
      await db.customStatement(
        '''UPDATE sync_state SET mirror_id = ?,
        next_sequence = 1, last_synced = NULL WHERE id = 1''',
        [newSyncId()],
      );
      await seedSyncOutbox(db);
    }
    await db.customStatement(
      '''UPDATE sync_state SET enabled = 1, email = ?, subject = ?,
      display_name = ?, picture_url = ?, error = NULL, failures = 0,
      retry_at = 0 WHERE id = 1''',
      [email, subject, displayName, pictureUrl],
    );
    return linked;
  });

  /// Replaces the ledger with [backup] (a restore, an imported file, or
  /// nothing plus [defaultCategories] for a wipe) and starts a new mirror
  /// whose first batch is the result, so this device never appends to a chain
  /// it didn't write. [owner] must hold the upload lease.
  Future<void> replaceLedger(
    String owner,
    SyncBackup backup, {
    bool defaultCategories = false,
  }) => db.transaction(() async {
    if (backup.schemaVersion > db.schemaVersion) {
      throw StateError('Update SimpleMoney to use this data.');
    }
    final state = await db
        .customSelect('SELECT lease FROM sync_state WHERE id = 1')
        .getSingle();
    if (state.readNullable<String>('lease') != owner) {
      throw StateError('An upload is finishing. Try again shortly.');
    }
    // Drafts refer to local account/category IDs, which a restore replaces.
    await db.customStatement('DELETE FROM pending_upi_payments');
    await db.customStatement('DELETE FROM sms_scan_queue');
    await db.customStatement('DELETE FROM agent_suggestions');
    // Restored account IDs can refer to different accounts on this device.
    // sms_account_links is synced, so the backup's own links replace these.
    await db.customStatement('DELETE FROM sms_balances');
    await db.customStatement('DELETE FROM sms_credit_limits');
    await db.customStatement('DELETE FROM sms_total_credit_limits');
    await db.customStatement('DELETE FROM sms_detected_accounts');
    await db.customStatement('UPDATE sms_imports SET transaction_id=NULL');
    if (defaultCategories) {
      // A device wipe also removes inbox-derived data and its opt-in.
      await db.customStatement('DELETE FROM sms_imports');
      await db.customStatement('DELETE FROM user_sms_rules');
      await db.customStatement(
        'UPDATE sms_import_state SET enabled=0, scanned_at=0 WHERE id=1',
      );
    }
    for (final table in syncTables.keys) {
      await db.customStatement('DELETE FROM $table');
    }
    for (final MapEntry(key: table, value: rows) in backup.tables.entries) {
      // Older backups may lack newer columns (left at their defaults);
      // unknown ones are dropped.
      final columns = {
        for (final column
            in await db.customSelect('PRAGMA table_info($table)').get())
          column.read<String>('name'),
      };
      for (final row in rows) {
        final values = {
          for (final MapEntry(:key, :value) in row.entries)
            if (columns.contains(key)) key: value,
        };
        await db.customStatement(
          'INSERT INTO $table (${values.keys.join(', ')}) '
          'VALUES (${List.filled(values.length, '?').join(', ')})',
          values.values.toList(),
        );
      }
    }
    // Messages the backup already saved or dismissed stay that way, so the
    // next scan of this inbox skips them instead of saving them again.
    await db.customStatement(
      '''INSERT INTO sms_imports (fingerprint, sender, body, received_at,
          candidate, rule_id, pack_version, status, transaction_id)
        SELECT fingerprint, sender, NULL, received_at,
          json_object('notificationKey', notification_key,
            'isCreditCard', credit_card),
          rule_id, pack_version, status, transaction_id
        FROM sms_history WHERE true
        ON CONFLICT(fingerprint) DO UPDATE SET status = excluded.status,
          transaction_id = excluded.transaction_id, body = NULL,
          candidate = excluded.candidate''',
    );
    if (defaultCategories) await db.seedDefaultCategories();
    await _restartMirror();
  });

  /// A new mirror whose first batch is everything on this phone — needed
  /// once the old mirror's files were deleted from Drive.
  Future<void> restartMirror() => db.transaction(_restartMirror);

  Future<void> _restartMirror() async {
    await db.customStatement('DELETE FROM sync_batch');
    await db.customStatement('DELETE FROM sync_outbox');
    await db.customStatement(
      '''UPDATE sync_state SET mirror_id = ?, next_sequence = 1,
      last_synced = NULL, error = NULL, retry_at = 0, failures = 0
      WHERE id = 1''',
      [newSyncId()],
    );
    await seedSyncOutbox(db);
  }

  /// Stamps "now" as the last synced time even when nothing was pending to
  /// upload — a manual Sync now still confirms this device is up to date.
  Future<void> touchLastSynced() => db.customStatement(
    'UPDATE sync_state SET last_synced = ? WHERE id = 1 AND enabled = 1',
    [_now],
  );

  Future<void> updateProfile(
    String email, {
    String? displayName,
    String? pictureUrl,
  }) => db.customStatement(
    '''UPDATE sync_state SET display_name = ?, picture_url = ?
    WHERE id = 1 AND enabled = 1 AND email = ?''',
    [displayName, pictureUrl, email],
  );

  Future<void> disconnect() => db.customStatement(
    'UPDATE sync_state SET enabled = 0, error = NULL WHERE id = 1',
  );

  /// Turns sync off and forgets the connected account, so the next connect
  /// starts fresh (account picker, new mirror) even for the same Google
  /// account. Data already on this phone and in Drive is untouched.
  Future<void> signOut() => db.customStatement(
    '''UPDATE sync_state SET enabled = 0, email = NULL, subject = NULL,
    display_name = NULL, picture_url = NULL, error = NULL WHERE id = 1''',
  );

  /// A persisted lease serializes foreground and WorkManager isolates. A killed
  /// process releases ownership by expiry; its immutable batch survives.
  /// [requireEnabled] false lets data management own the ledger while sync
  /// is off, still waiting out an upload that was already in flight.
  Future<bool> acquire(
    String owner, {
    bool force = false,
    bool requireEnabled = true,
  }) async =>
      await db.customUpdate(
        '''UPDATE sync_state SET lease = ?, lease_until = ?
        WHERE id = 1 ${requireEnabled ? 'AND enabled = 1' : ''}
        AND lease_until <= ?
        ${force ? '' : 'AND retry_at <= $_now'}''',
        variables: [Variable(owner), Variable(_now + 120000), Variable(_now)],
      ) ==
      1;

  Future<bool> renew(String owner) async =>
      await db.customUpdate(
        '''UPDATE sync_state SET lease_until = ?
      WHERE id = 1 AND lease = ? AND enabled = 1''',
        variables: [Variable(_now + 120000), Variable(owner)],
      ) ==
      1;

  Future<void> release(String owner) => db.customStatement(
    'UPDATE sync_state SET lease = NULL, lease_until = 0 WHERE lease = ?',
    [owner],
  );

  Future<SyncBatch?> pendingBatch() async {
    final row = await db
        .customSelect('SELECT * FROM sync_batch WHERE id = 1')
        .getSingleOrNull();
    return row == null ? null : SyncBatch.fromRow(row);
  }

  Future<SyncBatch?> freeze(String owner, String fileId) =>
      db.transaction(() async {
        final state = await db
            .customSelect('SELECT * FROM sync_state WHERE id = 1')
            .getSingle();
        if (state.readNullable<String>('lease') != owner ||
            state.read<int>('enabled') != 1) {
          return null;
        }
        final existing = await pendingBatch();
        if (existing != null) return existing;
        final rows = await db
            .customSelect(
              'SELECT * FROM sync_outbox ORDER BY table_name, record_key',
            )
            .get();
        if (rows.isEmpty) return null;
        final mirrorId = state.read<String>('mirror_id');
        final sequence = state.read<int>('next_sequence');
        final revision = state.read<int>('revision');
        final bytes = Uint8List.fromList(
          gzip.encode(
            utf8.encode(
              jsonEncode({
                'format': 'simple-money-mirror',
                'formatVersion': 1,
                'schemaVersion': db.schemaVersion,
                'mirrorId': mirrorId,
                'sequence': sequence,
                'previousSequence': sequence - 1,
                'createdAt': DateTime.now().toUtc().toIso8601String(),
                'changes': rows
                    .map(
                      (row) => {
                        'table': row.read<String>('table_name'),
                        'key': jsonDecode(row.read<String>('record_key')),
                        'row': row.readNullable<String>('row_json') == null
                            ? null
                            : jsonDecode(row.read<String>('row_json')),
                      },
                    )
                    .toList(),
              }),
            ),
          ),
        );
        final checksum = md5.convert(bytes).toString();
        await db.customStatement(
          '''INSERT INTO sync_batch
      (id, file_id, mirror_id, sequence, revision, payload, checksum)
      VALUES (1, ?, ?, ?, ?, ?, ?)''',
          [fileId, mirrorId, sequence, revision, bytes, checksum],
        );
        return SyncBatch(
          fileId: fileId,
          mirrorId: mirrorId,
          sequence: sequence,
          revision: revision,
          payload: bytes,
          checksum: checksum,
        );
      });

  Future<void> acknowledge(String owner, SyncBatch batch) =>
      db.transaction(() async {
        final state = await db
            .customSelect('SELECT * FROM sync_state WHERE id = 1')
            .getSingle();
        if (state.readNullable<String>('lease') != owner ||
            state.read<String>('mirror_id') != batch.mirrorId) {
          return;
        }
        // A row edited during upload has a higher revision and stays queued.
        await db.customStatement(
          'DELETE FROM sync_outbox WHERE revision <= ?',
          [batch.revision],
        );
        await db.customStatement('DELETE FROM sync_batch WHERE file_id = ?', [
          batch.fileId,
        ]);
        await db.customStatement(
          '''UPDATE sync_state SET next_sequence = ?,
      last_synced = ?, failures = 0, retry_at = 0, error = NULL WHERE id = 1''',
          [batch.sequence + 1, _now],
        );
      });

  Future<void> failed(String owner, String message) => db.transaction(() async {
    final state = await db
        .customSelect(
          'SELECT failures FROM sync_state WHERE lease = ?',
          variables: [Variable(owner)],
        )
        .getSingleOrNull();
    if (state == null) return;
    final failures = min(state.read<int>('failures') + 1, 10);
    final delay = min(30 * (1 << (failures - 1)), 3600) + Random().nextInt(15);
    await db.customStatement(
      '''UPDATE sync_state SET failures = ?, error = ?,
      retry_at = ? WHERE lease = ?''',
      [failures, message, _now + delay * 1000, owner],
    );
  });
}
