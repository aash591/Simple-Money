import 'package:flutter/material.dart';

import '../more/settings/sync/backup_widgets.dart';
import 'privacy_card.dart';

/// The setup's backup step: a picture, a line, and where the backup lives.
/// Its buttons belong to the setup's bottom bar.
class BackupWelcomeContent extends StatelessWidget {
  const BackupWelcomeContent({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HeroSlot(child: BackupHero()),
        const SizedBox(height: 24),
        Text(
          'Keep your data safe',
          textAlign: TextAlign.center,
          style: text.headlineMedium,
        ),
        const SizedBox(height: 10),
        Text(
          'Sync with your own Google Drive. Free, private and automatic.',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 24),
        const PrivacyCard(
          title: 'Where it’s kept',
          points: [
            'In your Google Drive’s private, hidden app data folder',
            'Only Simple Money can open it. It isn’t in My Drive',
            'Delete it any time: More › Settings › Your data',
          ],
        ),
      ],
    );
  }
}
