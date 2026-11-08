import 'package:flutter/material.dart';

import '../../components/common.dart';
import '../../components/feature_page.dart';

class LegalScreen extends StatelessWidget {
  const LegalScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final muted = Theme.of(context).colorScheme.onSurfaceVariant;
    return FeaturePage(
      title: 'Terms & Legal',
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 20, 18, 32),
        children: [
          Text(
            'Effective September 2026',
            style: text.bodySmall?.copyWith(color: muted),
          ),
          const SizedBox(height: 16),
          const _Section(
            title: 'Acceptance of these terms',
            body:
                'By installing or using SimpleMoney, you agree to these '
                'terms. If you don’t agree, please don’t use the app.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'License to use the app',
            body:
                'You’re granted a personal, non-exclusive, non-transferable '
                'license to install and use SimpleMoney on your own '
                'devices. You may not resell, sublicense or redistribute '
                'the app, or use it to build a competing product.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'Not financial advice',
            body:
                'SimpleMoney is a personal record-keeping tool. Balances, '
                'budgets and summaries are calculated from the entries you '
                'make. Nothing in the app is financial, tax or investment '
                'advice, and decisions you make based on it are your own '
                'responsibility.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'No warranty',
            body:
                'SimpleMoney is provided “as is” and “as available”, '
                'without warranties of any kind, whether express or '
                'implied. The app is not guaranteed to be error-free, '
                'uninterrupted, or fit for a particular purpose.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'Limitation of liability',
            body:
                'To the extent permitted by law, the developer is not '
                'liable for any indirect, incidental or consequential loss '
                '— including lost data or lost financial records — arising '
                'from your use of SimpleMoney. Keep independent copies of '
                'anything you can’t afford to lose.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'Your data and backups',
            body:
                'Data you enter is stored locally on your device. If you '
                'enable Google Drive backup, your ledger is written to a '
                'private folder in your own Drive storage under Google’s '
                'terms of service, in addition to these terms. See the '
                'Privacy Policy for details.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'Open source software',
            body:
                'SimpleMoney is built with the Flutter framework and a '
                'number of open source packages, each under its own '
                'license. See Open Source Licenses on the About screen for '
                'the full list and license text of every package used.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'Changes',
            body:
                'These terms may be updated as the app evolves. Continuing '
                'to use SimpleMoney after an update means you accept the '
                'revised terms.',
          ),
          const SizedBox(height: 14),
          const _Section(
            title: 'Contact',
            body:
                'Questions about these terms can be raised through the '
                'app’s listing page or the project’s source repository.',
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
