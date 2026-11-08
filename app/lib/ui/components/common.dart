import 'package:flutter/material.dart';

import '../theme/app_theme.dart' show AppChrome;
import '../theme/surface_style.dart';

export '../theme/surface_style.dart'
    show appCardGap, appCardRadius, homeCardGap;

class MoneyCard extends StatelessWidget {
  const MoneyCard({
    super.key,
    required this.child,
    this.color,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final Color? color;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) {
    final fill = color ?? Theme.of(context).colorScheme.surface;
    final glass = GlassCards.of(context);
    final border = Theme.of(context).extension<AppChrome>()?.cardBorder;
    const radius = BorderRadius.all(Radius.circular(appCardRadius));
    return DecoratedBox(
      decoration: BoxDecoration(
        color: glass ? fill.withValues(alpha: glassCardOpacity) : fill,
        borderRadius: radius,
        border: border == null ? null : Border.all(color: border),
        // A shadow would show through a see-through card as a dark smudge.
        boxShadow: glass ? null : appCardShadows(Theme.of(context).brightness),
      ),
      // A selected ListTile paints its selection colour with a rectangular
      // Material. Clip it to the card so it cannot show through the rounded
      // corners (most visible on the first selected item in a sheet). A
      // rounded-rect clip, not the path clip a clipping Container makes:
      // every card on screen pays for it on every frame of a scroll.
      child: ClipRRect(
        borderRadius: radius,
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.action, this.onTap});
  final String title;
  final String? action;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(title, style: Theme.of(context).textTheme.titleMedium),
      ),
      if (action != null)
        TextButton(
          onPressed: onTap,
          style: TextButton.styleFrom(
            padding: EdgeInsets.zero,
            minimumSize: const Size(48, 32),
          ),
          child: Text(action!),
        ),
    ],
  );
}

/// The app's one floating "+" button — same look wherever adding something
/// is the primary action on a page (Home's add transaction, Categories' add
/// category, and so on).
class AddFab extends StatelessWidget {
  const AddFab({super.key, required this.onPressed, this.tooltip});
  final VoidCallback onPressed;
  final String? tooltip;
  @override
  Widget build(BuildContext context) => FloatingActionButton(
    onPressed: onPressed,
    tooltip: tooltip,
    backgroundColor: Theme.of(context).colorScheme.primary,
    foregroundColor: Colors.white,
    shape: const CircleBorder(),
    elevation: 4,
    child: const Icon(Icons.add_rounded, size: 32),
  );
}

/// Plain leading icon for settings and menu rows.
class MenuRowIcon extends StatelessWidget {
  const MenuRowIcon(this.icon, {super.key, this.color, this.size = 42});

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: Icon(
      icon,
      color: color ?? Theme.of(context).colorScheme.onSurfaceVariant,
      size: 24,
    ),
  );
}

class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.color, this.size = 46});
  final IconData icon;
  final Color? color;
  final double size;
  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: (color ?? Theme.of(context).colorScheme.primary).withValues(
        alpha: .11,
      ),
      borderRadius: BorderRadius.circular(size * .4),
    ),
    child: Icon(
      icon,
      color: color ?? Theme.of(context).colorScheme.primary,
      size: size * .5,
    ),
  );
}
