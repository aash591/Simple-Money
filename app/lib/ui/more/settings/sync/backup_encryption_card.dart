import 'package:flutter/material.dart';

import '../../../../state/sync_controller.dart';
import '../../../components/common.dart';
import '../../../theme/app_theme.dart';
import 'backup_pin_screen.dart';
import 'sync_flow.dart';

class BackupEncryptionCard extends StatelessWidget {
  const BackupEncryptionCard({super.key, required this.sync});
  final SyncController sync;

  @override
  Widget build(BuildContext context) {
    final enabled = sync.status?.encryption != null;
    final busy =
        sync.connecting ||
        sync.restoring ||
        sync.managingData ||
        sync.changingEncryption ||
        sync.uploadsHeld;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final locked = busy || sync.status?.enabled != true;
    void toggle(bool value) => showBackupPinFlow(
      context,
      purpose: value ? BackupPinPurpose.enable : BackupPinPurpose.disable,
      onSubmit: (pin) => sync.setEncryption(value, pin),
    );
    return MoneyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: locked ? null : () => toggle(!enabled),
            child: Row(
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: (enabled ? green : scheme.primary).withValues(
                      alpha: .14,
                    ),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    enabled ? Icons.lock_rounded : Icons.lock_open_rounded,
                    size: 22,
                    color: enabled ? green : scheme.primary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Encrypt Drive backups',
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        enabled
                            ? 'On · your PIN is needed to restore'
                            : 'Off · lock them with a 6-character PIN',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                Switch.adaptive(
                  value: enabled,
                  onChanged: locked ? null : toggle,
                ),
              ],
            ),
          ),
          if (enabled)
            TextButton(
              onPressed: sync.changingEncryption || sync.restoring
                  ? null
                  : () async {
                      if (sync.uploadsHeld) {
                        await resumeDriveRestore(context, sync);
                      } else {
                        await showBackupPinFlow(
                          context,
                          purpose: BackupPinPurpose.unlock,
                          onSubmit: sync.unlockUploads,
                        );
                      }
                    },
              child: const Text('Enter backup PIN'),
            ),
        ],
      ),
    );
  }
}
