import 'package:flutter/gestures.dart' show kMinFlingVelocity;
import 'package:flutter/material.dart';

/// The app's shared motion: how things open, close and come to rest.
abstract final class AppMotion {
  /// Opening: sets off briskly and glides to a stop on its target, slowing
  /// all the way in, with no overshoot or bounce.
  static const Curve enter = Cubic(.22, 1, .36, 1);

  /// Closing, as a `reverseCurve`: slow to leave, then quickly gone. Reverse
  /// curves are sampled against a value already running backwards, so the
  /// ease-out shape here is what makes the exit accelerate.
  static const Curve exit = Curves.easeOutCubic;

  /// The spring that brings a dragged surface back to rest.
  static final settle = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 420,
    ratio: .78,
  );
}

/// Scrolling that flings the way Android lists do, but runs softly past an
/// end and springs back instead of stopping dead. Dragging past an end
/// stretches with growing resistance.
class ElasticScrollPhysics extends BouncingScrollPhysics {
  const ElasticScrollPhysics({super.parent});

  /// The fastest a fling may carry into the bounce, so a hard fling still
  /// only dips a little way past the end.
  static const _maxBounceVelocity = 3600.0;

  @override
  ElasticScrollPhysics applyTo(ScrollPhysics? ancestor) =>
      ElasticScrollPhysics(parent: buildParent(ancestor));

  // The bounce is the only thing borrowed from iOS: flings start and carry
  // exactly as they did.
  @override
  double get minFlingVelocity => kMinFlingVelocity;

  @override
  double carriedMomentum(double existingVelocity) => 0;

  @override
  Simulation? createBallisticSimulation(
    ScrollMetrics position,
    double velocity,
  ) {
    final tolerance = toleranceFor(position);
    final leaving =
        (velocity > 0 && position.pixels >= position.maxScrollExtent) ||
        (velocity < 0 && position.pixels <= position.minScrollExtent);
    // Already past an end (or about to be): spring back as usual.
    if (position.outOfRange || leaving || velocity.abs() < tolerance.velocity) {
      return super.createBallisticSimulation(position, velocity);
    }
    return _FlingThenBounce(
      position: position.pixels,
      velocity: velocity,
      min: position.minScrollExtent,
      max: position.maxScrollExtent,
      spring: spring,
      maxBounceVelocity: _maxBounceVelocity,
      tolerance: tolerance,
    );
  }
}

/// An Android fling that, if it would run past an end of the list, hands
/// over to a spring there with the speed it arrived at.
class _FlingThenBounce extends Simulation {
  _FlingThenBounce({
    required double position,
    required double velocity,
    required double min,
    required double max,
    required SpringDescription spring,
    required double maxBounceVelocity,
    super.tolerance,
  }) : _fling = ClampingScrollSimulation(
         position: position,
         velocity: velocity,
         tolerance: tolerance,
       ) {
    // Past its duration the fling reports where it comes to rest.
    final rest = _fling.x(double.maxFinite);
    if (rest >= min && rest <= max) return;
    final edge = rest > max ? max : min;
    // The fling only ever moves one way, so the moment it crosses the end
    // can be bisected.
    var low = 0.0, high = 1.0;
    while (!_fling.isDone(high) && high < 64) {
      high *= 2;
    }
    for (var i = 0; i < 32; i++) {
      final middle = (low + high) / 2;
      final past = rest > max
          ? _fling.x(middle) >= edge
          : _fling.x(middle) <= edge;
      if (past) {
        high = middle;
      } else {
        low = middle;
      }
    }
    _handover = high;
    _bounce = ScrollSpringSimulation(
      spring,
      edge,
      edge,
      _fling.dx(high).clamp(-maxBounceVelocity, maxBounceVelocity),
      tolerance: tolerance,
    );
  }

  final ClampingScrollSimulation _fling;
  ScrollSpringSimulation? _bounce;
  double _handover = double.infinity;

  @override
  double x(double time) =>
      time < _handover ? _fling.x(time) : _bounce!.x(time - _handover);

  @override
  double dx(double time) =>
      time < _handover ? _fling.dx(time) : _bounce!.dx(time - _handover);

  @override
  bool isDone(double time) => time < _handover
      ? _bounce == null && _fling.isDone(time)
      : _bounce!.isDone(time - _handover);
}
