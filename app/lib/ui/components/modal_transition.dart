import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/app_motion.dart';
import 'popup_zoom.dart' show PopupReveal;

/// Shared opening and closing motion for sheets and alerts: the surface
/// fades in while rising and gently easing to a stop, and drops away faster than it
/// arrived.
///
/// The fade goes through [PopupReveal] rather than an opacity layer: a
/// backdrop blur inside an opacity layer samples that empty layer instead of
/// the page, so the frost would snap on as the fade finished and snap off as
/// a close began. The frosted surface fades its own blur, tint and content.
class ModalTransition extends StatefulWidget {
  const ModalTransition({
    super.key,
    required this.animation,
    required this.child,
  });

  static const duration = Duration(milliseconds: 560);
  static const reverseDuration = Duration(milliseconds: 220);
  static const riseDistance = 32.0;

  final Animation<double> animation;
  final Widget child;

  @override
  State<ModalTransition> createState() => _ModalTransitionState();
}

class _ModalTransitionState extends State<ModalTransition> {
  late CurvedAnimation _rise, _fade;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(ModalTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _unbind();
      _bind();
    }
  }

  void _bind() {
    _rise = CurvedAnimation(
      parent: widget.animation,
      curve: AppMotion.enter,
      reverseCurve: AppMotion.exit,
    );
    // Fully visible well before the rise settles, so the glide into place is
    // seen rather than faded through.
    _fade = CurvedAnimation(
      parent: widget.animation,
      curve: const Interval(0, .4, curve: Curves.easeOut),
      reverseCurve: AppMotion.exit,
    );
  }

  void _unbind() {
    _rise.dispose();
    _fade.dispose();
  }

  @override
  void dispose() {
    _unbind();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return PopupReveal(
      opacity: _fade,
      child: AnimatedBuilder(
        animation: _rise,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, ModalTransition.riseDistance * (1 - _rise.value)),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// How sheets open and close, the way iOS moves its sheets: the sheet is
/// whole from the first frame and only slides, up from below the screen on
/// a critically damped spring (quick off the mark, gliding to a stop, no
/// bounce), and back down faster, gathering speed as it goes.
///
/// Nothing fades: a sheet fading in has to redraw its blur, tint, rim and
/// content into a fresh offscreen layer on every frame, which is what made
/// opening feel heavy (above all on Snapdragon phones). Sliding moves
/// pixels already painted.
class SheetTransition extends StatefulWidget {
  const SheetTransition({
    super.key,
    required this.animation,
    required this.below,
    required this.child,
  });

  static const duration = Duration(milliseconds: 500);
  static const reverseDuration = Duration(milliseconds: 280);

  final Animation<double> animation;

  /// The space between the sheet's bottom edge and the screen's, which it
  /// also has to cover to start out of sight.
  final double below;
  final Widget child;

  @override
  State<SheetTransition> createState() => _SheetTransitionState();
}

class _SheetTransitionState extends State<SheetTransition> {
  late CurvedAnimation _slide;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didUpdateWidget(SheetTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      _slide.dispose();
      _bind();
    }
  }

  void _bind() => _slide = CurvedAnimation(
    parent: widget.animation,
    curve: const CriticallyDampedCurve(),
    // Flat at the open end, so closing starts gently and speeds away.
    reverseCurve: AppMotion.exit,
  );

  @override
  void dispose() {
    _slide.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return AnimatedBuilder(
      animation: _slide,
      builder: (context, child) {
        final away = 1 - _slide.value;
        return Transform.translate(
          offset: Offset(0, widget.below * away),
          child: FractionalTranslation(
            translation: Offset(0, away),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }
}

/// The motion of a critically damped spring, iOS's sheet spring: the
/// fastest settle that never overshoots.
class CriticallyDampedCurve extends Curve {
  const CriticallyDampedCurve([this.stiffness = 9]);

  /// How quickly it closes in, in natural frequencies per run of the curve.
  final double stiffness;

  @override
  double transformInternal(double t) {
    double at(double t) => 1 - (1 + stiffness * t) * math.exp(-stiffness * t);
    // Scaled so the curve lands exactly on 1.
    return at(t) / at(1);
  }
}
