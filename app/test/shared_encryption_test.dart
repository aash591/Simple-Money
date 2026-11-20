import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/backup/backup_encryption.dart';

import 'backup_encryption_test.dart' show MemoryKeys;
import 'multi_device_merge_test.dart' show Phone, SharedDrive;

/// Encryption is one setting for all of an account's phones: the newest
/// choice among them applies, and a phone without the key asks for the PIN
/// instead of silently missing the other phones' changes.
void main() {
  late SharedDrive drive;
  late Phone a, b;
  late int cash;

  Future<List<String?>> titles(Phone phone) async => [
    for (final t in await phone.ledger()) t.title,
  ];
  bool encrypted(Phone phone, String mirror) => drive.files.values
      .where((f) => f.mirrorId == mirror)
      .every((f) => backupBatchEncryption(f.payload) != null);

  setUp(() async {
    drive = SharedDrive();
    a = Phone(drive, keys: MemoryKeys());
    b = Phone(drive, keys: MemoryKeys());
    await a.repository.connect('me@example.com', 'me');
    cash = await a.accounts.save(
      name: 'Cash',
      currency: 'INR',
      digits: 2,
      openingBalance: 100000,
    );
    await a.upload();
    await b.repository.connect('me@example.com', 'me');
    await b.engine.restore((await b.engine.findBackup())!);
    await b.upload();
  });
  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });

  test('turned on on one phone: the other asks for the PIN, then follows', () async {
    await a.engine.enableEncryption('Ab12x9');
    await a.spend(cash, 900, title: 'Secret lunch');
    await a.upload();
    expect(encrypted(a, await a.repository.mirrorId()), isTrue);

    // B can't read A's files: it says so instead of silently missing them.
    await b.pull();
    expect((await b.repository.status()).peerEncryption, isNotNull);
    expect(await titles(b), isNot(contains('Secret lunch')));
    // Its own changes still go up, and A gets them.
    await b.spend(cash, 100, title: 'From B');
    await b.upload();
    await a.pull();
    expect(await titles(a), contains('From B'));

    await expectLater(
      b.engine.joinEncryption('wrong1'),
      throwsA(isA<BackupEncryptionException>()),
    );
    await b.engine.joinEncryption('Ab12x9');
    final status = await b.repository.status();
    expect(status.encryption, (await a.repository.status()).encryption);
    expect(status.peerEncryption, isNull);

    // Now B merges A's files, and uploads its own with the same key.
    await b.pull();
    expect(await titles(b), contains('Secret lunch'));
    await b.spend(cash, 50, title: 'After the PIN');
    await b.upload();
    expect(encrypted(b, await b.repository.mirrorId()), isTrue);
    await a.pull();
    expect(await titles(a), contains('After the PIN'));
    expect((await a.account(cash)).balanceMinor, 100000 - 900 - 100 - 50);
  });

  test('turned off on one phone: the others follow without a PIN', () async {
    await a.engine.enableEncryption('Ab12x9');
    await a.upload();
    await b.pull();
    await b.engine.joinEncryption('Ab12x9');
    await b.upload();

    await a.engine.disableEncryption('Ab12x9');
    await a.spend(cash, 300, title: 'Plain again');
    await a.upload();
    await b.pull();
    expect((await b.repository.status()).encryption, isNull);
    expect(await titles(b), contains('Plain again'));
    await b.upload();
    expect(
      drive.files.values.every((f) => backupBatchEncryption(f.payload) == null),
      isTrue,
    );
  });

  test('turned on on both phones separately: they settle on one key', () async {
    await a.engine.enableEncryption('Ab12x9');
    await a.upload();
    // B turns it on before seeing A's: a different key from the same PIN.
    await b.engine.enableEncryption('Ab12x9');
    await b.upload();
    expect(
      (await a.repository.status()).encryption,
      isNot((await b.repository.status()).encryption),
    );

    // B's choice is newer: A asks for it, and both end on B's key.
    await a.pull();
    expect((await a.repository.status()).peerEncryption, isNotNull);
    await a.engine.joinEncryption('Ab12x9');
    await a.upload();
    await b.pull();
    expect(
      (await a.repository.status()).encryption,
      (await b.repository.status()).encryption,
    );
    expect((await b.repository.status()).peerEncryption, isNull);
    await a.spend(cash, 70, title: 'Both locked');
    await a.upload();
    await b.pull();
    expect(await titles(b), contains('Both locked'));
  });

  test('turning it on where the others already did asks for their PIN', () async {
    await a.engine.enableEncryption('Ab12x9');
    await a.upload();
    await b.pull();
    // "Turn on encryption" on B: the other phones' key, not a new one.
    await expectLater(
      b.engine.enableEncryption('Zz98yy'),
      throwsA(isA<BackupEncryptionException>()),
    );
    await b.engine.enableEncryption('Ab12x9');
    expect(
      (await b.repository.status()).encryption,
      (await a.repository.status()).encryption,
    );
  });
}
