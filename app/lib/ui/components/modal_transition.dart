import 'package:flutter/material.dart';

/// Shared opening and closing motion, extracted from the transaction sheet.
class ModalTransition extends StatelessWidget {
  const ModalTransition({
    super.key,
    required this.animation,
    required this.child,
  });

  static const duration = Duration(milliseconds: 280);
  static const curve = Curves.fastOutSlowIn;
  static const riseDistance = 24.0;

  final Animation<double> animation;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final progress = animation.drive(CurveTween(curve: curve));
    return FadeTransition(
      opacity: progress,
      child: AnimatedBuilder(
        animation: progress,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, riseDistance * (1 - progress.value)),
          child: child,
        ),
        child: child,
      ),
    );
  }
}
