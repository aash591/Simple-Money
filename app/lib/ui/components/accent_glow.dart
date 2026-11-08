import 'package:flutter/material.dart';

import '../theme/surface_style.dart';

/// Lays a wash of the accent colour behind [child] — the four main tabs — and
/// turns the cards inside see-through so they pick it up. It sits behind all
/// the tabs rather than inside each, so it holds still while they slide past
/// one another.
class AccentGlowScope extends StatelessWidget {
  const AccentGlowScope({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => GlassCards(
    child: Stack(
      children: [
        const Positioned.fill(child: _AccentGlow()),
        child,
      ],
    ),
  );
}

/// The accent colour pouring down from the top of the screen and fading out
/// by its middle.
class _AccentGlow extends StatelessWidget {
  const _AccentGlow();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tint = theme.colorScheme.primary;
    final strength = theme.brightness == Brightness.dark ? .42 : .2;
    return IgnorePointer(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              tint.withValues(alpha: strength),
              tint.withValues(alpha: strength * .4),
              tint.withValues(alpha: 0),
            ],
            stops: const [0, .22, .5],
          ),
        ),
      ),
    );
  }
}
