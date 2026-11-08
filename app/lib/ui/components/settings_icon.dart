import 'package:flutter/material.dart';

import '../../domain/app_icons.dart';
import 'app_icon.dart';

// A soft neutral surface keeps dark artwork distinct from the page and cards.
const darkIconBackground = Color(0xff454b50);
const darkIconBorder = Color(0xff565d63);

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
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * .1),
      decoration: BoxDecoration(
        color: darkIconBackground,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: darkIconBorder),
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
