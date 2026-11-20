import 'package:flutter/material.dart';

import '../components/common.dart';
import '../theme/app_theme.dart' show usesGlass;
import '../components/empty_art.dart' show EmptyArtwork, menuArtFor;

/// The fixed space at the top of a setup page that its picture sits in, so
/// the picture is the same size and in the same place on every page.
class HeroSlot extends StatelessWidget {
  const HeroSlot({super.key, required this.child});
  final Widget child;

  static const height = 160.0;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    child: Center(child: child),
  );
}

/// The round tinted icon that is the picture of a setup page.
class RoundIcon extends StatelessWidget {
  const RoundIcon(this.icon, {super.key});
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    // Icons with glass artwork float on their own shadow, with no circle.
    final art = usesGlass(context) ? menuArtFor(icon) : null;
    if (art != null) {
      return SizedBox(
        height: HeroSlot.height,
        child: Center(child: EmptyArtwork(art, size: 120)),
      );
    }
    return ExcludeSemantics(
      child: Container(
        width: 112,
        height: 112,
        decoration: BoxDecoration(
          color: primary.withValues(alpha: .12),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, size: 50, color: primary),
      ),
    );
  }
}

/// A short list of reassurances under a title, shown before the setup asks
/// for something (the SMS permission, the Google sign-in).
class PrivacyCard extends StatelessWidget {
  const PrivacyCard({super.key, required this.title, required this.points});
  final String title;
  final List<String> points;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MoneyCard(
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(child: Text(title, style: theme.textTheme.titleMedium)),
          const SizedBox(height: 10),
          for (final point in points)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Icon(
                      Icons.check_circle_rounded,
                      size: 18,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      point,
                      style: theme.textTheme.bodyMedium?.copyWith(height: 1.35),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
