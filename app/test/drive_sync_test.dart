import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simple_money/ui/components/glass_button.dart';
import 'package:simple_money/data/backup/drive_client.dart';
import 'package:simple_money/data/backup/sync_engine.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/backup/sync_schema.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/budget_repository.dart';
import 'package:simple_money/data/repositories/transaction_repository.dart';
import 'package:simple_money/state/sync_controller.dart';
import 'package:simple_money/ui/more/settings/sync/sync_screen.dart';
import 'package:simple_money/ui/welcome/backup_welcome_screen.dart';

Map<String, dynamic> decode(SyncBatch batch) =>
    jsonDecode(utf8.decode(gzip.decode(batch.payload))) as Map<String, dynamic>;

class FakeDrive implements MirrorTransport {
  final files = <String, SyncBatch>{};
  final modified = <String, DateTime>{};
  int allocated = 0;
  bool loseResponse = false;
  Future<void> Function(SyncBatch)? duringUpload;
  @override
  Future<String> newFileId() async => 'file-${++allocated}';
  @override
  Future<List<MirrorFile>> listFiles() async => [
    for (final batch in files.values)
      MirrorFile(
        id: batch.fileId,
        mirrorId: batch.mirrorId,
        sequence: batch.sequence,
        modified: modified[batch.fileId]!,
      ),
  ];
  @override
  Future<Uint8List> download(String fileId) async => files[fileId]!.payload;
  @override
  Future<void> deleteFile(String fileId) async => files.remove(fileId);
  @override
  Future<void> upload(SyncBatch batch) async {
    final existing = files[batch.fileId];
    if (existing != null) expect(batch.payload, existing.payload);
    files[batch.fileId] = batch;
    modified.putIfAbsent(
      batch.fileId,
      () => DateTime(2026).add(Duration(minutes: modified.length)),
    );
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
  PreviewSyncController(super.repository);
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
  Future<void> addAccount([String name = 'Cash']) =>
      AccountRepository(db)
          .save(name: name, currency: 'INR', digits: 2, openingBalance: 100000);

  test('OS-restored database starts an independent paused mirror', () async {
    await repository.bindInstallation('original-device');
    await connect();
    await engine.run();
    final originalMirror = drive.files.values.single.mirrorId;
    await repository.bindInstallation('original-device');
    expect((await repository.status()).enabled, isTrue);
    await repository.bindInstallation('replacement-device');
    final status = await repository.status();
    expect(status.enabled, isFalse);
    expect(status.lastSynced, isNull);
    expect(status.pending, greaterThan(0));
    await connect();
    await engine.run();
    expect(drive.files.values.last.mirrorId, isNot(originalMirror));
    expect(drive.files.values.last.sequence, 1);
  });

  test('A reinstall restores the newest backup with data, then mirrors it anew', () async {
    await addAccount();
    await addAccount('Bank');
    await TransactionRepository(db).addTransfer(
      amountMinor: 1200,
      fromAccountId: 1,
      toAccountId: 2,
      date: DateTime(2026, 9, 11),
    );
    await connect();
    expect(await engine.run(), isTrue);
    await db.customStatement(
      "UPDATE accounts SET name = 'Wallet' WHERE id = 1",
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
    final restoredMirror = drive.files.values.last;
    expect(restoredMirror.mirrorId, isNot(originalMirror));
    expect(restoredMirror.sequence, 1);
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
      final first = drive.files.values.single;
      expect(first.mirrorId, isNot(oldMirror));
      expect(first.sequence, 1);
      expect(
        (decode(first)['changes'] as List).where(
          (change) => change['table'] == 'accounts',
        ),
        hasLength(2),
      );
    },
  );

  test('Only entered data counts as this phone having data', () async {
    expect(await repository.hasLedgerData(), isFalse);
    await addAccount();
    expect(await repository.hasLedgerData(), isTrue);
  });

  test('A mirror is rebuilt only from its unbroken chain', () async {
    await connect();
    await engine.run();
    await addAccount();
    await engine.run();
    await addAccount('Bank');
    await engine.run();
    final other = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(other.close);
    final otherRepository = SyncRepository(other);
    await otherRepository.connect('test@example.com', 'google-user-1');
    final otherEngine = SyncEngine(
      otherRepository,
      openTransport: (_) async => drive,
    );
    drive.files.remove(drive.files.values.last.fileId);
    expect((await otherEngine.findBackup())!.count('accounts'), 1);
    drive.files.remove(
      drive.files.values.firstWhere((batch) => batch.sequence == 1).fileId,
    );
    expect(await otherEngine.findBackup(), isNull);
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
      final controller = PreviewSyncController(repository);
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
      await addAccount();
      await connect();
      expect(await engine.run(), isTrue);
      final first = decode(drive.files.values.single);
      expect(first['sequence'], 1);
      expect(first['previousSequence'], 0);
      expect(
        (first['changes'] as List).any((r) => r['table'] == 'accounts'),
        isTrue,
      );
      expect(
        (first['changes'] as List).any((r) => r['table'] == 'categories'),
        isTrue,
      );
      await db.customStatement("UPDATE accounts SET name = 'Wallet'");
      await db.customStatement("UPDATE accounts SET name = 'Pocket'");
      expect((await repository.status()).pending, 1);
      expect(await engine.run(), isTrue);
      final edit = decode(drive.files.values.last)['changes'] as List;
      expect(edit.single['row']['name'], 'Pocket');
      await AccountRepository(db).delete(1);
      expect(await engine.run(), isTrue);
      final deletion = decode(drive.files.values.last)['changes'] as List;
      expect(deletion.single['key'], [1]);
      expect(deletion.single['row'], isNull);
      expect((await repository.status()).pending, 0);
    },
  );

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
    expect(drive.files, hasLength(2));
    final last = decode(drive.files.values.last);
    expect(last['sequence'], 2);
    expect((last['changes'] as List).single['row']['name'], 'New name');
    expect((await repository.status()).pending, 0);
  });

