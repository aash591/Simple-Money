import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'fake_drive_listing.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/data/backup/drive_client.dart';
import 'package:simple_money/data/backup/sync_engine.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/backup/sync_schema.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/budget_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/state/sync_controller.dart';
import 'package:simple_money/ui/more/settings/sync/sync_screen.dart';
import 'package:simple_money/ui/welcome/backup_welcome_screen.dart';

Map<String, dynamic> decode(SyncBatch batch) =>
    jsonDecode(utf8.decode(gzip.decode(batch.payload))) as Map<String, dynamic>;

/// [table]'s rows in an uploaded device file.
List<Map<String, dynamic>> rowsIn(SyncBatch batch, String table) => [
  for (final row in (decode(batch)['tables'] as Map)[table] as List)
    Map<String, dynamic>.from(row as Map),
];

/// [table]'s rows across every file in [files].
List<Map<String, dynamic>> rowsAcross(Iterable<SyncBatch> files, String table) => [
  for (final file in files)
    if ((decode(file)['tables'] as Map).containsKey(table)) ...rowsIn(file, table),
];

/// A batch of the chain an older version of the app uploaded.
SyncBatch legacyBatch(
  String mirror,
  int sequence,
  List<Map<String, Object?>> changes,
) => SyncBatch(
  fileId: 'legacy-$mirror-$sequence',
  mirrorId: mirror,
  sequence: sequence,
  revision: sequence,
  checksum: '',
  payload: Uint8List.fromList(
    gzip.encode(
      utf8.encode(
        jsonEncode({
          'format': 'simple-money-mirror',
          'formatVersion': 1,
          'schemaVersion': 48,
          'mirrorId': mirror,
          'sequence': sequence,
          'createdAt': '2026-10-01T00:00:00.000Z',
          'changes': changes,
        }),
      ),
    ),
  ),
);

class FakeDrive implements MirrorTransport {
  final files = <String, SyncBatch>{};
  final modified = <String, DateTime>{};

  /// Files of an older version's chain, rather than a device's file.
  final legacy = <String>{};
  int allocated = 0, _clock = 0;

  /// Every upload, in order.
  final uploads = <SyncBatch>[];

  /// The file holding [section] of [mirror]'s data (of the only phone, when
  /// null).
  SyncBatch fileOf(String section, {String? mirror}) => files.values
      .singleWhere(
        (f) => f.section == section && (mirror == null || f.mirrorId == mirror),
      );

  /// The phones with files here.
  Set<String> get mirrors => {for (final f in files.values) f.mirrorId};


  void addLegacy(SyncBatch batch) {
    files[batch.fileId] = batch;
    legacy.add(batch.fileId);
    modified[batch.fileId] = DateTime(2026).add(Duration(minutes: ++_clock));
  }

  bool loseResponse = false;
  Future<void> Function(SyncBatch)? duringUpload;
  @override
  Future<String> newFileId() async => 'file-${++allocated}';
  @override
  Future<List<MirrorFile>> listFiles({DateTime? modifiedAfter}) async =>
      fakeListing(
        files,
        (id) => modified[id]!,
        legacy: legacy,
        modifiedAfter: modifiedAfter,
      );
  @override
  Future<Uint8List> download(String fileId) async => files[fileId]!.payload;
  @override
  Future<void> deleteFile(String fileId) async => files.remove(fileId);
  @override
  Future<void> upload(SyncBatch batch) async {
    if (batch.replace && !files.containsKey(batch.fileId)) {
      throw const DriveFileMissing();
    }
    uploads.add(batch);
    files[batch.fileId] = batch;
    modified[batch.fileId] = DateTime(2026).add(Duration(minutes: ++_clock));
    await duringUpload?.call(batch);
    if (loseResponse) {
      loseResponse = false;
      throw const SocketException('Connection lost after upload');
    }
  }

  @override
  void close() {}
}

class PreviewSyncController extends SyncController {
  PreviewSyncController(super.repository, {super.engine});
  @override
  bool get supported => true;
}

