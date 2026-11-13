import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../state/appearance_controller.dart' show AppearanceScope;
import '../theme/app_theme.dart' show AppChrome, usesGlass, usesAurora;
import '../theme/surface_style.dart';
import 'glass_surface.dart';
import 'search_field.dart' show SearchField;

export '../theme/surface_style.dart'
    show appCardGap, appCardRadius, homeCardGap;

class MoneyCard extends StatelessWidget {
  const MoneyCard({
    super.key,
    required this.child,
    this.color,
    this.featured = false,
    this.padding = const EdgeInsets.all(20),
  });
  final Widget child;
  final Color? color;
  final bool featured;
  final EdgeInsets padding;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final border = theme.extension<AppChrome>()?.cardBorder;
    const radius = BorderRadius.all(Radius.circular(appCardRadius));
    final dark = theme.brightness == Brightness.dark;
    // On glass the featured card stays as see-through as its neighbours;
    // an opaque wash made it look like a different kind of card.
    final washBase = usesGlass(context) && dark && border == null
        ? theme.colorScheme.surface.withValues(alpha: .82)
        : theme.colorScheme.surface;
    final wash = featured && !usesAurora(context)
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.alphaBlend(
                theme.colorScheme.primary.withValues(alpha: dark ? .12 : .14),
                washBase,
              ),
              washBase,
              Color.alphaBlend(
                theme.colorScheme.primary.withValues(alpha: dark ? .05 : .045),
                washBase,
              ),
            ],
          )
        : null;
    if (!usesGlass(context)) {
      return DecoratedBox(
        decoration: BoxDecoration(
          color: wash == null ? color ?? theme.colorScheme.surface : null,
          gradient: wash,
          borderRadius: radius,
          border: border == null ? null : Border.all(color: border),
          // Plain light style: the same soft shadow as the white buttons.
          boxShadow: SearchField.softShadow(context),
        ),
        child: _clipped(radius),
      );
    }
    var body = color != null
        ? _clipped(radius)
        : GlassCardWash(radius: radius, child: _clipped(radius));
    // Over a picture, the card frosts what is behind it.
    if (usesAurora(context) &&
        border == null &&
        AppearanceScope.maybeOf(context)?.wallpaperPath != null) {
      body = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter.grouped(
          filter: ui.ImageFilter.blur(
            sigmaX: 22,
            sigmaY: 22,
            tileMode: TileMode.mirror,
          ),
          child: body,
        ),
      );
    }
    return DecoratedBox(
      // Glass: a see-through, top-lit fill over the page's soft backdrop.
      // The true-black theme keeps its plain hairline instead of the glass
      // edge, which would glow too brightly against black.
      decoration: BoxDecoration(
        gradient: wash ?? glassCardFill(context, color: color),
        borderRadius: radius,
        border: border == null ? null : Border.all(color: border),
        boxShadow: glassCardShadows(theme.brightness),
      ),
      child: border != null
          ? body
          : DecoratedBox(
              position: DecorationPosition.foreground,
              decoration: GlassCardRim(
                dark: theme.brightness == Brightness.dark,
                radius: radius,
                accent: usesAurora(context) ? theme.colorScheme.primary : null,
              ),
              child: body,
            ),
    );
  }

  Widget _clipped(BorderRadius radius) {
    // A selected ListTile paints its selection colour with a rectangular
    // Material. Clip it to the card so it cannot show through the rounded
    // corners (most visible on the first selected item in a sheet). A
    // rounded-rect clip, not the path clip a clipping Container makes:
    // every card on screen pays for it on every frame of a scroll.
    return ClipRRect(
      borderRadius: radius,
      child: Padding(padding: padding, child: child),
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
    elevation: 2,
    child: const Icon(Icons.add_rounded, size: 32),
  );
}

/// Leading glass icon tile for settings and menu rows.
class MenuRowIcon extends StatelessWidget {
  const MenuRowIcon(this.icon, {super.key, this.color, this.size = 42});

  final IconData icon;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => GlassIconTile(
    icon,
    tint: color ?? Theme.of(context).colorScheme.primary,
    size: size * .95,
  );
}

class IconTile extends StatelessWidget {
  const IconTile(this.icon, {super.key, this.color, this.size = 46});
  final IconData icon;
  final Color? color;
  final double size;
  @override
  Widget build(BuildContext context) =>
      GlassIconTile(icon, tint: color, size: size);
}
