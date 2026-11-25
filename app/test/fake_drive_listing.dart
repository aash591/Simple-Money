import 'package:simple_money/data/backup/drive_client.dart';
import 'package:simple_money/data/backup/sync_repository.dart';

/// How Drive lists [files] (by file ID), as the fakes in the sync tests keep
/// them: [modifiedOf] gives each file's server time, [legacy] marks batches
/// of an older version's chain, and [modifiedAfter] keeps only newer files.
List<MirrorFile> fakeListing(
  Map<String, SyncBatch> files,
  DateTime Function(String fileId) modifiedOf, {
  Set<String> legacy = const {},
  DateTime? modifiedAfter,
}) => [
  for (final batch in files.values)
    if (modifiedAfter == null ||
        modifiedOf(batch.fileId).isAfter(modifiedAfter))
      MirrorFile(
        id: batch.fileId,
        mirrorId: batch.mirrorId,
        sequence: batch.sequence,
        modified: modifiedOf(batch.fileId),
        section: legacy.contains(batch.fileId) || batch.section.isEmpty
            ? null
            : batch.section,
        rows: batch.rows,
        newest: batch.newest,
        encryption: legacy.contains(batch.fileId) || batch.section.isEmpty
            ? null
            : batch.encryption,
        encryptionAt: batch.encryptionAt,
      ),
];
