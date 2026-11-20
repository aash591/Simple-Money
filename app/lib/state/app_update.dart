import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum AppUpdateStage {
  /// Up to date, or not checked yet.
  none,

  /// A newer version is on Google Play.
  available,

  /// Downloading in the background; the app stays usable.
  downloading,

  /// Downloaded, waiting for a restart to install.
  ready,
}

/// Google Play's flexible in-app update: tell the person a new version is out,
/// download it quietly in the background when they say so, then offer to
/// install it once it is ready. Android only; elsewhere it stays [none].
class AppUpdate extends ChangeNotifier {
  AppUpdate._();
  static final instance = AppUpdate._();

  static const _skippedKey = 'update_skipped_version';

  AppUpdateStage _stage = AppUpdateStage.none;
  AppUpdateStage get stage => _stage;

  /// Play's version code of the update on offer.
  int? versionCode;

  /// Set when the person has already said "Later" to [versionCode], so the
  /// sheet doesn't come back on every launch (the About row still shows it).
  bool skipped = false;

  StreamSubscription<InstallStatus>? _installs;

  bool get _supported => !kIsWeb && Platform.isAndroid;

  void _set(AppUpdateStage stage) {
    if (_stage == stage) return;
    _stage = stage;
    notifyListeners();
  }

  /// Asks Play whether a newer version exists. Quiet on any failure: apps
  /// not installed from Play (debug builds, sideloads) simply have none.
  Future<void> check() async {
    if (!_supported || _stage == AppUpdateStage.downloading) return;
    try {
      final info = await InAppUpdate.checkForUpdate();
      _listen();
      if (info.installStatus == InstallStatus.downloaded) {
        versionCode = info.availableVersionCode;
        _set(AppUpdateStage.ready);
        return;
      }
      if (info.installStatus == InstallStatus.downloading ||
          info.installStatus == InstallStatus.pending) {
        _set(AppUpdateStage.downloading);
        return;
      }
      if (info.updateAvailability == UpdateAvailability.updateAvailable &&
          info.flexibleUpdateAllowed) {
        versionCode = info.availableVersionCode;
        final prefs = await SharedPreferences.getInstance();
        skipped = prefs.getInt(_skippedKey) == versionCode;
        _set(AppUpdateStage.available);
      } else {
        _set(AppUpdateStage.none);
      }
    } catch (_) {
      // Not from Play, offline, or Play unavailable: nothing to offer.
    }
  }

  void _listen() {
    _installs ??= InAppUpdate.installUpdateListener.listen((status) {
      switch (status) {
        case InstallStatus.pending:
        case InstallStatus.downloading:
          _set(AppUpdateStage.downloading);
        case InstallStatus.downloaded:
          _set(AppUpdateStage.ready);
        case InstallStatus.failed:
        case InstallStatus.canceled:
          _set(AppUpdateStage.available);
        case InstallStatus.installed:
          _set(AppUpdateStage.none);
        case InstallStatus.installing:
        case InstallStatus.unknown:
          break;
      }
    }, onError: (_) {});
  }

  /// Starts the background download. Play shows its own small consent
  /// dialog first; if it is declined the offer stays as it was.
  Future<void> start() async {
    if (_stage != AppUpdateStage.available) return;
    try {
      final result = await InAppUpdate.startFlexibleUpdate();
      if (result == AppUpdateResult.success) {
        // The stream moves it on to downloading, then ready.
        if (_stage == AppUpdateStage.available) {
          _set(AppUpdateStage.downloading);
        }
      }
    } catch (_) {
      _set(AppUpdateStage.available);
    }
  }

  /// "Later": don't show the sheet again for this version.
  Future<void> skip() async {
    skipped = true;
    final code = versionCode;
    if (code == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_skippedKey, code);
  }

  /// Installs the downloaded update; the app restarts into it.
  Future<void> install() async {
    try {
      await InAppUpdate.completeFlexibleUpdate();
    } catch (_) {}
  }

  @override
  void dispose() {
    _installs?.cancel();
    super.dispose();
  }
}
