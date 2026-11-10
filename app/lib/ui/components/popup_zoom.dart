import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// Zooms from the corner nearest its trigger with a small, smooth overshoot,
/// while [PopupReveal] fades the glass in.
class PopupZoom extends StatefulWidget {
  const PopupZoom({
    super.key,
    required this.animation,
    this.alignment = Alignment.topLeft,
    this.layoutBuilder,
    required this.child,
  });

  final Animation<double> animation;
  final Alignment alignment;
  final Widget child;
  final Widget Function(double scale, Widget child)? layoutBuilder;

  @override
  State<PopupZoom> createState() => PopupZoomState();
}

class PopupZoomState extends State<PopupZoom> {
  // A short zoom reads as the popup growing out of its trigger; starting at
  // half size made it look like it appeared already open and then jumped.
  static final _scaleTween = Tween<double>(begin: .86, end: 1);

  late CurvedAnimation _scale, _reveal;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(covariant PopupZoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _unbind();
      _bind();
    }
  }

  /// Reverse curves are sampled against the parent's value, which is already
  /// running backwards, so they are flipped to keep the collapse accelerating
  /// instead of stalling out near the anchor. The reveal finishes early on
  /// open and holds through the start of a close, so the glass is never
  /// half-faded while it is still being read.
  void _bind() {
    _scale = CurvedAnimation(
      parent: widget.animation,
      curve: AppMotion.spring,
      reverseCurve: Curves.easeInCubic.flipped,
    );
    _reveal = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, .4, curve: Curves.easeOut),
      reverseCurve: const Interval(0, .75, curve: Curves.easeOut),
    );
  }

  void _unbind() {
    _scale.dispose();
    _reveal.dispose();
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return widget.layoutBuilder?.call(1, widget.child) ?? widget.child;
    }
    final child = PopupReveal(opacity: _reveal, child: widget.child);
    if (widget.layoutBuilder != null) {
      return AnimatedBuilder(
        animation: _scale,
        child: child,
        builder: (context, child) {
          final scale = _scaleTween.evaluate(_scale);
          return widget.layoutBuilder!(
            scale,
            Transform.scale(
              scale: scale,
              alignment: Alignment.topLeft,
              child: child,
            ),
          );
        },
      );
    }
    return ScaleTransition(
      scale: _scaleTween.animate(_scale),
      alignment: widget.alignment,
      child: child,
    );
  }
}

/// How visible the popup's glass is, 0 to 1. A plain opacity cannot be used:
/// a backdrop filter inside its saveLayer would blur the empty layer instead
/// of the page, so the frosted surface fades its own tint, rim and blur.
class PopupReveal extends InheritedWidget {
  const PopupReveal({super.key, required this.opacity, required super.child});

  final Animation<double> opacity;

  static Animation<double>? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PopupReveal>()?.opacity;

  @override
  bool updateShouldNotify(PopupReveal oldWidget) =>
      opacity != oldWidget.opacity;
}
