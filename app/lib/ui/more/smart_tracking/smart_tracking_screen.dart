import 'package:flutter/material.dart';

import '../../../data/community/community_fixes.dart';
import '../../../data/db/app_database.dart';
import '../../../data/keep_alive_platform.dart';
import '../../../state/sms_import_store.dart';
import '../../components/feature_page.dart';
import '../../components/menu_list.dart';
import '../../welcome/onboarding_screen.dart';
import 'keep_working/keep_working_card.dart';
import 'sms/teach_missed_sms_screen.dart';
import 'shared_fixes_screen.dart';

/// More › Smart tracking: everything about SimpleMoney adding transactions
/// from bank messages, in one place. From the top: keeping it running in the
/// background (only while there is something to do there: once every step is
/// done it moves to the bottom), SMS (the switch, teaching a missed one), and
/// the ways to teach it more: with an AI, or fixes other people shared.
/// Transactions from app notifications are experimental, so they are under
/// Settings › Experimental.
class SmartTrackingScreen extends StatefulWidget {
  const SmartTrackingScreen({
    super.key,
    this.smsStore,
    this.community,
    this.database,
    this.onRulesChanged,
    this.onTeach,
    this.keepAlive,
  });

  /// Replaced in tests.
  final KeepAlivePlatform? keepAlive;

  /// The bank SMS reader; without it (or off Android) there is no switch.
  final SmsImportStore? smsStore;

  /// Fixes other people shared; without it there is no Shared fixes row.
  final CommunitySync? community;

  /// For Unrecognized SMS, which reads messages with the saved rules.
  final AppDatabase? database;

  /// Reads the SMS inbox again after a shared fix changed the rules.
  final VoidCallback? onRulesChanged;

  /// Opens the AI assistant, which can learn a format the app misses.
  final VoidCallback? onTeach;

  /// Whether this phone can read SMS at all.
  static bool offered(SmsImportStore? sms, CommunitySync? community) =>
      (sms?.supported ?? false) || community != null;

  @override
  State<SmartTrackingScreen> createState() => _SmartTrackingScreenState();
}

class _SmartTrackingScreenState extends State<SmartTrackingScreen> {
  SmsImportStore? get smsStore => widget.smsStore;
  CommunitySync? get community => widget.community;
  AppDatabase? get database => widget.database;
  VoidCallback? get onRulesChanged => widget.onRulesChanged;
  VoidCallback? get onTeach => widget.onTeach;

  /// Steps still to do in Keep it working; unknown until the phone answers.
  /// The card is kept by this key so it isn't rebuilt when it moves.
  int? _left;
  final _keepKey = GlobalKey();

  /// Turning it on says what is read, then asks Android. Turning it off stops
  /// reading at once, including new messages.
  Future<void> _setSms(
    BuildContext context,
    SmsImportStore sms,
    bool on,
  ) async {
    if (!on) {
      await sms.disable();
      return;
    }
    // The same setup screen as the first run: what is read, the Android
    // prompt, then the accounts found.
    await Navigator.of(context).push(
      FeatureRoute<void>(
        Builder(
          builder: (context) => OnboardingScreen(
            database: sms.repository.database,
            sms: sms,
            smsOnly: true,
            onDone: () => Navigator.of(context).pop(),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sms = smsStore;
    final shared = community;
    final teach = onTeach;
    final keepAlive = widget.keepAlive ?? KeepAlivePlatform();
    final keep = keepAlive.supported;
    final keepLast = _left == 0;
    final card = KeepWorkingCard(
      key: _keepKey,
      platform: widget.keepAlive,
      onLeftChanged: (left) {
        if (mounted && left != _left) setState(() => _left = left);
      },
    );
    return FeaturePage(
      title: 'Smart tracking',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.info_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'SimpleMoney reads bank SMS right on this phone to add '
                        'transactions for you. They never leave it.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              // Whether Android may stop it in the background: first while
              // there is something to do (or not yet known), last once done.
              if (keep && !keepLast) ...[card, const SizedBox(height: 24)],
              MenuGroup(
                label: 'SMS',
                children: [
                  if (sms != null && sms.supported)
                    ListenableBuilder(
                      listenable: sms,
                      builder: (context, _) => MenuSwitchRow(
                        icon: Icons.sms_rounded,
                        title: 'Transactions from SMS',
                        subtitle: sms.enabled
                            ? 'Reading bank SMS to add transactions'
                            : 'Off · no SMS are read',
                        value: sms.enabled,
                        onChanged: sms.busy
                            ? null
                            : (value) => _setSms(context, sms, value),
                      ),
                    ),
                  MenuRow(
                    icon: Icons.sms_failed_rounded,
                    title: 'Teach a missed SMS',
                    subtitle: 'Tap the words to show the app what to read',
                    onTap: () => Navigator.of(context).push(
                      FeatureRoute<void>(
                        TeachMissedSmsScreen(
                          database: database,
                          onRulesChanged: onRulesChanged,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              // The ways to fix what was missed: ask an AI, or use what
              // other people shared.
              if (teach != null || shared != null)
                MenuGroup(
                  label: 'Teach and share',
                  children: [
                    if (teach != null)
                      MenuRow(
                        icon: Icons.auto_awesome_rounded,
                        title: 'Teach with AI',
                        subtitle:
                            'Claude or ChatGPT learns your missed SMS for you',
                        onTap: teach,
                      ),
                    if (shared != null)
                      MenuRow(
                        icon: Icons.groups_rounded,
                        title: 'Community rules',
                        subtitle: 'Shared by other users, used here',
                        onTap: () => Navigator.of(context).push(
                          FeatureRoute<void>(
                            SharedFixesScreen(
                              community: shared,
                              onRulesChanged: onRulesChanged,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              if (keep && keepLast) ...[
                if (teach != null || shared != null) const SizedBox(height: 24),
                card,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
