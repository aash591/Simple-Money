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
    GuideSection('Prompts to copy', [
      GuideTip.prompt(
        'Add transactions',
        'Add these to SimpleMoney as transactions, using my accounts and '
            'categories: ',
      ),
      GuideTip.prompt(
        'Teach the app missed SMS',
        'Look at the SMS SimpleMoney missed and teach it each payment format '
            'that repeats. Only teach ones that give an account or a clear '
            'category. I’ll pick the other in SMS review, so tell me which. '
            'Once it works, remind me to share it.',
      ),
      GuideTip.prompt(
        'Fix loan payments read as income',
        'My bank’s SMS for loan payments say “credited”, so SimpleMoney reads '
            'them as income. Find them, in SMS review and saved, and suggest '
            'them as payments to my loan, for the ones still to come too.',
      ),
      GuideTip.prompt(
        'Read a waiting statement',
        'Check the statements waiting in SimpleMoney and suggest a layout for '
            'each, so I can import them.',
      ),
      GuideTip.prompt(
        'Sort SMS waiting for review',
        'Go through my SMS waiting for review and suggest the right category '
            'and account for each.',
      ),
      GuideTip.prompt(
        'Fix uncategorised spending',
        'Find my transactions still under Personal and suggest a category for '
            'each payee.',
      ),
      GuideTip.prompt(
        'Find recurring payments',
        'Find my subscriptions, rent, premiums and other payments that repeat, '
            'and suggest them as recurring payments.',
      ),
      GuideTip.prompt(
        'Add a loan',
        'Here’s my loan statement. Add the loan with every payment made so '
            'far.',
      ),
      GuideTip.prompt(
        'Set up my portfolio',
        'Here’s my broker statement. Add the broker, then each stock, fund '
            'or coin I hold with what I paid, so my portfolio matches it.',
      ),
      GuideTip.prompt(
        'Record a purchase',
        'I bought 10 units of Parag Parikh Flexi Cap today at today’s NAV. '
            'Record it in my portfolio.',
      ),
      GuideTip.prompt(
        'See where money went',
        'Where did my money go last month? Break it down by category and top '
            'payees.',
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
