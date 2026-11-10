import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

/// What a chart card shows before it has data: the chart as it will look,
/// filled with [sample] data and softened by a blur, with a short message on
/// a soft panel laid over it.
class EmptyChartPreview extends StatelessWidget {
  const EmptyChartPreview({
    super.key,
    required this.sample,
    required this.title,
    required this.message,
  });

  /// The real chart widget, given made-up data. It can't be tapped and screen
  /// readers skip it.
  final Widget sample;
  final String title, message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Stack(
      alignment: Alignment.center,
      children: [
        ExcludeSemantics(
          child: IgnorePointer(
            child: Opacity(
              opacity: .75,
              // No clip: the blur's soft edge is allowed to spill past the
              // chart's box instead of being cut off in a square.
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: 4,
                  sigmaY: 4,
                  tileMode: TileMode.decal,
                ),
                child: sample,
              ),
            ),
          ),
        ),
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 12),
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: .78),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                message,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(height: 1.4),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
