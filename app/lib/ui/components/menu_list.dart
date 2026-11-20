import 'package:flutter/material.dart';

import 'common.dart';
import '../theme/app_theme.dart' show usesAurora;
import 'empty_art.dart';
import 'glass_surface.dart';

const _tileSize = 40.0;
const _rowPadding = 16.0;
const _tileGap = 14.0;

/// A card of [MenuRow]s under an optional small [label], with a divider
/// between rows that starts where their text does.
class MenuGroup extends StatelessWidget {
  const MenuGroup({super.key, this.label, required this.children});
  final String? label;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (label != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            child: Text(
              label!.toUpperCase(),
              style: theme.textTheme.bodySmall?.copyWith(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: .8,
              ),
            ),
          ),
        MoneyCard(
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const _MenuDivider(),
                children[i],
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _MenuDivider extends StatelessWidget {
  const _MenuDivider();
  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.only(
      left: _rowPadding + _tileSize + _tileGap,
      right: _rowPadding,
    ),
    child: Divider(height: 1),
  );
}

/// The glass tile every menu icon sits in: tinted with the accent so it
/// follows the theme, or [filled] with solid accent glass to stand out.
class MenuIconTile extends StatelessWidget {
  const MenuIconTile(this.icon, {super.key, this.filled = false, this.tint});
  final IconData icon;
  final bool filled;

  /// Instead of the accent, e.g. red for something that deletes.
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    // Aurora draws icons with glass artwork, with no tile behind. Glassy keeps
    // the simple icon set on menus, in its glass tile.
    final art = usesAurora(context) ? menuArtFor(icon) : null;
    if (art != null) {
      return SizedBox.square(
        dimension: _tileSize,
        child: Center(
          child: EmptyArtwork(art, size: menuArtSize, tint: tint),
        ),
      );
    }
    return GlassIconTile(
      icon,
      size: _tileSize,
      tint: tint ?? Theme.of(context).colorScheme.primary,
      filled: filled,
    );
  }
}

/// An icon tile, a title and an optional one-line explanation. [trailing]
/// replaces the chevron (a switch, say); [external] swaps it for an
/// open-in-browser mark.
class MenuRow extends StatelessWidget {
  const MenuRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.external = false,
    this.highlight = false,
    this.tint,
    this.proBadge = false,
  });
  final IconData icon;
  final String title;

  /// A small PRO tag on the icon: this row is a Pro feature.
  final bool proBadge;
  final String? subtitle;

  /// Without it, and without a [trailing] control, the row is dimmed: it
  /// is unavailable right now.
  final VoidCallback? onTap;
  final Widget? trailing;
  final bool external, highlight;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: _rowPadding,
            vertical: subtitle == null ? 14 : 13,
          ),
          child: Row(
            children: [
              proBadge
                  ? Stack(
                      clipBehavior: Clip.none,
                      children: [
                        MenuIconTile(icon, filled: highlight, tint: tint),
                        const Positioned(
                          right: -5,
                          bottom: -3,
                          child: IgnorePointer(child: MenuProBadge()),
                        ),
                      ],
                    )
                  : MenuIconTile(icon, filled: highlight, tint: tint),
              const SizedBox(width: _tileGap),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 12.5,
                          height: 1.35,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              trailing ??
                  Icon(
                    external
                        ? Icons.open_in_new_rounded
                        : Icons.chevron_right_rounded,
                    size: external ? 18 : 22,
                    color: theme.colorScheme.onSurfaceVariant.withValues(
                      alpha: .8,
                    ),
                  ),
            ],
          ),
        ),
      ),
    );
    return onTap == null && trailing == null
        ? Opacity(opacity: .45, child: row)
        : row;
  }
}

/// A [MenuRow] whose whole row toggles its switch.
class MenuSwitchRow extends StatelessWidget {
  const MenuSwitchRow({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => MenuRow(
    icon: icon,
    title: title,
    subtitle: subtitle,
    onTap: onChanged == null ? null : () => onChanged!(!value),
    trailing: Switch.adaptive(value: value, onChanged: onChanged),
  );
}

/// The small "PRO" tag shown on a Pro feature's icon or swatch.
class MenuProBadge extends StatelessWidget {
  const MenuProBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
      decoration: BoxDecoration(
        color: scheme.primary,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: scheme.surface, width: 1.5),
      ),
      child: Text(
        'PRO',
        style: TextStyle(
          color: scheme.onPrimary,
          fontSize: 8,
          height: 1.1,
          fontWeight: FontWeight.w800,
          letterSpacing: .3,
        ),
      ),
    );
  }
}
