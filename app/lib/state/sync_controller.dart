import '../data/platform_info.dart';
import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drive_authorization/drive_authorization.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../data/backup/drive_client.dart';
import '../data/backup/backup_encryption.dart';
import '../data/backup/sync_background.dart';
import '../data/backup/sync_engine.dart';
import '../data/backup/sync_repository.dart';
import '../data/backup/sync_notifications.dart';
import '../data/backup/sync_restore.dart';

class SyncController extends ChangeNotifier with WidgetsBindingObserver {
  SyncController(this.repository, {SyncEngine? engine})
    : engine =
          engine ??
          SyncEngine(
            repository,
            progress: isAndroidPlatform ? SyncNotifications() : null,
          );
  final SyncRepository repository;
  final SyncEngine engine;
  final _background = SyncBackground();
  SyncStatus? status;
  String? actionError;
  bool connecting = false;
  bool changingEncryption = false;
  BackupEncryption? pinRequired;
  BackupEncryption? _restoreEncryption;
  bool get uploadsHeld => _uploadsHeld || status?.restorePending == true;

  /// Looking for or applying a backup from Drive.
  bool restoring = false;

  /// Keeps manual sync feedback visible long enough to acknowledge a tap,
  /// including when there is nothing new to upload.
  bool manualSyncing = false;

  /// Importing, or deleting data on the phone or Drive.
  bool managingData = false;

  /// Reloads whatever cached the ledger, after a restore replaced it.
  VoidCallback? onRestored;
  bool get uploading => _running != null;
  bool get supported => isAndroidPlatform;
  bool _disposed = false, _uploadsHeld = false;

  /// The check running now, if any.
  Future<void>? _check;

  /// A forced check (Sync now, pulling a list down, back to the app) was
  /// asked for and hasn't started yet: the next check to start is forced.
  bool _forcePending = false;
  Timer? _timer;

  /// How often other phones' changes are checked for while the app is open.
  /// An idle check is one small request; see [SyncEngine.pull].
  ///
  /// Once a minute: people rarely use two phones at the same moment, and
  /// opening the app, Sync now and pulling a list down all check at once.
  /// It also keeps the Drive API well within its per-project request quota.
  static const pullEvery = Duration(minutes: 1);

  /// The same after leaving the app, while Android still keeps it running
  /// (usually a few minutes). Once Android stops it, the WorkManager job
  /// checks instead, at most every 15 minutes (Android's limit).
  static const backgroundPullEvery = Duration(minutes: 1);
  DateTime? _lastPull;

