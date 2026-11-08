import 'dart:async';
import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:drive_authorization/drive_authorization.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../data/backup/drive_client.dart';
import '../data/backup/sync_background.dart';
import '../data/backup/sync_engine.dart';
import '../data/backup/sync_repository.dart';
import '../data/backup/sync_restore.dart';

class SyncController extends ChangeNotifier with WidgetsBindingObserver {
  SyncController(this.repository) : engine = SyncEngine(repository);
  final SyncRepository repository;
  final SyncEngine engine;
  final _background = SyncBackground();
  SyncStatus? status;
  String? actionError;
  bool connecting = false;

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
  bool get supported => Platform.isAndroid;
  bool _disposed = false, _ticking = false, _uploadsHeld = false;
  Timer? _timer;
  StreamSubscription<List<ConnectivityResult>>? _connectivity;
  Future<void>? _running;

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    try {
      if (supported) {
        await repository.bindInstallation(
          await DriveAuthorization().installationId(),
        );
      }
      await refresh();
      if (!supported || _disposed) return;
      _connectivity = Connectivity().onConnectivityChanged.listen((networks) {
        if (networks.any((network) => network != ConnectivityResult.none)) {
          unawaited(_tick(force: true));
        }
      }, onError: (Object _) {});
      if (status?.enabled == true) await _background.enable();
      if (_disposed) return;
      _timer = Timer.periodic(
        const Duration(seconds: 3),
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

  Future<void> _tick({bool force = false}) async {
    if (_disposed ||
        _ticking ||
        connecting ||
        restoring ||
        managingData ||
        _uploadsHeld ||
        !supported) {
      return;
    }
    _ticking = true;
    try {
      await refresh();
      if (status?.enabled != true || status!.pending == 0) return;
      await _background.enqueue();
      if (_disposed) return;
      _running = engine.run(force: force).then((success) {
        if (success) actionError = null;
      });
      _notify();
      await _running;
      await refresh();
    } catch (_) {
      actionError = 'Sync will retry. Your changes are saved on this device.';
      _notify();
    } finally {
      final wasUploading = _running != null;
      _running = null;
      _ticking = false;
      if (wasUploading) _notify();
    }
  }

  Future<bool> hasLocalData() => repository.hasLedgerData();

  /// When the account already holds synced data from another install and
  /// this phone is new to it, returns that data and holds uploads until
  /// [restore] or [skipRestore].
  Future<SyncBackup?> connect() async {
    if (connecting || !supported) return null;
    connecting = true;
    actionError = null;
    _notify();
    DriveClient? client;
    var linked = false;
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
      linked = await repository.connect(
        email,
        subject,
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
      _uploadsHeld = linked || !await repository.hasLedgerData();
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
      final backup = await findBackup();
      if (backup != null) return backup;
      await skipRestore();
      return null;
    }
    await _tick(force: true);
    return null;
  }

  /// The newest backup from another installation, or null when there is none
  /// or Drive could not be checked (then [actionError] says why).
  Future<SyncBackup?> findBackup() async {
    if (restoring || !supported) return null;
    restoring = true;
    actionError = null;
    _notify();
    try {
      await _running;
      return await engine.findBackup();
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
      await skipRestore();
    }
  }

  /// Keeps this device's data and resumes uploading it.
  Future<void> skipRestore() async {
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
    if (managingData || restoring || connecting) {
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
      } catch (_) {
        // The next tick refreshes the status.
      }
      unawaited(_tick(force: true));
    }
  }

  Future<void> disconnect() async {
    if (connecting) return;
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
    if (connecting) return;
    connecting = true;
    _notify();
    try {
      await repository.signOut();
      await _background.disable();
      await _running;
      actionError = null;
      await refresh();
    } catch (_) {
      actionError = 'Could not sign out. Please try again.';
      _notify();
    } finally {
      connecting = false;
      _notify();
    }
  }

  Future<void> syncNow() async {
    if (manualSyncing || connecting || restoring || !supported) return;
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
    StateError(:final message) => message,
    PlatformException(code: 'authorization_required') =>
      'Reconnect your Google account to resume sync.',
    _ => fallback,
  };

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_tick(force: true));
    if (state == AppLifecycleState.paused && status?.enabled == true) {
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
