import 'package:flutter/material.dart';

import '../../components/common.dart';
import '../../components/feature_page.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return FeaturePage(
      title: 'Privacy Policy',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 32),
        children: [
          Text(
            'Last updated 4 November 2026',
            style: text.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 16),
          const _Section(
            title: 'Your data',
            body:
                'Your financial data is stored only on your device. '
                'SimpleMoney has no server or user accounts, and never sells '
                'or shares your data.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'SMS',
            body:
                'With your permission, SimpleMoney reads the SMS on your '
                'phone, including new ones as they arrive, to find bank '
                'transaction messages and add them as transactions. This is '
                'the app’s main feature. Other messages, such as OTPs and '
                'personal chats, are ignored and not stored. Messages are '
                'processed on your device only. They are never sold, shared '
                'or uploaded, unless you choose to report one. You can turn '
                'this off at any time in More › Settings › Transactions from '
                'SMS, or by turning off SMS in Android permissions.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'Ads',
            body:
                'The free version shows ads from Google AdMob. Google may '
                'collect your advertising ID, IP address, ad interactions '
                'and diagnostic information to serve ads. It has no '
                'access to your financial data or SMS. See '
                'policies.google.com/privacy.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'Purchases',
            body:
                'Pro is purchased through Google Play. We never receive your '
                'payment details. Pro users see no ads.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'Optional features',
            body:
                '• Google Drive backup: your data is saved to the private, '
                'hidden app data folder of your own Drive. Only SimpleMoney '
                'can open it, and it doesn’t appear in My Drive.\n'
                '• Report SMS: only the messages you select, with any note '
                'or contact you add, are sent securely to the developer.\n'
                '• Exchange rates: downloaded from a public currency '
                'service. No personal data is sent.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'Your choices',
            body:
                'You can buy Pro to remove ads, reset your advertising ID in '
                'Android settings, revoke SMS access, or disconnect backup at '
                'any time. Uninstalling deletes all data from your device.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'Children',
            body: 'SimpleMoney is not intended for children under 13.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'Contact',
            body:
                'For questions or deletion requests, email '
                'hi@aashglobal.in.',
          ),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.body});
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return MoneyCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: text.titleMedium),
          const SizedBox(height: 10),
          Text(body, style: text.bodyMedium?.copyWith(height: 1.6)),
        ],
      ),
    );
  }
}
