import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

/// A scroll-only position indicator for sheet bodies. It stays out of
/// hit testing so dragging near the edge still scrolls the content normally.
class SheetScrollIndicator extends StatefulWidget {
  const SheetScrollIndicator({super.key, required this.child});
  final Widget child;

  @override
  State<SheetScrollIndicator> createState() => _SheetScrollIndicatorState();
}

class _SheetScrollIndicatorState extends State<SheetScrollIndicator>
    with TickerProviderStateMixin {
  final _metrics = ValueNotifier<ScrollMetrics?>(null);
  late final _visibility = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 150),
  );
  Timer? _hideTimer;

  /// The scroll extent the thumb is drawn from. A lazily built list only
  /// estimates how tall its unbuilt rows are and revises that estimate as they
  /// scroll into view, so a thumb sized and placed straight from the reported
  /// extent jumps and resizes mid-scroll. This value chases the reported one
  /// instead, which turns each revision into a glide.
  final _extent = ValueNotifier<double>(0);
  double _target = 0;
  late final Ticker _ticker = createTicker(_chase);
  Duration _lastTick = Duration.zero;

  late final Listenable _repaint = Listenable.merge([
    _metrics,
    _extent,
    _visibility,
  ]);

  @override
  void dispose() {
    _hideTimer?.cancel();
    _visibility.dispose();
    _ticker.dispose();
    _metrics.dispose();
    _extent.dispose();
    super.dispose();
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0) {
      _update(notification.metrics);
      if (_target > 1 &&
          (notification is ScrollStartNotification ||
              notification is ScrollUpdateNotification)) {
        _hideTimer?.cancel();
        _visibility.forward();
      }
      if (notification is ScrollEndNotification) {
        _hideTimer?.cancel();
        _hideTimer = Timer(const Duration(milliseconds: 600), () {
          _visibility.reverse();
        });
      }
    }
    return false;
  }

  bool _onMetrics(ScrollMetricsNotification notification) {
    if (notification.depth == 0) _update(notification.metrics);
    return false;
  }

  void _update(ScrollMetrics metrics) {
    _metrics.value = metrics;
    final extent = metrics.maxScrollExtent - metrics.minScrollExtent;
    _target = extent.isFinite && extent > 1 ? extent : 0;
    if (_target == 0) {
      _hideTimer?.cancel();
      _visibility.value = 0;
    }
    // Nothing to chase towards on content that no longer scrolls, and a list
    // replaced wholesale — a filter, another account, a different month —
    // should not be animated across: only a revised estimate of the same
    // content glides.
    if (_target == 0 ||
        _extent.value <= 0 ||
        (_target - _extent.value).abs() > metrics.viewportDimension * 3) {
      _ticker.stop();
      _extent.value = _target;
      return;
    }
    if (!_ticker.isActive) {
      _lastTick = Duration.zero;
      _ticker.start();
    }
  }

  void _chase(Duration elapsed) {
    final remaining = _target - _extent.value;
    if (remaining.abs() < 0.5) {
      _extent.value = _target;
      _ticker.stop();
      return;
    }
    final seconds = (elapsed - _lastTick).inMicroseconds / 1e6;
    _lastTick = elapsed;
    if (seconds <= 0) return;
    // Closing the gap by a fixed fraction *per second* rather than per frame
    // keeps the glide identical on 60Hz and 120Hz displays.
    _extent.value += remaining * (1 - math.exp(-seconds * 14));
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollMetricsNotification>(
        onNotification: _onMetrics,
        child: NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          // The indicator is a sibling rather than a foreground painter so that
          // repainting the thumb every frame does not drag the whole list into
          // the repaint with it.
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              RepaintBoundary(
                child: ScrollConfiguration(
                  behavior: ScrollConfiguration.of(context)
                      .copyWith(scrollbars: false),
                  child: widget.child,
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: RepaintBoundary(
                    child: CustomPaint(
                      painter: _IndicatorPainter(
                        repaint: _repaint,
                        metrics: _metrics,
                        extent: _extent,
                        visibility: _visibility,
                      ),
                      willChange: true,
                      size: Size.infinite,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
}

class _IndicatorPainter extends CustomPainter {
  _IndicatorPainter({
    required Listenable repaint,
    required this.metrics,
    required this.extent,
    required this.visibility,
  }) : super(repaint: repaint);
  final ValueNotifier<ScrollMetrics?> metrics;
  final ValueNotifier<double> extent;
  final Animation<double> visibility;

  @override
  void paint(Canvas canvas, Size size) {
    final value = metrics.value;
    final scrollable = extent.value;
    if (value == null || value.axis != Axis.vertical || size.height <= 8) {
      return;
    }
    if (!scrollable.isFinite || scrollable <= 1 || visibility.value == 0) {
      return;
    }
    final track = size.height - 8;
    final height = math.min(
      track,
      math.max(
        36.0,
        track *
            value.viewportDimension /
            (scrollable + value.viewportDimension),
      ),
    );
    var progress = ((value.pixels - value.minScrollExtent) / scrollable).clamp(
      0.0,
      1.0,
    );
    if (value.axisDirection == AxisDirection.up) progress = 1 - progress;
    final thumb = RRect.fromRectAndRadius(
      Rect.fromLTWH(size.width - 5, 4 + (track - height) * progress, 2, height),
      const Radius.circular(1),
    );
    canvas.drawRRect(
      thumb.shift(const Offset(0, 1)),
      Paint()
        ..color = Colors.black.withValues(alpha: .12 * visibility.value)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2),
    );
    canvas.drawRRect(
      thumb,
      Paint()..color = Colors.white.withValues(alpha: .75 * visibility.value),
    );
  }

  @override
  bool shouldRepaint(_IndicatorPainter oldDelegate) =>
      oldDelegate.metrics != metrics ||
      oldDelegate.extent != extent ||
      oldDelegate.visibility != visibility;
}
