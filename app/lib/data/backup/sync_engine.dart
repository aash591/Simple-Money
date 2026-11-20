import 'dart:async';
import 'dart:math';

import 'package:drive_authorization/drive_authorization.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';

import 'drive_client.dart';
import 'backup_encryption.dart';
import 'backup_key_store.dart';
import 'sync_repository.dart';
import 'sync_notifications.dart';
import 'sync_restore.dart';
import 'sync_sections.dart';

typedef OpenMirrorTransport = Future<MirrorTransport> Function(String email);

class SyncEngine {
  SyncEngine(
    this.repository, {
    OpenMirrorTransport? openTransport,
    BackupKeyStore? keyStore,
    this.progress,
  }) : _openTransport = openTransport ?? _googleTransport,
       keyStore = keyStore ?? const SecureBackupKeyStore();
  final BackupKeyStore keyStore;

  /// Told how each upload goes, e.g. to show it as a notification.
  final UploadProgress? progress;
  final SyncRepository repository;
  final OpenMirrorTransport _openTransport;

  static Future<MirrorTransport> _googleTransport(String email) async =>
      DriveClient(
        await DriveAuthorization()
            .token(email: email)
            .timeout(const Duration(seconds: 45)),
      );

  /// The newest backup on the connected account from another installation.
  Future<SyncBackup?> findBackup({bool requirePin = false}) async {
    final status = await repository.status();
    if (!status.enabled) return null;
    final transport = await _openTransport(status.email!);
    final subject = await repository.subject();
    final keys = <String, BackupKey>{};
    try {
      return await findLatestBackup(
        transport,
        excludeMirrorId: await repository.mirrorId(),
        keyLookup: (configuration) async {
          if (requirePin || subject == null) return null;
          if (keys.containsKey(configuration.encoded)) {
            return keys[configuration.encoded];
          }
          final key = await keyStore.read(subject, configuration);
          if (key != null) keys[configuration.encoded] = key;
          return key;
        },
      );
    } finally {
      transport.close();
    }
  }

  /// How long a check lists only files changed since the last one, and how
  /// far back each looks, to catch an upload Drive stamped as the previous
  /// listing ran. A full listing then catches anything missed.
  static const fullListingEvery = Duration(hours: 1);
  static const listingOverlap = Duration(minutes: 2);

