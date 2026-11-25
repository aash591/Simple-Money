import 'package:flutter/material.dart';

const lightPageBackground = Color(0xffececef);
const appCardRadius = 24.0;
const appCardGap = 28.0;

/// Home packs more onto one screen than the other pages, so its cards sit
/// closer together.
const homeCardGap = 14.0;

List<BoxShadow> appCardShadows(Brightness brightness) => [
  BoxShadow(
    color: Colors.black.withValues(
      alpha: brightness == Brightness.dark ? .12 : .025,
    ),
    blurRadius: 18,
    spreadRadius: -4,
    offset: const Offset(0, 4),
  ),
];

/// Marks a page that paints a tinted backdrop: cards inside turn see-through
/// so the tint shows through them.
class GlassCards extends InheritedWidget {
  const GlassCards({super.key, required super.child});

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassCards>() != null;

  @override
  bool updateShouldNotify(GlassCards oldWidget) => false;
}

/// How much of a card's own fill survives over a [GlassCards] backdrop.
const glassCardOpacity = .72;
