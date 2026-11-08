import 'package:flutter/material.dart';

/// Renders a country's flag from its ISO 3166-1 alpha-2 [territory] code.
///
/// Flags are bundled as small raster images (see `tool/generate_flags.mjs`)
/// rather than Unicode emoji, which render as placeholder glyphs wherever the
/// device's emoji font lacks the regional-indicator pair, or as vectors, which
/// carried detail that is invisible at this size — the source artwork for
/// Serbia's coat of arms alone was 501KB. `Image.asset` also gets Flutter's
/// built-in image cache for free, so scrolling a long list doesn't re-decode.
class CurrencyFlag extends StatelessWidget {
  const CurrencyFlag(
    this.territory, {
    super.key,
    this.width = 32,
    this.height = 32,
    this.borderRadius = 6,
  });
  final String territory;
  final double width, height, borderRadius;

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(borderRadius),
    child: Image.asset(
      'assets/flags/${territory.toLowerCase()}.webp',
      width: width,
      height: height,
      fit: BoxFit.cover,
      filterQuality: FilterQuality.medium,
      errorBuilder: (context, _, _) {
        final muted = Theme.of(context).colorScheme.onSurfaceVariant;
        return Container(
          width: width,
          height: height,
          alignment: Alignment.center,
          color: muted.withValues(alpha: .11),
          child: Icon(Icons.public_rounded, size: width * .6, color: muted),
        );
      },
    ),
  );
}
