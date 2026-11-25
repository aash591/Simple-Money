import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_drive_listing.dart';

import 'package:simple_money/data/backup/drive_client.dart';
import 'package:simple_money/data/backup/sync_engine.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/backup/sync_schema.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/statement_import_repository.dart';

/// Drive's appDataFolder, shared by every device in a test.
class MemoryDrive implements MirrorTransport {
  final files = <String, SyncBatch>{};

  /// Files of an older version's chain, rather than a device's file.
  final legacy = <String>{};
  var _ids = 0;
  @override
  Future<String> newFileId() async => 'file-${++_ids}';
  @override
  Future<void> upload(SyncBatch batch) async => files[batch.fileId] = batch;
  @override
  Future<List<MirrorFile>> listFiles({DateTime? modifiedAfter}) async =>
      fakeListing(
        files,
        (id) =>
            DateTime(2026)
                .add(Duration(minutes: files.keys.toList().indexOf(id))),
        legacy: legacy,
        modifiedAfter: modifiedAfter,
      );
  @override
  Future<Uint8List> download(String fileId) async => files[fileId]!.payload;
  @override
  Future<void> deleteFile(String fileId) async => files.remove(fileId);
  @override
  void close() {}
}

Map<String, dynamic> decode(SyncBatch batch) =>
    jsonDecode(utf8.decode(gzip.decode(batch.payload))) as Map<String, dynamic>;

Future<int> slotOf(AppDatabase db) async =>
    (await db.customSelect('SELECT id_slot FROM sync_state').getSingle())
        .read<int>('id_slot');

Future<int> clockOf(AppDatabase db) async =>
    (await db.customSelect('SELECT clock FROM sync_state').getSingle())
        .read<int>('clock');

Future<int?> versionOf(AppDatabase db, String table, Object key) async =>
    (await db
            .customSelect(
              'SELECT hlc FROM sync_row_meta '
              'WHERE table_name = ? AND record_key = ?',
              variables: [
                Variable(table),
                Variable(jsonEncode([key])),
              ],
            )
            .getSingleOrNull())
        ?.read<int>('hlc');

Future<int> addAccount(AppDatabase db, String name) =>
    AccountRepository(db)
        .save(name: name, currency: 'INR', digits: 2, openingBalance: 0);

