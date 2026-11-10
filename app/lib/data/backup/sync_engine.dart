import 'dart:async';
import 'dart:math';

import 'package:drive_authorization/drive_authorization.dart';
import 'package:flutter/services.dart';

import 'drive_client.dart';
import 'backup_encryption.dart';
import 'backup_key_store.dart';
import 'sync_repository.dart';
import 'sync_restore.dart';

typedef OpenMirrorTransport = Future<MirrorTransport> Function(String email);

class SyncEngine {
  SyncEngine(
    this.repository, {
    OpenMirrorTransport? openTransport,
    BackupKeyStore? keyStore,
  }) : _openTransport = openTransport ?? _googleTransport,
       keyStore = keyStore ?? const SecureBackupKeyStore();
  final BackupKeyStore keyStore;
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

  /// Replaces the ledger with [backup] — synced data or an imported file.
  Future<void> restore(SyncBackup backup) => _owning((owner) async {
    if (backup.encryption case final configuration?) {
      final subject = await repository.subject();
      if (subject == null ||
          await keyStore.read(subject, configuration) == null) {
        throw BackupPinRequired(configuration);
      }
    }
    await repository.replaceLedger(owner, backup);
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

  Future<void> enableEncryption(String pin) async {
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
  /// The Drive copy is untouched: the phone continues on a new mirror.
  Future<void> eraseDevice() => _owning(
    (owner) => repository.replaceLedger(
      owner,
      SyncBackup(
        mirrorId: 'erase',
        updatedAt: DateTime.now(),
        schemaVersion: 0,
        tables: const {},
      ),
      defaultCategories: true,
    ),
  );

  /// Turns sync off, then deletes every SimpleMoney file from the account's
  /// Drive. Turning sync on again uploads this phone's data as a new mirror.
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
      await repository.restartMirror();
    });
  }

  /// Waits briefly for an upload another runner (e.g. WorkManager) is
  /// finishing, then runs [action] while no one else can upload.
  Future<void> _owning(Future<void> Function(String owner) action) async {
    final owner = newSyncId();
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

  /// False asks WorkManager to retry; all data stays local until verified.
  Future<bool> run({bool force = false}) async {
    final owner = newSyncId();
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
      transport = await _openTransport(current.email!);
      // Bound each background run. A later run drains any remaining edits.
      for (var count = 0; count < 8; count++) {
        if (!await repository.renew(owner)) return true;
        var batch = await repository.pendingBatch();
        if (batch == null) {
          if ((await repository.status()).pending == 0) return true;
          final fileId = await transport.newFileId();
          batch = await repository.freeze(
            owner,
            fileId,
            encodePayload: key?.encrypt,
          );
        }
        if (batch == null || !await repository.renew(owner)) return true;
        await transport.upload(batch);
        await repository.acknowledge(owner, batch);
      }
      return (await repository.status()).pending == 0;
    } catch (error) {
      final message = switch (error) {
        DriveSyncException(:final message) => message,
        BackupEncryptionException(:final message) => message,
        PlatformException(code: 'authorization_required') =>
          'Reconnect your Google account to resume sync.',
        _ => 'Waiting for a connection. Your changes are saved on this device.',
      };
      await repository.failed(owner, message);
      return false;
    } finally {
      transport?.close();
      await repository.release(owner);
    }
  }
}