  /// Merges every other phone's files that changed since they were last
  /// merged here, and returns how many records changed here (0: nothing new).
  ///
  /// A check reads Drive's change log since the previous one, which shows a
  /// file the moment it's uploaded (without one, it lists the files changed
  /// since, by Drive's own clock). Every so often, and when [full], it also
  /// lists all of them. Only files with a newer upload number than the one
  /// merged are downloaded.
  Future<int> pull({bool full = false}) async {
    final status = await repository.status();
    if (!status.enabled || status.restorePending) return 0;
    final transport = await _openTransport(status.email!);
    try {
      final own = await repository.mirrorId();
      final listing = await repository.listState();
      final listAll =
          full ||
          listing.cursor == null ||
          DateTime.now().difference(listing.listedAt) > fullListingEvery;
      final feed = transport is ChangeFeed ? transport as ChangeFeed : null;
      final token = await repository.changesToken();
      final List<MirrorFile> files;
      String? nextToken;
      if (feed != null && token != null && !listAll) {
        // What changed since the last check, shown the moment it's uploaded.
        try {
          (files, nextToken) = await feed.changesSince(token);
        } on DriveSyncException {
          // An expired or unknown position: the next check lists everything.
          await repository.saveChangesToken(null);
          rethrow;
        }
      } else {
        // Taken before listing, so nothing uploaded meanwhile is missed.
        final start = feed == null ? null : await feed.startToken();
        final listed = await transport.listFiles(
          modifiedAfter: listAll
              ? null
              : listing.cursor!.subtract(listingOverlap),
        );
        // A search can lag behind a just-uploaded file; the change log
        // can't, so its entries are added in too.
        (List<MirrorFile>, String)? recent;
        if (feed != null && token != null) {
          try {
            recent = await feed.changesSince(token);
          } on DriveSyncException {
            recent = null; // Expired: the listing covers it.
          }
        }
        final byId = <String, MirrorFile>{for (final f in listed) f.id: f};
        for (final f in recent?.$1 ?? const <MirrorFile>[]) {
          final known = byId[f.id];
          if (known == null || f.sequence > known.sequence) byId[f.id] = f;
        }
        files = byId.values.toList();
        nextToken = recent?.$2 ?? start;
      }
      DateTime? cursor;
      for (final file in files) {
        if (cursor == null || file.modified.isAfter(cursor)) {
          cursor = file.modified;
        }
      }
      if (listAll) await _cleanUpOwn(transport, files, own);
      // The newest encryption choice among the phones applies to all.
      try {
        await _followEncryption(transport, files, own);
      } on StateError {
        // Busy (an upload finishing): tried again on the next check.
      }

      final peers = await repository.peers();
      final peersNewest = await repository.peersNewest();
      final subject = await repository.subject();
      final keys = <String, BackupKey?>{};
      Future<BackupKey?> lookup(BackupEncryption configuration) async {
        if (subject == null) return null;
        return keys[configuration.encoded] ??= await keyStore.read(
          subject,
          configuration,
        );
      }

      Future<int> merge(String name, int sequence, SyncBackup data) {
        if (data.schemaVersion > repository.db.schemaVersion) {
          throw const DriveSyncException(
            'Update SimpleMoney to sync with your other phone.',
          );
        }
        return repository.mergeSnapshot(name, sequence, data);
      }

      var changed = 0;
      for (final phone in drivePhones(files, excludeMirrorId: own)) {
        final sections = phone.sections.entries.toList()
          ..sort((a, b) => compareSections(a.key, b.key));
        for (final MapEntry(key: section, value: file) in sections) {
          final name = '${phone.mirrorId}/$section';
          final merged = peers[name];
          if (merged != null && file.sequence <= merged) continue;
          // Re-uploaded with nothing newer than what was merged from it
          // (a day folded into its month, a restore, new encryption): the
          // listing says so, and the file isn't downloaded.
          if (merged != null &&
              file.newest != null &&
              file.newest! <= (peersNewest[name] ?? 0)) {
            await repository.markMerged(name, file.sequence);
            continue;
          }
          final data = await _read(() => readFile(transport, file, lookup));
          if (data != null) changed += await merge(name, file.sequence, data);
        }
        // A phone on the previous version: its single file.
        if (phone.single case final single?) {
          final name = '${phone.mirrorId}/';
          if (single.sequence > (peers[name] ?? 0)) {
            final data = await _read(() => readFile(transport, single, lookup));
            if (data != null) {
              changed += await merge(name, single.sequence, data);
            }
          }
        }
        // An older version's chain: only whole listings show all of it.
        if (listAll && phone.legacy.isNotEmpty) {
          final end = chainEnd(phone.legacy);
          if (end > (peers[phone.mirrorId] ?? 0)) {
            final data = await _read(
              () => readChain(transport, phone.legacy, lookup),
            );
            if (data != null) changed += await merge(phone.mirrorId, end, data);
          }
        }
      }
      await repository.saveListState(cursor, full: listAll);
      if (nextToken != null) await repository.saveChangesToken(nextToken);
      return changed;
    } finally {
      transport.close();
    }
  }

