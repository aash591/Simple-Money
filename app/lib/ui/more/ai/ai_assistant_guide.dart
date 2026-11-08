import 'package:flutter/material.dart';

import '../../components/app_icon.dart';
import '../../components/common.dart';
import '../../components/info_guide.dart';

/// One AI app's logo in a round badge: Claude and ChatGPT by name, a robot
/// for anything else.
class AiAppLogo extends StatelessWidget {
  const AiAppLogo(this.name, {super.key, this.size = 40});
  final String name;
  final double size;

  static String? brandKey(String name) {
    final n = name.toLowerCase();
    if (n.contains('claude') || n.contains('anthropic')) return 'brand:claude';
    if (n.contains('chatgpt') || n.contains('openai')) return 'brand:openai';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final key = brandKey(name);
    if (key == null) return IconTile(Icons.smart_toy_outlined, size: size);
    final theme = Theme.of(context);
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * .14),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: theme.colorScheme.surface,
        border: Border.all(
          color: theme.colorScheme.outlineVariant.withValues(alpha: .6),
        ),
      ),
      child: AppIcon(key, size: size * .72),
    );
  }
}

/// Claude and ChatGPT side by side, slightly overlapping.
class AiLogos extends StatelessWidget {
  const AiLogos({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      width: size * 1.7,
      height: size,
      child: Stack(
        children: [
          AiAppLogo('Claude', size: size),
          Positioned(
            left: size * .7,
            child: AiAppLogo('ChatGPT', size: size),
          ),
        ],
      ),
    ),
  );
}

const aiAssistantGuide = InfoGuide(
  title: 'About AI assistant',
  art: AiLogos(size: 56),
  headline: 'Ask Claude or ChatGPT about your money',
  summary: 'Get answers and quick fixes. Nothing changes without your OK.',
  steps: [
    GuideStep(
      'Copy the address',
      'Tap the address to copy it.',
      path: ['More', 'AI assistant', 'Address'],
    ),
    GuideStep(
      'Add it in Claude',
      'Paste the address and save.',
      path: ['Claude', 'Settings', 'Connectors', 'Add custom connector'],
    ),
    GuideStep(
      'Or add it in ChatGPT',
      'Turn on developer mode first, then paste the address.',
      path: ['ChatGPT', 'Settings', 'Apps & Connectors', 'Create'],
    ),
    GuideStep(
      'When it asks for a code, come back',
      'Only then get the code. It’s copied and a session starts. Paste it in Claude or ChatGPT.',
      path: ['More', 'AI assistant', 'Get pairing code'],
    ),
    GuideStep(
      'Ask away',
      'A session ends on its own. Next time, just tap Start.',
      path: ['More', 'AI assistant', 'Start'],
    ),
    GuideStep(
      'Approve or skip fixes',
      'You can undo them later.',
      path: ['More', 'AI assistant', 'Suggestions'],
    ),
  ],
  sections: [
    GuideSection('Try asking', [
      GuideTip(
        Icons.pie_chart_outline_rounded,
        'Where did my money go last month?',
      ),
      GuideTip(Icons.sms_outlined, 'Sort my SMS waiting for review'),
      GuideTip(
        Icons.edit_note_rounded,
        'Fix the categories of my Swiggy orders',
      ),
      GuideTip(Icons.rule_rounded, 'Why was this SMS missed?'),
      GuideTip(
        Icons.account_balance_outlined,
        'Add this loan (attach the statement)',
      ),
      GuideTip(Icons.handshake_outlined, 'I lent Rahul 5,000 last week'),
      GuideTip(
        Icons.create_new_folder_outlined,
        'Which categories am I missing?',
      ),
    ]),
    GuideSection('Good to know', [
      GuideTip(
        Icons.verified_user_outlined,
        'The AI sees your data only during a session',
        'When no session is on, it can’t reach anything.',
      ),
      GuideTip(
        Icons.shield_outlined,
        'Your data goes only to the AI you connect',
        'Claude follows Anthropic’s privacy policy, ChatGPT follows OpenAI’s.',
      ),
      GuideTip(
        Icons.link_off_rounded,
        'Disconnect an AI app anytime',
        'Tap the unlink icon next to it.',
        ['More', 'AI assistant', 'Connected apps'],
      ),
    ]),
  ],
);
