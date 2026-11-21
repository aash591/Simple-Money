import 'package:flutter/material.dart';

import '../../components/empty_art.dart';
import '../../theme/app_theme.dart' show usesGlass;

/// The top half of a choice screen: the artwork the Portfolio's empty page uses,
/// and one line on what this step is for.
class StepIntro extends StatelessWidget {
  const StepIntro({super.key, required this.title, required this.message});
  final String title, message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final art = usesGlass(context)
        ? const EmptyArtwork(EmptyArt.chart, size: 112)
        : const GlassLens(
            size: 112,
            child: EmptyArtwork(EmptyArt.chart, size: 60),
          );
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            art,
            const SizedBox(height: 18),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 300),
              child: Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(
                  height: 1.5,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
