import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'drive_client.dart';
import 'backup_encryption.dart';
import 'sync_schema.dart';

/// The latest state of one installation's mirror, rebuilt from its batches.
class SyncBackup {
  const SyncBackup({
    required this.mirrorId,
    required this.updatedAt,
    required this.schemaVersion,
    required this.tables,
    this.encryption,
  });
  final String mirrorId;
  final DateTime updatedAt;
  final int schemaVersion;
  final BackupEncryption? encryption;

  /// Complete rows per synced table, exactly as they were uploaded.
  final Map<String, List<Map<String, Object?>>> tables;

  int count(String table) => tables[table]?.length ?? 0;

  /// Every install uploads its default categories on connecting, so a mirror
  /// with nothing else is a fresh install's rather than a backup worth offering.
  bool get hasLedgerData =>
      count('accounts') +
          count('transactions') +
          count('budgets') +
          count('debt_entries') +
          count('loans') +
          count('recurring_payments') >
      0;
}

/// The most recently updated mirror on Drive, other than [excludeMirrorId]
/// (this device's own), that holds more than default categories.
Future<SyncBackup?> findLatestBackup(
  MirrorTransport transport, {
  String? excludeMirrorId,
  BackupKeyLookup? keyLookup,
}) async {
  final mirrors = <String, List<MirrorFile>>{};
  for (final file in await transport.listFiles()) {
    if (file.mirrorId == excludeMirrorId) continue;
    mirrors.putIfAbsent(file.mirrorId, () => []).add(file);
  }
  DateTime latest(List<MirrorFile> files) =>
      files.map((file) => file.modified).reduce((a, b) => a.isAfter(b) ? a : b);
  final ordered = mirrors.values.toList()
    ..sort((a, b) => latest(b).compareTo(latest(a)));
  for (final files in ordered) {
    final backup = await _rebuild(transport, files, keyLookup);
    if (backup != null && backup.hasLedgerData) return backup;
  }
  return null;
}

/// A batch holds only the changes since the previous one, so a mirror is
/// rebuilt from the unbroken chain starting at sequence 1. Anything past a
/// missing batch can't be applied and is left out.
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
  var schemaVersion = 0;
  final encryption = backupBatchEncryption(payloads.first);
  for (var i = 0; i < chain.length; i++) {
    if (backupBatchEncryption(payloads[i]) != encryption) {
      throw const DriveSyncException(
        'The backup encryption settings do not match. Your phone data has not changed.',
      );
    }
    final batch = _decode(
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
    for (final change in batch['changes'] as List) {
      final table = change['table'] as String;
      // Only known tables: their names end up in SQL during a restore.
      if (!syncTables.containsKey(table)) continue;
      final rows = tables.putIfAbsent(table, () => {});
      final key = jsonEncode(change['key']);
      final row = change['row'];
      if (row == null) {
        rows.remove(key);
      } else {
        rows[key] = Map<String, Object?>.from(row as Map);
      }
    }
  }
  return SyncBackup(
    mirrorId: chain.first.mirrorId,
    updatedAt: chain.last.modified,
    schemaVersion: schemaVersion,
    encryption: encryption,
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

Map<String, dynamic> _decode(Uint8List bytes) {
  // Drive serves the stored gzip bytes, but an HTTP layer may already have
  // decompressed them.
  final gzipped = bytes.length > 1 && bytes[0] == 0x1f && bytes[1] == 0x8b;
  return jsonDecode(utf8.decode(gzipped ? gzip.decode(bytes) : bytes))
      as Map<String, dynamic>;
}