void main() {
  late AppDatabase db;
  late SyncRepository repository;
  late FakeDrive drive;
  late SyncEngine engine;
  setUp(() {
    db = AppDatabase(NativeDatabase.memory(), false);
    repository = SyncRepository(db);
    drive = FakeDrive();
    engine = SyncEngine(repository, openTransport: (_) async => drive);
  });
  tearDown(() => db.close());

  testWidgets('Unchanged sync polls do not rebuild listeners', (tester) async {
    final controller = SyncController(repository);
    addTearDown(controller.dispose);
    var updates = 0;
    controller.addListener(() => updates++);

    await controller.refresh();
    expect(updates, 1);
    await controller.refresh();
    await controller.refresh();
    expect(updates, 1);

    await repository.connect('test@example.com', 'test-subject');
    await controller.refresh();
    expect(updates, 2);
    expect(controller.status!.enabled, isTrue);
    await controller.refresh();
    expect(updates, 2);

    await repository.disconnect();
    await controller.refresh();
    expect(updates, 3);
    expect(controller.status!.enabled, isFalse);
  });

  Future<bool> connect() =>
      repository.connect('test@example.com', 'google-user-1');
  Future<int> addAccount([String name = 'Cash']) =>
      AccountRepository(db)
          .save(name: name, currency: 'INR', digits: 2, openingBalance: 100000);

  test('OS-restored database starts an independent paused mirror', () async {
    await repository.bindInstallation('original-device');
    await connect();
    await engine.run();
    final originalMirror = drive.mirrors.single;
    await repository.bindInstallation('original-device');
    expect((await repository.status()).enabled, isTrue);
    await repository.bindInstallation('replacement-device');
    final status = await repository.status();
    expect(status.enabled, isFalse);
    expect(status.lastSynced, isNull);
    expect(status.pending, greaterThan(0));
    await connect();
    await engine.run();
    expect(drive.mirrors, hasLength(2));
    expect(drive.mirrors, contains(await repository.mirrorId()));
    expect(await repository.mirrorId(), isNot(originalMirror));
  });

  test('A reinstall restores the newest backup with data, then mirrors it anew', () async {
    final from = await addAccount();
    final to = await addAccount('Bank');
    await TransactionRepository(db).addTransfer(
      amountMinor: 1200,
      fromAccountId: from,
      toAccountId: to,
      date: DateTime(2026, 9, 11),
    );
    await connect();
    expect(await engine.run(), isTrue);
    await db.customStatement(
      "UPDATE accounts SET name = 'Wallet' WHERE id = $from",
    );
    expect(await engine.run(), isTrue);
    final originalMirror = await repository.mirrorId();

    // Cleared app data: a fresh install on the same account first uploads
    // nothing but its default categories.
    final fresh = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(fresh.close);
    final freshRepository = SyncRepository(fresh);
    final freshEngine = SyncEngine(
      freshRepository,
      openTransport: (_) async => drive,
    );
    expect(
      await freshRepository.connect('test@example.com', 'google-user-1'),
      isTrue,
    );
    expect(await freshEngine.run(), isTrue);
    expect(await AccountRepository(fresh).load(), isEmpty);

    final backup = (await freshEngine.findBackup())!;
    expect(backup.mirrorId, originalMirror);
    expect(backup.count('accounts'), 2);
    expect(backup.count('transactions'), 1);
    await freshEngine.restore(backup);

    Future<List<Map<String, Object?>>> rows(
      AppDatabase d,
      String table,
    ) async => [
      for (final row
          in await d
              .customSelect(
                'SELECT * FROM $table ORDER BY ${syncTables[table]!.join(', ')}',
              )
              .get())
        row.data,
    ];
    for (final table in syncTables.keys) {
      expect(await rows(fresh, table), await rows(db, table), reason: table);
    }
    expect(
      (await AccountRepository(fresh).load()).map((a) => a.name),
      containsAll(['Wallet', 'Bank']),
    );

    final status = await freshRepository.status();
    expect(status.enabled, isTrue);
    expect(status.pending, greaterThan(0));
    expect(await freshEngine.run(), isTrue);
    // The fresh install's own files now hold the restored data.
    expect(drive.mirrors, hasLength(2));
    final freshMirror = await freshRepository.mirrorId();
    expect(freshMirror, isNot(originalMirror));
    expect(
      rowsIn(drive.fileOf('accounts', mirror: freshMirror), 'accounts'),
      hasLength(2),
    );
    expect(
      rowsAcross(
        drive.files.values.where((f) => f.mirrorId == freshMirror),
        'transactions',
      ),
      hasLength(1),
    );
    // The newer categories-only mirror from before the restore is skipped.
    expect((await freshEngine.findBackup())!.mirrorId, originalMirror);
  });

  test('Reconnecting the same account is not a new link', () async {
    expect(await connect(), isTrue);
    await repository.disconnect();
    expect(await connect(), isFalse);
  });

  test(
    'Deleting Drive data turns sync off and re-uploads a full copy later',
    () async {
      await addAccount();
      await connect();
      await engine.run();
      await addAccount('Bank');
      await engine.run();
      expect(drive.files, isNotEmpty);
      final oldMirror = await repository.mirrorId();
      await engine.eraseDrive();
      expect(drive.files, isEmpty);
      final status = await repository.status();
      expect(status.enabled, isFalse);
      expect(status.lastSynced, isNull);
      expect(await AccountRepository(db).load(), hasLength(2));
      await connect();
      await engine.run();
      final file = drive.fileOf('accounts');
      expect(file.mirrorId, oldMirror);
      expect(file.replace, isFalse); // made again, not replaced
      expect(rowsIn(file, 'accounts'), hasLength(2));
    },
  );

  test('Only entered data counts as this phone having data', () async {
    expect(await repository.hasLedgerData(), isFalse);
    await addAccount();
    expect(await repository.hasLedgerData(), isTrue);
  });

  test("An older version's chain is read only up to its first gap", () async {
    Map<String, Object?> account(int id, String name) => {
      'table': 'accounts',
      'key': [id],
      'hlc': hlcAt(DateTime(2026, 10, id)),
      'row': {
        'id': id,
        'name': name,
        'currency': 'INR',
        'digits': 2,
        'balance_minor': 1000 * id,
        'sort_order': id,
      },
    };
    drive.addLegacy(legacyBatch('old', 1, [account(1, 'Cash')]));
    drive.addLegacy(legacyBatch('old', 2, [account(2, 'Bank')]));
    drive.addLegacy(legacyBatch('old', 4, [account(4, 'After a gap')]));
    await connect();
    final backup = (await engine.findBackup())!;
    expect(backup.mirrorId, 'old');
    expect(backup.count('accounts'), 2);
    // Merged like any other phone's data.
    expect(await engine.pull(), 2);
    expect(
      (await AccountRepository(db).load()).map((a) => a.name),
      unorderedEquals(['Cash', 'Bank']),
    );
    expect((await AccountRepository(db).load()).first.balanceMinor, 1000);
    drive.files.remove('legacy-old-1');
    expect(await engine.findBackup(), isNull);
  });

  test(
    'Failure backoff prevents repeated requests until an explicit retry',
    () async {
      await connect();
      var attempts = 0;
      final offline = SyncEngine(
        repository,
        openTransport: (_) async {
          attempts++;
          throw const SocketException('offline');
        },
      );
      expect(await offline.run(), isFalse);
      expect(await offline.run(), isFalse);
      expect(attempts, 1);
      expect((await repository.status()).pending, greaterThan(0));
      expect(await engine.run(force: true), isTrue);
      expect((await repository.status()).error, isNull);
    },
  );

  testWidgets(
    'Sync screen shows pending, success, and paused states at phone width',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = PreviewSyncController(repository, engine: engine);
      addTearDown(controller.dispose);
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(home: SyncScreen(controller: controller)),
      );
      expect(find.text('Sign in with Google'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await connect();
      await controller.refresh();
      await tester.pump();
      // Before the first upload lands, the screen shows sync in progress.
      expect(find.text('Syncing…'), findsWidgets);
      expect(find.text('Up to date'), findsNothing);
      await engine.run();
      await controller.refresh();
      await tester.pump();
      expect(find.text('Up to date'), findsOneWidget);
      expect(find.text('Sync now'), findsOneWidget);
      expect(
        tester.getSize(find.widgetWithText(GlassButton, 'Sync now')).height,
        48,
      );
      expect(find.text('Turn off sync'), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      await tester.tap(find.text('Sync now'));
      await tester.pump();
      expect(controller.manualSyncing, isTrue);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(controller.manualSyncing, isFalse);
      expect(find.text('Sync now'), findsOneWidget);
      // The profile refresh is best-effort and has its own ten-second limit.
      await tester.pump(const Duration(seconds: 10));
      await db.customStatement(
        "INSERT INTO budgets (kind, currency, digits) VALUES ('total', 'INR', 2)",
      );
      await controller.refresh();
      await tester.pump();
      expect(find.text('1 change waiting'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await repository.disconnect();
      await controller.refresh();
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: SyncScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Turn on sync'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Backup welcome explains the feature on a small screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BackupWelcomeContent()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Keep your data safe'), findsOneWidget);
    expect(find.textContaining('Free, private and automatic'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test(
    'Initial mirror includes existing rows; edits coalesce and deletes remain',
    () async {
      final cash = await addAccount();
      await connect();
      expect(await engine.run(), isTrue);
      final file = drive.fileOf('accounts');
      final count = drive.files.length;
      expect(rowsIn(file, 'accounts'), hasLength(1));
      expect(rowsIn(drive.fileOf('categories'), 'categories'), isNotEmpty);
      await db.customStatement("UPDATE accounts SET name = 'Wallet'");
      await db.customStatement("UPDATE accounts SET name = 'Pocket'");
      expect((await repository.status()).pending, 1);
      expect(await engine.run(), isTrue);
      // Only the accounts file, replaced.
      expect(drive.files, hasLength(count));
      expect(drive.uploads.last.section, 'accounts');
      final edited = drive.fileOf('accounts');
      expect(edited.fileId, file.fileId);
      expect(edited.sequence, greaterThan(file.sequence));
      expect(rowsIn(edited, 'accounts').single['name'], 'Pocket');
      await AccountRepository(db).delete(cash);
      expect(await engine.run(), isTrue);
      final deleted = drive.fileOf('accounts');
      expect(rowsIn(deleted, 'accounts'), isEmpty);
      // The deletion's version stays, so the other phones delete it too.
      expect(
        ((decode(deleted)['versions'] as Map)['accounts'] as Map).keys,
        contains(jsonEncode([cash])),
      );
      expect((await repository.status()).pending, 0);
    },
  );

  test('Only the sections that changed are uploaded', () async {
    final cash = await addAccount();
    final transactions = TransactionRepository(db);
    final old = await transactions.addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: 500,
      accountId: cash,
      categoryId: 1,
      title: 'Old',
      date: DateTime(2025, 1, 5),
    );
    // Made in January 2025: it belongs to that month's file for good.
    await db.customStatement(
      'UPDATE transactions SET created_at = ? WHERE id = ?',
      [DateTime.utc(2025, 1, 5).millisecondsSinceEpoch, old],
    );
    await connect();
    expect(await engine.run(), isTrue);
    expect(drive.fileOf('transactions/2025-01'), isNotNull);

    // Editing an old record replaces only its month.
    drive.uploads.clear();
    await db.customStatement(
      "UPDATE transactions SET title = 'Old, edited' WHERE id = ?",
      [old],
    );
    expect(await engine.run(), isTrue);
    expect(drive.uploads.map((u) => u.section), ['transactions/2025-01']);

    // A new expense: today's file, and the account its balance moved.
    drive.uploads.clear();
    await transactions.addExpenseOrIncome(
      type: TransactionType.expense,
      amountMinor: 700,
      accountId: cash,
      categoryId: 1,
      title: 'Lunch',
      date: DateTime.now(),
    );
    expect(await engine.run(), isTrue);
    final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
    expect(
      drive.uploads.map((u) => u.section).toSet(),
      {'accounts', 'transactions/$today'},
    );

    // Deleting it: the deletion goes in this month's deletions file.
    drive.uploads.clear();
    await transactions.delete(old);
    expect(await engine.run(), isTrue);
    expect(
      drive.uploads.map((u) => u.section),
      contains('transactions/deleted/${today.substring(0, 7)}'),
    );
  });

  test("Yesterday's day file is folded into its month and deleted", () async {
    await addAccount();
    await connect();
    expect(await engine.run(), isTrue);
    // As if yesterday's records had their own file.
    drive.files['old-day'] = SyncBatch(
      fileId: 'old-day',
      mirrorId: await repository.mirrorId(),
      sequence: 1,
      payload: Uint8List(0),
      checksum: '',
      section: 'transactions/2020-01-01',
    );
    await repository.fileUploaded('transactions/2020-01-01', 'old-day', 1);
    await db.customStatement("UPDATE accounts SET name = 'Wallet'");
    expect(await engine.run(), isTrue);
    expect(drive.files.containsKey('old-day'), isFalse);
    expect(await repository.sectionFile('transactions/2020-01-01'), isNull);
  });

  test('Rollback leaves no queued change and no revision advance', () async {
    await connect();
    await engine.run();
    final before = await db
        .customSelect('SELECT revision FROM sync_state')
        .getSingle();
    await expectLater(
      db.transaction(() async {
        await addAccount();
        throw StateError('abort');
      }),
      throwsStateError,
    );
    expect((await repository.status()).pending, 0);
    expect(await AccountRepository(db).load(), isEmpty);
    final after = await db
        .customSelect('SELECT revision FROM sync_state')
        .getSingle();
    expect(after.read<int>('revision'), before.read<int>('revision'));
  });

  test('Edit during upload stays pending until a subsequent batch', () async {
    await addAccount();
    await connect();
    drive.duringUpload = (batch) async {
      if (batch.sequence == 1) {
        await db.customStatement("UPDATE accounts SET name = 'New name'");
      }
    };
    expect(await engine.run(), isTrue);
    final last = drive.fileOf('accounts');
    expect(last.sequence, greaterThan(1));
    expect(rowsIn(last, 'accounts').single['name'], 'New name');
    expect((await repository.status()).pending, 0);
  });

  test('A lost response never makes a second file', () async {
    await addAccount();
    await connect();
    drive.loseResponse = true;
    expect(await engine.run(), isFalse);
    expect((await repository.status()).pending, greaterThan(0));
    expect((await repository.status()).lastSynced, isNull);
    await addAccount('Bank');
    expect(await engine.run(force: true), isTrue);
    // One file per section, each made with the ID saved before it was.
    final sections = {for (final f in drive.files.values) f.section};
    expect(drive.files, hasLength(sections.length));
    expect(drive.allocated, drive.files.length);
    expect(rowsIn(drive.files.values.firstWhere((f) => f.section == 'accounts'), 'accounts'), hasLength(2));
    expect((await repository.status()).pending, 0);
  });

  test(
    'Composite keys and a transfer reconstruct the exact latest database',
    () async {
      final from = await addAccount();
      final to = await addAccount('Bank');
      await connect();
      await engine.run();
      await TransactionRepository(db).addTransfer(
        amountMinor: 1200,
        fromAccountId: from,
        toAccountId: to,
        date: DateTime(2026, 9, 11),
      );
      await db.transaction(() async {
        await db.customStatement(
          'INSERT INTO budgets (id, kind, name, currency, digits) '
          "VALUES(1, 'categories', 'Food', 'INR', 2)",
        );
        await db.customStatement('INSERT INTO budget_categories VALUES(1, 1)');
        await db.customStatement(
          'INSERT INTO budget_amounts VALUES(1, 202609, 50000)',
        );
      });
      await engine.run();
      await db.customStatement(
        'UPDATE budget_amounts SET start_month = 202610',
      );
      await db.customStatement('DELETE FROM budget_categories');
      await engine.run();
      for (final entry in syncTables.entries) {
        final rows = await db.customSelect('SELECT * FROM ${entry.key}').get();
        String key(Map<String, Object?> row) =>
            jsonEncode(entry.value.map((k) => row[k]).toList());
        expect(
          {
            for (final row in rowsAcross(drive.files.values, entry.key))
              key(row): row,
          },
          {
            for (final row in rows)
              key(row.data): jsonDecode(jsonEncode(row.data)),
          },
          reason: entry.key,
        );
      }
      expect(
        rowsIn(drive.fileOf('budget_amounts'), 'budget_amounts')
            .single['start_month'],
        202610,
      );
    },
  );

  test(
    'Foreground and background runners cannot own the mirror simultaneously',
    () async {
      await connect();
      expect(await repository.acquire('worker-a'), isTrue);
      expect(await repository.acquire('worker-b', force: true), isFalse);
      final plan = (await repository.uploadPlan())!;
      await db.customStatement('UPDATE sync_state SET lease_until = 0');
      expect(await repository.acquire('worker-b'), isTrue);
      // A runner that lost the lease can't mark anything as sent.
      await repository.acknowledge('worker-a', plan);
      expect((await repository.status()).pending, greaterThan(0));
      await repository.release('worker-a');
      expect((await repository.status()).busy, isTrue);
    },
  );

  test('Pausing keeps offline edits; changing account starts an independent full mirror', () async {
    await addAccount();
    await connect();
    await engine.run();
    final firstMirror = drive.mirrors.single;
    await repository.disconnect();
    await db.customStatement("UPDATE accounts SET name = 'Changed offline'");
    final before = drive.uploads.length;
    expect(await engine.run(), isTrue);
    expect(drive.uploads, hasLength(before));
    await connect();
    await engine.run();
    expect(drive.mirrors, {firstMirror});
    expect(
      rowsIn(drive.fileOf('accounts'), 'accounts').single['name'],
      'Changed offline',
    );
    await repository.disconnect();
    await repository.connect('second@example.com', 'google-user-2');
    await engine.run();
    final second = await repository.mirrorId();
    expect(second, isNot(firstMirror));
    final last = drive.fileOf('accounts', mirror: second);
    expect(last.sequence, 1);
    expect(last.replace, isFalse);
    expect(rowsIn(last, 'accounts'), hasLength(1));
  });

  test('A reserved file ID survives closing and reopening the database', () async {
    final directory = await Directory.systemTemp.createTemp('money_sync_');
    final file = File('${directory.path}/ledger.sqlite');
    var diskDb = AppDatabase(NativeDatabase(file), false);
    try {
      var diskRepository = SyncRepository(diskDb);
      await diskRepository.connect('test@example.com', 'user');
      await diskRepository.reserveFile('accounts', 'persistent-id');
      await diskDb.close();
      diskDb = AppDatabase(NativeDatabase(file), false);
      diskRepository = SyncRepository(diskDb);
      final reopened = (await diskRepository.sectionFile('accounts'))!;
      expect(reopened.id, 'persistent-id');
      expect(reopened.created, isFalse);
      expect((await diskRepository.status()).pending, greaterThan(0));
    } finally {
      await diskDb.close();
      await directory.delete(recursive: true);
    }
  });

  test('v7 upgrade queues existing data without changing the ledger', () async {
    final directory = await Directory.systemTemp.createTemp(
      'money_sync_migration_',
    );
    final file = File('${directory.path}/ledger.sqlite');
    var diskDb = AppDatabase(NativeDatabase(file), false);
    try {
      await AccountRepository(diskDb).save(
        name: 'Existing',
        currency: 'INR',
        digits: 2,
        openingBalance: 12345,
      );
      for (final table in syncTables.keys) {
        for (final operation in ['insert', 'update', 'delete']) {
          await diskDb.customStatement('DROP TRIGGER sync_${table}_$operation');
        }
      }
      for (final operation in ['insert', 'update', 'delete']) {
        await diskDb.customStatement(
          'DROP TRIGGER history_transactions_$operation',
        );
      }
      for (final table in [
        'sync_batch',
        'sync_outbox',
        'sync_state',
        'record_history',
      ]) {
        await diskDb.customStatement('DROP TABLE $table');
      }
      await diskDb.customStatement('ALTER TABLE budgets DROP COLUMN icon');
      await diskDb.customStatement('PRAGMA user_version = 7');
      await diskDb.close();
      diskDb = AppDatabase(NativeDatabase(file), false);
      final accounts = await AccountRepository(diskDb).load();
      expect(accounts.single.balanceMinor, 12345);
      expect((await SyncRepository(diskDb).status()).pending, greaterThan(0));
      await diskDb.customStatement("UPDATE accounts SET name = 'Edited'");
      final queued = await diskDb
          .customSelect(
            "SELECT row_json FROM sync_outbox WHERE table_name = 'accounts'",
          )
          .getSingle();
      expect(jsonDecode(queued.read<String>('row_json'))['name'], 'Edited');
    } finally {
      await diskDb.close();
      await directory.delete(recursive: true);
    }
  });

  test('v10 upgrade syncs a budget icon', () async {
    final directory = await Directory.systemTemp.createTemp(
      'money_sync_migration_',
    );
    final file = File('${directory.path}/ledger.sqlite');
    var diskDb = AppDatabase(NativeDatabase(file), false);
    try {
      // The triggers name every column, so they go before the column does.
      for (final operation in ['insert', 'update', 'delete']) {
        await diskDb.customStatement('DROP TRIGGER sync_budgets_$operation');
      }
      await diskDb.customStatement('ALTER TABLE budgets DROP COLUMN icon');
      await createSyncTriggers(diskDb, 'budgets');
      await diskDb.customStatement('PRAGMA user_version = 9');
      await diskDb.close();
      diskDb = AppDatabase(NativeDatabase(file), false);
      final category = await diskDb
          .customSelect(
            "SELECT id FROM categories WHERE type = 'expense' "
            'AND parent_id IS NULL LIMIT 1',
          )
          .getSingle();
      await BudgetRepository(diskDb).save(
        categoryIds: {category.read<int>('id')},
        icon: 'gift',
        currency: 'INR',
        digits: 2,
        fromMonth: DateTime(2026, 9),
        amountMinor: 1000,
      );
      final queued = await diskDb
          .customSelect(
            "SELECT row_json FROM sync_outbox WHERE table_name = 'budgets'",
          )
          .getSingle();
      expect(jsonDecode(queued.read<String>('row_json'))['icon'], 'gift');
    } finally {
      await diskDb.close();
      await directory.delete(recursive: true);
    }
  });

  test('A create that already happened is replaced, and checked', () async {
    final payload = Uint8List.fromList(gzip.encode(utf8.encode('{}')));
    final batch = SyncBatch(
      fileId: 'known-id',
      mirrorId: 'mirror',
      sequence: 1,
      payload: payload,
      checksum: md5.convert(payload).toString(),
      section: 'accounts',
    );
    var gets = 0;
    final client = DriveClient(
      'test-token',
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer test-token');
        if (request.method == 'POST') return http.Response('{}', 409);
        expect(request.method, 'PATCH');
        gets++;
        return http.Response(
          jsonEncode({
            'id': batch.fileId,
            'md5Checksum': batch.checksum,
            'size': '${batch.payload.length}',
          }),
          200,
        );
      }),
    );
    await client.upload(batch);
    expect(gets, 1);
    client.close();
    final corrupt = DriveClient(
      'test-token',
      client: MockClient(
        (_) async => http.Response(
          jsonEncode({
            'id': batch.fileId,
            'md5Checksum': 'wrong',
            'size': '${batch.payload.length}',
          }),
          200,
        ),
      ),
    );
    await expectLater(
      corrupt.upload(batch),
      throwsA(isA<DriveSyncException>()),
    );
    corrupt.close();
  });
}