  /// How often this phone looks for its own edits waiting to go up (one
  /// small local query). An upload only replaces the few small files whose
  /// records changed, so each edit goes up right away.
  static const checkEvery = Duration(seconds: 1);
  bool _foreground = true;
  int? _seenProgress;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Future<void>? _running;

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      if (supported) {
        await repository.bindInstallation(
          await DriveAuthorization().installationId(),
        );
        // How other phones' activity logs will name this one.
        unawaited(
          DriveAuthorization()
              .deviceName()
              .then(repository.setDeviceName)
              .catchError((Object _) {}),
        );
      }
      await refresh();
      _seenProgress = await repository.peerProgress();
      if (!supported || _disposed) return;
      _connectivity = Connectivity().onConnectivityChanged.listen((networks) {
        if (networks.any((network) => network != ConnectivityResult.none)) {
          unawaited(_tick(force: true));
        }
      }, onError: (Object _) {});
      if (status?.enabled == true) await _background.enable();
      if (_disposed) return;
      _timer = Timer.periodic(
        checkEvery,
        (_) => unawaited(_tick()),
      );
      await _tick();
    } catch (_) {
      actionError = 'Sync could not start. Reopen the app to retry.';
      _notify();
    }
  }

  Future<void> refresh() async {
    if (_disposed) return;
    final next = await repository.status();
    if (_disposed) return;
    final previous = status;
    status = next;
    // Polling is needed to observe background uploads, but unchanged results
    // should not rebuild the profile and sync screens.
    if (previous == next) return;
    _notify();
  }

  /// Uploads this phone's waiting edits, then merges the other phones'
  /// changes. A regular check while one is running is skipped; a [force]d
  /// one waits for it and then runs, so Sync now and pulling a list down
  /// always fetch what is on Drive by then.
  Future<void> _tick({bool force = false}) async {
    if (_disposed ||
        connecting ||
        restoring ||
        managingData ||
        changingEncryption ||
        uploadsHeld ||
        !supported) {
      return;
    }
    if (force) _forcePending = true;
    while (true) {
      final running = _check;
      if (running == null) break;
      if (!force) return;
      await running;
      if (!_forcePending) {
        // A check that started since took this request: wait for it.
        final taken = _check;
        if (taken != null) await taken;
        return;
      }
    }
    final check = _runCheck(force: _forcePending);
    _forcePending = false;
    _check = check;
    try {
      await check;
    } finally {
      if (identical(_check, check)) _check = null;
    }
  }

  Future<void> _runCheck({required bool force}) async {
    try {
      await refresh();
      if (status?.enabled != true) return;
      if (status!.pending > 0) {
        await _background.enqueue();
        if (_disposed) return;
        _running = engine.run(force: force).then((success) {
          if (success) actionError = null;
        });
        _notify();
        await _running;
        await refresh();
      }
      await _pull(force: force);
    } catch (_) {
      actionError = 'Sync will retry. Your changes are saved on this device.';
      _notify();
    } finally {
      final wasUploading = _running != null;
      _running = null;
      if (wasUploading) _notify();
    }
  }

  /// Merges other phones' changes every [pullEvery] while the app is open,
  /// every [backgroundPullEvery] after leaving it while Android keeps it
  /// running, and at once when [force]d (opening the app, Sync now, pulling
  /// a list down). Once Android stops the app, WorkManager's periodic run
  /// does it instead.
  Future<void> _pull({bool force = false}) async {
    final last = _lastPull;
    if (_disposed || status?.enabled != true) return;
    final every = _foreground ? pullEvery : backgroundPullEvery;
    if (!force && last != null && DateTime.now().difference(last) < every) {
      return;
    }
    _lastPull = DateTime.now();
    try {
      // A forced check (Sync now, back to the app) lists every file.
      final changed = await engine.pull(full: force);
      // Also catches what the background job merged while the app was away.
      final progress = await repository.peerProgress();
      final seen = _seenProgress;
      _seenProgress = progress;
      if (_disposed) return;
      if (changed > 0 || (seen != null && seen != progress)) {
        onRestored?.call();
        _notify(); // e.g. an open activity log
      }
    } on DriveSyncException catch (error) {
      // Only a version mismatch needs the user; the rest retries next time.
      if (error.message.startsWith('Update')) {
        actionError = error.message;
        _notify();
      }
    } catch (_) {}
  }

  /// After an undo in the activity log: the reverted record syncs to the
  /// other phones like any edit made here.
  void changedLocally() => unawaited(_tick(force: true));

  Future<bool> hasLocalData() => repository.hasLedgerData();

  /// When the account already holds synced data from another install and
  /// this phone is new to it, returns that data and holds uploads until
  /// [restore] or [skipRestore].
  Future<SyncBackup?> connect() async {
    if (connecting ||
        changingEncryption ||
        managingData ||
        restoring ||
        !supported) {
      return null;
    }
    connecting = true;
    actionError = null;
    _notify();
    DriveClient? client;
    var needsRestore = false;
    _uploadsHeld = false;
    try {
      await _running;
      final token = await DriveAuthorization().token(
        email: status?.email,
        interactive: true,
      );
      client = DriveClient(token);
      final account = await client.account();
      final email = account['email'];
      final subject = account['sub'];
      if (email is! String ||
          subject is! String ||
          account['email_verified'] != true) {
        throw const DriveSyncException(
          'Google could not verify the connected account.',
        );
      }
      final displayName = account['name'];
      final pictureUrl = account['picture'];
      needsRestore =
          await repository.subject() != subject ||
          status?.restorePending == true ||
          !await repository.hasLedgerData();
      await repository.connect(
        email,
        subject,
        holdUploads: needsRestore,
        displayName: displayName is String && displayName.trim().isNotEmpty
            ? displayName.trim()
            : null,
        pictureUrl:
            pictureUrl is String && Uri.tryParse(pictureUrl)?.hasScheme == true
            ? pictureUrl
            : null,
      );
      // A new link, or a phone with nothing entered yet, first checks Drive
      // for data to restore; nothing uploads until that is settled.
      _uploadsHeld = needsRestore;
      if (!_uploadsHeld) await _background.enable();
      await refresh();
    } on PlatformException catch (error) {
      if (error.code != 'canceled') {
        actionError = error.message ?? 'Could not connect to Google Drive.';
      }
    } catch (error) {
      actionError = describeError(
        error,
        'Could not connect. Check your internet connection and try again.',
      );
    } finally {
      client?.close();
      connecting = false;
      _notify();
    }
    if (_uploadsHeld) {
      final backup = await findBackup(requirePin: true);
      if (backup != null) return backup;
      if (actionError != null || pinRequired != null) return null;
      await skipRestore();
      return null;
    }
    await _tick(force: true);
    return null;
  }

  /// The newest backup from another installation, or null when there is none
  /// or Drive could not be checked (then [actionError] says why).
  Future<SyncBackup?> findBackup({bool requirePin = false}) async {
    if (restoring || !supported) return null;
    restoring = true;
    actionError = null;
    _notify();
    try {
      await _running;
      final backup = await engine.findBackup(requirePin: requirePin);
      pinRequired = null;
      _restoreEncryption = backup?.encryption;
      return backup;
    } on BackupPinRequired catch (error) {
      pinRequired = error.configuration;
      actionError = error.message;
      return null;
    } catch (error) {
      actionError = describeError(
        error,
        'Could not check Google Drive. Check your internet connection and try again.',
      );
      return null;
    } finally {
      restoring = false;
      _notify();
    }
  }

  /// Replaces this device's data with [backup], then uploads it as this
  /// device's own mirror.
  Future<bool> restore(SyncBackup backup) async {
    if (restoring) return false;
    restoring = true;
    actionError = null;
    _notify();
    try {
      await _running;
      await engine.restore(backup);
      onRestored?.call();
      return true;
    } catch (error) {
      actionError = describeError(
        error,
        'Could not restore the backup. Please try again.',
      );
      return false;
    } finally {
      restoring = false;
      if (actionError == null) {
        await skipRestore();
      } else {
        await refresh();
        _notify();
      }
    }
  }

  Future<SyncBackup?> unlockBackup(String pin) async {
    final configuration = pinRequired;
    if (configuration == null) return findBackup();
    await engine.unlockEncryption(pin, configuration);
    return findBackup();
  }

  Future<void> unlockUploads(String pin) async {
    final configuration = status?.encryption;
    if (configuration == null) {
      throw StateError('No encrypted backup is configured.');
    }
    await engine.unlockEncryption(pin, configuration);
    actionError = null;
    unawaited(_tick(force: true));
  }

  Future<void> setEncryption(bool enabled, String pin) async {
    if (changingEncryption ||
        connecting ||
        restoring ||
        managingData ||
        uploadsHeld) {
      throw StateError('Finish the current sync action first.');
    }
    changingEncryption = true;
    _notify();
    try {
      await _running;
      if (enabled) {
        await engine.enableEncryption(pin);
      } else {
        await engine.disableEncryption(pin);
      }
      actionError = null;
      await refresh();
    } finally {
      changingEncryption = false;
      _notify();
      unawaited(_tick(force: true));
    }
  }

  /// Enters the PIN the account's other phones use ([SyncStatus.peerEncryption]),
  /// so their files can be read again; then syncs at once.
  Future<void> joinEncryption(String pin) async {
    if (changingEncryption || connecting || restoring || managingData) {
      throw StateError('Finish the current sync action first.');
    }
    changingEncryption = true;
    _notify();
    try {
      await _running;
      await engine.joinEncryption(pin);
      actionError = null;
      await refresh();
    } finally {
      changingEncryption = false;
      _notify();
      unawaited(_tick(force: true));
    }
  }

  /// Keeps this device's data and resumes uploading it.
  Future<void> skipRestore() async {
    // A locked backup cannot be skipped into an unencrypted upload by mistake.
    if (pinRequired != null) {
      throw StateError('Unlock your backup before continuing.');
    }
    await engine.resumeUploads(encryption: _restoreEncryption);
    _restoreEncryption = null;
    _uploadsHeld = false;
    try {
      await refresh();
      if (status?.enabled == true) await _background.enable();
    } catch (_) {
      // The foreground timer still uploads; WorkManager is re-armed on start.
    }
    unawaited(_tick(force: true));
  }

  /// Replaces this phone's data with an imported file.
  Future<void> importData(SyncBackup data) =>
      _manageData(() => engine.restore(data));

  /// Adds a UPI statement's new transactions to the ledger.
  Future<void> addStatementTransactions(Future<void> Function() add) =>
      _manageData(add);

  /// Deletes everything on this phone; the Drive copy stays.
  Future<void> eraseDevice() => _manageData(engine.eraseDevice);

  /// Deletes the synced copy from Google Drive and turns sync off.
  Future<void> eraseDrive() => _manageData(() async {
    await engine.eraseDrive();
    await _background.disable();
  });

  /// Uploads wait while [action] runs; screens reload afterwards.
  Future<void> _manageData(Future<void> Function() action) async {
    if (managingData || restoring || connecting || changingEncryption) {
      throw StateError('Sync is busy. Try again shortly.');
    }
    managingData = true;
    _notify();
    try {
      await _running;
      await action();
      onRestored?.call();
    } finally {
      managingData = false;
      try {
        await refresh();
        // Deleting this phone's data or importing a file turns sync off.
        if (status?.enabled != true) await _background.disable();
      } catch (_) {
        // The next tick refreshes the status.
      }
      unawaited(_tick(force: true));
    }
  }

  Future<void> disconnect() async {
    if (connecting || changingEncryption || managingData || restoring) return;
    connecting = true;
    _notify();
    try {
      await repository.disconnect();
      await _background.disable();
      await _running;
      actionError = null;
      await refresh();
    } catch (_) {
      actionError = 'Could not pause sync. Please try again.';
      _notify();
    } finally {
      connecting = false;
      _notify();
    }
  }

  /// Turns sync off and forgets the connected Google account.
  Future<void> signOut() async {
    if (connecting || changingEncryption || managingData || restoring) return;
    connecting = true;
    _notify();
    try {
      final subject = await repository.subject();
      await repository.signOut();
      await _background.disable();
      await _running;
      if (subject != null) await engine.keyStore.forget(subject);
      pinRequired = null;
      _uploadsHeld = false;
      _restoreEncryption = null;
      actionError = null;
      await refresh();
    } catch (_) {
      await refresh();
      actionError = 'Could not sign out. Please try again.';
      _notify();
    } finally {
      connecting = false;
      _notify();
    }
  }

  Future<void> syncNow() async {
    if (manualSyncing ||
        connecting ||
        restoring ||
        changingEncryption ||
        uploadsHeld ||
        !supported) {
      return;
    }
    manualSyncing = true;
    actionError = null;
    _notify();
    final stopwatch = Stopwatch()..start();
    unawaited(_refreshProfile());
    try {
      await _tick(force: true);
      // Nothing pending still means this device is confirmed up to date —
      // show that as of now rather than leaving the last real upload's time.
      if (status?.enabled == true &&
          status?.error == null &&
          actionError == null) {
        await repository.touchLastSynced();
        await refresh();
      }
      final remaining = const Duration(milliseconds: 500) - stopwatch.elapsed;
      if (!remaining.isNegative) await Future<void>.delayed(remaining);
    } finally {
      manualSyncing = false;
      _notify();
    }
  }

  /// Best-effort: picks up a changed Google name/photo. Never blocks or fails
  /// the actual sync, which is why errors here are swallowed.
  Future<void> _refreshProfile() async {
    final email = status?.email;
    if (!supported || email == null) return;
    DriveClient? client;
    try {
      final token = await DriveAuthorization()
          .token(email: email)
          .timeout(const Duration(seconds: 10));
      client = DriveClient(token);
      final account = await client.account();
      final displayName = account['name'];
      final rawPictureUrl = account['picture'];
      final pictureUrl =
          rawPictureUrl is String &&
              Uri.tryParse(rawPictureUrl)?.hasScheme == true
          ? rawPictureUrl
          : null;
      // Google reuses the same URL when a user changes their photo, so the
      // disk cache can't tell the file went stale on its own — evict it.
      if (pictureUrl != null) {
        await CachedNetworkImage.evictFromCache(pictureUrl);
      }
      await repository.updateProfile(
        email,
        displayName: displayName is String && displayName.trim().isNotEmpty
            ? displayName.trim()
            : null,
        pictureUrl: pictureUrl,
      );
      await refresh();
    } catch (_) {
      // Stale name/photo is fine until the next sync attempt.
    } finally {
      client?.close();
    }
  }

  String describeError(Object error, String fallback) => switch (error) {
    DriveSyncException(:final message) => message,
    BackupEncryptionException(:final message) => message,
    StateError(:final message) => message,
    PlatformException(code: 'authorization_required') =>
      'Reconnect your Google account to resume sync.',
    _ => fallback,
  };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    final notifications = engine.progress is SyncNotifications
        ? engine.progress as SyncNotifications
        : null;
    if (state == AppLifecycleState.resumed) {
      notifications?.cameBack();
      unawaited(_tick(force: true));
    }
    if (state == AppLifecycleState.paused && status?.enabled == true) {
      // Shows an upload still running, or edits not up yet, until they are.
      notifications?.leftApp(waiting: status?.pending ?? 0);
      unawaited(_background.enqueue().catchError((Object _) {}));
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _connectivity?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
