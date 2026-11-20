import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../../data/backup/sync_repository.dart';
import '../../../../state/sync_controller.dart';
import '../../../components/common.dart';
import '../../../components/feature_page.dart';
import '../../../components/glass_button.dart';
import '../../../theme/app_theme.dart';
import 'backup_widgets.dart';
import 'backup_encryption_card.dart';
import 'sync_flow.dart';

class SyncScreen extends StatelessWidget {
  const SyncScreen({super.key, required this.controller});
  final SyncController? controller;

  @override
  Widget build(BuildContext context) {
    final sync = controller;
    if (sync == null || !sync.supported) {
      return const FeaturePage(
        title: 'Sync',
        child: Center(
          child: Text('Google Drive sync is available on Android.'),
        ),
      );
    }
    return FeaturePage(
      title: 'Sync',
      child: ListenableBuilder(
        listenable: sync,
        builder: (context, _) {
          final status = sync.status;
          if (status == null) {
            return Center(
              child: sync.actionError == null
                  ? const CircularProgressIndicator()
                  : Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        sync.actionError!,
                        textAlign: TextAlign.center,
                      ),
                    ),
            );
          }
          return ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
            children: [
              MoneyCard(
                padding: const EdgeInsets.all(22),
                child: status.enabled
                    ? _Connected(sync: sync, status: status)
                    : _Off(sync: sync, status: status),
              ),
              if (status.email != null) ...[
                const SizedBox(height: 16),
                BackupEncryptionCard(sync: sync),
              ],
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  status.encryption != null
                      ? 'Syncs by itself. On a new phone, sign in with the same Google account and enter your backup PIN to restore.'
                      : 'Syncs by itself. On a new phone, sign in with the same Google account to get it all back.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(height: 1.5),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Never signed in, or turned off (the account is still remembered).
class _Off extends StatelessWidget {
  const _Off({required this.sync, required this.status});
  final SyncController sync;
  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final paused = status.email != null;
    final busy = sync.connecting || sync.restoring;
    return Column(
      children: [
        const BackupHero(size: 88),
        const SizedBox(height: 12),
        Text(
          paused ? 'Sync is off' : 'Sync with Google Drive',
          textAlign: TextAlign.center,
          style: text.titleLarge,
        ),
        const SizedBox(height: 8),
        Text(
          paused
              ? 'Changes on this phone aren’t being synced.'
              : 'Keep your data safe in your own Google Drive.',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        if (paused) ...[
          const SizedBox(height: 18),
          _AccountChip(status: status),
        ],
        if (sync.actionError != null) ...[
          const SizedBox(height: 16),
          ErrorBanner(sync.actionError!),
        ],
        const SizedBox(height: 22),
        if (paused)
          _PrimaryButton(
            label: 'Turn on sync',
            busyLabel: 'Turning on…',
            icon: Icons.sync_rounded,
            busy: busy,
            onPressed: () => connectDrive(context, sync),
          )
        else
          GoogleSignInButton(
            busy: busy,
            busyLabel: sync.restoring ? 'Restoring your data…' : null,
            onPressed: () => connectDrive(context, sync),
          ),
        if (paused) ...[
          const SizedBox(height: 6),
          _DangerButton(
            onPressed: busy ? null : () => signOutOfDrive(context, sync),
            label: 'Sign out',
          ),
        ],
      ],
    );
  }
}

/// [pin]: this phone's changes are up, but the other phones' are locked
/// with a PIN not entered here yet.
enum _Health { restoring, locked, syncing, error, pending, pin, synced }

class _Connected extends StatelessWidget {
  const _Connected({required this.sync, required this.status});
  final SyncController sync;
  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final error = sync.actionError ?? status.error;
    final pending = status.pending;
    final health = sync.restoring
        ? _Health.restoring
        : sync.uploadsHeld
        ? _Health.locked
        : status.busy || sync.uploading || status.lastSynced == null
        ? (error != null ? _Health.error : _Health.syncing)
        : error != null
        ? _Health.error
        : pending > 0
        ? _Health.pending
        : status.peerEncryption != null
        ? _Health.pin
        : _Health.synced;
    final lastSynced = status.lastSynced == null
        ? null
        : 'Last synced ${_ago(status.lastSynced!)}';
    final (title, subtitle) = switch (health) {
      _Health.restoring => (
        'Restoring your data',
        'Getting everything from Google Drive',
      ),
      _Health.locked => (
        'Backup waiting',
        error ?? 'Continue restoring before this phone uploads.',
      ),
      _Health.syncing => (
        'Syncing…',
        lastSynced ?? 'Setting up your first sync',
      ),
      _Health.error => ('Can’t sync right now', error!),
      _Health.pending => (
        '$pending change${pending == 1 ? '' : 's'} waiting',
        'They sync when you’re back online',
      ),
      _Health.pin => (
        'PIN needed',
        'Enter your other phone’s PIN below to get its changes',
      ),
      _Health.synced => ('Up to date', lastSynced!),
    };
    final working = health == _Health.syncing || health == _Health.restoring;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _HealthBadge(health),
            const SizedBox(width: 16),
            Expanded(
              child: Semantics(
                liveRegion: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: text.titleLarge?.copyWith(fontSize: 20)),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: text.bodySmall?.copyWith(
                        fontSize: 13,
                        height: 1.4,
                        color: health == _Health.error ? coral : null,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _AccountChip(status: status),
        const SizedBox(height: 18),
        _PrimaryButton(
          label: sync.uploadsHeld ? 'Continue restore' : 'Sync now',
          busyLabel: sync.restoring ? 'Restoring…' : 'Syncing…',
          icon: Icons.sync_rounded,
          busy: working || sync.connecting || sync.manualSyncing,
          onPressed: sync.uploadsHeld
              ? () => resumeDriveRestore(context, sync)
              : sync.syncNow,
        ),
        if (status.error != null || sync.actionError != null) ...[
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: TextButton(
              onPressed: working || sync.connecting
                  ? null
                  : () => connectDrive(context, sync),
              child: const Text('Reconnect'),
            ),
          ),
        ],
        const SizedBox(height: 10),
        _DangerButton(
          onPressed: sync.connecting || sync.restoring ? null : sync.disconnect,
          label: 'Turn off sync',
        ),
        const SizedBox(height: 10),
        _DangerButton(
          onPressed: sync.connecting || sync.restoring
              ? null
              : () => signOutOfDrive(context, sync),
          label: 'Sign out',
        ),
      ],
    );
  }
}

class _PrimaryButton extends StatelessWidget {
  const _PrimaryButton({
    required this.label,
    required this.busyLabel,
    required this.icon,
    required this.busy,
    required this.onPressed,
  });
  final String label, busyLabel;
  final IconData icon;
  final bool busy;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => GlassButton(
    color: Theme.of(context).colorScheme.primary,
    textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
    onPressed: busy ? null : onPressed,
    child: Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        busy
            ? SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Theme.of(context).colorScheme.primary,
                ),
              )
            : Icon(icon),
        const SizedBox(width: 8),
        Flexible(child: Text(busy ? busyLabel : label)),
      ],
    ),
  );
}

