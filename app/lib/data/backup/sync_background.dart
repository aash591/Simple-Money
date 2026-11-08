import 'package:flutter/widgets.dart';
import 'package:drive_authorization/drive_authorization.dart';
import 'package:workmanager/workmanager.dart';

import '../db/app_database.dart';
import 'sync_engine.dart';
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
      return await SyncEngine(repository).run();
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

  Future<void> enqueue() async {
    await initialize();
    await Workmanager().registerOneOffTask(
      '$_task-pending',
      _task,
      existingWorkPolicy: ExistingWorkPolicy.keep,
      constraints: Constraints(networkType: NetworkType.connected),
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(seconds: 30),
    );
  }

  Future<void> disable() async {
    await initialize();
    await Workmanager().cancelByUniqueName('$_task-periodic');
    await Workmanager().cancelByUniqueName('$_task-pending');
  }
}
