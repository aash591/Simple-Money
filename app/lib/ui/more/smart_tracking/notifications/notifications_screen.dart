import 'package:flutter/material.dart';

import '../../../../data/db/app_database.dart';
import '../../../../data/notification_access_platform.dart';
import '../../../components/feature_page.dart';
import '../../../components/menu_list.dart';
import 'taught_app_screen.dart';
import 'teach_notification_screen.dart';

/// Smart tracking › App notifications: the switch, whether Android allows
/// reading notifications, and the apps taught so far. An app is added by
/// teaching it from one of its notifications; only taught apps are read.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({
    super.key,
    this.platform,
    this.database,
    this.onRulesChanged,
  });

  /// Replaced in tests.
  final NotificationAccessPlatform? platform;

  /// Teaching saves rules here; without it there is no Teach button.
  final AppDatabase? database;

  /// Reads again with a new rule, after an app was taught.
  final VoidCallback? onRulesChanged;

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen>
    with WidgetsBindingObserver {
  late final NotificationAccessPlatform _platform =
      widget.platform ?? NotificationAccessPlatform();
  bool _loaded = false, _granted = false, _enabled = false;
  List<TaughtApp> _taught = const [];
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Back from Android's settings, access may have been given or taken away.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _load();
  }

  Future<void> _load() async {
    try {
      final granted = await _platform.isGranted();
      final (enabled, taught) = await _platform.state();
      if (!mounted) return;
      setState(() {
        _granted = granted;
        _enabled = enabled;
        _taught = taught;
        _error = null;
        _loaded = true;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Couldn’t load your apps. Try again.';
          _loaded = true;
        });
      }
    }
  }

  Future<void> _setEnabled(bool on) async {
    // Asked again, not remembered: access may have been taken away since.
    final granted = await _platform.isGranted();
    setState(() {
      _granted = granted;
      _enabled = on;
    });
    await _platform.setEnabled(on);
    // Reading only starts once Android has been told it is allowed.
    if (on && !granted) await _platform.openSettings();
  }

  /// Pauses or resumes reading one app, keeping what it was taught.
  Future<void> _setApp(TaughtApp app, bool on) async {
    final next = [
      for (final a in _taught)
        if (a.package == app.package) a.copyWith(enabled: on) else a,
    ];
    setState(() => _taught = next);
    await _platform.setTaught(next);
  }

  /// The app's page: what it was taught, to teach it again. Without a
  /// database to read that from, a tap pauses or resumes it instead.
  Future<void> _open(TaughtApp app) async {
    final database = widget.database;
    if (database == null) return _setApp(app, !app.enabled);
    await Navigator.of(context).push(
      FeatureRoute<bool>(
        TaughtAppScreen(
          database: database,
          app: app,
          platform: widget.platform,
          onRulesChanged: widget.onRulesChanged,
        ),
      ),
    );
    // It may have been paused, resumed, taught again or removed there.
    await _load();
  }

  /// The app's own icon, or its first letter when Android gave none.
  Widget _appIcon(TaughtApp app) {
    final scheme = Theme.of(context).colorScheme;
    final icon = app.icon;
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: SizedBox.square(
        dimension: 40,
        child: icon != null
            ? Image.memory(icon, fit: BoxFit.cover, gaplessPlayback: true)
            : ColoredBox(
                color: scheme.primary.withValues(alpha: .18),
                child: Center(
                  child: Text(
                    app.label.isEmpty ? '?' : app.label[0].toUpperCase(),
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: scheme.primary,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Future<void> _teach() async {
    final database = widget.database;
    if (database == null) return;
    await Navigator.of(context).push(
      FeatureRoute<bool>(
        TeachNotificationScreen(
          database: database,
          platform: widget.platform,
          onRulesChanged: widget.onRulesChanged,
        ),
      ),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FeaturePage(
      title: 'App notifications',
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
                child: Text(
                  'Some banks and payment apps send a notification instead of '
                  'an SMS. Teach SimpleMoney from one of their notifications, '
                  'and only those apps are read, right on this phone.',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 18),
                  child: Text(_error!, style: theme.textTheme.bodyMedium),
                ),
              if (_loaded) ...[
                MenuGroup(
                  children: [
                    // On only while Android really allows it: with access
                    // missing or taken away, nothing is read.
                    MenuSwitchRow(
                      icon: Icons.notifications_active_rounded,
                      title: 'Transactions from notifications',
                      subtitle: !_enabled
                          ? 'Off · no notifications are read'
                          : _granted
                          ? 'Reading the apps taught below'
                          : 'Waiting for notification access',
                      value: _enabled && _granted,
                      onChanged: _setEnabled,
                    ),
                    MenuRow(
                      icon: Icons.verified_user_rounded,
                      title: 'Notification access',
                      subtitle: _granted
                          ? 'Allowed in Android settings'
                          : 'Tap to allow in Android settings',
                      highlight: _enabled && !_granted,
                      onTap: _platform.openSettings,
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // The way to add an app, before the list of those already
                // added: the main thing to do on this screen.
                if (widget.database != null) ...[
                  MenuGroup(
                    children: [
                      MenuRow(
                        key: const Key('teach-from-notification'),
                        icon: Icons.add_rounded,
                        title: 'Teach from a notification',
                        subtitle: 'Pick a notification, then tap the words',
                        highlight: true,
                        onTap: _teach,
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                ],
                MenuGroup(
                  label: 'Taught apps',
                  children: [
                    if (_taught.isEmpty)
                      const MenuRow(
                        icon: Icons.apps_rounded,
                        title: 'No apps yet',
                        subtitle: 'An app shows here once you teach it',
                      ),
                    for (final app in _taught)
                      // Tap for what it was taught; the switch pauses it.
                      MenuRow(
                        key: Key('taught-${app.package}'),
                        icon: Icons.apps_rounded,
                        leading: _appIcon(app),
                        title: app.label,
                        subtitle: app.enabled
                            ? 'Reading its notifications'
                            : 'Paused · not reading',
                        onTap: () => _open(app),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
