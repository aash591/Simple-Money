import 'package:flutter/material.dart';

import '../../../state/main_currency_controller.dart';
import 'main_currency_screen.dart';

import '../../../state/ad_gate.dart';
import '../../../state/appearance_controller.dart';
import '../../../state/home_layout.dart';
import '../../../state/sms_import_store.dart';
import '../../../state/sync_controller.dart';
import '../../../state/upi_settings.dart';
import '../../../state/vibration_settings.dart';
import '../../components/app_toast.dart';
import '../../components/confirmation_alert.dart';
import '../../components/menu_list.dart';
import '../../components/feature_page.dart';
import '../home_layout_screen.dart';
import 'customization_screen.dart';
import 'data/data_screen.dart';
import 'security_screen.dart';
import 'sync/sync_screen.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({
    super.key,
    this.syncController,
    this.upiSettings,
    this.homeLayout,
    this.smsStore,
  });
  final SyncController? syncController;
  final UpiSettings? upiSettings;
  final HomeLayout? homeLayout;

  /// The bank SMS reader; without it (or off Android) there is no switch.
  final SmsImportStore? smsStore;

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
    final ok = await showConfirmationAlert(
      context,
      title: 'Read bank SMS?',
      message:
          'Simple Money will read the SMS on your phone, including new ones '
          'as they arrive, and pick out the ones from your bank to add as '
          'transactions. Messages stay on your device and are never sold or '
          'shared. OTPs and personal messages are ignored.',
      confirmLabel: 'Continue',
      destructive: false,
    );
    if (!ok) return;
    await sms.enable();
    if (context.mounted && !sms.enabled) {
      showAppToast(
        context,
        'SMS access wasn’t allowed. You can allow it in Android Settings › '
        'Apps › Simple Money › Permissions.',
      );
    }
  }

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
            label: 'General',
            children: [
              ListenableBuilder(
                listenable: VibrationSettings.instance,
                builder: (context, _) => MenuSwitchRow(
                  icon: Icons.vibration_rounded,
                  title: 'Vibrations',
                  subtitle: VibrationSettings.instance.enabled
                      ? 'Enabled'
                      : 'Disabled',
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
              if (smsStore case final sms? when sms.supported)
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
              if (currentUpiSettings != null)
                ListenableBuilder(
                  listenable: currentUpiSettings,
                  builder: (context, _) => MenuSwitchRow(
                    icon: Icons.qr_code_scanner_rounded,
                    title: 'Google Pay option',
                    subtitle:
                        'Adds an option to launch Google Pay from the '
                        'transaction menu',
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
              if (MainCurrencyScope.maybeOf(context) case final currency?)
                MenuRow(
                  icon: Icons.currency_exchange_rounded,
                  title: 'Main currency',
                  subtitle:
                      '${currency.code} · Combined balances and summaries',
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
                        'Reorder, show or hide cards and charts · '
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
                subtitle: 'Theme, dark mode style and accent color',
                onTap: () => _openCustomization(context),
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
                subtitle: 'Keep your data safe on Google Drive',
                onTap: () => Navigator.of(context).push(
                  FeatureRoute<void>(SyncScreen(controller: syncController)),
                ),
              ),
              MenuRow(
                icon: Icons.folder_rounded,
                title: 'Your data',
                subtitle: 'Export, import or delete your data',
                onTap: () => Navigator.of(context).push(
                  FeatureRoute<void>(DataScreen(controller: syncController)),
                ),
              ),
              MenuRow(
                icon: Icons.lock_rounded,
                title: 'Security',
                subtitle: 'Protect your app with device authentication',
                onTap: () =>
                    Navigator.of(context)
                        .push(FeatureRoute<void>(const SecurityScreen())),
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
