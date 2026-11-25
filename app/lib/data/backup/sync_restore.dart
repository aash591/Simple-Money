import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'drive_client.dart';
import 'backup_encryption.dart';
import 'sync_schema.dart';
import 'sync_sections.dart';

/// The `format` inside a section file, and inside the single file the
/// previous version keeps (see SyncRepository.buildSection).
const sectionSnapshotFormat = 'simple-money-section';
const deviceSnapshotFormat = 'simple-money-device';

/// Records of one installation: one section file, the single file of a
/// phone on the previous version, a chain an older version uploaded, an
/// exported file, or (for a restore) a phone's section files not yet read.
class SyncBackup {
  const SyncBackup({
    required this.mirrorId,
    required this.updatedAt,
    required this.schemaVersion,
    required this.tables,
    this.encryption,
    this.versions = const {},
    this.bases = const {},
    this.device,
    this.fromDrive = false,
    this.counts,
    this.files = const [],
  });
  final String mirrorId;
  final DateTime updatedAt;
  final int schemaVersion;
  final BackupEncryption? encryption;

  /// Complete rows per synced table, exactly as they were uploaded.
  final Map<String, List<Map<String, Object?>>> tables;

  /// The HLC of each record's last change, per table and record key (as
  /// `sync_row_meta` stores it), deletions included. Empty for an imported
  /// file, whose rows then count as never changed.
  final Map<String, Map<String, int>> versions;

  /// Each account's base (balance less what its transactions add) and the
  /// HLC of the change that set it. Empty when the source didn't say.
  final Map<int, (int, int)> bases;

  /// How the phone that uploaded it names itself.
  final String? device;

  /// Read from Google Drive (a restore), rather than an imported file.
  final bool fromDrive;

  /// Records per table, when [files] are still to be read.
  final Map<String, int>? counts;

  /// A phone's section files, read one by one when restoring from it.
  final List<MirrorFile> files;

  int count(String table) => counts?[table] ?? tables[table]?.length ?? 0;

  /// Every install uploads its default categories on connecting, so a phone
  /// with nothing else is a fresh install's rather than a backup worth
  /// offering.
  bool get hasLedgerData =>
      count('accounts') +
          count('transactions') +
          count('budgets') +
          count('debt_entries') +
          count('loans') +
          count('recurring_payments') >
      0;
}

/// One other phone's files on Drive: its section files (the newest of each
/// section), or the single file of the previous version, or the chain of an
/// older one.
class DrivePhone {
  DrivePhone(this.mirrorId);
  final String mirrorId;
  final sections = <String, MirrorFile>{};
  MirrorFile? single;
  final legacy = <MirrorFile>[];
  DateTime updated = DateTime.fromMillisecondsSinceEpoch(0);
}

/// The phones on Drive in [files], most recently updated first;
/// [excludeMirrorId] (this phone) is left out.
List<DrivePhone> drivePhones(
  List<MirrorFile> files, {
  String? excludeMirrorId,
}) {
  final phones = <String, DrivePhone>{};
  for (final file in files) {
    if (file.mirrorId == excludeMirrorId) continue;
    final phone = phones.putIfAbsent(
      file.mirrorId,
      () => DrivePhone(file.mirrorId),
    );
    if (file.modified.isAfter(phone.updated)) phone.updated = file.modified;
    final section = file.section;
    if (section != null) {
      if (!isKnownSection(section)) continue;
      final current = phone.sections[section];
      if (current == null || file.sequence > current.sequence) {
        phone.sections[section] = file;
      }
    } else if (file.isDeviceFile) {
      if (phone.single == null || file.sequence > phone.single!.sequence) {
        phone.single = file;
      }
    } else {
      phone.legacy.add(file);
    }
  }
  return phones.values.toList()..sort((a, b) => b.updated.compareTo(a.updated));
}

/// The last batch of an older version's unbroken chain from batch 1.
int chainEnd(Iterable<MirrorFile> files) {
  final present = {for (final f in files) f.sequence};
  var end = 0;
  while (present.contains(end + 1)) {
    end++;
  }
  return end;
}

/// An older version's chain of batches, rebuilt (see [_rebuild]).
Future<SyncBackup?> readChain(
  MirrorTransport transport,
  List<MirrorFile> files,
  BackupKeyLookup? keyLookup,
) => _rebuild(transport, files, keyLookup);

