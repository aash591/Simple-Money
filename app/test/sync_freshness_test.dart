import 'dart:async';
import 'dart:convert';
import 'dart:io' show pid;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simple_money/data/backup/drive_client.dart';
import 'package:simple_money/data/backup/sync_engine.dart';
import 'package:simple_money/data/backup/sync_repository.dart';

import 'drive_sync_test.dart' show PreviewSyncController;
import 'fake_drive_listing.dart';
import 'multi_device_merge_test.dart' show Phone, SharedDrive;

/// Drive whose search lags behind uploads (as the real one can, for
/// seconds), but whose change log doesn't.
class LaggingDrive extends SharedDrive implements ChangeFeed {
  /// File IDs in upload order: the change log.
  final log = <String>[];

  /// Files the search doesn't show yet.
  final unindexed = <String>{};
  bool lagging = false;

  @override
  Future<void> upload(SyncBatch batch) async {
    await super.upload(batch);
    log.add(batch.fileId);
    if (lagging) unindexed.add(batch.fileId);
  }

  @override
  Future<List<MirrorFile>> listFiles({DateTime? modifiedAfter}) async => [
    for (final file in await super.listFiles(modifiedAfter: modifiedAfter))
      if (!unindexed.contains(file.id)) file,
  ];

  @override
  Future<String> startToken() async => '${log.length}';

  @override
  Future<(List<MirrorFile>, String)> changesSince(String token) async {
    final changed = log.skip(int.parse(token)).toSet();
    return (
      fakeListing(
        {
          for (final id in changed)
            if (files[id] case final batch?) id: batch,
        },
        (id) => modified[id]!,
      ),
      '${log.length}',
    );
  }
}

/// Counts pulls; the first one waits until [release] is completed.
class SlowEngine extends SyncEngine {
  SlowEngine(super.repository, {super.openTransport});
  final release = Completer<void>();
  var pulls = 0;

  @override
  Future<int> pull({bool full = false}) async {
    pulls++;
    if (pulls == 1) await release.future;
    return 0;
  }
}

void main() {
  test("a change shows up at once, though Drive's search lags", () async {
    final drive = LaggingDrive();
    final a = Phone(drive), b = Phone(drive);
    addTearDown(() async {
      await a.db.close();
      await b.db.close();
    });
    await a.repository.connect('me@example.com', 'me');
    final cash = await a.accounts.save(
      name: 'Cash',
      currency: 'INR',
      digits: 2,
      openingBalance: 100000,
    );
    await a.upload();
    await b.repository.connect('me@example.com', 'me');
    await b.engine.restore((await b.engine.findBackup())!);
    await b.upload();
    await b.pull();

    drive.lagging = true;
    await a.spend(cash, 400, title: 'Just now');
    await a.upload();
    // A regular check reads the change log, which already has it.
    expect(await b.pull(), greaterThan(0));
    expect((await b.ledger()).single.title, 'Just now');

    // So does a full listing (Sync now), which adds the log to the search.
    await a.spend(cash, 100, title: 'Also now');
    await a.upload();
    expect(await b.engine.pull(full: true), greaterThan(0));
    expect(
      (await b.ledger()).map((t) => t.title),
      containsAll(['Just now', 'Also now']),
    );
  });

  test('a sync asked for during a running check still runs', () async {
    final phone = Phone(SharedDrive());
    addTearDown(phone.db.close);
    await phone.repository.connect('me@example.com', 'me');
    await phone.engine.run(force: true);
    final engine = SlowEngine(
      phone.repository,
      openTransport: (_) async => phone.drive,
    );
    final controller = PreviewSyncController(phone.repository, engine: engine);
    addTearDown(controller.dispose);

    final first = controller.syncNow();
    await pumpEventQueue();
    expect(engine.pulls, 1);
    // Back to the app (or a list pulled down) while that check still runs:
    // it used to be dropped; now it runs once the first is done.
    controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(engine.pulls, 1);
    engine.release.complete();
    await first;
    await pumpEventQueue();
    expect(engine.pulls, 2);
  });

  test('an upload left by an app swiped away is taken over at once', () async {
    final phone = Phone(SharedDrive());
    addTearDown(phone.db.close);
    await phone.repository.connect('me@example.com', 'me');
    // Held by this process: others wait.
    final mine = newLeaseOwner();
    expect(await phone.repository.acquire(mine), isTrue);
    expect(await phone.repository.acquire(newLeaseOwner()), isFalse);
    await phone.repository.release(mine);
    // Held by a process that's gone (another process ID): taken at once,
    // not after the two minutes the lease would last.
    expect(await phone.repository.acquire('${pid + 1}:abc'), isTrue);
    final taker = newLeaseOwner();
    expect(await phone.repository.acquire(taker), isTrue);
    await phone.repository.release(taker);
    // A run with the lease left behind goes through too.
    expect(await phone.repository.acquire('${pid + 1}:abc'), isTrue);
    expect(await phone.engine.run(), isTrue);
  });

  test("Drive's change log is read page by page, SimpleMoney files only", () async {
    final pages = <String?>[];
    final client = DriveClient(
      'token',
      client: MockClient((request) async {
        pages.add(request.url.queryParameters['pageToken']);
        Map<String, Object?> file(String id, {bool trashed = false}) => {
          'id': id,
          'modifiedTime': '2026-11-19T10:00:00.000Z',
          'trashed': trashed,
          'appProperties': {
            'format': sectionFileFormat,
            'mirrorId': 'm1',
            'sequence': '7',
            'section': 'accounts',
            'enc': 'off',
            'encAt': '0',
          },
        };
        final body = request.url.queryParameters['pageToken'] == '5'
            ? {
                'nextPageToken': '6',
                'changes': [
                  {'removed': false, 'file': file('a')},
                  {'removed': true},
                  {
                    'removed': false,
                    'file': {
                      'id': 'other',
                      'modifiedTime': '2026-11-19T10:00:00.000Z',
                      'appProperties': {'format': 'something-else'},
                    },
                  },
                ],
              }
            : {
                'newStartPageToken': '9',
                'changes': [
                  {'removed': false, 'file': file('b')},
                  {'removed': false, 'file': file('c', trashed: true)},
                ],
              };
        return http.Response(jsonEncode(body), 200);
      }),
    );
    final (files, next) = await client.changesSince('5');
    expect(pages, ['5', '6']);
    expect(files.map((f) => f.id), ['a', 'b']);
    expect(files.first.section, 'accounts');
    expect(files.first.sequence, 7);
    expect(next, '9');
    client.close();
  });
}
