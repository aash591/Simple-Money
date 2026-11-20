import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';

import '../db/app_database.dart';
import 'sync_restore.dart';
import 'sync_activity.dart';
import 'backup_encryption.dart';
import 'sync_schema.dart';
import 'sync_sections.dart';

/// An upload lease's owner: this process's ID, then a random part. The app
/// runs in one process, so a lease held by another process ID was left by
/// one that's gone (e.g. the app swiped away mid-upload) and is taken over
/// at once rather than after it expires.
String newLeaseOwner() => '$pid:${newSyncId()}';

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
    this.encryption,
    this.restorePending = false,
    this.peerEncryption,
  });
  final bool enabled, busy;
  final bool restorePending;
  final BackupEncryption? encryption;

  /// The account's other phones chose this encryption, and this phone
  /// doesn't have its PIN yet: their files can't be read until it's entered.
  final BackupEncryption? peerEncryption;
  final int pending, retryAt;
  final String? email, displayName, pictureUrl, error;
  final DateTime? lastSynced;

  @override
  bool operator ==(Object other) =>
      other is SyncStatus &&
      enabled == other.enabled &&
      busy == other.busy &&
      encryption == other.encryption &&
      peerEncryption == other.peerEncryption &&
      restorePending == other.restorePending &&
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
    encryption,
    peerEncryption,
    restorePending,
    pending,
    retryAt,
    email,
    displayName,
    pictureUrl,
    error,
    lastSynced,
  );
}

/// One file to upload: a section of this phone's data (see
/// sync_sections.dart), already encoded.
class SyncBatch {
  const SyncBatch({
    required this.fileId,
    required this.mirrorId,
    required this.sequence,
    required this.payload,
    required this.checksum,
    this.revision = 0,
    this.replace = false,
    this.section = '',
    this.rows = 0,
    this.newest = 0,
    this.encryption = 'off',
    this.encryptionAt = 0,
  });
  final String fileId, mirrorId, checksum;
  final int sequence, revision;
  final Uint8List payload;

  /// The file already exists on Drive: the upload replaces its content.
  final bool replace;
  final String section;

  /// How many records it holds.
  final int rows;

  /// The newest version among its records. A phone's own edits are always
  /// newer than anything it holds, so an upload whose newest is no higher
  /// than before carries nothing new (a day folded into its month, a
  /// restore, new encryption): the other phones can skip it unread.
  final int newest;

  /// The uploading phone's encryption setting (see [encryptionFingerprint])
  /// and when it was chosen: the other phones follow the newest choice.
  final String encryption;
  final int encryptionAt;
}

/// What one upload sends (see SyncRepository.uploadPlan).
class UploadPlan {
  const UploadPlan({
    required this.sections,
    required this.retire,
    required this.revision,
    required this.changes,
  });

  /// The sections to upload, small tables first.
  final List<String> sections;

  /// Day files of an earlier day, by section, to delete once their month
  /// is up: their file IDs.
  final Map<String, String> retire;

  /// Queued edits up to this revision are in it.
  final int revision;

