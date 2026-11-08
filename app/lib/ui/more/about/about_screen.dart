import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../components/common.dart';
import '../../components/feature_page.dart';
import '../../components/menu_list.dart';
import 'legal_screen.dart';
import 'privacy_policy_screen.dart';

class AboutScreen extends StatefulWidget {
  const AboutScreen({super.key});

  @override
  State<AboutScreen> createState() => _AboutScreenState();
}

class _AboutScreenState extends State<AboutScreen> {
  String _version = '';
  String _build = '';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() {
        _version = info.version;
        _build = info.buildNumber;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final appVersion = _version.isEmpty ? '' : '$_version ($_build)';
    final text = Theme.of(context).textTheme;
    return FeaturePage(
      title: 'About',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 24, 18, 32),
        children: [
          Center(
            child: Column(
              children: [
                Container(
                  width: 84,
                  height: 84,
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(22),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: .08),
                        blurRadius: 18,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  ),
                  child: Image.asset(
                    'assets/images/app_icon.webp',
                    fit: BoxFit.cover,
                  ),
                ),
                const SizedBox(height: 16),
                Text('SimpleMoney', style: text.titleLarge),
                const SizedBox(height: 6),
                Text(
                  appVersion.isEmpty ? '' : 'Version $appVersion',
                  style: text.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          MoneyCard(
            child: Text(
              'A calmer way to track your money. Your data stays on your phone unless you back it up.',
              textAlign: TextAlign.center,
              style: text.bodyMedium?.copyWith(height: 1.6),
            ),
          ),
          const SizedBox(height: 22),
          MenuGroup(
            children: [
              MenuRow(
                icon: Icons.privacy_tip_rounded,
                title: 'Privacy Policy',
                subtitle: 'What stays on your device, what doesn’t',
                onTap: () =>
                    Navigator.of(context)
                        .push(FeatureRoute<void>(const PrivacyPolicyScreen())),
              ),
              MenuRow(
                icon: Icons.gavel_rounded,
                title: 'Terms & Legal',
                subtitle: 'The fine print, in plain language',
                onTap: () =>
                    Navigator.of(context)
                        .push(FeatureRoute<void>(const LegalScreen())),
              ),
              MenuRow(
                icon: Icons.code_rounded,
                title: 'Open Source Licenses',
                subtitle: 'The libraries SimpleMoney is built on',
                onTap: () => Navigator.of(context).push(
                  FeatureRoute<void>(
                    LicensePage(
                      applicationName: 'SimpleMoney',
                      applicationVersion: appVersion,
                      applicationIcon: Padding(
                        padding: const EdgeInsets.all(16),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(18),
                          child: Image.asset(
                            'assets/images/app_icon.webp',
                            width: 64,
                            height: 64,
                            fit: BoxFit.cover,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 28),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.shield_outlined,
                size: 15,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text('Your money. Your space.', style: text.bodySmall),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            'Made with ❤️ by AasH591',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
