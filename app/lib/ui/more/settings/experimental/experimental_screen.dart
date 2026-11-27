import 'package:flutter/material.dart';

import '../../../../data/db/app_database.dart';
import '../../../../data/notification_access_platform.dart';
import '../../../components/feature_page.dart';
import '../../../components/menu_list.dart';
import '../../smart_tracking/notifications/notifications_row.dart';

/// Settings › Experimental: early features, still being tried. They may
/// change, so they live here rather than with the finished ones.
class ExperimentalScreen extends StatelessWidget {
  const ExperimentalScreen({
    super.key,
    this.database,
    this.onRulesChanged,
    this.notifications,
  });

  /// Where teaching an app saves its rules.
  final AppDatabase? database;

  /// Reads again with a new rule, after an app was taught.
  final VoidCallback? onRulesChanged;

  /// Replaced in tests.
  final NotificationAccessPlatform? notifications;

  /// Whether anything here can be used on this phone, so Settings only shows
  /// the way in when there is something behind it.
  static bool offered([NotificationAccessPlatform? notifications]) =>
      (notifications ?? NotificationAccessPlatform()).supported;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FeaturePage(
      title: 'Experimental',
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
                      Icons.science_rounded,
                      size: 20,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        'Early features we are still trying out. They may '
                        'change as we learn how they work for you.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (offered(notifications))
                MenuGroup(
                  label: 'Notifications',
                  children: [
                    NotificationsRow(
                      platform: notifications,
                      database: database,
                      onRulesChanged: onRulesChanged,
                    ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}
