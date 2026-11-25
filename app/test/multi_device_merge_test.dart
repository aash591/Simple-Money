import 'dart:typed_data';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_drive_listing.dart';

import 'package:simple_money/data/backup/backup_key_store.dart';
import 'package:simple_money/data/backup/drive_client.dart';
import 'package:simple_money/data/backup/sync_engine.dart';
import 'package:simple_money/data/backup/sync_notifications.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/account.dart';
import 'package:simple_money/domain/transaction.dart';

/// The account's appDataFolder: one file per phone, replaced on each upload.
class SharedDrive implements MirrorTransport {
  final files = <String, SyncBatch>{};
  final modified = <String, DateTime>{};
  var _ids = 0, _clock = 0;
  int listings = 0, downloads = 0, uploads = 0;

  /// Bytes uploaded so far.
  int uploaded = 0;

  /// The file holding [section] of [mirror]'s data (of the only phone, when
  /// null).
  SyncBatch fileOf(String section, {String? mirror}) =>
      files.values.singleWhere(
        (f) => f.section == section && (mirror == null || f.mirrorId == mirror),
      );

  /// The phones with files here.
  Set<String> get mirrors => {for (final f in files.values) f.mirrorId};

  @override
  Future<String> newFileId() async => 'file-${++_ids}';
  @override
  Future<void> upload(SyncBatch batch) async {
    if (batch.replace && !files.containsKey(batch.fileId)) {
      throw const DriveFileMissing();
    }
    uploads++;
    uploaded += batch.payload.length;
    files[batch.fileId] = batch;
    modified[batch.fileId] = DateTime(2026).add(Duration(minutes: ++_clock));
  }

  @override
  Future<List<MirrorFile>> listFiles({DateTime? modifiedAfter}) async {
    listings++;
    return fakeListing(
      files,
      (id) => modified[id]!,
      modifiedAfter: modifiedAfter,
    );
  }

  @override
  Future<Uint8List> download(String fileId) async {
    downloads++;
    return files[fileId]!.payload;
  }

  @override
  Future<void> deleteFile(String fileId) async => files.remove(fileId);
  @override
  void close() {}
}

class Phone {
  Phone(this.drive, {BackupKeyStore? keys}) {
    repository = SyncRepository(db);
    engine = SyncEngine(
      repository,
      openTransport: (_) async => drive,
      keyStore: keys,
    );
  }
  final SharedDrive drive;
  final db = AppDatabase(NativeDatabase.memory(), false);
  late final SyncRepository repository;
  late final SyncEngine engine;
  late final transactions = TransactionRepository(db);
  late final accounts = AccountRepository(db);

  Future<void> upload() async => expect(await engine.run(force: true), isTrue);

  /// An engine for this phone that reports uploads to [progress].
  SyncEngine engineWith({UploadProgress? progress}) => SyncEngine(
    repository,
    openTransport: (_) async => drive,
    keyStore: engine.keyStore,
    progress: progress,
  );
  Future<int> pull() => engine.pull();

  Future<Account> account(int id) async =>
      (await accounts.load()).singleWhere((a) => a.id == id);
  Future<List<MoneyTransaction>> ledger() => transactions.load();
  Future<int> food() async => (await CategoryRepository(db).load())
      .firstWhere((c) => c.parentId == null && c.type.name == 'expense')
      .id;

  Future<int> spend(int account, int amount, {String? title}) async =>
      transactions.addExpenseOrIncome(
        type: TransactionType.expense,
        amountMinor: amount,
        accountId: account,
        categoryId: await food(),
        title: title,
        date: DateTime(2026, 11, 18),
      );
}

