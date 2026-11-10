import 'package:flutter/material.dart';

import '../theme/surface_style.dart';

/// How a card looks while it is being dragged in a reorderable list: a little
/// larger, on a soft shadow, so it reads as lifted off the page. Pass it as
/// the list's `proxyDecorator`.
Widget reorderLift(Widget child, int index, Animation<double> animation) =>
    AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final lift = Curves.easeOut.transform(animation.value);
        return Transform.scale(
          scale: 1 + .03 * lift,
          child: DecoratedBox(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(appCardRadius),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: .28 * lift),
                  blurRadius: 24 * lift,
                  offset: Offset(0, 10 * lift),
                ),
              ],
            ),
            child: Material(color: Colors.transparent, child: child),
          ),
        );
      },
      child: child,
    );
