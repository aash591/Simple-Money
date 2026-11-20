import 'package:flutter/material.dart';

import '../../data/play_store.dart';
import '../../state/review_prompt.dart';
import '../more/help/report_issue_screen.dart';
import '../theme/sheet_colors.dart';
import 'adaptive_sheet.dart';
import 'feature_page.dart';

/// Asks for a rating on Google Play if [ReviewPrompt] says it's time, having
/// just added a transaction ([savesBefore] is the count before the sheet
/// opened, so a sheet closed without saving never asks).
///
/// Shown as a bottom sheet with five stars: 4–5 goes on to Google Play,
/// 1–3 goes to feedback, so unhappy people reach us first and nobody is
/// asked whether they like the app before being shown the store.
Future<void> maybeAskForReview(
  BuildContext context, {
  required int savesBefore,
  ReviewPrompt? prompt,
}) async {
  final review = prompt ?? ReviewPrompt.instance;
  if (review.saves <= savesBefore || !review.due) return;
  // Let the sheet finish closing, so the two never overlap.
  await Future<void>.delayed(const Duration(milliseconds: 450));
  if (!context.mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) {
    return;
  }
  final stars = await showRatingSheet(context);
  final rate = stars != null && stars >= 4;
  final feedback = stars != null && stars < 4;
  await review.answer(
    rate
        ? ReviewAnswer.rate
        : feedback
        ? ReviewAnswer.feedback
        : ReviewAnswer.later,
  );
  if (rate) {
    await openPlayStorePage();
  } else if (feedback && context.mounted) {
    await Navigator.of(context)
        .push(FeatureRoute<void>(const ReportIssueScreen()));
  }
}

/// The rating sheet. Returns the stars picked (1–5), or null if dismissed.
Future<int?> showRatingSheet(BuildContext context) =>
    showAdaptiveSheet<int>(context, builder: (_) => const _RatingSheet());

class _RatingSheet extends StatefulWidget {
  const _RatingSheet();

  @override
  State<_RatingSheet> createState() => _RatingSheetState();
}

class _RatingSheetState extends State<_RatingSheet> {
  int _stars = 0;

  static const _captions = [
    'Tap a star to rate',
    'Sorry to hear that',
    'We can do better',
    'Thanks for the honesty',
    'Glad you like it',
    'Wonderful, thank you!',
  ];

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return SheetPage(
      header: const SheetHeader('Rate SimpleMoney'),
      bodyPadding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
      body: Column(
        children: [
          Text(
            'Enjoying SimpleMoney?',
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: colors.text,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'A quick rating on Google Play helps others find it.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, height: 1.4, color: colors.muted),
          ),
          const SizedBox(height: 18),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 1; i <= 5; i++)
                Semantics(
                  button: true,
                  label: '$i star${i == 1 ? '' : 's'}',
                  child: IconButton(
                    iconSize: 40,
                    padding: const EdgeInsets.all(4),
                    onPressed: () => setState(() => _stars = i),
                    icon: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 150),
                      child: Icon(
                        i <= _stars
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        key: ValueKey(i <= _stars),
                        color: i <= _stars
                            ? const Color(0xFFFFB400)
                            : colors.outline,
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            _captions[_stars],
            style: TextStyle(fontSize: 13, color: colors.muted),
          ),
        ],
      ),
      actions: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(52),
                ),
                onPressed: _stars == 0
                    ? null
                    : () => Navigator.of(context).pop(_stars),
                child: Text(_stars >= 4 ? 'Rate on Google Play' : 'Continue'),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Not now'),
            ),
          ],
        ),
      ),
    );
  }
}
