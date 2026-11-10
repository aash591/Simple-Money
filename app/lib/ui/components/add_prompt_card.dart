import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../state/appearance_controller.dart' show AppearanceScope;
import '../theme/app_theme.dart' show AppChrome, usesAurora, usesGlass;
import 'dashed_outline.dart';
import 'glass_surface.dart' show glassCardFill;

/// One button on an [AddPromptCard].
class AddPromptAction {
  const AddPromptAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

/// What stands in for a Home card before there is anything to show in it: a
/// dashed outline holding a short description and the way to add the first
/// item.
class AddPromptCard extends StatelessWidget {
  const AddPromptCard({
    super.key,
    required this.icon,
    required this.title,
    required this.message,
    required this.actions,
  });
  final IconData icon;
  final String title, message;
  final List<AddPromptAction> actions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final glass =
        usesGlass(context) && theme.extension<AppChrome>()?.cardBorder == null;
    final frosted =
        glass &&
        usesAurora(context) &&
        AppearanceScope.maybeOf(context)?.wallpaperPath != null;
    final radius = BorderRadius.circular(24);
    Widget card = Container(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 22),
      decoration: BoxDecoration(
        // On glass: the same see-through fill as the cards around it.
        color: glass ? null : scheme.primary.withValues(alpha: .03),
        gradient: glass ? glassCardFill(context) : null,
        borderRadius: radius,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: scheme.primary.withValues(alpha: .1),
            ),
            child: Icon(icon, color: scheme.primary),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 4),
          Text(
            message,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall?.copyWith(
              fontSize: 14,
              height: 1.45,
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 10,
            runSpacing: 10,
            children: [
              for (final action in actions)
                FilledButton.icon(
                  onPressed: action.onTap,
                  style: FilledButton.styleFrom(
                    minimumSize: const Size(0, 44),
                    shape: const StadiumBorder(),
                    backgroundColor: scheme.primary.withValues(alpha: .1),
                    foregroundColor: scheme.primary,
                    elevation: 0,
                  ),
                  icon: Icon(action.icon, size: 18),
                  label: Text(action.label),
                ),
            ],
          ),
        ],
      ),
    );
    if (frosted) {
      card = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: 22,
            sigmaY: 22,
            tileMode: TileMode.mirror,
          ),
          child: card,
        ),
      );
    }
    // Drawn over the fill, so the frosted glass cannot hide it.
    return CustomPaint(
      foregroundPainter: DashedOutline(
        scheme.primary.withValues(alpha: .35),
        radius: 24,
      ),
      child: card,
    );
  }
}
