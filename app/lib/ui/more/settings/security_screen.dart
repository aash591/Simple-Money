import 'package:flutter/material.dart';

import '../../../state/security_controller.dart';
import '../../components/choice_list_sheet.dart';
import '../../components/common.dart';
import '../../components/feature_page.dart';

class SecurityScreen extends StatelessWidget {
  const SecurityScreen({super.key});

  Future<void> _pickTiming(
    BuildContext context,
    SecurityController security,
  ) async {
    final primary = Theme.of(context).colorScheme.primary;
    final picked = await showChoiceListSheet<LockTiming>(
      context,
      title: 'Lock after time away',
      selected: security.timing,
      items: [
        for (final option in LockTiming.values)
          ChoiceItem<LockTiming>(
            value: option,
            icon: Icon(
              switch (option) {
                LockTiming.immediately => Icons.bolt_rounded,
                LockTiming.never => Icons.all_inclusive_rounded,
                _ => Icons.schedule_rounded,
              },
              size: 20,
              color: primary,
            ),
            label: option.label,
          ),
      ],
    );
    if (picked != null) await security.setTiming(picked);
  }

  @override
  Widget build(BuildContext context) {
    final security = SecurityScope.of(context);
    final theme = Theme.of(context);
    return FeaturePage(
      title: 'Security',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 24, 18, 32),
        children: [
          _SettingCard(
            child: SwitchListTile.adaptive(
              secondary: Icon(
                Icons.visibility_off_outlined,
                color: theme.colorScheme.primary,
              ),
              title: const Text('Hide amounts'),
              subtitle: const Text(
                'Balances show as dots until you tap the eye.',
              ),
              value: security.hideAmounts,
              onChanged: security.busy || !security.ready
                  ? null
                  : security.setHideAmounts,
            ),
          ),
          const SizedBox(height: 14),
          _SettingCard(
            child: SwitchListTile.adaptive(
              secondary: Icon(
                Icons.fingerprint_rounded,
                color: theme.colorScheme.primary,
              ),
              title: const Text('Authenticate to show amounts'),
              subtitle: const Text(
                'Use fingerprint, face or PIN to show hidden balances.',
              ),
              value: security.authenticateToRevealAmounts,
              onChanged:
                  security.busy || !security.ready || !security.hideAmounts
                  ? null
                  : security.setAuthenticateToRevealAmounts,
            ),
          ),
          const SizedBox(height: 14),
          _SettingCard(
            child: SwitchListTile.adaptive(
              secondary: Icon(
                Icons.lock_outline_rounded,
                color: theme.colorScheme.primary,
              ),
              title: const Text('App lock'),
              subtitle: const Text(
                'Require device authentication when opening SimpleMoney.',
              ),
              value: security.enabled,
              onChanged: security.busy || !security.ready
                  ? null
                  : security.setEnabled,
            ),
          ),
          if (security.enabled) ...[
            // Each enabled trigger independently ends the session.
            if (security.screenLockSupported) ...[
              const SizedBox(height: 14),
              _SettingCard(
                child: SwitchListTile.adaptive(
                  secondary: Icon(
                    Icons.phonelink_lock_outlined,
                    color: theme.colorScheme.primary,
                  ),
                  title: const Text('Lock when the screen turns off'),
                  subtitle: const Text(
                    'Ask again as soon as your phone locks.',
                  ),
                  value: security.lockOnScreenOff,
                  onChanged: security.busy ? null : security.setLockOnScreenOff,
                ),
              ),
            ],
            const SizedBox(height: 14),
            _SettingCard(
              child: SwitchListTile.adaptive(
                secondary: Icon(
                  Icons.layers_clear_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('Lock when cleared from recents'),
                subtitle: const Text(
                  'Lock when cleared from recents, even before the time-away limit.',
                ),
                value: security.lockOnAppClose,
                onChanged: security.busy ? null : security.setLockOnAppClose,
              ),
            ),
            const SizedBox(height: 14),
            _SettingCard(
              child: ListTile(
                leading: Icon(
                  Icons.timer_outlined,
                  color: theme.colorScheme.primary,
                ),
                title: const Text('Lock after time away'),
                subtitle: Text(
                  security.timing.label,
                  style: TextStyle(
                    color: theme.colorScheme.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                trailing: const Icon(Icons.chevron_right_rounded),
                onTap: security.busy
                    ? null
                    : () => _pickTiming(context, security),
              ),
            ),
            /*
            const SizedBox(height: 14),
            Text(
              security.screenLockSupported
                  ? 'Locks when your phone locks, and after this long away. Quick trips out come straight back.'
                  : 'Leave for less than this, and you come straight back in.',
              style: text.bodyMedium,
            ),
            if (security.relocksOnlyOnRestart) ...[
              const SizedBox(height: 10),
              Text(
                'With these settings, the app stays unlocked until you close it.',
                style: text.bodyMedium?.copyWith(
                  color: theme.colorScheme.error,
                ),
              ),
            ],
            */
          ],
          const SizedBox(height: 18),
          _SettingCard(
            child: SwitchListTile.adaptive(
              secondary: Icon(
                Icons.visibility_off_outlined,
                color: theme.colorScheme.primary,
              ),
              title: const Text('Hide app preview'),
              subtitle: const Text(
                'Blurs SimpleMoney in recent apps. Doesn’t change when it locks.',
              ),
              value: security.hideAppPreview,
              onChanged: security.busy || !security.ready
                  ? null
                  : security.setHideAppPreview,
            ),
          ),
          /*
          const SizedBox(height: 18),
          const Text(
            'Fingerprint, face, or your phone’s PIN, pattern or password.',
          ),
          const SizedBox(height: 12),
          Text(
            'SimpleMoney never sees or stores your biometrics or screen lock credentials.',
            style: text.bodySmall,
          ),
          */
          if (security.busy) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
          if (security.error != null) ...[
            const SizedBox(height: 18),
            Text(
              security.error!,
              style: TextStyle(color: theme.colorScheme.error),
            ),
          ],
        ],
      ),
    );
  }
}

/// A rounded card holding one settings row, with ink that stays inside it.
class _SettingCard extends StatelessWidget {
  const _SettingCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => MoneyCard(
    padding: EdgeInsets.zero,
    child: Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: child,
    ),
  );
}