  test('Lost upload response retries the same file and bytes without losing newer edits', () async {
    await connect();
    drive.loseResponse = true;
    expect(await engine.run(), isFalse);
    final batch = await repository.pendingBatch();
    expect(batch, isNotNull);
    expect((await repository.status()).lastSynced, isNull);
    await addAccount();
    expect(await engine.run(force: true), isTrue);
    expect(drive.files, hasLength(2));
    expect(drive.allocated, 2);
    expect(await repository.pendingBatch(), isNull);
    expect((await repository.status()).pending, 0);
  });

  test(
    'Composite keys and a transfer reconstruct the exact latest database',
    () async {
      await addAccount();
      await addAccount('Bank');
      await connect();
      await engine.run();
      await TransactionRepository(db).addTransfer(
        amountMinor: 1200,
        fromAccountId: 1,
        toAccountId: 2,
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
      final transferBatch = decode(drive.files.values.last)['changes'] as List;
      expect(
        transferBatch.where((r) => r['table'] == 'accounts'),
        hasLength(2),
      );
      expect(
        transferBatch.where((r) => r['table'] == 'transactions'),
        hasLength(1),
      );
      await db.customStatement(
        'UPDATE budget_amounts SET start_month = 202610',
      );
      await db.customStatement('DELETE FROM budget_categories');
      await engine.run();
      final mirror = <String, Map<String, Object?>>{};
      for (final batch in drive.files.values) {
        for (final change in decode(batch)['changes'] as List) {
          final table = mirror.putIfAbsent(change['table'] as String, () => {});
          final key = jsonEncode(change['key']);
          if (change['row'] == null) {
            table.remove(key);
          } else {
            table[key] = change['row'];
          }
        }
      }
      for (final entry in syncTables.entries) {
        final rows = await db.customSelect('SELECT * FROM ${entry.key}').get();
        final expected = {
          for (final row in rows)
            jsonEncode(entry.value.map((k) => row.data[k]).toList()): row.data,
        };
        expect(mirror[entry.key] ?? {}, expected, reason: entry.key);
      }
    },
  );

  test(
    'Foreground and background runners cannot own the mirror simultaneously',
    () async {
      await connect();
      expect(await repository.acquire('worker-a'), isTrue);
      expect(await repository.acquire('worker-b', force: true), isFalse);
      final batch = (await repository.freeze('worker-a', 'file-1'))!;
      await db.customStatement('UPDATE sync_state SET lease_until = 0');
      expect(await repository.acquire('worker-b'), isTrue);
      await repository.acknowledge('worker-a', batch);
      expect(await repository.pendingBatch(), isNotNull);
      expect((await repository.status()).pending, greaterThan(0));
      await repository.release('worker-a');
      expect((await repository.status()).busy, isTrue);
    },
  );

  test('Pausing keeps offline edits; changing account starts an independent full mirror', () async {
    await addAccount();
    await connect();
    await engine.run();
    final firstMirror = drive.files.values.single.mirrorId;
    await repository.disconnect();
    await db.customStatement("UPDATE accounts SET name = 'Changed offline'");
    expect(await engine.run(), isTrue);
    expect(drive.files, hasLength(1));
    await connect();
    await engine.run();
    expect(drive.files.values.last.mirrorId, firstMirror);
    await repository.disconnect();
    await repository.connect('second@example.com', 'google-user-2');
    await engine.run();
    final last = drive.files.values.last;
    expect(last.mirrorId, isNot(firstMirror));
    expect(last.sequence, 1);
    expect((decode(last)['changes'] as List).length, greaterThan(1));
  });

  test(
    'Pending immutable upload survives closing and reopening the database',
    () async {
      final directory = await Directory.systemTemp.createTemp('money_sync_');
      final file = File('${directory.path}/ledger.sqlite');
      var diskDb = AppDatabase(NativeDatabase(file), false);
      try {
        var diskRepository = SyncRepository(diskDb);
        await diskRepository.connect('test@example.com', 'user');
        await diskRepository.acquire('owner');
        final original = (await diskRepository.freeze(
          'owner',
          'persistent-id',
        ))!;
        await diskDb.close();
        diskDb = AppDatabase(NativeDatabase(file), false);
        diskRepository = SyncRepository(diskDb);
        final reopened = (await diskRepository.pendingBatch())!;
        expect(reopened.payload, original.payload);
        expect(reopened.fileId, 'persistent-id');
        expect((await diskRepository.status()).pending, greaterThan(0));
      } finally {
        await diskDb.close();
        await directory.delete(recursive: true);
      }
    },
  );

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
      for (final table in ['sync_batch', 'sync_outbox', 'sync_state']) {
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

  test('Drive duplicate response is accepted only after checking the remote checksum', () async {
    await connect();
    await repository.acquire('owner');
    final batch = (await repository.freeze('owner', 'known-id'))!;
    var gets = 0;
    final client = DriveClient(
      'test-token',
      client: MockClient((request) async {
        expect(request.headers['Authorization'], 'Bearer test-token');
        if (request.method == 'POST') return http.Response('{}', 409);
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
