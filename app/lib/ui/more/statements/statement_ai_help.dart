import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../components/action_buttons.dart';
import '../../components/app_toast.dart';
import '../../theme/app_theme.dart';

/// What to paste to Claude or ChatGPT to set up a new statement layout.
/// Most people don't know what to ask, and the words matter little to the
/// AI as long as it's pointed at the layouts waiting for columns.
const statementLayoutPrompt =
    'Set up the new statement layout in my SimpleMoney app. Look at the '
    'statements waiting for columns, work out which column is which, and '
    'send it as a suggestion for me to approve.';

/// Help for a statement layout the app can't read yet: a prompt to copy,
/// what the AI does and doesn't get to see, and the way to the AI assistant.
/// [onOpenAi] opens it; without it the path is written out.
class StatementAiHelp extends StatelessWidget {
  const StatementAiHelp({super.key, this.onOpenAi});
  final VoidCallback? onOpenAi;

  Future<void> _copy(BuildContext context) async {
    await Clipboard.setData(const ClipboardData(text: statementLayoutPrompt));
    if (context.mounted) {
      showAppToast(context, 'Prompt copied', icon: Icons.copy_rounded);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Start an AI session here, then paste this in Claude or ChatGPT. '
          'Not sure what to ask? This works:',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        Material(
          color: theme.colorScheme.surfaceContainerHighest.withValues(
            alpha: .6,
          ),
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () => _copy(context),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Expanded(
                    child: Text(
                      statementLayoutPrompt,
                      style: TextStyle(fontSize: 13.5, height: 1.35),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Icon(
                    Icons.copy_rounded,
                    size: 18,
                    color: theme.colorScheme.primary,
                    semanticLabel: 'Copy prompt',
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 14),
        _Reassurance(
          Icons.table_chart_outlined,
          'It sees only the column names and up to 5 example rows. Never '
          'the whole file.',
          muted,
        ),
        _Reassurance(
          Icons.timer_outlined,
          'Only while a session is on, and only the AI app you connected.',
          muted,
        ),
        _Reassurance(
          Icons.verified_user_outlined,
          'It can only suggest. Nothing changes until you approve. The '
          'examples are removed from your phone once the layout is saved.',
          muted,
        ),
        _Reassurance(
          Icons.bolt_rounded,
          'Your file waits on this phone. Once you approve, it imports in '
          'one tap: no need to pick it again.',
          muted,
        ),
        if (onOpenAi != null) ...[
          const SizedBox(height: 12),
          PillButton(
            label: 'Go to AI session',
            primary: false,
            onPressed: onOpenAi,
          ),
        ] else ...[
          const SizedBox(height: 6),
          Text(
            'Start a session: More › AI assistant',
            style: theme.textTheme.bodySmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    );
  }
}

class _Reassurance extends StatelessWidget {
  const _Reassurance(this.icon, this.text, this.color);
  final IconData icon;
  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 18, color: accent),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: Theme.of(context).textTheme.bodySmall
                ?.copyWith(color: color, height: 1.35),
          ),
        ),
      ],
    ),
  );
}
