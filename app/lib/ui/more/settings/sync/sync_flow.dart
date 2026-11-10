import 'package:flutter/material.dart';

import '../../../../state/sync_controller.dart';
import '../../../../data/backup/sync_restore.dart';
import 'backup_pin_screen.dart';
import '../../../components/app_toast.dart';
import '../../../components/confirmation_alert.dart';

/// Signs in to Google Drive. If the account already has synced data and this
/// phone has nothing entered, that data is brought back straight away; only
/// a phone with entries of its own is asked which to keep.
/// True once sync is on.
Future<bool> connectDrive(BuildContext context, SyncController sync) async {
  final backup = await sync.connect();
  if (!context.mounted) return false;
  return _finishRestore(context, sync, backup);
}

/// Also used after cancellation or an app restart while a backup was locked.
Future<bool> resumeDriveRestore(
  BuildContext context,
  SyncController sync,
) async {
  final backup = await sync.findBackup(requirePin: true);
  if (!context.mounted) return false;
  return _finishRestore(context, sync, backup);
}

Future<bool> _finishRestore(
  BuildContext context,
  SyncController sync,
  SyncBackup? backup,
) async {
  if (!context.mounted) return false;
  if (sync.pinRequired != null) {
    final unlocked = await showBackupPinFlow(
      context,
      purpose: BackupPinPurpose.unlock,
      onSubmit: (pin) async {
        backup = await sync.unlockBackup(pin);
        if (sync.actionError != null) throw StateError(sync.actionError!);
      },
    );
    if (!unlocked || !context.mounted) return false;
  }
  final selectedBackup = backup;
  if (selectedBackup != null) {
    final useSynced =
        !await sync.hasLocalData() ||
        (context.mounted &&
            await showConfirmationAlert(
              context,
              title: 'Use your synced data?',
              message: 'This phone already has entries. Use your Google Drive data instead, or keep this phone’s.',
              confirmLabel: 'Use synced',
              cancelLabel: 'Keep phone’s',
              destructive: false,
            ));
    if (!useSynced) {
      await sync.skipRestore();
    } else if (await sync.restore(selectedBackup) && context.mounted) {
      showAppToast(context, 'Your data is back', icon: Icons.check_rounded);
    }
  } else if (sync.status?.enabled == true &&
      sync.actionError == null &&
      context.mounted) {
    if (sync.uploadsHeld) await sync.skipRestore();
    if (!context.mounted) return false;
    showAppToast(context, 'Sync is on', icon: Icons.cloud_done_outlined);
  }
  return sync.status?.enabled == true &&
      !sync.uploadsHeld &&
      sync.actionError == null;
}

/// Turns sync off and forgets the connected Google account, after
/// confirming. Data on this phone and in Google Drive is left alone.
Future<void> signOutOfDrive(BuildContext context, SyncController sync) async {
  if (!await showConfirmationAlert(
    context,
    title: 'Sign out of Google Drive?',
    message: 'Sync turns off. Your data stays here and in Google Drive.',
    confirmLabel: 'Sign out',
  )) {
    return;
  }
  await sync.signOut();
  if (context.mounted) {
    showAppToast(context, 'Signed out', icon: Icons.logout_rounded);
  }
}
