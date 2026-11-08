import 'package:flutter/material.dart';

import '../../../../state/sync_controller.dart';
import '../../../components/app_toast.dart';
import '../../../components/confirmation_alert.dart';

/// Signs in to Google Drive. If the account already has synced data and this
/// phone has nothing entered, that data is brought back straight away; only
/// a phone with entries of its own is asked which to keep.
/// True once sync is on.
Future<bool> connectDrive(BuildContext context, SyncController sync) async {
  final backup = await sync.connect();
  if (backup != null) {
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
    } else if (await sync.restore(backup) && context.mounted) {
      showAppToast(context, 'Your data is back', icon: Icons.check_rounded);
    }
  } else if (sync.status?.enabled == true && context.mounted) {
    showAppToast(context, 'Sync is on', icon: Icons.cloud_done_outlined);
  }
  return sync.status?.enabled == true;
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
