import 'package:flutter/material.dart';

import '../../../../data/db/app_database.dart';
import '../../../../data/notification_access_platform.dart';
import '../../../components/feature_page.dart';
import '../../../components/menu_list.dart';
import 'notifications_screen.dart';

/// The App notifications row on Smart tracking, saying whether notification
/// access is really allowed and how many apps are being read.
class NotificationsRow extends StatefulWidget {
  const NotificationsRow({
    super.key,
    this.platform,
    this.database,
    this.onRulesChanged,
  });

  /// Replaced in tests.
  final NotificationAccessPlatform? platform;

  /// Where teaching saves rules; passed on to the screen.
  final AppDatabase? database;

  /// Reads again with a new rule, after an app was taught.
  final VoidCallback? onRulesChanged;

  @override
  State<NotificationsRow> createState() => _NotificationsRowState();
}

class _NotificationsRowState extends State<NotificationsRow>
    with WidgetsBindingObserver {
  late final NotificationAccessPlatform _platform =
      widget.platform ?? NotificationAccessPlatform();
  String _subtitle = 'Bank and payment apps that send no SMS';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    try {
      final granted = await _platform.isGranted();
      final (enabled, apps) = await _platform.state();
      final text = !enabled
          ? 'Off · no notifications are read'
          : !granted
          ? 'Allow notification access to start'
          : apps.isEmpty
          ? 'On · teach an app to start'
          : 'Reading ${apps.length} ${apps.length == 1 ? 'app' : 'apps'}';
      if (mounted) setState(() => _subtitle = text);
    } catch (_) {
      /* Keep the plain line. */
    }
  }

  @override
  Widget build(BuildContext context) => MenuRow(
    icon: Icons.notifications_active_rounded,
    title: 'Transactions from notifications',
    subtitle: _subtitle,
    onTap: () async {
      await Navigator.of(context).push(
        FeatureRoute<void>(
          NotificationsScreen(
            platform: widget.platform,
            database: widget.database,
            onRulesChanged: widget.onRulesChanged,
          ),
        ),
      );
      await _refresh();
    },
  );
}