/// The most recently updated phone on Drive, other than [excludeMirrorId]
/// (this one), that holds more than default categories. A phone with
/// section files is judged by the counts their metadata carries, and only
/// one small file is read, to learn its encryption and version; restoring
/// from it reads the rest (see [SyncBackup.files]).
Future<SyncBackup?> findLatestBackup(
  MirrorTransport transport, {
  String? excludeMirrorId,
  BackupKeyLookup? keyLookup,
}) async {
  for (final phone in drivePhones(
    await transport.listFiles(),
    excludeMirrorId: excludeMirrorId,
  )) {
    if (phone.sections.isNotEmpty) {
      final counts = <String, int>{};
      for (final MapEntry(key: section, value: file)
          in phone.sections.entries) {
        if (section.contains('/deleted/')) continue;
        final table = sectionTable(section);
        counts[table] = (counts[table] ?? 0) + (file.rows ?? 0);
      }
      final files = phone.sections.values.toList()
        ..sort((a, b) => compareSections(a.section!, b.section!));
      final probe = SyncBackup(
        mirrorId: phone.mirrorId,
        updatedAt: phone.updated,
        schemaVersion: 0,
        tables: const {},
        counts: counts,
      );
      if (!probe.hasLedgerData) continue;
      final sample = await readFile(transport, files.first, keyLookup);
      return SyncBackup(
        mirrorId: phone.mirrorId,
        updatedAt: phone.updated,
        schemaVersion: sample.schemaVersion,
        tables: const {},
        encryption: sample.encryption,
        device: sample.device,
        fromDrive: true,
        counts: counts,
        files: files,
      );
    }
    final backup = phone.single != null
        ? await readFile(transport, phone.single!, keyLookup)
        : await _rebuild(transport, phone.legacy, keyLookup);
    if (backup != null && backup.hasLedgerData) return backup;
  }
  return null;
}

/// Downloads and checks a section file, or the single file of a phone on
/// the previous version.
Future<SyncBackup> readFile(
  MirrorTransport transport,
  MirrorFile file,
  BackupKeyLookup? keyLookup,
) async {
  final payload = await transport.download(file.id);
  final data = decodeMirrorBatch(
    await decryptBackupBatch(payload, file.mirrorId, file.sequence, keyLookup),
  );
  if (data['format'] !=
          (file.section != null
              ? sectionSnapshotFormat
              : deviceSnapshotFormat) ||
      data['mirrorId'] != file.mirrorId ||
      data['sequence'] != file.sequence ||
      (file.section != null && data['section'] != file.section)) {
    throw const DriveSyncException(
      'A sync file on Google Drive is damaged and could not be read.',
    );
  }
  final tables = <String, List<Map<String, Object?>>>{};
  for (final MapEntry(key: table, value: rows)
      in (data['tables'] as Map? ?? const {}).entries) {
    // Only known tables: their names end up in SQL.
    if (!syncTables.containsKey(table) || rows is! List) continue;
    tables[table as String] = [
      for (final row in rows)
        if (row is Map) Map<String, Object?>.from(row),
    ];
  }
  final versions = <String, Map<String, int>>{};
  for (final MapEntry(key: table, value: records)
      in (data['versions'] as Map? ?? const {}).entries) {
    if (!syncTables.containsKey(table) || records is! Map) continue;
    versions[table as String] = {
      for (final MapEntry(:key, :value) in records.entries)
        if (value is int) key as String: value,
    };
  }
  final bases = <int, (int, int)>{};
  for (final MapEntry(:key, :value)
      in (data['bases'] as Map? ?? const {}).entries) {
    final id = int.tryParse('$key');
    if (id != null &&
        value is List &&
        value.length == 2 &&
        value[0] is int &&
        value[1] is int) {
      bases[id] = (value[0] as int, value[1] as int);
    }
  }
  return SyncBackup(
    mirrorId: file.mirrorId,
    updatedAt: file.modified,
    schemaVersion: data['schemaVersion'] as int? ?? 0,
    encryption: backupBatchEncryption(payload),
    tables: tables,
    versions: versions,
    bases: bases,
    device: data['device'] is String ? data['device'] as String : null,
    fromDrive: true,
  );
}