  /// Reads one file, or null when it can't be read now: locked with a PIN
  /// this phone doesn't have, damaged, or replaced or deleted while being
  /// read. It is tried again on the next check.
  static Future<SyncBackup?> _read(Future<SyncBackup?> Function() read) async {
    try {
      return await read();
    } on BackupEncryptionException {
      return null;
    } on DriveSyncException catch (error) {
      if (error.message.startsWith('Update')) rethrow;
      return null;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  /// Deletes what this phone no longer needs on Drive: the single file or
  /// batches an older version of it uploaded, once its sections are up, and
  /// section files it no longer tracks (e.g. a day file deleted mid-way).
  Future<void> _cleanUpOwn(
    MirrorTransport transport,
    List<MirrorFile> files,
    String own,
  ) async {
    if (!await repository.hasSectionFiles()) return;
    final mine = await repository.ownFileIds();
    for (final file in files) {
      if (file.mirrorId != own || mine.contains(file.id)) continue;
      try {
        await transport.deleteFile(file.id);
      } catch (_) {
        return; // Tried again on the next full listing.
      }
    }
  }

  /// Replaces the ledger with [backup]: an imported file, or synced data. A
  /// phone's section files are read one at a time, so a big ledger never
  /// has to fit in memory at once; then the next pull merges the others.
  Future<void> restore(SyncBackup backup) => _owning((owner) async {
    if (backup.encryption case final configuration?) {
      final subject = await repository.subject();
      if (subject == null ||
          await keyStore.read(subject, configuration) == null) {
        throw BackupPinRequired(configuration);
      }
    }
    await repository.replaceLedger(owner, backup);
    if (backup.files.isNotEmpty) {
      final status = await repository.status();
      final subject = await repository.subject();
      final transport = await _openTransport(status.email!);
      try {
        for (final file in backup.files) {
          final data = await readFile(transport, file, (configuration) async {
            if (subject == null) return null;
            return keyStore.read(subject, configuration);
          });
          await repository.mergeSnapshot(
            '${file.mirrorId}/${file.section}',
            file.sequence,
            data,
            quiet: true,
          );
        }
      } finally {
        transport.close();
      }
    }
    // An imported file replaces this phone's data only. Sync stays off
    // until turned on again, then offers to keep it or use the synced data.
    if (!backup.fromDrive && (await repository.status()).enabled) {
      await repository.disconnect();
    }
  });

  Future<void> unlockEncryption(
    String pin,
    BackupEncryption configuration,
  ) async {
    final subject = await repository.subject();
    if (subject == null) throw StateError('Sign in to Google Drive first.');
    final key = await configuration.unlock(pin);
    await keyStore.save(subject, key);
  }

  Future<void> resumeUploads({BackupEncryption? encryption}) => _owning((
    owner,
  ) async {
    if (encryption != null) {
      final subject = await repository.subject();
      if (subject == null || await keyStore.read(subject, encryption) == null) {
        throw BackupPinRequired(encryption);
      }
    }
    await repository.resumeUploads(owner, encryption);
  });

  /// Turns encryption on for the account. When another phone already did,
  /// [pin] must be that phone's PIN, and its key is used, so every phone
  /// reads every other phone's files; otherwise a new key is made from it.
  Future<void> enableEncryption(String pin) async {
    if (await repository.peerEncryption() case final peer?) {
      return joinEncryption(pin, peer: peer);
    }
    final key = await BackupEncryption.create(pin);
    await _owning((owner) async {
      final subject = await repository.subject();
      final status = await repository.status();
      if (subject == null || !status.enabled) {
        throw StateError('Sign in to Google Drive first.');
      }
      if (status.restorePending) {
        throw StateError('Finish restoring your backup first.');
      }
      // Persist the secret before atomically activating it and reseeding a full
      // mirror. A failed secure-storage write leaves the current backup intact.
      await keyStore.save(subject, key);
      await repository.changeEncryption(owner, key.configuration);
    });
  }

  /// Takes the encryption the account's other phones chose (see
  /// [SyncStatus.peerEncryption]), unlocked with their [pin]: their files
  /// can be read again, and this phone's go up with the same key.
  Future<void> joinEncryption(
    String pin, {
    ({BackupEncryption config, int at})? peer,
  }) async {
    final chosen = peer ?? await repository.peerEncryption();
    if (chosen == null) {
      throw StateError('Your other phones don\'t use a PIN any more.');
    }
    final BackupKey key;
    try {
      key = await chosen.config.unlock(pin);
    } on BackupEncryptionException {
      throw const BackupEncryptionException(
        'That isn\'t the PIN your other phone uses. Try again.',
      );
    }
    final subject = await repository.subject();
    if (subject == null) throw StateError('Sign in to Google Drive first.');
    await keyStore.save(subject, key);
    await _owning(
      (owner) =>
          repository.changeEncryption(owner, chosen.config, at: chosen.at),
    );
  }

  /// Makes this phone use the newest encryption choice among the account's
  /// phones, as their files' metadata tells: turned off elsewhere, it turns
  /// off here; turned on with a key this phone has, it switches to it; with
  /// one it doesn't have, it waits for that PIN ([SyncStatus.peerEncryption])
  /// and keeps uploading its own changes meanwhile. A choice made here that
  /// is newer is left for the others to follow.
  Future<void> _followEncryption(
    MirrorTransport transport,
    List<MirrorFile> files,
    String own,
  ) async {
    MirrorFile? newest;
    for (final file in files) {
      final choice = file.encryption;
      if (file.mirrorId == own || choice == null) continue;
      final best = newest;
      final order = best == null
          ? 1
          : compareEncryptionChoices(
              (file.encryptionAt ?? 0, choice),
              (best.encryptionAt ?? 0, best.encryption!),
            );
      // The same choice: its smallest file, to read the key settings from.
      if (order > 0 ||
          (order == 0 && (file.rows ?? 0) < (best!.rows ?? 0))) {
        newest = file;
      }
    }
    if (newest == null) return;
    final theirs = (newest.encryptionAt ?? 0, newest.encryption!);
    final status = await repository.status();
    if (status.restorePending) return;
    final mine = (
      await repository.encryptionAt(),
      encryptionFingerprint(status.encryption),
    );
    if (theirs.$2 == mine.$2) {
      if (theirs.$1 > mine.$1) await repository.setEncryptionAt(theirs.$1);
      if (status.peerEncryption != null) {
        await repository.setPeerEncryption(null);
      }
      return;
    }
    if (compareEncryptionChoices(theirs, mine) <= 0) return;
    if (theirs.$2 == 'off') {
      await _owning(
        (owner) => repository.changeEncryption(owner, null, at: theirs.$1),
      );
      return;
    }
    final waiting = await repository.peerEncryption();
    BackupEncryption? config;
    if (waiting != null &&
        encryptionFingerprint(waiting.config) == theirs.$2) {
      config = waiting.config;
    } else {
      config = backupBatchEncryption(await transport.download(newest.id));
      // Replaced while being read: tried again on the next check.
      if (config == null || encryptionFingerprint(config) != theirs.$2) return;
    }
    final subject = await repository.subject();
    final key = subject == null ? null : await keyStore.read(subject, config);
    if (key != null) {
      final chosen = config;
      await _owning(
        (owner) => repository.changeEncryption(owner, chosen, at: theirs.$1),
      );
    } else if (waiting == null ||
        waiting.at != theirs.$1 ||
        waiting.config != config) {
      await repository.setPeerEncryption(config, at: theirs.$1);
    }
  }

  Future<void> disableEncryption(String pin) async {
    final configuration = (await repository.status()).encryption;
    if (configuration == null) return;
    await configuration.unlock(pin);
    await _owning((owner) async {
      if ((await repository.status()).encryption != configuration) {
        throw StateError('Backup settings changed. Try again.');
      }
      await repository.changeEncryption(owner, null);
    });
  }

  /// Deletes everything on this phone; categories go back to the defaults.
  /// The Drive copy is untouched, and sync turns off: left on, it would
  /// bring everything back from the other phones' files.
  Future<void> eraseDevice() => _owning((owner) async {
    await repository.replaceLedger(
      owner,
      SyncBackup(
        mirrorId: 'erase',
        updatedAt: DateTime.now(),
        schemaVersion: 0,
        tables: const {},
      ),
      defaultCategories: true,
    );
    if ((await repository.status()).enabled) await repository.disconnect();
  });

  /// Turns sync off, then deletes every SimpleMoney file from the account's
  /// Drive. Turning sync on again uploads all of this phone's data.
  Future<void> eraseDrive() async {
    final email = (await repository.status()).email;
    if (email == null) throw StateError('Sign in to Google Drive first.');
    await _owning((owner) async {
      // Off before listing, so no upload can land after the wipe.
      await repository.disconnect();
      final transport = await _openTransport(email);
      try {
        final files = await transport.listFiles();
        var next = 0;
        Future<void> worker() async {
          while (next < files.length) {
            await transport.deleteFile(files[next++].id);
          }
        }

        await Future.wait([
          for (var i = 0; i < min(6, files.length); i++) worker(),
        ]);
      } finally {
        transport.close();
      }
      await repository.forgetFiles();
      await repository.restartMirror();
    });
  }

  /// Waits briefly for an upload another runner (e.g. WorkManager) is
  /// finishing, then runs [action] while no one else can upload.
  Future<void> _owning(Future<void> Function(String owner) action) async {
    final owner = newLeaseOwner();
    var attempts = 0;
    while (!await repository.acquire(
      owner,
      force: true,
      requireEnabled: false,
    )) {
      if (++attempts == 30) {
        throw StateError('An upload is finishing. Try again shortly.');
      }
      await Future<void>.delayed(const Duration(seconds: 1));
    }
    try {
      await action(owner);
    } finally {
      await repository.release(owner);
    }
  }

  /// Uploads the sections whose records changed. False asks WorkManager to
  /// retry; everything stays queued until every section is verified on
  /// Drive.
  Future<bool> run({bool force = false}) async {
    final owner = newLeaseOwner();
    final initial = await repository.status();
    if (!initial.enabled) return true;
    if (initial.restorePending) return false;
    if (initial.pending == 0) return true;
    if (!await repository.acquire(owner, force: force)) return false;
    MirrorTransport? transport;
    try {
      // Re-read after acquiring ownership: an account change could have happened
      // between the initial status check and the lease acquisition.
      final current = await repository.status();
      if (!current.enabled || current.restorePending) return true;
      BackupKey? key;
      if (current.encryption case final configuration?) {
        final subject = await repository.subject();
        key = subject == null
            ? null
            : await keyStore.read(subject, configuration);
        if (key == null) throw BackupPinRequired(configuration);
      }
      final mirror = await repository.mirrorId();
      final choice = (
        encryptionFingerprint(current.encryption),
        await repository.encryptionAt(),
      );
      transport = await _openTransport(current.email!);
      // Edits made during an upload go up with the next. Bounded so a
      // background run ends.
      var reported = false;
      for (var round = 0; round < 3; round++) {
        final plan = await repository.uploadPlan();
        if (plan == null) {
          if (reported) progress?.finished();
          return true;
        }
        progress?.started(plan.sections.length);
        reported = true;
        for (final (index, section) in plan.sections.indexed) {
          if (!await repository.renew(owner)) return true;
          await _uploadSection(transport, mirror, section, key, choice);
          progress?.advanced(index + 1, plan.sections.length);
        }
        for (final MapEntry(key: section, value: fileId)
            in plan.retire.entries) {
          try {
            await transport.deleteFile(fileId);
          } catch (_) {
            // Left behind; deleted by the next full listing's clean-up.
          }
          await repository.forgetFile(section);
        }
        if (!await repository.renew(owner)) return true;
        await repository.acknowledge(owner, plan);
      }
      final waiting = (await repository.status()).pending;
      if (reported) {
        if (waiting == 0) {
          progress?.finished();
        } else {
          progress?.failed(waiting);
        }
      }
      return waiting == 0;
    } catch (error) {
      final message = switch (error) {
        DriveSyncException(:final message) => message,
        BackupEncryptionException(:final message) => message,
        PlatformException(code: 'authorization_required') =>
          'Reconnect your Google account to resume sync.',
        _ => 'Waiting for a connection. Your changes are saved on this device.',
      };
      await repository.failed(owner, message);
      progress?.failed((await repository.status()).pending);
      return false;
    } finally {
      transport?.close();
      await repository.release(owner);
    }
  }

  /// Uploads [section] as it is now, making its file first when needed. The
  /// file's ID is saved before it is created, so a lost response never
  /// leaves a second copy.
  Future<void> _uploadSection(
    MirrorTransport transport,
    String mirror,
    String section,
    BackupKey? key,
    (String, int) choice,
  ) async {
    for (var attempt = 0; ; attempt++) {
      var file = await repository.sectionFile(section);
      final sequence = await repository.nextSequence();
      final built = await repository.buildSection(section, sequence);
      // Nothing in it and no file yet (an unused table): nothing to make.
      if (file == null && built.empty) return;
      if (file == null) {
        final id = await transport.newFileId();
        await repository.reserveFile(section, id);
        file = (id: id, created: false);
      }
      final payload = key == null
          ? built.bytes
          : await key.encrypt(built.bytes, mirror, sequence);
      try {
        await transport.upload(
          SyncBatch(
            fileId: file.id,
            mirrorId: mirror,
            sequence: sequence,
            payload: payload,
            checksum: md5.convert(payload).toString(),
            replace: file.created,
            section: section,
            rows: built.rows,
            newest: built.newest,
            encryption: choice.$1,
            encryptionAt: choice.$2,
          ),
        );
      } on DriveFileMissing {
        // Deleted from Drive (e.g. by another phone): made again.
        await repository.forgetFile(section);
        if (attempt > 0) rethrow;
        continue;
      }
      await repository.fileUploaded(section, file.id, sequence);
      return;
    }
  }
}

/// Which of two encryption choices (when chosen, fingerprint) is newer and
/// so applies to every phone. Ties (choices from before phones recorded
/// when, both 0) go to encryption over none, then by fingerprint, so every
/// phone settles on the same one.
int compareEncryptionChoices((int, String) a, (int, String) b) {
  if (a.$1 != b.$1) return a.$1.compareTo(b.$1);
  final aOn = a.$2 != 'off', bOn = b.$2 != 'off';
  if (aOn != bOn) return aOn ? 1 : -1;
  return a.$2.compareTo(b.$2);
}
