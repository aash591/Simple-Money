import 'package:fake_async/fake_async.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/backup/sync_notifications.dart';

import 'multi_device_merge_test.dart' show Phone, SharedDrive;

/// Records what would be posted instead of posting it.
class FakePlugin implements FlutterLocalNotificationsPlugin {
  /// The notification showing now: (title, body), or null.
  (String?, String?)? showing;
  int shows = 0;

  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    Object? onDidReceiveNotificationResponse,
    Object? onDidReceiveBackgroundNotificationResponse,
  }) async => true;

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shows++;
    showing = (title, body);
  }

  @override
  Future<void> cancel({required int id, String? tag}) async => showing = null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// What an upload run reported.
class Recorder implements UploadProgress {
  final events = <String>[];
  @override
  void started(int total) => events.add('started $total');
  @override
  void advanced(int done, int total) => events.add('$done/$total');
  @override
  void finished() => events.add('finished');
  @override
  void failed(int waiting) => events.add('failed $waiting');
}

void main() {
  test('a quick upload in the app shows nothing', () {
    fakeAsync((time) {
      final plugin = FakePlugin();
      final notes = SyncNotifications(plugin: plugin);
      notes.started(2);
      notes.advanced(2, 2);
      notes.finished();
      time.elapse(const Duration(seconds: 5));
      expect(plugin.shows, 0);
    });
  });

  test('a slow upload shows its progress until it is done', () {
    fakeAsync((time) {
      final plugin = FakePlugin();
      final notes = SyncNotifications(plugin: plugin);
      notes.started(70);
      time.elapse(const Duration(seconds: 3));
      expect(plugin.showing?.$1, 'Saving to Google Drive');
      notes.advanced(12, 70);
      time.flushMicrotasks();
      expect(plugin.showing?.$2, '12 of 70');
      notes.finished();
      time.flushMicrotasks();
      expect(plugin.showing, isNull);
    });
  });

  test(
    'leaving the app mid-upload shows it; one that fails says what waits',
    () {
      fakeAsync((time) {
        final plugin = FakePlugin();
        final notes = SyncNotifications(plugin: plugin);
        notes.started(3);
        notes.leftApp(waiting: 3);
        time.flushMicrotasks();
        expect(plugin.showing?.$1, 'Saving to Google Drive');
        notes.failed(3);
        time.flushMicrotasks();
        expect(plugin.showing?.$1, 'Changes waiting to upload');
        expect(plugin.showing?.$2, startsWith('3 changes saved on this phone'));
        // Back online later (e.g. the background job): it clears.
        notes.started(1);
        notes.finished();
        time.flushMicrotasks();
        expect(plugin.showing, isNull);
      });
    },
  );

  test('back in the app, a waiting note goes (the Sync screen shows it)', () {
    fakeAsync((time) {
      final plugin = FakePlugin();
      final notes = SyncNotifications(plugin: plugin);
      notes.leftApp(waiting: 2);
      time.flushMicrotasks();
      expect(plugin.showing?.$1, 'Changes waiting to upload');
      notes.cameBack();
      time.flushMicrotasks();
      expect(plugin.showing, isNull);
    });
  });

  test('an upload run reports each file and the end', () async {
    final drive = SharedDrive();
    final phone = Phone(drive);
    addTearDown(phone.db.close);
    final recorder = Recorder();
    await phone.repository.connect('me@example.com', 'me');
    await phone.accounts.save(
      name: 'Cash',
      currency: 'INR',
      digits: 2,
      openingBalance: 100,
    );
    final engine = phone.engineWith(progress: recorder);
    expect(await engine.run(force: true), isTrue);
    final total = int.parse(recorder.events.first.split(' ').last);
    expect(recorder.events, [
      'started $total',
      for (var i = 1; i <= total; i++) '$i/$total',
      'finished',
    ]);
  });
}
