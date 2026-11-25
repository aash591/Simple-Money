import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fake_drive_listing.dart';

import 'package:simple_money/data/backup/drive_client.dart';
import 'package:simple_money/data/backup/sync_engine.dart';
import 'package:simple_money/data/backup/sync_repository.dart';
import 'package:simple_money/data/bank_sms_parser.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/data/sms_inbox_platform.dart';
import 'package:simple_money/state/sms_import_store.dart';
import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';

class _Inbox extends SmsInboxPlatform {
  _Inbox(this.rows);
  final List<InboxSms> rows;
  @override
  bool get supported => true;
  @override
  Future<void> setRealtimeEnabled(bool enabled) async {}
  @override
  Future<bool> hasPermission() async => true;
  @override
  Future<bool> requestPermission() async => true;
  @override
  Future<List<InboxSms>> readPage({
    required int afterId,
    required int since,
  }) async => rows.where((r) => r.id > afterId).toList();
}

class _Drive implements MirrorTransport {
  final files = <String, SyncBatch>{};
  final modified = <String, DateTime>{};
  int allocated = 0;
  @override
  Future<String> newFileId() async => 'file-${++allocated}';
  @override
  Future<List<MirrorFile>> listFiles({DateTime? modifiedAfter}) async =>
      fakeListing(files, (id) => modified[id]!, modifiedAfter: modifiedAfter);
  @override
  Future<Uint8List> download(String fileId) async => files[fileId]!.payload;
  @override
  Future<void> deleteFile(String fileId) async => files.remove(fileId);
  @override
  Future<void> upload(SyncBatch batch) async {
    files[batch.fileId] = batch;
    modified.putIfAbsent(
      batch.fileId,
      () => DateTime(2026).add(Duration(minutes: modified.length)),
    );
  }

  @override
  void close() {}
}

void main() {
  late BankSmsParser engine;
  setUpAll(() {
    engine = BankSmsParser(
      const RuleCompiler().loadRuntime(
        jsonDecode(
          File(
            'packages/universal_bank_sms_parser/distribution/packs/india/sbi.json',
          ).readAsStringSync(),
        ) as Map<String, dynamic>,
      ),
    );
  });

  final inbox = [
    for (final (i, (amount, balance)) in [
      ('500', '9500'),
      ('250', '9250'),
      ('120', '9130'),
    ].indexed)
      InboxSms(
        i + 1,
        BankSms(
          sender: 'ATMSBI',
          body:
              'Rs.$amount debited from A/c X1234 on 1${i + 3}Sep25. Avl Bal Rs.$balance',
          receivedAt: DateTime(2026, 10, 7 + i, 12),
        ),
      ),
  ];

  Future<SmsImportStore> scan(AppDatabase db) async {
    final store = SmsImportStore(
      SmsImportRepository(db),
      platform: _Inbox(inbox),
      engineLoader: () async => engine,
    );
    addTearDown(store.dispose);
    await store.enable();
    return store;
  }

  Future<int> count(AppDatabase db, String table) async =>
      (await db.customSelect('SELECT count(*) AS n FROM $table').getSingle())
          .read<int>('n');

  test('A restored phone does not save its inbox again', () async {
    final drive = _Drive();
    final old = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(old.close);
    final oldSync = SyncRepository(old);
    final first = await scan(old);
    // One saved here, one dismissed, one left to review.
    final pending = first.pending;
    expect(await count(old, 'transactions'), greaterThan(0));
    if (pending.isNotEmpty) await first.dismiss(pending.first);
    final transactions = await count(old, 'transactions');
    final accounts = (await AccountRepository(old).load()).length;
    final settled = await count(old, 'sms_history');
    expect(settled, greaterThan(transactions - 1));
    expect(await count(old, "sms_imports WHERE status != 'pending'"), settled);
    await oldSync.connect('test@example.com', 'google-user-1');
    expect(
      await SyncEngine(oldSync, openTransport: (_) async => drive).run(),
      isTrue,
    );

    final fresh = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(fresh.close);
    final freshSync = SyncRepository(fresh);
    final freshEngine = SyncEngine(
      freshSync,
      openTransport: (_) async => drive,
    );
    await freshSync.connect('test@example.com', 'google-user-1');
    await freshEngine.run();
    await freshEngine.restore((await freshEngine.findBackup())!);
    expect(await count(fresh, 'sms_history'), settled);
    expect(await count(fresh, 'sms_account_links'), greaterThan(0));

    final second = await scan(fresh);
    expect(await count(fresh, 'transactions'), transactions);
    expect((await AccountRepository(fresh).load()).length, accounts);
    expect(
      second.pendingCount,
      await count(old, "sms_imports WHERE status = 'pending'"),
    );
    expect(second.lastScan?.saved ?? 0, 0);
  });

  test('Undoing a saved SMS takes it out of the synced history', () async {
    final db = AppDatabase(NativeDatabase.memory(), false);
    addTearDown(db.close);
    await scan(db);
    final before = await count(db, 'sms_history');
    expect(before, greaterThan(0));
    await db.customStatement(
      "UPDATE sms_imports SET status='pending', transaction_id=NULL "
      "WHERE fingerprint=(SELECT fingerprint FROM sms_history LIMIT 1)",
    );
    expect(await count(db, 'sms_history'), before - 1);
    // Cleanup rewrites candidates without changing anything worth uploading.
    final outbox = await count(
      db,
      "sync_outbox WHERE table_name='sms_history'",
    );
    await db.customStatement(
      "UPDATE sms_imports SET candidate=json_object('notificationKey',json_extract(candidate,'\$.notificationKey'),'isCreditCard',json_extract(candidate,'\$.isCreditCard')) WHERE status!='pending'",
    );
    final revision =
        (await db.customSelect('SELECT revision FROM sync_state').getSingle())
            .read<int>('revision');
    await db.customStatement(
      "UPDATE sms_imports SET candidate=candidate WHERE status!='pending'",
    );
    expect(
      (await db.customSelect('SELECT revision FROM sync_state').getSingle())
          .read<int>('revision'),
      revision,
    );
    expect(
      await count(db, "sync_outbox WHERE table_name='sms_history'"),
      outbox,
    );
  });
}
