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
