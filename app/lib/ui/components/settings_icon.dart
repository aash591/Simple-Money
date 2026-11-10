import 'package:flutter/material.dart';

import '../../domain/app_icons.dart';
import 'app_icon.dart';

class SettingsIcon extends StatelessWidget {
  const SettingsIcon(this.iconKey, {super.key, required this.size});

  final String? iconKey;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (Theme.of(context).brightness != Brightness.dark) {
      return AppIcon(iconKey, size: size);
    }
    final brand = resolveBrandIcon(iconKey);
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * .1),
      decoration: BoxDecoration(
        // A soft glass tile in the theme's own colours keeps dark artwork
        // distinct from the page and cards, as the icon picker does.
        color: scheme.onSurface.withValues(alpha: .07),
        borderRadius: BorderRadius.circular(size * .3),
        border: Border.all(color: scheme.onSurface.withValues(alpha: .1)),
      ),
      child: brand == null
          ? AppIcon(iconKey, size: size * .8)
          : Image.asset(
              brandIconAssetPath(brand.key, Brightness.dark),
              fit: BoxFit.contain,
            ),
    );
  }
}
