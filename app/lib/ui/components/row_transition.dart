import 'package:flutter/material.dart';

/// A list row that unfolds when it is new and folds away when it leaves, so
/// an entry arriving (added here, or from another phone) or being deleted is
/// seen happening rather than popping in or out. A new row also glows with
/// the accent for a moment, to show where it landed.
///
/// Give it a key from the row's identity (e.g. `ValueKey(transaction.id)`),
/// so the same row keeps its state across rebuilds. With animations turned
/// off on the phone, rows just appear and disappear.
class RowTransition extends StatefulWidget {
  const RowTransition({
    super.key,
    required this.child,
    this.entering = false,
    this.leaving = false,
  });
  final Widget child;

  /// New since the list was last shown: unfolds when first built.
  final bool entering;

  /// Deleted: folds away (and can't be tapped meanwhile).
  final bool leaving;

  static const duration = Duration(milliseconds: 320);
  static const glow = Duration(milliseconds: 1400);

  @override
  State<RowTransition> createState() => _RowTransitionState();
}

class _RowTransitionState extends State<RowTransition>
    with TickerProviderStateMixin {
  late final _size = AnimationController(
    vsync: this,
    duration: RowTransition.duration,
    value: widget.entering && !widget.leaving ? 0 : 1,
  );
  late final _glow = AnimationController(
    vsync: this,
    duration: RowTransition.glow,
    value: widget.entering ? 1 : 0,
  );
  late final _curve = CurvedAnimation(
    parent: _size,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _size.duration = Duration.zero;
      _glow.duration = Duration.zero;
    }
  }

  @override
  void initState() {
    super.initState();
    if (widget.leaving) {
      _size.reverse();
    } else if (widget.entering) {
      _size.forward();
      _glow.reverse();
    }
  }

  @override
  void didUpdateWidget(RowTransition old) {
    super.didUpdateWidget(old);
    if (widget.leaving && !old.leaving) {
      _size.reverse();
    } else if (!widget.leaving && old.leaving) {
      _size.forward(); // Back again (e.g. the deletion was undone).
    }
  }

  @override
  void dispose() {
    _curve.dispose();
    _size.dispose();
    _glow.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return SizeTransition(
      sizeFactor: _curve,
      axisAlignment: -1,
      child: FadeTransition(
        opacity: _curve,
        child: IgnorePointer(
          ignoring: widget.leaving,
          child: AnimatedBuilder(
            animation: _glow,
            builder: (context, child) => DecoratedBox(
              decoration: BoxDecoration(
                color: accent.withValues(
                  alpha: .14 * Curves.easeIn.transform(_glow.value),
                ),
              ),
              child: child,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
