import 'package:simple_money/state/vibration_settings.dart';
import 'package:flutter/material.dart';

/// Gives each user-driven scroll one light tick per edge reached.
/// Programmatic scrolling and content that fits its viewport stay silent.
class ScrollEdgeHaptics extends StatefulWidget {
  const ScrollEdgeHaptics({super.key, required this.child});

  final Widget child;

  @override
  State<ScrollEdgeHaptics> createState() => _ScrollEdgeHapticsState();
}

class _ScrollEdgeHapticsState extends State<ScrollEdgeHaptics> {
  final _gestures = Expando<Set<bool>>();

  bool _onScroll(ScrollNotification notification) {
    final source = notification.context;
    if (source == null) return false;
    if (notification is ScrollStartNotification) {
      _gestures[source] = notification.dragDetails != null ? <bool>{} : null;
    } else if (notification is ScrollEndNotification) {
      _gestures[source] = null;
    } else if (notification is ScrollUpdateNotification ||
        notification is OverscrollNotification) {
      final edges = _gestures[source];
      final metrics = notification.metrics;
      if (edges == null || metrics.maxScrollExtent <= metrics.minScrollExtent) {
        return false;
      }
      final atStart = metrics.pixels <= metrics.minScrollExtent;
      final atEnd = metrics.pixels >= metrics.maxScrollExtent;
      if ((atStart || atEnd) && edges.add(atStart)) {
        VibrationSettings.softTick();
      }
    }
    return false;
  }

  @override
  Widget build(BuildContext context) =>
      NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: widget.child,
      );
}
