import 'package:flutter/material.dart';

import '../theme/surface_style.dart';
import 'glass_surface.dart';

/// Lays the glass backdrop — soft pools of the accent colour — behind
/// [child], the four main tabs, and marks the cards inside as glass. It sits
/// behind all the tabs rather than inside each, so it holds still while they
/// slide past one another.
class AccentGlowScope extends StatelessWidget {
  const AccentGlowScope({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => GlassCards(
    child: Stack(
      children: [
        const Positioned.fill(child: GlassBackdrop()),
        child,
      ],
    ),
  );
}