void main() {
  late AppDatabase db;
  setUp(() => db = AppDatabase(NativeDatabase.memory(), false));
  tearDown(() => db.close());

  group('Row IDs', () {
    test(
      'grow in creation order, carry the device slot and fit in JSON',
      () async {
        final slot = await slotOf(db);
        expect(slot, inInclusiveRange(0, 2047));
        final since2025 = DateTime.now()
            .difference(DateTime.utc(2025))
            .inMilliseconds;
        final ids = [for (var i = 0; i < 20; i++) await addAccount(db, 'A$i')];
        for (final id in ids) {
          expect(id & 2047, slot);
          expect(id, lessThan(1 << 53));
          // The time part is close to now, so new IDs sort after all old ones.
          expect((id >> 11) - since2025, inInclusiveRange(-5000, 60000));
        }
        // Created within the same millisecond or not, never equal, never back.
        for (var i = 1; i < ids.length; i++) {
          expect(ids[i], greaterThan(ids[i - 1]));
        }
      },
    );

    test('two installations creating rows at once never collide', () async {
      final other = AppDatabase(NativeDatabase.memory(), false);
      addTearDown(other.close);
      await db.customStatement('UPDATE sync_state SET id_slot = 7');
      await other.customStatement('UPDATE sync_state SET id_slot = 8');
      final mine = <int>{}, theirs = <int>{};
      for (var i = 0; i < 50; i++) {
        mine.add(await addAccount(db, 'Mine $i'));
        theirs.add(await addAccount(other, 'Theirs $i'));
      }
      expect(mine.intersection(theirs), isEmpty);
    });

    test('after rows from another device, keep going above them', () async {
      final ahead = ((await addAccount(db, 'First') >> 11) + 100000) << 11;
      await db.customStatement(
        "INSERT INTO accounts (id, name, currency, digits, balance_minor, "
        "sort_order) VALUES (${ahead | 5}, 'Theirs', 'INR', 2, 0, 9)",
      );
      final next = await addAccount(db, 'Next');
      expect(next, greaterThan(ahead));
      expect(next & 2047, await slotOf(db));
    });

    test('default categories are the same records on every install', () async {
      final other = AppDatabase(NativeDatabase.memory(), false);
      addTearDown(other.close);
      Future<List<Map<String, Object?>>> categories(AppDatabase d) async => [
        for (final row
            in await d
                .customSelect(
                  'SELECT id, name, parent_id FROM categories ORDER BY id',
                )
                .get())
          row.data,
      ];
      final mine = await categories(db);
      expect(mine.first['id'], 1);
      expect(mine.last['id'], mine.length);
      expect(await categories(other), mine);
    });
  });

  group('Change clock', () {
    test(
      'stamps every change, newest last, and the upload carries it',
      () async {
        await SyncRepository(db).connect('a@example.com', 'subject');
        final before = await clockOf(db);
        final id = await addAccount(db, 'Cash');
        final created = (await versionOf(db, 'accounts', id))!;
        expect(created, greaterThan(before));
        expect(
          created >> 16,
          closeTo(DateTime.now().millisecondsSinceEpoch, 60000),
        );
        await db.customStatement("UPDATE accounts SET name = 'Wallet'");
        final edited = (await versionOf(db, 'accounts', id))!;
        expect(edited, greaterThan(created));

        final drive = MemoryDrive();
        await SyncEngine(
          SyncRepository(db),
          openTransport: (_) async => drive,
        ).run();
        final versions =
            decode(
                  drive.files.values.singleWhere(
                    (f) => f.section == 'accounts',
                  ),
                )['versions']
                as Map;
        expect((versions['accounts'] as Map)[jsonEncode([id])], edited);
      },
    );

    test('changes applied from elsewhere are not queued as edits', () async {
      await db.customStatement('UPDATE sync_state SET applying = 1');
      await addAccount(db, 'From another phone');
      await db.customStatement('UPDATE sync_state SET applying = 0');
      final queued = await db
          .customSelect(
            "SELECT * FROM sync_outbox WHERE table_name = 'accounts'",
          )
          .get();
      expect(queued, isEmpty);
      final versions = await db
          .customSelect(
            "SELECT * FROM sync_row_meta WHERE table_name = 'accounts'",
          )
          .get();
      expect(versions, isEmpty);
    });
  });

  test(
    'v46 upgrade keeps pending edits, versions them and stamps new ones',
    () async {
      final directory = await Directory.systemTemp.createTemp('sync_v47_');
      final file = File('${directory.path}/ledger.sqlite');
      var disk = AppDatabase(NativeDatabase(file), false);
      try {
        // A v46 install with an account edit waiting to upload.
        final old = await disk.customInsert(
          "INSERT INTO accounts (name, currency, digits, balance_minor, "
          "sort_order) VALUES ('Old', 'INR', 2, 0, 0)",
        );
        for (final table in syncTables.keys) {
          for (final operation in ['insert', 'update', 'delete']) {
            await disk.customStatement('DROP TRIGGER sync_${table}_$operation');
          }
        }
        await disk.customStatement('DROP TABLE sync_row_meta');
        for (final column in ['id_slot', 'clock', 'applying']) {
          await disk.customStatement(
            'ALTER TABLE sync_state DROP COLUMN $column',
          );
        }
        await disk.customStatement('ALTER TABLE sync_outbox DROP COLUMN hlc');
        await disk.customStatement('DELETE FROM sync_outbox');
        await disk.customStatement(
          "INSERT INTO sync_outbox VALUES ('accounts', '[$old]', "
          "'{\"id\":$old,\"name\":\"Old\"}', 1)",
        );
        await disk.customStatement('PRAGMA user_version = 46');
        await disk.close();

        disk = AppDatabase(NativeDatabase(file), false);
        expect(await slotOf(disk), inInclusiveRange(0, 2047));
        final pending = await disk
            .customSelect(
              "SELECT hlc FROM sync_outbox WHERE table_name = 'accounts'",
            )
            .getSingle();
        expect(pending.read<int>('hlc'), greaterThan(0));
        expect(
          await versionOf(disk, 'accounts', old),
          pending.read<int>('hlc'),
        );

        await disk.customStatement("UPDATE accounts SET name = 'Renamed'");
        expect(
          await versionOf(disk, 'accounts', old),
          greaterThan(pending.read<int>('hlc')),
        );
        // Every synced table has its triggers again, new columns included.
        final triggers = await disk
            .customSelect(
              "SELECT name FROM sqlite_master WHERE type = 'trigger' "
              "AND name LIKE 'sync\\_%' ESCAPE '\\'",
            )
            .get();
        expect(triggers, hasLength(syncTables.length * 3));
        final added = await addAccount(disk, 'New');
        expect(added, greaterThan(old));
        expect(added & 2047, await slotOf(disk));
      } finally {
        await disk.close();
        await directory.delete(recursive: true);
      }
    },
  );

  test('every column of every synced table reaches the other phone', () async {
    // A change copies the whole row; a column a trigger doesn't know of
    // would silently stay behind (icons, titles, loan terms, …).
    for (final table in syncTables.keys) {
      final columns = {
        for (final row
            in await db.customSelect('PRAGMA table_info($table)').get())
          row.read<String>('name'),
      };
      final trigger = await db
          .customSelect(
            "SELECT sql FROM sqlite_master WHERE name = 'sync_${table}_update'",
          )
          .getSingle();
      for (final column in columns) {
        expect(
          trigger.read<String>('sql'),
          contains("'$column', NEW.$column"),
          reason: '$table.$column',
        );
      }
    }
  });

  test('SMS corrections are synced and restored', () async {
    final drive = MemoryDrive();
    await SyncRepository(db).connect('a@example.com', 'subject');
    await db.customStatement(
      "INSERT INTO sms_corrections VALUES ('SBIINB', 'sbi.loan', 'debit', "
      'NULL, 7, 1)',
    );
    await addAccount(db, 'Cash'); // Only a mirror with data is offered.
    await SyncEngine(
      SyncRepository(db),
      openTransport: (_) async => drive,
    ).run();
    final phone = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(phone.close);
    final repository = SyncRepository(phone);
    final engine = SyncEngine(repository, openTransport: (_) async => drive);
    await repository.connect('a@example.com', 'subject');
    await engine.restore((await engine.findBackup())!);
    final restored = await phone
        .customSelect('SELECT * FROM sms_corrections')
        .getSingle();
    expect(restored.read<String>('direction'), 'debit');
    expect(restored.read<int>('category_id'), 7);
  });

  group('Statement formats', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('learned layouts and account links reach another phone', () async {
      final drive = MemoryDrive();
      await SyncRepository(db).connect('a@example.com', 'subject');
      final cash = await addAccount(db, 'Cash');
      final statements = StatementImportRepository(db);
      await statements.saveColumnMapping('date|amount|narration', {
        'date': 0,
        'amount': 1,
      });
      await statements.saveAccountLinks({'HDFC XX1234': cash});
      await SyncEngine(
        SyncRepository(db),
        openTransport: (_) async => drive,
      ).run();

      final phone = AppDatabase(NativeDatabase.memory(), false);
      addTearDown(phone.close);
      final repository = SyncRepository(phone);
      final engine = SyncEngine(repository, openTransport: (_) async => drive);
      await repository.connect('a@example.com', 'subject');
      await engine.restore((await engine.findBackup())!);
      final restored = StatementImportRepository(phone);
      expect(await restored.columnMappings(), {
        'date|amount|narration': {'date': 0, 'amount': 1},
      });
      expect(await restored.accountLinks(), {'HDFC XX1234': cash});
    });

    test('saving the same layout again queues nothing', () async {
      final statements = StatementImportRepository(db);
      await statements.saveColumnMapping('sig', {'date': 0});
      await db.customStatement('DELETE FROM sync_outbox');
      await statements.saveColumnMapping('sig', {'date': 0});
      await statements.saveAccountLinks({});
      final queued = await db.customSelect('SELECT * FROM sync_outbox').get();
      expect(queued, isEmpty);
    });

    test('changing a saved layout or link queues the change', () async {
      // An upsert on a synced table once made the change triggers fail.
      final statements = StatementImportRepository(db);
      await statements.saveColumnMapping('sig', {'date': 0});
      await statements.saveColumnMapping('sig', {'date': 1});
      await statements.saveAccountLinks({'HDFC': 1});
      await statements.saveAccountLinks({'HDFC': 2});
      expect(await statements.columnMappings(), {
        'sig': {'date': 1},
      });
      expect(await statements.accountLinks(), {'HDFC': 2});
      final queued = await db
          .customSelect(
            "SELECT row_json FROM sync_outbox WHERE table_name IN "
            "('statement_layouts', 'statement_account_links')",
          )
          .get();
      expect(queued, hasLength(2));
    });

    test('what an older version kept on the phone moves into sync', () async {
      SharedPreferences.setMockInitialValues({
        StatementImportRepository.mappingsKey: jsonEncode({
          'old-sig': {'date': 2},
        }),
        StatementImportRepository.linksKey: jsonEncode({'SBI XX9': 5}),
        StatementImportRepository.ownerKey: jsonEncode({}),
      });
      final statements = StatementImportRepository(db);
      expect(await statements.columnMappings(), {
        'old-sig': {'date': 2},
      });
      expect(await statements.accountLinks(), {'SBI XX9': 5});
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(StatementImportRepository.mappingsKey), isNull);
      final queued = await db
          .customSelect(
            "SELECT table_name FROM sync_outbox "
            "WHERE table_name LIKE 'statement_%'",
          )
          .get();
      expect(queued, hasLength(3));
    });
  });

  group('Restore', () {
    test('keeps the versions the other phone gave its rows', () async {
      final drive = MemoryDrive();
      await SyncRepository(db).connect('a@example.com', 'subject');
      final id = await addAccount(db, 'Cash');
      await db.customStatement("UPDATE accounts SET name = 'Wallet'");
      final version = (await versionOf(db, 'accounts', id))!;
      await SyncEngine(
        SyncRepository(db),
        openTransport: (_) async => drive,
      ).run();

      final phone = AppDatabase(NativeDatabase.memory(), false);
      addTearDown(phone.close);
      final repository = SyncRepository(phone);
      final engine = SyncEngine(repository, openTransport: (_) async => drive);
      await repository.connect('a@example.com', 'subject');
      await engine.restore((await engine.findBackup())!);

      expect(await versionOf(phone, 'accounts', id), version);
      expect(await clockOf(phone), greaterThanOrEqualTo(version));
      // Its own file carries the row at that version, not as new.
      await engine.run();
      final mine = drive.files.values.firstWhere(
        (f) => f.mirrorId != drive.files.values.first.mirrorId,
      );
      expect(
        ((decode(mine)['versions'] as Map)['accounts'] as Map)[jsonEncode([
          id,
        ])],
        version,
      );
      // Edits made after the restore come after it.
      await phone.customStatement("UPDATE accounts SET name = 'Mine'");
      expect(await versionOf(phone, 'accounts', id), greaterThan(version));
    });

    test('batches from before v47 count as made when uploaded', () async {
      final drive = MemoryDrive();
      final made = DateTime.utc(2026, 3, 4, 5, 6, 7);
      final payload = Uint8List.fromList(
        gzip.encode(
          utf8.encode(
            jsonEncode({
              'format': 'simple-money-mirror',
              'formatVersion': 1,
              'schemaVersion': 46,
              'mirrorId': 'old-phone',
              'sequence': 1,
              'previousSequence': 0,
              'createdAt': made.toIso8601String(),
              'changes': [
                {
                  'table': 'accounts',
                  'key': [42],
                  'row': {
                    'id': 42,
                    'name': 'Old phone',
                    'currency': 'INR',
                    'digits': 2,
                    'balance_minor': 0,
                    'sort_order': 0,
                  },
                },
                {
                  'table': 'accounts',
                  'key': [43],
                  'row': null,
                },
              ],
            }),
          ),
        ),
      );
      drive.files['f'] = SyncBatch(
        fileId: 'f',
        mirrorId: 'old-phone',
        sequence: 1,
        revision: 1,
        payload: payload,
        checksum: md5.convert(payload).toString(),
      );
      drive.legacy.add('f');
      final repository = SyncRepository(db);
      final engine = SyncEngine(repository, openTransport: (_) async => drive);
      await repository.connect('a@example.com', 'subject');
      await engine.restore((await engine.findBackup())!);
      expect(await versionOf(db, 'accounts', 42), hlcAt(made));
      // The deletion is remembered too, so it can't come back from elsewhere.
      expect(await versionOf(db, 'accounts', 43), hlcAt(made));
    });
  });
}
