import 'package:flutter/material.dart';

import '../../../data/daily_reminders.dart';
import '../../../data/db/app_database.dart';
import '../../../state/main_currency_controller.dart';
import 'main_currency_screen.dart';

import '../../../state/ad_gate.dart';
import '../../../state/appearance_controller.dart';
import '../../../state/home_layout.dart';
import '../../../state/sync_controller.dart';
import '../../../state/upi_settings.dart';
import '../../../state/vibration_settings.dart';
import '../../components/app_toast.dart';
import '../../components/menu_list.dart';
import '../../components/feature_page.dart';
import '../home_layout_screen.dart';
import 'about/about_screen.dart';
import 'customization_screen.dart';
import 'data/data_screen.dart';
import 'help/help_screen.dart';
import 'security_screen.dart';
import 'sync/sync_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    this.syncController,
    this.upiSettings,
    this.homeLayout,
    this.database,
  });
  final SyncController? syncController;
  final UpiSettings? upiSettings;
  final HomeLayout? homeLayout;

  /// The app's database, for screens that read messages with the saved rules.
  final AppDatabase? database;

  @override
  Widget build(BuildContext context) {
    final currentHomeLayout = homeLayout;
    final currentUpiSettings = upiSettings;
    return FeaturePage(
      title: 'Settings',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 24, 18, 32),
        children: [
          MenuGroup(
            label: 'Preferences',
            children: [
              if (MainCurrencyScope.maybeOf(context) case final currency?)
                MenuRow(
                  icon: Icons.currency_exchange_rounded,
                  title: 'Main currency',
                  subtitle: currency.code,
                  onTap: () => Navigator.of(context).push(
                    FeatureRoute<void>(
                      MainCurrencyScreen(controller: currency),
                    ),
                  ),
                ),
              if (currentHomeLayout != null)
                ListenableBuilder(
                  listenable: currentHomeLayout,
                  builder: (context, _) => MenuRow(
                    icon: Icons.dashboard_customize_rounded,
                    title: 'Home screen cards',
                    subtitle:
                        '${currentHomeLayout.visible.length} of '
                        '${currentHomeLayout.order.length} shown',
                    onTap: () => Navigator.of(context).push(
                      FeatureRoute<void>(
                        HomeLayoutScreen(layout: currentHomeLayout),
                      ),
                    ),
                  ),
                ),
              MenuRow(
                icon: Icons.palette_rounded,
                title: 'Customization',
                onTap: () => _openCustomization(context),
              ),
            ],
          ),
          const SizedBox(height: 24),
          MenuGroup(
            label: 'Alerts & shortcuts',
            children: [
              ListenableBuilder(
                listenable: DailyReminders.instance,
                builder: (context, _) => MenuSwitchRow(
                  icon: Icons.notifications_active_rounded,
                  title: 'Daily reminders',
                  subtitle: DailyReminders.instance.enabled
                      ? '8 pm and 10 pm'
                      : 'Off',
                  value: DailyReminders.instance.enabled,
                  onChanged: DailyReminders.instance.saving
                      ? null
                      : (value) async {
                          try {
                            await DailyReminders.instance.setEnabled(value);
                          } catch (_) {
                            if (context.mounted) {
                              showAppToast(
                                context,
                                'Could not save this setting. Try again.',
                              );
                            }
                          }
                        },
                ),
              ),
              ListenableBuilder(
                listenable: VibrationSettings.instance,
                builder: (context, _) => MenuSwitchRow(
                  icon: Icons.vibration_rounded,
                  title: 'Vibrations',
                  value: VibrationSettings.instance.enabled,
                  onChanged: VibrationSettings.instance.saving
                      ? null
                      : (value) async {
                          try {
                            await VibrationSettings.instance.setEnabled(value);
                          } catch (_) {
                            if (context.mounted) {
                              showAppToast(
                                context,
                                'Could not save this setting. Try again.',
                              );
                            }
                          }
                        },
                ),
              ),
              if (currentUpiSettings != null)
                ListenableBuilder(
                  listenable: currentUpiSettings,
                  builder: (context, _) => MenuSwitchRow(
                    icon: Icons.qr_code_scanner_rounded,
                    title: 'Google Pay option',
                    value: currentUpiSettings.enabled,
                    onChanged:
                        currentUpiSettings.loading || currentUpiSettings.saving
                        ? null
                        : (value) async {
                            try {
                              await currentUpiSettings.setEnabled(value);
                            } catch (_) {
                              if (context.mounted) {
                                showAppToast(
                                  context,
                                  'Could not save this setting. Try again.',
                                );
                              }
                            }
                          },
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          MenuGroup(
            label: 'Data & security',
            children: [
              MenuRow(
                icon: Icons.cloud_rounded,
                title: 'Sync',
                onTap: () => Navigator.of(context).push(
                  FeatureRoute<void>(SyncScreen(controller: syncController)),
                ),
              ),
              MenuRow(
                icon: Icons.folder_rounded,
                title: 'Your data',
                onTap: () => Navigator.of(context).push(
                  FeatureRoute<void>(DataScreen(controller: syncController)),
                ),
              ),
              MenuRow(
                icon: Icons.lock_rounded,
                title: 'Security',
                onTap: () =>
                    Navigator.of(context)
                        .push(FeatureRoute<void>(const SecurityScreen())),
              ),
            ],
          ),
          const SizedBox(height: 24),
          MenuGroup(
            label: 'Help & about',
            children: [
              MenuRow(
                icon: Icons.help_rounded,
                title: 'Help',
                onTap: () =>
                    Navigator.of(context)
                        .push(FeatureRoute<void>(const HelpScreen())),
              ),
              MenuRow(
                icon: Icons.info_rounded,
                title: 'About SimpleMoney',
                onTap: () =>
                    Navigator.of(context)
                        .push(FeatureRoute<void>(const AboutScreen())),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A theme mode change counts as one ad moment, judged once the screen
/// closes. Accent colours take their own ad as they're picked.
Future<void> _openCustomization(BuildContext context) async {
  final appearance = AppearanceScope.maybeOf(context);
  final before = appearance?.value;
  await Navigator.of(context)
      .push(FeatureRoute<void>(const CustomizationScreen()));
  if (appearance != null && appearance.value != before) {
    await AdGate.instance.after(AdMoment.theme);
  }
}
