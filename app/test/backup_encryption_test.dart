import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/backup/backup_encryption.dart';
import 'package:simple_money/data/backup/backup_key_store.dart';
import 'package:simple_money/data/backup/sync_engine.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';

import 'drive_sync_test.dart' show FakeDrive;

class MemoryKeys implements BackupKeyStore {
  final keys = <String, BackupKey>{};
  bool failWrites = false;
  @override
  Future<BackupKey?> read(
    String subject,
    BackupEncryption configuration,
  ) async => keys['$subject:${configuration.encoded}'];
  @override
  Future<void> save(String subject, BackupKey key) async {
    if (failWrites) throw StateError('Secure storage unavailable');
    keys['$subject:${key.configuration.encoded}'] = key;
  }

  @override
  Future<void> forget(String subject) async =>
      keys.removeWhere((name, _) => name.startsWith('$subject:'));
}

void main() {
  late BackupKey key;
  setUpAll(() async => key = await BackupEncryption.create('Ab12x9'));

  test(
    'v42 upgrade preserves queued data and restore hold survives reopening',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'money_encryption_',
      );
      final file = File('${directory.path}/ledger.sqlite');
      var db = AppDatabase(NativeDatabase(file), false);
      try {
        await AccountRepository(db).save(
          name: 'Existing',
          currency: 'INR',
          digits: 2,
          openingBalance: 12345,
        );
        final repository = SyncRepository(db);
        await repository.connect('test@example.com', 'subject');
        final pending = (await repository.status()).pending;
        await db.customStatement(
          'ALTER TABLE sync_state DROP COLUMN encryption_config',
        );
        await db.customStatement(
          'ALTER TABLE sync_state DROP COLUMN restore_pending',
        );
        await db.customStatement('PRAGMA user_version = 42');
        await db.close();
        db = AppDatabase(NativeDatabase(file), false);
        final upgraded = SyncRepository(db);
        expect((await AccountRepository(db).load()).single.balanceMinor, 12345);
        expect((await upgraded.status()).pending, pending);
        expect((await upgraded.status()).encryption, isNull);
        await upgraded.holdUploads(true);
        await db.close();
        db = AppDatabase(NativeDatabase(file), false);
        final reopened = SyncRepository(db);
        expect((await reopened.status()).restorePending, isTrue);
        expect(await reopened.acquire('background', force: true), isFalse);
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('PIN is exactly six case-sensitive ASCII letters or digits', () async {
    for (final invalid in [
      '',
      '12345',
      '1234567',
      'abc!12',
      'abc 12',
      'abcé12',
    ]) {
      expect(BackupEncryption.validPin(invalid), isFalse);
    }
    expect(BackupEncryption.validPin('123456'), isTrue);
    expect(BackupEncryption.validPin('ABCdef'), isTrue);
    await expectLater(
      key.configuration.unlock('ab12x9'),
      throwsA(isA<BackupEncryptionException>()),
    );
    final recovered = await key.configuration.unlock('Ab12x9');
    expect(
      await recovered.secret.extractBytes(),
      await key.secret.extractBytes(),
    );
  });

  test(
    'fresh nonces, authenticated contents and mirror identity, legacy support',
    () async {
      final plain = Uint8List.fromList(utf8.encode('private ledger'));
      final first = await key.encrypt(plain, 'mirror', 1);
      final second = await key.encrypt(plain, 'mirror', 1);
      expect(first, isNot(second));
      expect(utf8.decode(first), isNot(contains('private ledger')));
      expect(utf8.decode(first), isNot(contains('Ab12x9')));
      expect(
        await decryptBackupBatch(first, 'mirror', 1, (_) async => key),
        plain,
      );
      await expectLater(
        decryptBackupBatch(first, 'mirror', 1, null),
        throwsA(isA<BackupPinRequired>()),
      );
      await expectLater(
        decryptBackupBatch(first, 'other', 1, (_) async => key),
        throwsA(isA<BackupEncryptionException>()),
      );
      await expectLater(
        decryptBackupBatch(first, 'mirror', 2, (_) async => key),
        throwsA(isA<BackupEncryptionException>()),
      );
      final envelope = jsonDecode(utf8.decode(first)) as Map<String, dynamic>;
      final box = envelope['box'] as Map<String, dynamic>;
      final ciphertext = base64Decode(box['ciphertext'] as String);
      ciphertext[0] ^= 1;
      box['ciphertext'] = base64Encode(ciphertext);
      await expectLater(
        decryptBackupBatch(
          Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
          'mirror',
          1,
          (_) async => key,
        ),
        throwsA(isA<BackupEncryptionException>()),
      );
      expect(await decryptBackupBatch(plain, 'mirror', 1, null), plain);
    },
  );

  test('encrypted restore holds uploads, rejects wrong PIN, and replaces the plain copy', () async {
    final db = AppDatabase(NativeDatabase.memory(), false);
    final fresh = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(db.close);
    addTearDown(fresh.close);
    final repository = SyncRepository(db);
    final drive = FakeDrive();
    final keys = MemoryKeys();
    final engine = SyncEngine(
      repository,
      keyStore: keys,
      openTransport: (_) async => drive,
    );
    await AccountRepository(
      db,
    ).save(name: 'Wallet', currency: 'INR', digits: 2, openingBalance: 10000);
    await repository.connect('test@example.com', 'subject');
    expect((await repository.status()).encryption, isNull);
    expect(await engine.run(), isTrue);
    final mine = await repository.mirrorId();
    SyncBatch fileOf(String mirror) => drive.files.values.singleWhere(
      (f) => f.mirrorId == mirror && f.section == 'accounts',
    );
    expect(backupBatchEncryption(fileOf(mine).payload), isNull);
    keys.failWrites = true;
    await expectLater(engine.enableEncryption('Ab12x9'), throwsStateError);
    expect((await repository.status()).encryption, isNull);
    keys.failWrites = false;
    await engine.enableEncryption('Ab12x9');
    drive.loseResponse = true;
    expect(await engine.run(), isFalse);
    final files = drive.files.length;
    final frozen = fileOf(mine).payload;
    expect(await engine.run(force: true), isTrue);
    // The retry replaced the same files rather than making more.
    expect(drive.files, hasLength(files));
    // The plain copies uploaded before are replaced, not kept beside them.
    expect(
      drive.files.values.every((f) => backupBatchEncryption(f.payload) != null),
      isTrue,
    );
    expect(backupBatchEncryption(frozen), isNotNull);

    final target = SyncRepository(fresh);
    final targetKeys = MemoryKeys();
    final targetEngine = SyncEngine(
      target,
      keyStore: targetKeys,
      openTransport: (_) async => drive,
    );
    await target.connect('test@example.com', 'subject', holdUploads: true);
    final count = drive.files.length;
    expect(await targetEngine.run(force: true), isFalse);
    expect(drive.files, hasLength(count));
    await expectLater(
      targetEngine.findBackup(requirePin: true),
      throwsA(isA<BackupPinRequired>()),
    );
    final configuration = (await repository.status()).encryption!;
    await expectLater(
      targetEngine.unlockEncryption('wrong1', configuration),
      throwsA(isA<BackupEncryptionException>()),
    );
    expect(await AccountRepository(fresh).load(), isEmpty);
    expect((await target.status()).restorePending, isTrue);
    await targetEngine.unlockEncryption('Ab12x9', configuration);
    final backup = (await targetEngine.findBackup())!;
    await targetEngine.restore(backup);
    await targetEngine.resumeUploads(encryption: backup.encryption);
    expect((await AccountRepository(fresh).load()).single.name, 'Wallet');
    expect(await targetEngine.run(force: true), isTrue);
    expect(
      backupBatchEncryption(fileOf(await target.mirrorId()).payload),
      configuration,
    );

    await targetKeys.forget('subject');
    await fresh.customStatement("UPDATE accounts SET name = 'Changed'");
    final before = drive.files.length;
    expect(await targetEngine.run(force: true), isFalse);
    expect(drive.files, hasLength(before));
    expect((await target.status()).error, contains('PIN'));
    await expectLater(
      engine.disableEncryption('wrong1'),
      throwsA(isA<BackupEncryptionException>()),
    );
    expect((await repository.status()).encryption, configuration);
    await engine.disableEncryption('Ab12x9');
    expect(await engine.run(force: true), isTrue);
    expect(backupBatchEncryption(fileOf(mine).payload), isNull);
  });
}