void main() {
  late SharedDrive drive;
  late Phone a, b;
  late int cash;

  // Phone A has the ledger; phone B joins by restoring it. Both then sync.
  setUp(() async {
    drive = SharedDrive();
    a = Phone(drive);
    b = Phone(drive);
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
    expect(await a.pull(), 0); // B's restored copy is nothing new to A.
    expect(await b.pull(), 0);
  });
  tearDown(() async {
    await a.db.close();
    await b.db.close();
  });

  test('an edit on one phone shows up on the other', () async {
    await a.spend(cash, 2500, title: 'Lunch');
    await a.upload();
    expect(await b.pull(), greaterThan(0));
    final lunch = (await b.ledger()).single;
    expect(lunch.title, 'Lunch');
    expect((await b.account(cash)).balanceMinor, 100000 - 2500);
    expect((await b.account(cash)).transactionCount, 1);
  });

  test('spending on both phones at once keeps both in the balance', () async {
    await a.spend(cash, 1000, title: 'Tea');
    await b.spend(cash, 2000, title: 'Bus');
    await a.upload();
    await b.upload();
    await a.pull();
    await b.pull();
    for (final phone in [a, b]) {
      expect(
        (await phone.ledger()).map((t) => t.title),
        unorderedEquals(['Tea', 'Bus']),
      );
      final account = await phone.account(cash);
      expect(account.balanceMinor, 100000 - 3000);
      expect(account.transactionCount, 2);
    }
  });

  test('the later edit of the same record wins on both phones', () async {
    final id = await a.spend(cash, 1000, title: 'First');
    await a.upload();
    await b.pull();
    Future<void> rename(Phone phone, String title) =>
        phone.transactions.updateExpenseOrIncome(
          id: id,
          type: TransactionType.expense,
          amountMinor: title == 'From B' ? 3000 : 1000,
          accountId: cash,
          categoryId: 1,
          title: title,
          date: DateTime(2026, 11, 18),
        );
    await rename(a, 'From A');
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await rename(b, 'From B'); // later
    await a.upload();
    await b.upload();
    await a.pull();
    await b.pull();
    for (final phone in [a, b]) {
      final only = (await phone.ledger()).single;
      expect(only.title, 'From B');
      expect((await phone.account(cash)).balanceMinor, 100000 - 3000);
    }
  });

  test('a deletion beats an older edit and never comes back', () async {
    final id = await a.spend(cash, 1000, title: 'Mistake');
    await a.upload();
    await b.pull();
    await b.transactions.updateExpenseOrIncome(
      id: id,
      type: TransactionType.expense,
      amountMinor: 1500,
      accountId: cash,
      categoryId: 1,
      title: 'Edited',
      date: DateTime(2026, 11, 18),
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await a.transactions.delete(id); // later
    await b.upload();
    await a.upload();
    await a.pull();
    await b.pull();
    for (final phone in [a, b]) {
      expect(await phone.ledger(), isEmpty);
      expect((await phone.account(cash)).balanceMinor, 100000);
    }
  });

  test(
    'a balance set by hand survives a later expense on the other phone',
    () async {
      await a.transactions.adjustBalance(
        accountId: cash,
        mode: BalanceAdjustmentMode.setTo,
        amountMinor: 50000,
      );
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await b.spend(cash, 700); // later, without knowing of the adjustment
      await a.upload();
      await b.upload();
      await a.pull();
      await b.pull();
      for (final phone in [a, b]) {
        expect((await phone.account(cash)).balanceMinor, 50000 - 700);
      }
    },
  );

  test('new accounts and transfers between them merge exactly', () async {
    final bank = await b.accounts.save(
      name: 'Bank',
      currency: 'INR',
      digits: 2,
      openingBalance: 900000,
    );
    await b.transactions.addTransfer(
      amountMinor: 20000,
      fromAccountId: bank,
      toAccountId: cash,
      date: DateTime(2026, 11, 18),
    );
    await a.spend(cash, 500);
    await b.upload();
    await a.upload();
    await a.pull();
    await b.pull();
    for (final phone in [a, b]) {
      expect((await phone.account(bank)).balanceMinor, 900000 - 20000);
      expect((await phone.account(cash)).balanceMinor, 100000 + 20000 - 500);
    }
  });

  test('an idle check downloads nothing', () async {
    final downloads = drive.downloads;
    for (var i = 0; i < 5; i++) {
      expect(await a.pull(), 0);
    }
    // B's own upload doesn't make B download it.
    await b.spend(cash, 100);
    await b.upload();
    expect(await b.pull(), 0);
    expect(drive.downloads, downloads);
    // Something from B: A fetches just the files B replaced, once.
    expect(await a.pull(), greaterThan(0));
    final fetched = drive.downloads - downloads;
    expect(fetched, inInclusiveRange(1, 3));
    expect(await a.pull(), 0);
    expect(drive.downloads, downloads + fetched);
  });

  test('a re-upload with nothing new is skipped unread', () async {
    await a.spend(cash, 900, title: 'Tea');
    await a.upload();
    expect(await b.pull(), greaterThan(0));
    // A uploads every section again (as after new encryption): newer files,
    // but nothing in them newer than what B merged.
    await a.repository.restartMirror();
    await a.upload();
    final downloads = drive.downloads;
    expect(await b.pull(), 0);
    expect(drive.downloads, downloads);
    // A real edit is still fetched.
    await a.spend(cash, 100, title: 'Bus');
    await a.upload();
    expect(await b.pull(), greaterThan(0));
    expect(drive.downloads, greaterThan(downloads));
    expect((await b.ledger()).map((t) => t.title), contains('Bus'));
  });

  test('each section is one file, replaced on each upload', () async {
    for (var i = 0; i < 4; i++) {
      await a.spend(cash, 100 + i);
      await a.upload();
      await b.spend(cash, 200 + i);
      await b.upload();
    }
    expect(
      drive.files,
      hasLength(
        {for (final f in drive.files.values) (f.mirrorId, f.section)}.length,
      ),
    );
    await a.pull();
    await b.pull();
    for (final phone in [a, b]) {
      expect(await phone.ledger(), hasLength(8));
    }
  });

  test('a phone whose file was deleted from Drive uploads it again', () async {
    drive.files.clear();
    await a.spend(cash, 100, title: 'After the wipe');
    await a.upload();
    expect(drive.mirrors, {await a.repository.mirrorId()});
    expect(await b.pull(), greaterThan(0));
    expect((await b.ledger()).single.title, 'After the wipe');
  });

  test(
    "merged changes aren't uploaded again by the phone that received them",
    () async {
      await a.spend(cash, 900);
      await a.upload();
      await b.pull();
      final queued = await b.db.customSelect('SELECT * FROM sync_outbox').get();
      expect(queued, isEmpty);
    },
  );

  test(
    'a phone that keeps its own data gets the others\' and they get its',
    () async {
      await a.spend(cash, 300, title: 'From A');
      await a.upload();
      // C had its own ledger before connecting and keeps it.
      final c = Phone(drive);
      addTearDown(c.db.close);
      final wallet = await c.accounts.save(
        name: 'Wallet',
        currency: 'INR',
        digits: 2,
        openingBalance: 5000,
      );
      await c.spend(wallet, 1200, title: 'From C');
      await c.repository.connect('me@example.com', 'me');
      await c.upload();
      expect(await c.pull(), greaterThan(0));
      await a.pull();
      await b.pull();
      for (final phone in [a, b, c]) {
        expect(
          (await phone.ledger()).map((t) => t.title),
          unorderedEquals(['From A', 'From C']),
        );
        expect((await phone.account(cash)).balanceMinor, 100000 - 300);
        expect((await phone.account(wallet)).balanceMinor, 5000 - 1200);
      }
      // And it keeps going both ways.
      await c.spend(cash, 50, title: 'Later from C');
      await c.upload();
      await a.pull();
      expect((await a.ledger()).map((t) => t.title), contains('Later from C'));
      final peers = await a.repository.peers();
      final cMirror = await c.repository.mirrorId();
      expect(peers.keys.any((k) => k.startsWith('$cMirror/')), isTrue);
    },
  );

  test('a batch applies once even if pulled twice at the same time', () async {
    await a.spend(cash, 400);
    await a.upload();
    await Future.wait([b.pull(), b.pull()]);
    expect(await b.ledger(), hasLength(1));
    expect((await b.account(cash)).balanceMinor, 100000 - 400);
    final applied = await b.db
        .customSelect(
          "SELECT max(applied) AS n FROM sync_peers WHERE mirror_id LIKE ?",
          variables: [Variable('${await a.repository.mirrorId()}/%')],
        )
        .getSingle();
    expect(applied.read<int>('n'), greaterThan(1));
  });

  test(
    "a new phone's untouched default categories don't undo a rename",
    () async {
      await a.db.customStatement(
        "UPDATE categories SET name = 'Groceries' WHERE id = 1",
      );
      await a.upload();
      final c = Phone(drive);
      addTearDown(c.db.close);
      await c.repository.connect('me@example.com', 'me');
      await c.upload(); // its defaults, never changed
      await a.pull();
      final name = await a.db
          .customSelect('SELECT name FROM categories WHERE id = 1')
          .getSingle();
      expect(name.read<String>('name'), 'Groceries');
    },
  );
}
