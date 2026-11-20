import 'package:flutter/widgets.dart';
import 'package:drive_authorization/drive_authorization.dart';
import 'package:workmanager/workmanager.dart';

import '../db/app_database.dart';
import 'sync_engine.dart';
import 'sync_notifications.dart';
import 'sync_repository.dart';

const _task = 'simple-money-drive-sync';

@pragma('vm:entry-point')
void driveSyncDispatcher() {
  Workmanager().executeTask((task, _) async {
    WidgetsFlutterBinding.ensureInitialized();
    if (task != _task) return true;
    final db = AppDatabase();
    try {
      final repository = SyncRepository(db);
      await repository.bindInstallation(
        await DriveAuthorization().installationId(),
      );
      // In the background an upload shows at once, until it's done.
      final engine = SyncEngine(
        repository,
        progress: SyncNotifications()..background = true,
      );
      final uploaded = await engine.run();
      // The app opens with other phones' changes already merged.
      try {
        await engine.pull();
      } catch (_) {}
      return uploaded;
    } catch (_) {
      return false;
    } finally {
      await db.close();
    }
  });
}

class SyncBackground {
  static Future<void>? _initialization;
  Future<void> initialize() =>
      _initialization ??= Workmanager().initialize(driveSyncDispatcher);

  Future<void> enable() async {
    await initialize();
    await Workmanager().registerPeriodicTask(
      '$_task-periodic',
      _task,
      frequency: const Duration(minutes: 15),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(seconds: 30),
    );
  }

  static Future<int>? _sdk;

  /// Queues an upload of the waiting edits that doesn't depend on the app:
  /// it runs, with its progress notification, even after the app is swiped
  /// away. From Android 12 it is expedited (starts right away; a normal job
  /// once Android's expedited quota is used up). Before Android 12 expedited
  /// work needs a foreground notification the plugin doesn't give, so it is
  /// a normal job there.
  Future<void> enqueue() async {
    await initialize();
    final sdk = await (_sdk ??= DriveAuthorization().sdkInt().catchError(
      (Object _) => 0,
    ));
    await Workmanager().registerOneOffTask(
      '$_task-pending',
      _task,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(seconds: 30),
      expedited: sdk >= 31,
      outOfQuotaPolicy: OutOfQuotaPolicy.runAsNonExpeditedWorkRequest,
    );
  }

  Future<void> disable() async {
    await initialize();
    await Workmanager().cancelByUniqueName('$_task-periodic');
    await Workmanager().cancelByUniqueName('$_task-pending');
  }
}
