import 'package:flutter/material.dart';

import '../../state/appearance_controller.dart' show AppearanceScope;
import '../theme/app_theme.dart' show AppChrome, usesGlass, usesAurora;
import '../theme/surface_style.dart';
import 'cached_shadow.dart';
import 'empty_art.dart' show EmptyArtwork, menuArtFor;
import 'glass_blur.dart';
import 'glass_surface.dart';

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
      // No shadow: the card is set apart by its fill and border alone.
      return DecoratedBox(
        decoration: BoxDecoration(
          color: wash == null ? color ?? theme.colorScheme.surface : null,
          gradient: wash,
          borderRadius: radius,
          border: border == null ? null : Border.all(color: border),
        ),
        child: _clipped(radius),
      );
    }
    var body = color != null
        ? _clipped(radius)
        : GlassCardWash(radius: radius, child: _clipped(radius));
    final fill = wash ?? glassCardFill(context, color: color, deeper: true);
    // Over a picture, the card frosts what is behind it. The fill goes over
    // the frost, not under it: the frost is an opaque copy of the picture
    // and would hide it, leaving a light card as dark as the picture.
    final frosted =
        usesAurora(context) &&
        border == null &&
        AppearanceScope.maybeOf(context)?.wallpaperPath != null;
    if (frosted) {
      body = ClipRRect(
        borderRadius: radius,
        child: Frosted(
          sigma: FrostImages.cardSigma,
          tileMode: TileMode.mirror,
          onPage: true,
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: fill),
            child: body,
          ),
        ),
      );
    }
    // The shadows come from cached images rather than the decoration: two
    // blur shaders under every card, on every frame of a scroll, cost more
    // than the rest of the card's glass put together.
    return CustomPaint(
      painter: BoxShadowPainter(
        radius: radius,
        shadows: glassCardShadows(theme.brightness),
      ),
      child: DecoratedBox(
        // Glass: a see-through, top-lit fill over the page's soft backdrop.
        // The true-black theme keeps its plain hairline instead of the glass
        // edge, which would glow too brightly against black.
        decoration: BoxDecoration(
          gradient: frosted ? null : fill,
          borderRadius: radius,
          border: border == null ? null : Border.all(color: border),
        ),
        child: border != null
            ? body
            : DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: GlassCardRim(
                  dark: theme.brightness == Brightness.dark,
                  radius: radius,
                  accent: usesAurora(context)
                      ? theme.colorScheme.primary
                      : null,
                ),
                child: body,
              ),
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
  const SectionTitle(
    this.title, {
    super.key,
    this.action,
    this.onTap,
    this.compact = false,
  });
  final String title;
  final String? action;
  final VoidCallback? onTap;

  /// A small muted label, like "Total balance" above its amount, instead of a
  /// full section heading. What Home's cards use.
  final bool compact;
  @override
  Widget build(BuildContext context) => Row(
    children: [
      Expanded(
        child: Text(
          title,
          style: compact
              ? Theme.of(context).textTheme.bodySmall
              : Theme.of(context).textTheme.titleMedium,
        ),
      ),
      if (action != null)
        // A chevron rather than words; the action text is its label for
        // screen readers. As tall as the title line, no more, so cards with
        // one don't sit lower than the rest.
        Semantics(
          button: true,
          label: action,
          excludeSemantics: true,
          child: InkResponse(
            onTap: onTap,
            radius: 20,
            child: SizedBox(
              width: 40,
              height: 22,
              // Flush with the card's right padding, where Month overview's
              // chevron sits.
              // Nudged out into the card's padding so it sits in the top-right
              // corner rather than inset from it.
              child: Align(
                alignment: Alignment.centerRight,
                child: Transform.translate(
                  offset: const Offset(6, -3),
                  child: const Icon(Icons.chevron_right_rounded, size: 20),
                ),
              ),
            ),
          ),
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
  Widget build(BuildContext context) {
    // Glass artwork is Aurora's; Glassy keeps the simple icons in glass tiles.
    final art = usesAurora(context) ? menuArtFor(icon) : null;
    if (art != null) {
      return SizedBox.square(
        dimension: size * .95,
        child: Center(
          child: EmptyArtwork(art, size: size * .88, tint: color),
        ),
      );
    }
    return GlassIconTile(
      icon,
      tint: color ?? Theme.of(context).colorScheme.primary,
      size: size * .95,
    );
  }
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