/// An older version's batches each hold only the changes since the previous
/// one, so its data is rebuilt from the unbroken chain starting at sequence
/// 1. Anything past a missing batch can't be applied and is left out.
Future<SyncBackup?> _rebuild(
  MirrorTransport transport,
  List<MirrorFile> files,
  BackupKeyLookup? keyLookup,
) async {
  final bySequence = {for (final file in files) file.sequence: file};
  final chain = [
    for (var sequence = 1; bySequence.containsKey(sequence); sequence++)
      bySequence[sequence]!,
  ];
  if (chain.isEmpty) return null;
  final payloads = await _downloadAll(transport, chain);
  final tables = <String, Map<String, Map<String, Object?>>>{};
  final versions = <String, Map<String, int>>{};
  final bases = <int, (int, int)>{};
  String? device;
  var schemaVersion = 0;
  final encryption = backupBatchEncryption(payloads.first);
  for (var i = 0; i < chain.length; i++) {
    if (backupBatchEncryption(payloads[i]) != encryption) {
      throw const DriveSyncException(
        'The backup encryption settings do not match. Your phone data has not changed.',
      );
    }
    final batch = decodeMirrorBatch(
      await decryptBackupBatch(
        payloads[i],
        chain[i].mirrorId,
        chain[i].sequence,
        keyLookup,
      ),
    );
    if (batch['format'] != 'simple-money-mirror' ||
        batch['mirrorId'] != chain[i].mirrorId ||
        batch['sequence'] != chain[i].sequence) {
      throw const DriveSyncException(
        'A backup file on Google Drive is damaged and could not be restored.',
      );
    }
    schemaVersion = max(schemaVersion, batch['schemaVersion'] as int);
    if (batch['device'] is String) device = batch['device'] as String;
    // Batches from before v47 carry no per-change clock; when the batch was
    // made is the closest there is.
    final made = DateTime.tryParse('${batch['createdAt']}');
    final fallback = made == null ? 0 : hlcAt(made);
    for (final change in batch['changes'] as List) {
      final table = change['table'] as String;
      // Only known tables: their names end up in SQL during a restore.
      if (!syncTables.containsKey(table)) continue;
      final rows = tables.putIfAbsent(table, () => {});
      final key = jsonEncode(change['key']);
      final hlc = change['hlc'];
      // An explicit 0 is a record never changed since v47; no clock at all
      // is a batch from before it.
      final version = change.containsKey('hlc')
          ? (hlc is int ? hlc : 0)
          : fallback;
      versions.putIfAbsent(table, () => {})[key] = version;
      final row = change['row'];
      if (row == null) {
        rows.remove(key);
      } else {
        rows[key] = Map<String, Object?>.from(row as Map);
      }
      final id = (change['key'] as List).firstOrNull;
      if (table == 'accounts' && id is int) {
        if (change['anchor'] case final int anchor when row != null) {
          final at = change['anchorHlc'] is int
              ? change['anchorHlc'] as int
              : version;
          final current = bases[id];
          if (current == null || at >= current.$2) bases[id] = (anchor, at);
        } else if (row == null) {
          bases.remove(id);
        }
      }
    }
  }
  return SyncBackup(
    mirrorId: chain.first.mirrorId,
    updatedAt: chain.last.modified,
    schemaVersion: schemaVersion,
    encryption: encryption,
    versions: versions,
    bases: bases,
    device: device,
    fromDrive: true,
    tables: {
      for (final MapEntry(:key, :value) in tables.entries)
        key: value.values.toList(),
    },
  );
}

/// Batches are small but numerous, so a few download at once.
Future<List<Uint8List>> _downloadAll(
  MirrorTransport transport,
  List<MirrorFile> files,
) async {
  final results = List<Uint8List?>.filled(files.length, null);
  var next = 0;
  Future<void> worker() async {
    while (next < files.length) {
      final index = next++;
      results[index] = await transport.download(files[index].id);
    }
  }

  await Future.wait([for (var i = 0; i < min(6, files.length); i++) worker()]);
  return results.cast<Uint8List>();
}

Map<String, dynamic> decodeMirrorBatch(Uint8List bytes) {
  // Drive serves the stored gzip bytes, but an HTTP layer may already have
  // decompressed them.
  final gzipped = bytes.length > 1 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  return jsonDecode(utf8.decode(gzipped ? gzip.decode(bytes) : bytes))
      as Map<String, dynamic>;
}
