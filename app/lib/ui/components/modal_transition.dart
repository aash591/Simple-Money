import 'package:flutter/material.dart';

import '../theme/app_motion.dart';

/// Shared opening and closing motion for sheets and alerts: the surface
/// fades in while rising onto a soft spring, and drops away faster than it
/// arrived.
class ModalTransition extends StatefulWidget {
  const ModalTransition({
    super.key,
    required this.animation,
    required this.child,
  });

  static const duration = Duration(milliseconds: 400);
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
      curve: AppMotion.spring,
      reverseCurve: AppMotion.exit,
    );
    // Fully visible well before the spring settles, so the overshoot is
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
    return FadeTransition(
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
