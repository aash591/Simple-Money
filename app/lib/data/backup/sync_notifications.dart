import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

/// What an upload run reports as it goes (see SyncEngine.run).
abstract interface class UploadProgress {
  /// An upload of [total] files began.
  void started(int total);

  /// [done] of [total] files are on Drive.
  void advanced(int done, int total);

  /// Everything waiting is on Drive.
  void finished();

  /// The upload stopped (offline, signed out); [waiting] changes are still
  /// only on this phone.
  void failed(int waiting);
}

/// Shows a Drive upload as a notification while it's worth seeing, so it's
/// clear when everything is safely on Drive:
///
/// - an upload taking longer than [delay] (the first upload after an update,
///   a restore, a big import, a slow connection): "Saving to Google Drive"
///   with progress, gone when it's done;
/// - an upload still running after leaving the app ([background]): shown at
///   once, gone when it's done;
/// - an upload that couldn't finish, if it was showing or the app is in the
///   background: "Changes waiting to upload", which can be swiped away and
///   clears itself once they go up.
///
/// A quick upload while the app is open shows nothing. Silent and low
/// priority throughout.
class SyncNotifications implements UploadProgress {
  SyncNotifications({
    FlutterLocalNotificationsPlugin? plugin,
    this.delay = const Duration(seconds: 2),
  }) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  final Duration delay;
  static const _id = 9200001;

  /// The app isn't on screen (or this is the background job): uploads are
  /// shown at once.
  bool background = false;

  Timer? _timer;
  bool _running = false, _shown = false;
  int _done = 0, _total = 0;
  Future<void>? _ready;

  static const _channel = AndroidNotificationDetails(
    'drive_sync',
    'Google Drive sync',
    channelDescription:
        'Shows while your changes are being saved to Google '
        'Drive',
    importance: Importance.low,
    priority: Priority.low,
    playSound: false,
    enableVibration: false,
    onlyAlertOnce: true,
    showWhen: false,
  );

  Future<void> _init() => _ready ??= _plugin
      .initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_app_art'),
        ),
      )
      .then((_) {});

  @override
  void started(int total) {
    _running = true;
    _done = 0;
    _total = total;
    _timer?.cancel();
    if (background) {
      unawaited(_showProgress());
    } else {
      _timer = Timer(delay, () {
        if (_running) unawaited(_showProgress());
      });
    }
  }

  @override
  void advanced(int done, int total) {
    _done = done;
    _total = total;
    if (_shown) unawaited(_showProgress());
  }

  @override
  void finished() {
    _running = false;
    _timer?.cancel();
    unawaited(_cancel());
  }

  @override
  void failed(int waiting) {
    _running = false;
    _timer?.cancel();
    if (waiting <= 0) {
      unawaited(_cancel());
    } else if (_shown || background) {
      unawaited(_showWaiting(waiting));
    }
  }

  /// Leaving the app: an upload still running shows from now on, and edits
  /// that couldn't go up yet say so.
  void leftApp({required int waiting}) {
    background = true;
    if (_running) {
      _timer?.cancel();
      unawaited(_showProgress());
    } else if (waiting > 0) {
      unawaited(_showWaiting(waiting));
    }
  }

  /// Back in the app: the Sync screen shows the state, so a waiting note
  /// that isn't about an upload in progress goes away.
  void cameBack() {
    background = false;
    if (!_running) unawaited(_cancel());
  }

  Future<void> _showProgress() async {
    _shown = true;
    final many = _total > 1;
    await _guard(
      () => _plugin.show(
        id: _id,
        title: 'Saving to Google Drive',
        body: many ? '$_done of $_total' : 'Your latest changes',
        notificationDetails: NotificationDetails(
          android: AndroidNotificationDetails(
            _channel.channelId,
            _channel.channelName,
            channelDescription: _channel.channelDescription,
            importance: _channel.importance,
            priority: _channel.priority,
            playSound: false,
            enableVibration: false,
            onlyAlertOnce: true,
            showWhen: false,
            ongoing: true,
            autoCancel: false,
            showProgress: true,
            maxProgress: many ? _total : 0,
            progress: many ? _done : 0,
            indeterminate: !many,
          ),
        ),
      ),
    );
  }

  Future<void> _showWaiting(int waiting) async {
    _shown = true;
    await _guard(
      () => _plugin.show(
        id: _id,
        title: 'Changes waiting to upload',
        body:
            '$waiting change${waiting == 1 ? '' : 's'} saved on this phone. '
            'They go to Google Drive when you’re back online.',
        notificationDetails: const NotificationDetails(android: _channel),
      ),
    );
  }

  /// Removes the notification. The background job always does, as the
  /// app may have posted it (e.g. "Changes waiting to upload").
  Future<void> _cancel() async {
    if (!_shown && !background) return;
    _shown = false;
    await _guard(() => _plugin.cancel(id: _id));
  }

  /// Notifications are a convenience: a phone that refuses them (or a test
  /// without the plugin) still syncs.
  Future<void> _guard(Future<void> Function() action) async {
    try {
      await _init();
      await action();
    } catch (_) {}
  }
}