class _DangerButton extends StatelessWidget {
  const _DangerButton({required this.onPressed, required this.label});
  final VoidCallback? onPressed;
  final String label;

  @override
  Widget build(BuildContext context) => GlassButton(
    onPressed: onPressed,
    foregroundColor: coral,
    textStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
    child: Text(label),
  );
}

String _ago(DateTime time) {
  final elapsed = DateTime.now().difference(time);
  if (elapsed.inMinutes < 1) return 'just now';
  if (elapsed.inMinutes < 60) return '${elapsed.inMinutes} min ago';
  if (elapsed.inHours < 24) return '${elapsed.inHours} h ago';
  return DateFormat.MMMd().add_jm().format(time);
}

class _HealthBadge extends StatelessWidget {
  const _HealthBadge(this.health);
  final _Health health;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (health) {
      _Health.restoring => (
        Icons.cloud_download_rounded,
        Theme.of(context).colorScheme.primary,
      ),
      _Health.locked => (
        Icons.lock_outline_rounded,
        Theme.of(context).colorScheme.primary,
      ),
      _Health.syncing => (
        Icons.sync_rounded,
        Theme.of(context).colorScheme.primary,
      ),
      _Health.error => (Icons.cloud_off_rounded, coral),
      _Health.pending => (
        Icons.cloud_queue_rounded,
        Theme.of(context).colorScheme.primary,
      ),
      _Health.pin => (Icons.key_rounded, coral),
      _Health.synced => (Icons.cloud_done_rounded, green),
    };
    final working = health == _Health.syncing || health == _Health.restoring;
    return SizedBox.square(
      dimension: 60,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: color.withValues(alpha: .12),
            ),
            child: Icon(icon, color: color, size: 28),
          ),
          if (working)
            SizedBox.square(
              dimension: 60,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: color,
                strokeCap: StrokeCap.round,
              ),
            ),
        ],
      ),
    );
  }
}

class _AccountChip extends StatelessWidget {
  const _AccountChip({required this.status});
  final SyncStatus status;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = status.displayName;
    final email = status.email ?? '';
    final picture = status.pictureUrl;
    const fallback = Icon(
      Icons.person_outline_rounded,
      color: Colors.white,
      size: 20,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 10, 14, 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: .04),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Row(
        children: [
          Container(
            width: 38,
            height: 38,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Theme.of(context).colorScheme.primary,
            ),
            child: picture == null
                ? fallback
                : CachedNetworkImage(
                    imageUrl: picture,
                    fit: BoxFit.cover,
                    fadeInDuration: Duration.zero,
                    errorWidget: (_, _, _) => fallback,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name ?? email,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium?.copyWith(fontSize: 14),
                ),
                if (name != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    email,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 10),
          const GoogleLogo(size: 18),
        ],
      ),
    );
  }
}
