import 'package:flutter/material.dart';

import '../../domain/app_icons.dart';
import '../../domain/brand_dark_icons.dart';

bool usesDarkBrandAsset(String key, Brightness brightness) =>
    brightness == Brightness.dark && darkBrandIconKeys.contains(key);

String brandIconAssetPath(String key, Brightness brightness) {
  final suffix = usesDarkBrandAsset(key, brightness) ? '_dark' : '';
  return 'assets/icon_packs/brands/$key$suffix.webp';
}

/// The image [AppIcon] draws for [iconKey], or null for a text wordmark —
/// for loading icons ahead of a list that is about to show them.
ImageProvider? appIconImage(String? iconKey, Brightness brightness) {
  final brand = resolveBrandIcon(iconKey);
  if (brand != null) {
    return AssetImage(brandIconAssetPath(brand.key, brightness));
  }
  if (resolveWordmarkBrand(iconKey) != null) return null;
  return AssetImage(appIconAsset(iconKey));
}

/// Renders whichever icon [iconKey] names — one of `appIconKeys` (a category
/// icon), a `brand:`-prefixed key (a merchant/subscription logo), or a
/// `mark:`-prefixed key (a text wordmark badge for a brand with no
/// safely-licensable logo file) — so call sites don't need to know which
/// kind they have.
///
/// Every icon uses the picker cell as its surface. Category icons use the
/// app's consistent soft 3D artwork; official service and bank marks remain
/// flat and are drawn directly in that same space.
class AppIcon extends StatelessWidget {
  const AppIcon(this.iconKey, {super.key, this.size});
  final String? iconKey;

  /// Explicit size, or null to fill whatever space the parent provides
  /// (e.g. a GridView cell, which already constrains its own size).
  final double? size;

  @override
  Widget build(BuildContext context) {
    final brand = resolveBrandIcon(iconKey);
    if (brand != null) {
      final brightness = Theme.of(context).brightness;
      // Catalog colors are baked into the WebP. Only selected marks need a
      // separate dark-surface asset.
      final logo = Image.asset(
        brandIconAssetPath(brand.key, brightness),
        width: size,
        height: size,
        fit: BoxFit.contain,
      );
      return _BrandIcon(logo: logo, size: size);
    }
    final wordmark = resolveWordmarkBrand(iconKey);
    if (wordmark != null) {
      final iconSize = size ?? 48;
      return SizedBox(
        width: size,
        height: size,
        child: Center(
          child: Text(
            wordmark.label,
            style: TextStyle(
              color: _brandColor(context, wordmark.color),
              fontWeight: FontWeight.w700,
              fontSize: iconSize * .34,
              height: 1,
            ),
          ),
        ),
      );
    }
    return _SizedIconEffect(
      size: size,
      child: Image.asset(
        appIconAsset(iconKey),
        fit: BoxFit.contain,
        filterQuality: FilterQuality.low,
        gaplessPlayback: true,
      ),
    );
  }

  /// Preserve recognizable brand colors, except black marks which need the
  /// same light-on-dark treatment as the category artwork.
  Color _brandColor(BuildContext context, Color color) {
    final isBlack = color.computeLuminance() < .02;
    return isBlack && Theme.of(context).brightness == Brightness.dark
        ? Colors.white
        : color;
  }
}

/// The stacked-card illustration used for the aggregate "All accounts"
/// selector. It shares the category artwork's subtle depth treatment while
/// remaining unavailable as a per-account icon choice.
class AllAccountsIcon extends StatelessWidget {
  const AllAccountsIcon({super.key, this.size});

  final double? size;

  @override
  Widget build(BuildContext context) => _SizedIconEffect(
    size: size,
    child: Image.asset(
      allAccountsIconAsset,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.low,
      gaplessPlayback: true,
    ),
  );
}

/// Adds a broad, structureless depth field around the icon rather than tracing
/// its silhouette or collapsing to a small contact point. It is only a radial
/// gradient, so it needs neither a filtered layer nor a second artwork draw.
class _IconEffect extends StatelessWidget {
  const _IconEffect({required this.dimension, required this.child});

  final double dimension;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    if (!dark) return SizedBox.square(dimension: dimension, child: child);
    final effectColor = theme.colorScheme.primary;

    return SizedBox.square(
      dimension: dimension,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Align(
            alignment: const Alignment(0, .08),
            child: IgnorePointer(
              child: ExcludeSemantics(
                child: SizedBox(
                  width: dimension * .92,
                  height: dimension * .74,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(dimension),
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: .86,
                        colors: [
                          effectColor.withValues(alpha: .16),
                          effectColor.withValues(alpha: .11),
                          effectColor.withValues(alpha: .04),
                          effectColor.withValues(alpha: 0),
                        ],
                        stops: const [0, .30, .70, 1],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          child,
        ],
      ),
    );
  }
}

class _SizedIconEffect extends StatelessWidget {
  const _SizedIconEffect({required this.size, required this.child});

  final double? size;
  final Widget child;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final tileSize =
          size ?? (constraints.hasBoundedWidth ? constraints.maxWidth : 48.0);
      return SizedBox.square(
        dimension: tileSize,
        child: Center(
          child: _IconEffect(dimension: tileSize, child: child),
        ),
      );
    },
  );
}

/// Gives every standalone official logo the same maximum visual dimension as
/// the normalized category artwork, while preserving the logo's aspect ratio.
class _BrandIcon extends StatelessWidget {
  const _BrandIcon({required this.logo, required this.size});

  final Widget logo;
  final double? size;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final tileSize =
          size ?? (constraints.hasBoundedWidth ? constraints.maxWidth : 48.0);
      return SizedBox.square(
        dimension: tileSize,
        child: Center(
          // Match the category artwork's visual footprint.
          child: _IconEffect(dimension: tileSize * .82, child: logo),
        ),
      );
    },
  );
}

/// [iconKey]'s artwork with [badgeKey]'s small in the bottom-right corner,
/// e.g. a loan's car with its bank. Just [iconKey] when there's no badge.
class BadgedAppIcon extends StatelessWidget {
  const BadgedAppIcon(this.iconKey, {super.key, this.badgeKey, this.size = 40});
  final String? iconKey, badgeKey;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (badgeKey == null) return AppIcon(iconKey, size: size);
    final badge = size * .55;
    final theme = Theme.of(context);
    return SizedBox.square(
      dimension: size,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: AppIcon(iconKey, size: size)),
          Positioned(
            right: -size * .12,
            bottom: -size * .12,
            child: Container(
              width: badge,
              height: badge,
              padding: EdgeInsets.all(badge * .08),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: theme.colorScheme.surface,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .08),
                    blurRadius: 4,
                  ),
                ],
              ),
              child: ClipOval(child: AppIcon(badgeKey, size: badge * .84)),
            ),
          ),
        ],
      ),
    );
  }
}