  /// How many edits it carries, for the activity log.
  final int changes;
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
        failures = 0, lease = NULL, lease_until = 0, restore_pending = 1,
        drive_file_id = NULL, list_cursor = NULL WHERE id = 1''',
        [newSyncId()],
      );
      // The old phone may still be creating rows with the slot it came with.
      await newDeviceSlot(db);
      await _forgetPeers();
      await db.customStatement('DELETE FROM sync_files');
      await markSyncDirty(db);
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
      restorePending: row.read<int>('restore_pending') == 1,
      encryption: _encryption(row.readNullable<String>('encryption_config')),
      peerEncryption: _encryption(row.readNullable<String>('peer_encryption')),
    );
  }

  static BackupEncryption? _encryption(String? encoded) => encoded == null
      ? null
      : BackupEncryption.fromJson(jsonDecode(encoded) as Map<String, dynamic>);

  Future<String?> subject() async =>
      (await db
              .customSelect('SELECT subject FROM sync_state WHERE id = 1')
              .getSingle())
          .readNullable<String>('subject');

  Future<void> holdUploads(bool hold) => db.customStatement(
    'UPDATE sync_state SET restore_pending = ? WHERE id = 1',
    [hold ? 1 : 0],
  );

  /// Sets this phone's encryption to [configuration] (null: off) and uploads
  /// everything again with it. [at] is when the choice was made: now, for a
  /// choice made here, or the other phone's time when following its choice.
  Future<void> changeEncryption(
    String owner,
    BackupEncryption? configuration, {
    int? at,
  }) => db.transaction(() async {
    final row = await db
        .customSelect(
          'SELECT lease, restore_pending FROM sync_state WHERE id = 1',
        )
        .getSingle();
    if (row.readNullable<String>('lease') != owner ||
        row.read<int>('restore_pending') != 0) {
      throw StateError(
        'Finish restoring your backup before changing encryption.',
      );
    }
    await db.customStatement(
      'UPDATE sync_state SET encryption_config = ?, encryption_at = ?, '
      'peer_encryption = NULL, peer_encryption_at = 0 WHERE id = 1',
      [configuration?.encoded, at ?? _now],
    );
    await _reupload();
  });

  /// When this phone's encryption was chosen (see [changeEncryption]).
  Future<int> encryptionAt() async =>
      (await db
              .customSelect('SELECT encryption_at FROM sync_state WHERE id = 1')
              .getSingle())
          .read<int>('encryption_at');

  /// The same encryption, chosen at [at] on the phone it came from.
  Future<void> setEncryptionAt(int at) => db.customStatement(
    'UPDATE sync_state SET encryption_at = ? WHERE id = 1',
    [at],
  );

  /// The other phones' newer choice of encryption this phone can't use yet.
  Future<({BackupEncryption config, int at})?> peerEncryption() async {
    final row = await db
        .customSelect(
          'SELECT peer_encryption, peer_encryption_at FROM sync_state '
          'WHERE id = 1',
        )
        .getSingle();
    final config = _encryption(row.readNullable<String>('peer_encryption'));
    return config == null
        ? null
        : (config: config, at: row.read<int>('peer_encryption_at'));
  }

  Future<void> setPeerEncryption(BackupEncryption? config, {int at = 0}) =>
      db.customStatement(
        'UPDATE sync_state SET peer_encryption = ?, peer_encryption_at = ? '
        'WHERE id = 1',
        [config?.encoded, at],
      );

  Future<void> resumeUploads(String owner, BackupEncryption? configuration) =>
      db.transaction(() async {
        final row = await db
            .customSelect(
              'SELECT lease, encryption_config FROM sync_state WHERE id = 1',
            )
            .getSingle();
        if (row.readNullable<String>('lease') != owner) {
          throw StateError('Sync is busy. Try again.');
        }
        if (configuration != null &&
            row.readNullable<String>('encryption_config') !=
                configuration.encoded) {
          await db.customStatement(
            'UPDATE sync_state SET encryption_config = ? WHERE id = 1',
            [configuration.encoded],
          );
          await _reupload();
        }
        await db.customStatement(
          'UPDATE sync_state SET restore_pending = 0 WHERE id = 1',
        );
      });

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
    bool holdUploads = false,
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
        next_sequence = 1, last_synced = NULL, encryption_config = NULL,
        drive_file_id = NULL, list_cursor = NULL WHERE id = 1''',
        [newSyncId()],
      );
      await _forgetPeers();
      await db.customStatement('DELETE FROM sync_files');
      await markSyncDirty(db);
    }
    await db.customStatement(
      '''UPDATE sync_state SET enabled = 1, email = ?, subject = ?,
      display_name = ?, picture_url = ?, error = NULL, failures = 0,
      retry_at = 0, restore_pending = ? WHERE id = 1''',
      [email, subject, displayName, pictureUrl, holdUploads ? 1 : 0],
    );
    await logActivity(SyncActivityKind.connected, message: email);
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
    // These rows are the backup's, not edits made now: keep the triggers
    // from stamping them, and record the versions the backup carries instead.
    // Rolled back with everything else if the restore fails.
    await db.customStatement(
      'UPDATE sync_state SET applying = 1, history_off = 1 WHERE id = 1',
    );
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
    // schemaVersion 0 is a wipe, which clears everything.
    bool carried(String table) =>
        backup.schemaVersion == 0 ||
        backup.schemaVersion >= (syncTableSince[table] ?? 0);
    for (final table in syncTables.keys) {
      if (!carried(table)) continue;
      await db.customStatement('DELETE FROM $table');
      await db.customStatement(
        'DELETE FROM sync_row_meta WHERE table_name = ?',
        [table],
      );
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
    if (backup.encryption != null) {
      await db.customStatement(
        'UPDATE sync_state SET encryption_config = ? WHERE id = 1',
        [backup.encryption!.encoded],
      );
    }
    if (defaultCategories) await db.seedDefaultCategories();
    var newest = 0;
    for (final MapEntry(key: table, value: versions)
        in backup.versions.entries) {
      if (!syncTables.containsKey(table)) continue;
      for (final MapEntry(key: recordKey, value: hlc) in versions.entries) {
        newest = max(newest, hlc);
        await db.customStatement(
          'INSERT OR REPLACE INTO sync_row_meta VALUES (?, ?, ?)',
          [table, recordKey, hlc],
        );
      }
    }
    // Changes made here from now on must come after everything restored.
    await db.customStatement(
      'UPDATE sync_state SET applying = 0, history_off = 0, '
      'clock = max(clock, ?) WHERE id = 1',
      [newest],
    );
    // Every phone's file is merged again from the start; records this
    // phone now has at the same or a newer version are skipped.
    await _forgetPeers();
    await db.customStatement('DELETE FROM sync_account_base');
    for (final MapEntry(key: id, value: base) in backup.bases.entries) {
      await db.customStatement(
        'INSERT OR REPLACE INTO sync_account_base VALUES (?, ?, ?)',
        [id, base.$1, base.$2],
      );
    }
    await logActivity(
      backup.schemaVersion == 0
          ? SyncActivityKind.erased
          : backup.fromDrive
          ? SyncActivityKind.restored
          : SyncActivityKind.imported,
      count: backup.count('transactions'),
    );
    await _reupload();
  });

  /// Uploads this phone's file again in full, e.g. after it was deleted from
  /// Drive. Each upload holds everything, so this only queues one.
  Future<void> restartMirror() => db.transaction(_reupload);

  Future<void> _reupload() async {
    // A file frozen before (e.g. with other encryption) is not sent.
    await db.customStatement('DELETE FROM sync_batch');
    await db.customStatement(
      '''UPDATE sync_state SET last_synced = NULL, error = NULL, retry_at = 0,
      failures = 0 WHERE id = 1''',
    );
    await markSyncDirty(db);
  }

  /// Forgets this phone's files on Drive (they were deleted): the next
  /// upload makes them again.
  Future<void> forgetFiles() => db.transaction(() async {
    await db.customStatement('DELETE FROM sync_files');
    await db.customStatement(
      'UPDATE sync_state SET list_cursor = NULL WHERE id = 1',
    );
  });

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

  Future<void> disconnect() => db.transaction(() async {
    await db.customStatement(
      'UPDATE sync_state SET enabled = 0, error = NULL WHERE id = 1',
    );
    await logActivity(SyncActivityKind.paused);
  });

  /// Turns sync off and forgets the connected account, so the next connect
  /// starts fresh (account picker, new mirror) even for the same Google
  /// account. Data already on this phone and in Drive is untouched.
  Future<void> signOut() => db.transaction(() async {
    await db.customStatement(
      '''UPDATE sync_state SET enabled = 0, email = NULL, subject = NULL,
    display_name = NULL, picture_url = NULL, error = NULL, restore_pending = 0, encryption_config = NULL WHERE id = 1''',
    );
    await _forgetPeers();
    await logActivity(SyncActivityKind.paused, message: 'Signed out');
  });

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
        WHERE id = 1 ${requireEnabled ? 'AND enabled = 1 AND restore_pending = 0' : ''}
        AND (lease_until <= ? OR lease IS NULL
          OR (lease GLOB '[0-9]*:*' AND lease NOT LIKE ?))
        ${force ? '' : 'AND retry_at <= $_now'}''',
        variables: [
          Variable(owner),
          Variable(_now + 120000),
          Variable(_now),
          Variable('$pid:%'),
        ],
      ) ==
      1;

  Future<bool> renew(String owner) async =>
      await db.customUpdate(
        '''UPDATE sync_state SET lease_until = ?
      WHERE id = 1 AND lease = ? AND enabled = 1 AND restore_pending = 0''',
        variables: [Variable(_now + 120000), Variable(owner)],
      ) ==
      1;

  Future<void> release(String owner) => db.customStatement(
    'UPDATE sync_state SET lease = NULL, lease_until = 0 WHERE lease = ?',
    [owner],
  );

  // ---- Uploading this phone's sections -------------------------------------

  static String _month(String ms) => "strftime('%Y-%m', $ms / 1000, 'unixepoch')";
  static String _day(String ms) =>
      "strftime('%Y-%m-%d', $ms / 1000, 'unixepoch')";
  static String _keyOf(String table, [String alias = 't']) =>
      'json_array(${syncTables[table]!.map((c) => '$alias.$c').join(', ')})';

  /// What the next upload has to send: the sections whose records changed
  /// since the last one (all of them after a restore, a new account or new
  /// encryption), and day files from an earlier day, whose records now
  /// belong in their month. Null when nothing is waiting.
  Future<UploadPlan?> uploadPlan() => db.transaction(() async {
    final queued = await db
        .customSelect('SELECT table_name, row_json, hlc FROM sync_outbox')
        .get();
    if (queued.isEmpty) return null;
    final revision = (await db
            .customSelect('SELECT revision FROM sync_state WHERE id = 1')
            .getSingle())
        .read<int>('revision');
    final now = DateTime.now().toUtc();
    final sections = <String>{};
    var changes = 0;
    for (final change in queued) {
      final table = change.read<String>('table_name');
      if (table == '') {
        sections.addAll(await _allSections(now));
        continue;
      }
      if (!syncTables.containsKey(table)) continue;
      changes++;
      final json = change.readNullable<String>('row_json');
      sections.add(
        sectionOf(
          table,
          json == null ? null : Map<String, Object?>.from(jsonDecode(json) as Map),
          change.read<int>('hlc'),
          now,
        ),
      );
    }
    final today = dayOf(now.millisecondsSinceEpoch);
    final retire = <String, String>{};
    for (final file in await db
        .customSelect('SELECT section, file_id FROM sync_files')
        .get()) {
      final section = file.read<String>('section');
      final day = sectionDay(section);
      if (day == null || day == today) continue;
      sections.add(monthSectionOfDay(section));
      retire[section] = file.read<String>('file_id');
    }
    sections.removeAll(retire.keys);
    return UploadPlan(
      sections: sections.toList()..sort(compareSections),
      retire: retire,
      revision: revision,
      changes: changes,
    );
  });

  /// Every section this phone's data has now.
  Future<Set<String>> _allSections(DateTime now) async {
    final today = dayOf(now.millisecondsSinceEpoch);
    final sections = <String>{};
    for (final table in syncTables.keys) {
      final column = sectionedTables[table];
      if (column == null) {
        sections.add(table);
        continue;
      }
      for (final row in await db
          .customSelect(
            'SELECT DISTINCT CASE WHEN ${_day(column)} = ? '
            'THEN ${_day(column)} ELSE ${_month(column)} END AS s FROM $table',
            variables: [Variable(today)],
          )
          .get()) {
        sections.add('$table/${row.read<String>('s')}');
      }
      for (final row in await db
          .customSelect(
            'SELECT DISTINCT ${_month('(hlc >> 16)')} AS s FROM sync_row_meta '
            'WHERE table_name = ? AND record_key NOT IN '
            '(SELECT ${_keyOf(table)} FROM $table t)',
            variables: [Variable(table)],
          )
          .get()) {
        sections.add('$table/deleted/${row.read<String>('s')}');
      }
    }
    return sections;
  }

  /// The next upload number; each file this phone uploads gets its own, so
  /// the other phones can tell which files changed since they last merged.
  Future<int> nextSequence() => db.transaction(() async {
    final sequence = (await db
            .customSelect('SELECT next_sequence FROM sync_state WHERE id = 1')
            .getSingle())
        .read<int>('next_sequence');
    await db.customStatement(
      'UPDATE sync_state SET next_sequence = ? WHERE id = 1',
      [sequence + 1],
    );
    return sequence;
  });

  /// [section] of this phone's data as it is now, gzip JSON: its records,
  /// their versions (deletions included) and, for accounts, each base.
  Future<({Uint8List bytes, int rows, bool empty, int newest})> buildSection(
    String section,
    int sequence,
  ) => db.transaction(() async {
    final state = await db
        .customSelect(
          'SELECT mirror_id, device_name FROM sync_state WHERE id = 1',
        )
        .getSingle();
    final parts = section.split('/');
    final table = parts.first;
    if (!isKnownSection(section)) throw ArgumentError(section);
    final key = _keyOf(table);
    final rows = <Map<String, Object?>>[];
    final versions = <String, int>{};
    final bases = <String, List<int>>{};
    final today = dayOf(DateTime.now().millisecondsSinceEpoch);

    Future<void> live(String where, List<Object?> args) async {
      for (final row in await db
          .customSelect(
            'SELECT t.*, $key AS sync_key, m.hlc AS sync_hlc FROM $table t '
            'LEFT JOIN sync_row_meta m ON m.table_name = ? '
            'AND m.record_key = $key $where',
            variables: [Variable(table), for (final a in args) Variable(a)],
          )
          .get()) {
        final data = Map<String, Object?>.from(row.data)
          ..remove('sync_key')
          ..remove('sync_hlc');
        rows.add(data);
        final hlc = row.readNullable<int>('sync_hlc');
        if (hlc != null) versions[row.read<String>('sync_key')] = hlc;
      }
    }

    Future<void> deleted(String where, List<Object?> args) async {
      for (final row in await db
          .customSelect(
            'SELECT record_key, hlc FROM sync_row_meta '
            'WHERE table_name = ? AND record_key NOT IN '
            '(SELECT $key FROM $table t) $where',
            variables: [Variable(table), for (final a in args) Variable(a)],
          )
          .get()) {
        versions[row.read<String>('record_key')] = row.read<int>('hlc');
      }
    }

    if (parts.length == 1) {
      await live('', const []);
      await deleted('', const []);
      if (table == 'accounts') {
        for (final row in rows) {
          final id = row['id'];
          final base = id is int ? await accountBase(id) : null;
          if (base != null) bases['$id'] = [base.$1, base.$2];
        }
      }
    } else if (parts[1] == 'deleted') {
      await deleted('AND ${_month('(hlc >> 16)')} = ?', [parts[2]]);
    } else {
      final column = 't.${sectionedTables[table]}';
      if (parts[1].length == 10) {
        await live('WHERE ${_day(column)} = ?', [parts[1]]);
      } else {
        await live('WHERE ${_month(column)} = ? AND ${_day(column)} != ?', [
          parts[1],
          today,
        ]);
      }
    }
    final bytes = Uint8List.fromList(
      gzip.encode(
        utf8.encode(
          jsonEncode({
            'format': sectionSnapshotFormat,
            'formatVersion': 3,
            'schemaVersion': db.schemaVersion,
            'mirrorId': state.read<String>('mirror_id'),
            'section': section,
            'sequence': sequence,
            // How the other phones' activity logs name this one.
            'device': ?state.readNullable<String>('device_name'),
            'createdAt': DateTime.now().toUtc().toIso8601String(),
            'tables': {table: rows},
            'versions': {table: versions},
            'bases': bases,
          }),
        ),
      ),
    );
    return (
      bytes: bytes,
      rows: rows.length,
      empty: rows.isEmpty && versions.isEmpty,
      newest: versions.values.fold(0, max),
    );
  });

  /// [section]'s Drive file: its ID, and whether Drive has it yet.
  Future<({String id, bool created})?> sectionFile(String section) async {
    final row = await db
        .customSelect(
          'SELECT file_id, created FROM sync_files WHERE section = ?',
          variables: [Variable(section)],
        )
        .getSingleOrNull();
    return row == null
        ? null
        : (id: row.read<String>('file_id'), created: row.read<int>('created') == 1);
  }

  /// Saves the ID [section]'s file will be created with, before creating it.
  Future<void> reserveFile(String section, String fileId) => db.customStatement(
    'INSERT OR REPLACE INTO sync_files (section, file_id) VALUES (?, ?)',
    [section, fileId],
  );

  /// [section]'s file now holds upload [sequence].
  Future<void> fileUploaded(String section, String fileId, int sequence) =>
      db.customStatement(
        'INSERT OR REPLACE INTO sync_files VALUES (?, ?, 1, ?)',
        [section, fileId, sequence],
      );

  /// [section]'s file is gone from Drive (or was deleted on purpose).
  Future<void> forgetFile(String section) => db.customStatement(
    'DELETE FROM sync_files WHERE section = ?',
    [section],
  );

  /// The IDs of this phone's files on Drive.
  Future<Set<String>> ownFileIds() async => {
    for (final row in await db
        .customSelect('SELECT file_id FROM sync_files')
        .get())
      row.read<String>('file_id'),
  };

  /// Whether all of this phone's data is on Drive as section files: some
  /// exist, and no full upload is still waiting (the queue's '' row). Only
  /// then are the files an older version of it uploaded safe to delete.
  Future<bool> hasSectionFiles() async =>
      (await db.customSelect('''SELECT
            EXISTS(SELECT 1 FROM sync_files WHERE created = 1)
            AND NOT EXISTS(SELECT 1 FROM sync_outbox WHERE table_name = '')
            AS done''').getSingle()).read<int>('done') ==
      1;

  /// After every section of [plan] is on Drive: what was waiting up to then
  /// is sent.
  Future<void> acknowledge(String owner, UploadPlan plan) =>
      db.transaction(() async {
        final state = await db
            .customSelect('SELECT lease FROM sync_state WHERE id = 1')
            .getSingle();
        if (state.readNullable<String>('lease') != owner) return;
        // A record edited during upload has a higher revision and stays
        // queued for the next one.
        await db.customStatement(
          'DELETE FROM sync_outbox WHERE revision <= ?',
          [plan.revision],
        );
        await logActivity(SyncActivityKind.sent, count: plan.changes);
        await db.customStatement(
          '''UPDATE sync_state SET last_synced = ?, failures = 0, retry_at = 0,
          error = NULL WHERE id = 1''',
          [_now],
        );
      });

  /// Where listing the other phones' files left off: the newest modified
  /// time seen, and when they were last listed in full.
  Future<({DateTime? cursor, DateTime listedAt})> listState() async {
    final row = await db
        .customSelect(
          'SELECT list_cursor, listed_at FROM sync_state WHERE id = 1',
        )
        .getSingle();
    return (
      cursor: DateTime.tryParse(row.readNullable<String>('list_cursor') ?? ''),
      listedAt: DateTime.fromMillisecondsSinceEpoch(row.read<int>('listed_at')),
    );
  }

  /// Where Drive's change log was last read up to (see ChangeFeed).
  Future<String?> changesToken() async =>
      (await db
              .customSelect('SELECT changes_token FROM sync_state WHERE id = 1')
              .getSingle())
          .readNullable<String>('changes_token');

  Future<void> saveChangesToken(String? token) => db.customStatement(
    'UPDATE sync_state SET changes_token = ? WHERE id = 1',
    [token],
  );

  Future<void> saveListState(DateTime? cursor, {bool full = false}) =>
      db.customStatement(
        'UPDATE sync_state SET list_cursor = coalesce(?, list_cursor)'
        '${full ? ', listed_at = ?' : ''} WHERE id = 1',
        [cursor?.toUtc().toIso8601String(), if (full) _now],
      );

  // ---- Merging other phones' files ----------------------------------------

  /// Forgets which upload of each other phone's file was merged here: the
  /// next pull reads every file again. Records already here at the same or
  /// a newer version are skipped, so this only costs the download.
  Future<void> _forgetPeers() async {
    await db.customStatement('DELETE FROM sync_peers');
    // Where Drive was last read up to belongs to that account: listed in
    // full again.
    await db.customStatement(
      'UPDATE sync_state SET changes_token = NULL, list_cursor = NULL '
      'WHERE id = 1',
    );
  }

  /// The last upload merged here per other phone (by its mirror ID).
  Future<Map<String, int>> peers() async => {
    for (final row in await db.customSelect('SELECT * FROM sync_peers').get())
      row.read<String>('mirror_id'): row.read<int>('applied'),
  };

  /// Grows whenever another phone's file is merged, here or by the
  /// background job, so open screens know to reload.
  Future<int> peerProgress() async =>
      (await db
              .customSelect(
                'SELECT CAST(total(applied) AS INTEGER) AS n FROM sync_peers',
              )
              .getSingle())
          .read<int>('n');

  /// Records that [mirrorId]'s upload [sequence] needs nothing merged (e.g.
  /// it couldn't be read and shouldn't be retried every few seconds).
  /// Per file merged here (see [peers]), the newest version it held.
  Future<Map<String, int>> peersNewest() async => {
    for (final row in await db.customSelect('SELECT * FROM sync_peers').get())
      row.read<String>('mirror_id'): row.read<int>('newest'),
  };

  Future<void> markMerged(
    String mirrorId,
    int sequence, {
    int newest = 0,
  }) => db.customStatement(
    '''INSERT INTO sync_peers (mirror_id, applied, newest) VALUES (?, ?, ?)
    ON CONFLICT(mirror_id) DO UPDATE SET applied = excluded.applied,
      newest = max(newest, excluded.newest)''',
    [mirrorId, sequence, newest],
  );

  /// [accountId]'s base (balance less what its transactions add) and the HLC
  /// of the change that set it, or null when the account doesn't exist.
  ///
  /// A base other than the one last recorded was changed on this phone since
  /// (an adjustment, a bank-reported balance, an edited opening balance),
  /// by the account's latest change here.
  Future<(int, int)?> accountBase(int accountId) async {
    final account = await db
        .customSelect(
          'SELECT balance_minor FROM accounts WHERE id = ?',
          variables: [Variable(accountId)],
        )
        .getSingleOrNull();
    if (account == null) return null;
    final anchor =
        account.read<int>('balance_minor') - (await _effect(accountId)).$1;
    final stored = await db
        .customSelect(
          'SELECT anchor, hlc FROM sync_account_base WHERE account_id = ?',
          variables: [Variable(accountId)],
        )
        .getSingleOrNull();
    if (stored != null && stored.read<int>('anchor') == anchor) {
      return (anchor, stored.read<int>('hlc'));
    }
    final changed =
        (await db
                .customSelect(
                  "SELECT hlc FROM sync_row_meta WHERE table_name = 'accounts' "
                  'AND record_key = ?',
                  variables: [
                    Variable(jsonEncode([accountId])),
                  ],
                )
                .getSingleOrNull())
            ?.read<int>('hlc') ??
        0;
    await db.customStatement(
      'INSERT OR REPLACE INTO sync_account_base VALUES (?, ?, ?)',
      [accountId, anchor, changed],
    );
    return (anchor, changed);
  }

  /// What [accountId]'s transactions add to its balance, and how many there are.
  Future<(int, int)> _effect(int accountId) async {
    final row = await db
        .customSelect(accountEffectSql, variables: [Variable(accountId)])
        .getSingle();
    return (row.read<int>('effect'), row.read<int>('count'));
  }

  /// Merges another phone's file into this one: [snapshot] is upload
  /// [sequence] of its [mirrorId]. Each record keeps the newer of its
  /// version here and there, deletions included; a record this phone never
  /// had is added whatever its version, so two phones that each started
  /// with their own data end up with both. Balances are recomputed from each
  /// account's base and the merged transactions. All or nothing. Returns how
  /// many records changed here.
  ///
  /// [mirrorId] is whatever names the file merged: a phone's mirror ID, with
  /// the section for a section file. [quiet] (a restore) keeps the activity
  /// log out of it.
  Future<int> mergeSnapshot(
    String mirrorId,
    int sequence,
    SyncBackup snapshot, {
    bool quiet = false,
  }) => db.transaction(() async {
    final applied =
        (await db
                .customSelect(
                  'SELECT applied FROM sync_peers WHERE mirror_id = ?',
                  variables: [Variable(mirrorId)],
                )
                .getSingleOrNull())
            ?.read<int>('applied') ??
        0;
    if (sequence <= applied) return 0;

    final changes =
        <
          ({
            String table,
            List<Object?> key,
            String recordKey,
            int hlc,
            Map<String, Object?>? row,
          })
        >[];
    for (final MapEntry(key: table, value: keyColumns) in syncTables.entries) {
      final rows = <String, Map<String, Object?>>{
        for (final row in snapshot.tables[table] ?? const [])
          jsonEncode([for (final c in keyColumns) row[c]]): row,
      };
      final versions = snapshot.versions[table] ?? const <String, int>{};
      final recordKeys = {...versions.keys, ...rows.keys};
      if (recordKeys.isEmpty) continue;
      final here = await _versionsOf(table, recordKeys);
      Set<String>? present;
      for (final recordKey in recordKeys) {
        final hlc = versions[recordKey] ?? 0;
        final row = rows[recordKey];
        final mine = here[recordKey];
        final bool newer;
        if (mine != null) {
          newer = hlc > mine;
        } else if (hlc > 0) {
          newer = true;
        } else {
          // Never changed there since versions were kept, never seen here:
          // added only when this phone has no record by that key.
          present ??= await _presentKeys(table, recordKeys);
          newer = row != null && !present.contains(recordKey);
        }
        if (!newer) continue;
        final Object? key;
        try {
          key = jsonDecode(recordKey);
        } on FormatException {
          continue;
        }
        if (key is! List || key.length != keyColumns.length) continue;
        changes.add((
          table: table,
          key: key,
          recordKey: recordKey,
          hlc: hlc,
          row: row,
        ));
      }
    }

    // Accounts whose balance this merge can move, and their base before it.
    final touched = <int>{};
    for (final change in changes) {
      if (change.table == 'accounts' && change.key.single is int) {
        touched.add(change.key.single as int);
      } else if (change.table == 'transactions') {
        final local = await db
            .customSelect(
              'SELECT account_id, to_account_id FROM transactions WHERE id = ?',
              variables: [Variable(change.key.single)],
            )
            .getSingleOrNull();
        for (final id in [
          local?.readNullable<int>('account_id'),
          local?.readNullable<int>('to_account_id'),
          change.row?['account_id'],
          change.row?['to_account_id'],
        ]) {
          if (id is int) touched.add(id);
        }
      }
    }
    final bases = <int, (int, int)>{
      for (final id in touched) id: ?await accountBase(id),
    };
    // A base has its own version: the newer one wins even when this
    // phone's account row is newer for other reasons.
    for (final MapEntry(key: id, value: remote) in snapshot.bases.entries) {
      final current = bases.containsKey(id) ? bases[id] : await accountBase(id);
      if (current == null || remote.$2 > current.$2) {
        bases[id] = remote;
        touched.add(id);
      }
    }
    if (changes.isEmpty && touched.isEmpty) {
      await markMerged(mirrorId, sequence, newest: newestIn(snapshot));
      return 0;
    }

    final device = snapshot.device?.trim().isNotEmpty == true
        ? snapshot.device!.trim()
        : 'Another phone';
    await db.customStatement(
      'UPDATE sync_state SET applying = 1, history_device = ?, '
      'history_off = ? WHERE id = 1',
      [device, quiet ? 1 : 0],
    );
    final columns = <String, Set<String>>{};
    final smsSettled = <String>[];
    final items = <Map<String, Object?>>[];
    var count = 0, newest = 0;
    // Additions and edits first, then deletions.
    for (final change in [
      ...changes.where((c) => c.row != null),
      ...changes.where((c) => c.row == null),
    ]) {
      final table = change.table;
      final keyColumns = syncTables[table]!;
      final key = change.key;
      final where = keyColumns.map((c) => '$c = ?').join(' AND ');
      final row = change.row;
      final before =
          (await db
                  .customSelect(
                    'SELECT * FROM $table WHERE $where',
                    variables: [for (final v in key) Variable(v)],
                  )
                  .getSingleOrNull())
              ?.data;
      if (row == null) {
        if (before != null) {
          await db.customStatement('DELETE FROM $table WHERE $where', key);
        }
      } else {
        final names = columns[table] ??= {
          for (final c
              in await db.customSelect('PRAGMA table_info($table)').get())
            c.read<String>('name'),
        };
        // Columns this version doesn't have are dropped; ones the other
        // phone's version lacks keep their value (or default) here.
        final values = <String, Object?>{
          for (final MapEntry(:key, :value) in row.entries)
            if (names.contains(key)) key: value,
          for (final (i, column) in keyColumns.indexed) column: key[i],
        };
        if (table == 'accounts' &&
            key.single is int &&
            !snapshot.bases.containsKey(key.single)) {
          // A file from a version that sent no base: its balance less this
          // phone's transactions stands in.
          final id = key.single as int;
          bases[id] = (
            (values['balance_minor'] as int? ?? 0) - (await _effect(id)).$1,
            change.hlc,
          );
          touched.add(id);
        }
        final updates = values.keys
            .where((c) => !keyColumns.contains(c))
            .map((c) => '$c = excluded.$c');
        try {
          await db.customStatement(
            'INSERT INTO $table (${values.keys.join(', ')}) '
            'VALUES (${List.filled(values.length, '?').join(', ')}) '
            'ON CONFLICT(${keyColumns.join(', ')}) DO '
            '${updates.isEmpty ? 'NOTHING' : 'UPDATE SET ${updates.join(', ')}'}',
            values.values.toList(),
          );
        } on Object {
          // Clashes with a different record here (e.g. a second total
          // budget for one currency): this phone's stays.
          continue;
        }
        if (table == 'sms_history') smsSettled.add(key.single as String);
      }
      await db.customStatement(
        'INSERT OR REPLACE INTO sync_row_meta VALUES (?, ?, ?)',
        [table, change.recordKey, change.hlc],
      );
      newest = max(newest, change.hlc);
      // A deletion of something this phone never had changes nothing.
      if (row == null && before == null) continue;
      if (describable.contains(table) && items.length < 50) {
        final item = await _describe(
          table,
          row == null
              ? 'deleted'
              : before == null
              ? 'added'
              : 'edited',
          Map<String, Object?>.from(row ?? before!),
        );
        if (item != null) items.add(item.toJson());
      }
      count++;
    }

    for (final id in touched) {
      final base = bases[id];
      if (base == null) continue;
      final (effect, transactions) = await _effect(id);
      final updated = await db.customUpdate(
        'UPDATE accounts SET balance_minor = ?, transaction_count = ? '
        'WHERE id = ?',
        variables: [
          Variable(base.$1 + effect),
          Variable(transactions),
          Variable(id),
        ],
      );
      if (updated == 0) continue;
      await db.customStatement(
        'INSERT OR REPLACE INTO sync_account_base VALUES (?, ?, ?)',
        [id, base.$1, base.$2],
      );
    }
    // Messages the other phone saved or dismissed are settled here too, so
    // this phone's own scan doesn't save them again.
    for (var i = 0; i < smsSettled.length; i += 500) {
      final chunk = smsSettled.skip(i).take(500).toList();
      await db.customStatement(
        '''INSERT INTO sms_imports (fingerprint, sender, body, received_at,
            candidate, rule_id, pack_version, status, transaction_id)
          SELECT fingerprint, sender, NULL, received_at,
            json_object('notificationKey', notification_key,
              'isCreditCard', credit_card),
            rule_id, pack_version, status, transaction_id
          FROM sms_history
          WHERE fingerprint IN (${List.filled(chunk.length, '?').join(', ')})
          ON CONFLICT(fingerprint) DO UPDATE SET status = excluded.status,
            transaction_id = excluded.transaction_id''',
        chunk,
      );
    }
    await db.customStatement(
      'UPDATE sync_state SET applying = 0, history_device = NULL, '
      'history_off = 0, clock = max(clock, ?) WHERE id = 1',
      [newest],
    );
    await markMerged(mirrorId, sequence, newest: newestIn(snapshot));
    if (count > 0 && !quiet) {
      await logActivity(
        SyncActivityKind.received,
        device: device,
        count: count,
        items: items,
      );
    }
    return count;
  });

  /// The newest version among [snapshot]'s records.
  static int newestIn(SyncBackup snapshot) => snapshot.versions.values
      .expand((records) => records.values)
      .fold(0, max);

  /// The versions this phone knows of [table]'s [recordKeys].
  Future<Map<String, int>> _versionsOf(
    String table,
    Iterable<String> recordKeys,
  ) async {
    final keys = recordKeys.toList();
    final known = <String, int>{};
    for (var i = 0; i < keys.length; i += 500) {
      final chunk = keys.skip(i).take(500).toList();
      for (final row in await db
          .customSelect(
            'SELECT record_key, hlc FROM sync_row_meta WHERE table_name = ? '
            'AND record_key IN (${List.filled(chunk.length, '?').join(', ')})',
            variables: [Variable(table), for (final k in chunk) Variable(k)],
          )
          .get()) {
        known[row.read<String>('record_key')] = row.read<int>('hlc');
      }
    }
    return known;
  }

  /// Which of [table]'s [recordKeys] this phone has a record for.
  Future<Set<String>> _presentKeys(
    String table,
    Iterable<String> recordKeys,
  ) async {
    final columns = syncTables[table]!;
    if (columns.length > 1) {
      // Only small link tables have composite keys.
      return {
        for (final r in await db
            .customSelect('SELECT ${_keyOf(table)} AS k FROM $table t')
            .get())
          r.read<String>('k'),
      };
    }
    final keys = [
      for (final k in recordKeys)
        if (jsonDecode(k) case [final Object? v]) (k, v),
    ];
    final present = <String>{};
    for (var i = 0; i < keys.length; i += 500) {
      final chunk = keys.skip(i).take(500).toList();
      for (final row in await db
          .customSelect(
            'SELECT ${_keyOf(table)} AS k FROM $table t WHERE ${columns.single} '
            'IN (${List.filled(chunk.length, '?').join(', ')})',
            variables: [for (final (_, v) in chunk) Variable(v)],
          )
          .get()) {
        present.add(row.read<String>('k'));
      }
    }
    return present;
  }

  // ---- History ---------------------------------------------------------------

  Future<void> setDeviceName(String name) => db.customStatement(
    'UPDATE sync_state SET device_name = ? WHERE id = 1',
    [name.trim().isEmpty ? null : name.trim()],
  );

  /// Adds a sync event to More › History (record changes are kept by
  /// the change history instead). Uploads, what one phone sent, and the same
  /// error, repeated within a few minutes, join the latest entry instead of
  /// filling the log.
  Future<void> logActivity(
    SyncActivityKind kind, {
    String? device,
    int count = 0,
    List<Map<String, Object?>> items = const [],
    String? message,
  }) async {
    if (kind == SyncActivityKind.sent && count == 0) return;
    final last = await db
        .customSelect('SELECT * FROM sync_activity ORDER BY id DESC LIMIT 1')
        .getSingleOrNull();
    final joins =
        last != null &&
        const {
          SyncActivityKind.sent,
          SyncActivityKind.received,
          SyncActivityKind.error,
        }.contains(kind) &&
        last.read<String>('kind') == kind.name &&
        last.readNullable<String>('device') == device &&
        last.readNullable<String>('message') == message &&
        _now - last.read<int>('at') < const Duration(minutes: 5).inMilliseconds;
    if (joins) {
      final merged = [
        ...items,
        ...jsonDecode(last.read<String>('items')) as List,
      ].take(50).toList();
      await db.customStatement(
        'UPDATE sync_activity SET at = ?, count = count + ?, items = ? '
        'WHERE id = ?',
        [_now, count, jsonEncode(merged), last.read<int>('id')],
      );
      return;
    }
    await db.customStatement(
      'INSERT INTO sync_activity (at, kind, device, count, items, message) '
      'VALUES (?, ?, ?, ?, ?, ?)',
      [_now, kind.name, device, count, jsonEncode(items), message],
    );
    await db.customStatement('''DELETE FROM sync_activity WHERE id <=
        (SELECT id FROM sync_activity ORDER BY id DESC LIMIT 1 OFFSET 500)''');
  }

  /// The sync events, newest first.
  Future<List<SyncActivity>> activity({int limit = 500}) async => [
    for (final row
        in await db
            .customSelect(
              'SELECT id, at, kind, device, count, items, message '
              'FROM sync_activity ORDER BY id DESC LIMIT ?',
              variables: [Variable(limit)],
            )
            .get())
      SyncActivity(
        id: row.read<int>('id'),
        at: DateTime.fromMillisecondsSinceEpoch(row.read<int>('at')),
        kind: SyncActivityKind.parse(row.read<String>('kind')),
        device: row.readNullable<String>('device'),
        count: row.read<int>('count'),
        items: SyncActivity.decodeItems(row.read<String>('items')),
        message: row.readNullable<String>('message'),
      ),
  ];

  /// Tables whose records the log names one by one. The rest (SMS history,
  /// budget months, links) only count towards the total.
  static const describable = {
    'accounts',
    'categories',
    'transactions',
    'budgets',
    'debt_people',
    'debt_entries',
    'loans',
    'loan_events',
    'recurring_payments',
    'user_sms_rules',
    'sms_category_memory',
    'sms_corrections',
    'statement_layouts',
  };

  Future<SyncActivityItem?> _describe(
    String table,
    String action,
    Map<String, Object?> row,
  ) async {
    String? text(String column) {
      final value = row[column];
      return value is String && value.trim().isNotEmpty ? value.trim() : null;
    }

    int? number(String column) =>
        row[column] is int ? row[column] as int : null;
    SyncActivityItem item(
      String kind, {
      String? label,
      int? amount,
      String? currency,
      int? digits,
    }) => SyncActivityItem(
      action: action,
      kind: kind,
      label: label,
      amountMinor: amount,
      currency: currency,
      digits: digits,
    );
    switch (table) {
      case 'transactions':
        final account = await db
            .customSelect(
              'SELECT currency, digits FROM accounts WHERE id = ?',
              variables: [Variable(row['account_id'])],
            )
            .getSingleOrNull();
        return item(
          text('type') ?? 'transaction',
          label: text('title') ?? text('note')?.split('\n').first,
          amount: number('amount_minor'),
          currency: account?.read<String>('currency'),
          digits: account?.read<int>('digits'),
        );
      case 'accounts':
        return item('account', label: text('name'));
      case 'categories':
        return item('category', label: text('name'));
      case 'budgets':
        return item('budget', label: text('name'));
      case 'debt_people':
        return item('person', label: text('name'));
      case 'debt_entries':
        return item(
          'debt',
          label: text('note') ?? text('kind'),
          amount: number('amount_minor'),
          currency: text('currency'),
          digits: number('digits'),
        );
      case 'loans':
        String? lender;
        try {
          lender =
              (jsonDecode(text('payload') ?? '{}') as Map)['lender'] as String?;
        } catch (_) {}
        return item('loan', label: lender);
      case 'loan_events':
        return item('loan payment');
      case 'recurring_payments':
        return item(
          'recurring payment',
          label: text('name'),
          amount: number('amount_minor'),
          currency: text('currency'),
          digits: number('digits'),
        );
      case 'user_sms_rules':
        return item('SMS format', label: text('bank_name'));
      case 'sms_category_memory':
        return item('learned category', label: text('merchant'));
      case 'sms_corrections':
        return item('SMS correction', label: text('sender'));
      case 'statement_layouts':
        return item('statement format');
    }
    return null;
  }

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
    await logActivity(SyncActivityKind.error, message: message, count: 1);
  });
}
