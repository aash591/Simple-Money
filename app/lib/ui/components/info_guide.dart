import 'package:flutter/material.dart';

import 'common.dart';
import 'feature_page.dart';

/// A feature's "how this works" page: the problem it solves, the steps to
/// use it, and tips. Screens describe one as data and open it with
/// [InfoGuideButton], so every guide looks and reads the same.
class InfoGuide {
  const InfoGuide({
    required this.title,
    required this.headline,
    required this.summary,
    this.art,
    this.steps = const [],
    this.sections = const [],
    this.footnote,
  });

  /// The page title, e.g. 'About AI assistant'.
  final String title;

  /// The problem, in the user's words: what this lets them do.
  final String headline;
  final String summary;

  /// Shown above the headline: a logo or illustration. Defaults to an info
  /// icon.
  final Widget? art;
  final List<GuideStep> steps;
  final List<GuideSection> sections;

  /// A closing note in small print, such as privacy.
  final String? footnote;
}

class GuideStep {
  const GuideStep(this.title, this.text, {this.path = const [], this.example});
  final String title, text;

  /// Where to tap, in order, e.g. ['More', 'AI assistant', 'Get pairing code'].
  /// '⋮' stands for an options menu.
  final List<String> path;

  /// An optional, harmless demo shown under the step.
  final Widget? example;
}

/// A titled list of tips, such as 'Try asking' or 'Good to know'.
class GuideSection {
  const GuideSection(this.title, this.tips);
  final String title;
  final List<GuideTip> tips;
}

class GuideTip {
  const GuideTip(this.icon, this.title, [this.text, this.path = const []]);
  final IconData icon;
  final String title;
  final String? text;

  /// Where to tap, in order.
  final List<String> path;
}

/// A tap path as chips: More › AI assistant › Get pairing code.
class GuidePath extends StatelessWidget {
  const GuidePath(this.path, {super.key});
  final List<String> path;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = theme.colorScheme.primary;
    return Semantics(
      label:
          'Tap ${path.map((s) => s == '⋮' ? 'the options menu' : s).join(', then ')}',
      excludeSemantics: true,
      child: Wrap(
        spacing: 4,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (final (i, step) in path.indexed) ...[
            if (i > 0)
              Icon(
                Icons.chevron_right_rounded,
                size: 16,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
              decoration: BoxDecoration(
                color: color.withValues(alpha: .1),
                borderRadius: BorderRadius.circular(8),
              ),
              // '⋮' is the options menu: drawn as its icon, which every
              // font can show.
              child: step == '⋮'
                  ? Icon(Icons.more_vert_rounded, size: 16, color: color)
                  : Text(
                      step,
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The header's info button that opens [guide].
class InfoGuideButton extends StatelessWidget {
  const InfoGuideButton(this.guide, {super.key});
  final InfoGuide guide;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: guide.title,
    padding: EdgeInsets.zero,
    alignment: Alignment.center,
    icon: const Icon(Icons.info_outline_rounded, size: 22),
    onPressed: () => openInfoGuide(context, guide),
  );
}

Future<void> openInfoGuide(BuildContext context, InfoGuide guide) =>
    Navigator.of(context).push(FeatureRoute<void>(InfoGuideScreen(guide)));

class InfoGuideScreen extends StatelessWidget {
  const InfoGuideScreen(this.guide, {super.key});
  final InfoGuide guide;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      height: 1.4,
    );
    return FeaturePage(
      title: guide.title,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
        children: [
          const SizedBox(height: 8),
          Center(
            child:
                guide.art ??
                const IconTile(Icons.lightbulb_outline_rounded, size: 56),
          ),
          const SizedBox(height: 16),
          Text(
            guide.headline,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall?.copyWith(
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(guide.summary, textAlign: TextAlign.center, style: muted),
          if (guide.steps.isNotEmpty) ...[
            const _Heading('How it works'),
            MoneyCard(
              child: Column(
                children: [
                  for (final (i, step) in guide.steps.indexed) ...[
                    if (i > 0) const SizedBox(height: 18),
                    _Step(i + 1, step),
                  ],
                ],
              ),
            ),
          ],
          for (final section in guide.sections) ...[
            _Heading(section.title),
            MoneyCard(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
              child: Column(
                children: [
                  for (final (i, tip) in section.tips.indexed) ...[
                    if (i > 0) const Divider(height: 1, indent: 52),
                    _Tip(tip),
                  ],
                ],
              ),
            ),
          ],
          if (guide.footnote case final note?) ...[
            const SizedBox(height: 20),
            Text(
              note,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.4,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(4, 28, 4, 10),
    child: Semantics(
      header: true,
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium
            ?.copyWith(fontWeight: FontWeight.w600),
      ),
    ),
  );
}

class _Step extends StatelessWidget {
  const _Step(this.number, this.step);
  final int number;
  final GuideStep step;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Only the number and title share a row; the rest uses the full width.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            CircleAvatar(
              radius: 12,
              backgroundColor: theme.colorScheme.primary.withValues(alpha: .12),
              child: Text(
                '$number',
                style: theme.textTheme.labelMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                step.title,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        if (step.path.isNotEmpty) ...[
          const SizedBox(height: 10),
          GuidePath(step.path),
        ],
        const SizedBox(height: 6),
        Text(
          step.text,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.4,
          ),
        ),
        if (step.example case final example?) ...[
          const SizedBox(height: 12),
          example,
        ],
      ],
    );
  }
}

class _Tip extends StatelessWidget {
  const _Tip(this.tip);
  final GuideTip tip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          IconTile(tip.icon, size: 36),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 2),
                Text(tip.title, style: theme.textTheme.titleSmall),
                if (tip.text case final text?) ...[
                  const SizedBox(height: 3),
                  Text(
                    text,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                      height: 1.4,
                    ),
                  ),
                ],
                if (tip.path.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  GuidePath(tip.path),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
