import 'package:simple_money/state/vibration_settings.dart';

import 'dart:math' as math;
import 'dart:ui' show lerpDouble;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'chart_data.dart';
import 'chart_frame.dart';
import 'chart_palette.dart';

/// Builds the mark inside a slice's callout badge — an icon, usually.
typedef ChartBadgeBuilder = Widget Function(BuildContext context, int index);

/// A donut that labels itself: each slice gets a callout — a leader line
/// with an arrowhead on the slice, ending in a round badge with its share —
/// so no separate legend is needed.
///
/// Tapping a slice or its badge pops the slice out, dims the rest and shows
/// its name, value and share in the hole; tapping it again, the hole or
/// anywhere else clears it. The ring sweeps in on first show and whenever
/// the data changes, unless the platform asks for reduced motion.
///
/// Badges sit on an oval around the ring, each as close to its slice as its
/// neighbours allow, so every leader is a short straight line clear of the
/// ring. When more slices than badges fit, the smallest go unlabelled (they
/// stay tappable). Like every chart here it is unit-agnostic: pass
/// [formatValue] for the value shown on selection.
class CalloutDonutChart extends StatefulWidget {
  const CalloutDonutChart({
    super.key,
    required this.slices,
    this.height = 290,
    this.thickness = 22,
    this.badgeBuilder,
    this.centerLabel,
    this.centerCaption,
    this.formatValue,
    this.onSelect,
  });

  final List<ChartEntry> slices;
  final double height, thickness;

  /// The mark inside each badge. Null draws a dot in the slice's colour.
  final ChartBadgeBuilder? badgeBuilder;

  /// What the hole shows with nothing selected — usually the total.
  final String? centerLabel;
  final String? centerCaption;
  final ChartValueFormatter? formatValue;

  /// Told whenever the selection changes; null means it was cleared.
  final ValueChanged<int?>? onSelect;

  @override
  State<CalloutDonutChart> createState() => _CalloutDonutChartState();
}

class _CalloutDonutChartState extends State<CalloutDonutChart>
    with TickerProviderStateMixin {
  late final _reveal = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final _pop = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 240),
    value: 1,
  );
  int? _selected, _previous;

  bool get _reduceMotion => MediaQuery.disableAnimationsOf(context);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion) {
      _reveal.value = 1;
    } else if (_reveal.isDismissed) {
      _reveal.forward();
    }
  }

  @override
  void didUpdateWidget(CalloutDonutChart old) {
    super.didUpdateWidget(old);
    if (listEquals(old.slices, widget.slices)) return;
    if (_selected != null && _selected! >= widget.slices.length) {
      _selected = _previous = null;
    }
    if (!_reduceMotion) _reveal.forward(from: 0);
  }

  @override
  void dispose() {
    _reveal.dispose();
    _pop.dispose();
    super.dispose();
  }

  void _select(int? index) {
    final next = index == _selected ? null : index;
    if (next == _selected) return;
    setState(() {
      _previous = _selected;
      _selected = next;
    });
    if (_reduceMotion) {
      _pop.value = 1;
    } else {
      _pop.forward(from: 0);
    }
    VibrationSettings.selectionClick();
    widget.onSelect?.call(next);
  }

  /// How strongly slice [i] is drawn when [selected] is the selection.
  double _alpha(int? selected, int i) =>
      selected == null || selected == i ? 1 : .3;

  String _share(double value, double total) {
    if (total <= 0) return '0%';
    final share = value / total * 100;
    return share > 0 && share < 1 ? '<1%' : '${share.round()}%';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = ChartPalette.of(context);
    final scaler = MediaQuery.textScalerOf(context);
    final captionStyle = chartLabelStyle(context)
        .copyWith(fontWeight: FontWeight.w600);
    final slices = widget.slices;
    final format = widget.formatValue;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 320.0;
        final g = _Geometry.of(
          size: Size(width, widget.height),
          slices: slices,
          thickness: widget.thickness,
          caption: measureChartText('100%', captionStyle, scaler),
        );
        // The sweep/pop only changes paint and opacity. Keep text, icons and
        // tap targets out of its per-frame build/layout work.
        final badges = {
          for (final callout in g.callouts)
            callout.index: _Badge(
              entry: slices[callout.index],
              share: _share(slices[callout.index].value, g.total),
              selected: _selected == callout.index,
              captionStyle: captionStyle.copyWith(
                color: theme.colorScheme.onSurface,
              ),
              onTap: () => _select(callout.index),
              child: widget.badgeBuilder?.call(context, callout.index),
            ),
        };
        return Semantics(
          label: [
            ?widget.centerLabel,
            for (final slice in slices)
              if (slice.value > 0)
                '${slice.label}: ${format == null ? '' : '${format(slice.value)}, '}${_share(slice.value, g.total)}',
          ].join('; '),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (details) => _select(g.sliceAt(details.localPosition)),
            child: SizedBox(
              width: width,
              height: widget.height,
              child: AnimatedBuilder(
                animation: Listenable.merge([_reveal, _pop]),
                child: _center(context, g),
                builder: (context, center) {
                  final reveal = Curves.easeOutCubic.transform(_reveal.value);
                  final labels = const Interval(
                    .55,
                    1,
                    curve: Curves.easeOut,
                  ).transform(_reveal.value);
                  final t = Curves.easeOutCubic.transform(_pop.value);
                  final alphas = [
                    for (var i = 0; i < slices.length; i++)
                      lerpDouble(
                        _alpha(_previous, i),
                        _alpha(_selected, i),
                        t,
                      )!,
                  ];
                  final explode = [
                    for (var i = 0; i < slices.length; i++)
                      lerpDouble(
                        _previous == i ? 1 : 0,
                        _selected == i ? 1 : 0,
                        t,
                      )!,
                  ];
                  final hole = g.radius - widget.thickness;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _CalloutDonutPainter(
                            geometry: g,
                            slices: slices,
                            thickness: widget.thickness,
                            reveal: reveal,
                            lines: labels,
                            alphas: alphas,
                            explode: explode,
                            track: palette.track,
                          ),
                        ),
                      ),
                      Positioned(
                        left: g.center.dx - hole * .85,
                        top: g.center.dy - hole * .72,
                        width: hole * 1.7,
                        height: hole * 1.44,
                        child: IgnorePointer(
                          child: Center(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: center,
                            ),
                          ),
                        ),
                      ),
                      for (final callout in g.callouts)
                        Positioned(
                          left: g.badgeCenter(callout).dx - g.boxWidth / 2,
                          top: g.badgeCenter(callout).dy - _Geometry.badge / 2,
                          width: g.boxWidth,
                          child: Opacity(
                            opacity: labels * alphas[callout.index],
                            child: badges[callout.index],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _center(BuildContext context, _Geometry g) {
    final text = Theme.of(context).textTheme;
    final selected = _selected;
    final format = widget.formatValue;
    final Widget content;
    if (selected != null && selected < widget.slices.length) {
      final slice = widget.slices[selected];
      content = Column(
        key: ValueKey(selected),
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            slice.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: text.bodySmall,
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              format == null
                  ? _share(slice.value, g.total)
                  : format(slice.value),
              style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (format != null)
            Text(
              _share(slice.value, g.total),
              style: text.labelMedium?.copyWith(
                color: slice.color,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      );
    } else {
      content = Column(
        key: const ValueKey('total'),
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.centerLabel != null)
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                widget.centerLabel!,
                style: text.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
          if (widget.centerCaption != null)
            Text(
              widget.centerCaption!,
              style: text.bodySmall,
              textAlign: TextAlign.center,
            ),
        ],
      );
    }
    return AnimatedSwitcher(
      duration: _reduceMotion
          ? Duration.zero
          : const Duration(milliseconds: 180),
      child: content,
    );
  }
}

/// One slice's badge: its mark in a tinted ring of the slice's colour, with
/// the share on a small tag overlapping its bottom edge.
class _Badge extends StatelessWidget {
  const _Badge({
    required this.entry,
    required this.share,
    required this.selected,
    required this.captionStyle,
    required this.onTap,
    this.child,
  });
  final ChartEntry entry;
  final String share;
  final bool selected;
  final TextStyle captionStyle;
  final VoidCallback onTap;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    return Semantics(
      button: true,
      selected: selected,
      label: '${entry.label}, $share',
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: AnimatedScale(
          scale: selected ? 1.12 : 1,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOutBack,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: _Geometry.badge,
                height: _Geometry.badge,
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color.alphaBlend(
                    entry.color.withValues(alpha: .12),
                    surface,
                  ),
                  border: Border.all(
                    color: entry.color,
                    width: selected ? 2 : 1.4,
                  ),
                ),
                child:
                    child ??
                    Center(
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: entry.color,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
              ),
              Transform.translate(
                offset: const Offset(0, -_Geometry.tagOverlap),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5),
                  decoration: BoxDecoration(
                    color: surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: entry.color.withValues(alpha: .6),
                    ),
                  ),
                  child: Text(share, maxLines: 1, style: captionStyle),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Callout {
  _Callout(this.index, this.angle);
  final int index;

  /// Where on the oval the badge sits, in the ring's angle convention.
  double angle;
}

/// Where everything goes for one size: the ring, each slice's angles, and the
/// badges spread around an oval outside it without overlapping.
class _Geometry {
  _Geometry._({
    required this.size,
    required this.center,
    required this.radius,
    required this.thickness,
    required this.total,
    required this.starts,
    required this.sweeps,
    required this.boxWidth,
    required this.orbit,
    required this.callouts,
  });

  static const badge = 34.0, tagOverlap = 7.0, gap = 14.0;

  factory _Geometry.of({
    required Size size,
    required List<ChartEntry> slices,
    required double thickness,
    required Size caption,
  }) {
    final boxWidth = math.max(badge, caption.width + 12);
    // Below a badge's centre: the rest of its circle, then the share tag.
    final below = badge / 2 - tagOverlap + caption.height + 2;
    final above = badge / 2;
    final center = Offset(
      size.width / 2,
      size.height / 2 + (above - below) / 2,
    );
    final ry = (size.height - above - below) / 2 - 2;
    final radius = math
        .min(ry - gap - badge / 2, size.width / 2 - boxWidth - gap)
        .clamp(thickness + 28, 130.0);
    final orbit = Size(
      math.min(
        size.width / 2 - boxWidth / 2 - 2,
        radius + gap + badge / 2 + 24,
      ),
      math.max(ry, radius + gap + badge / 2),
    );

    final total = slices.fold<double>(0, (s, e) => s + math.max(0, e.value));
    final starts = <double>[], sweeps = <double>[];
    var angle = -math.pi / 2;
    for (final slice in slices) {
      final sweep = total <= 0 || slice.value <= 0
          ? 0.0
          : slice.value / total * math.pi * 2;
      starts.add(angle);
      sweeps.add(sweep);
      angle += sweep;
    }

    // As many badges as fit around the oval, biggest slices first.
    final minDistance = math.max(boxWidth, badge + caption.height) + 6;
    final perimeter =
        math.pi *
        2 *
        math.sqrt(
          (orbit.width * orbit.width + orbit.height * orbit.height) / 2,
        );
    final room = math.max(1, (perimeter / minDistance).floor());
    final chosen = [
      for (var i = 0; i < slices.length; i++)
        if (sweeps[i] > 0) i,
    ]..sort((a, b) => slices[b].value.compareTo(slices[a].value));
    final callouts = [
      for (final i in chosen.take(room)) _Callout(i, starts[i] + sweeps[i] / 2),
    ]..sort((a, b) => a.angle.compareTo(b.angle));

    final geometry = _Geometry._(
      size: size,
      center: center,
      radius: radius,
      thickness: thickness,
      total: total,
      starts: starts,
      sweeps: sweeps,
      boxWidth: boxWidth,
      orbit: orbit,
      callouts: callouts,
    );
    geometry._spread(minDistance);
    return geometry;
  }

  final Size size;
  final Offset center;
  final double radius, thickness, total, boxWidth;
  final List<double> starts, sweeps;

  /// The oval badge centres sit on, as its two radii.
  final Size orbit;
  final List<_Callout> callouts;

  Offset _onOrbit(double angle) =>
      center +
      Offset(math.cos(angle) * orbit.width, math.sin(angle) * orbit.height);

  Offset badgeCenter(_Callout callout) => _onOrbit(callout.angle);

  Offset direction(double angle) => Offset(math.cos(angle), math.sin(angle));
  double mid(int i) => starts[i] + sweeps[i] / 2;

  /// Where a slice's leader starts: as near its badge as the slice allows.
  double anchorAngle(_Callout callout) {
    final i = callout.index;
    final inset = math.min(sweeps[i] * .2, .12);
    var angle = callout.angle;
    // Compare on the same turn as the slice.
    while (angle < starts[i] - math.pi) {
      angle += math.pi * 2;
    }
    while (angle > starts[i] + sweeps[i] + math.pi) {
      angle -= math.pi * 2;
    }
    return angle.clamp(starts[i] + inset, starts[i] + sweeps[i] - inset);
  }

  /// Nudges neighbouring badges apart along the oval until none overlap,
  /// keeping each as close to its slice as it can.
  void _spread(double minDistance) {
    final n = callouts.length;
    if (n < 2) return;
    final mean = (orbit.width + orbit.height) / 2;
    for (var pass = 0; pass < 300; pass++) {
      var moved = false;
      for (var k = 0; k < n; k++) {
        final a = callouts[k], b = callouts[(k + 1) % n];
        final distance = (_onOrbit(a.angle) - _onOrbit(b.angle)).distance;
        if (distance >= minDistance - .5) continue;
        final push = math.max(minDistance - distance, 1) / mean / 2;
        a.angle -= push;
        b.angle += push;
        moved = true;
      }
      if (!moved) break;
    }
  }

  /// The slice under [position], or null for the hole or outside the ring.
  int? sliceAt(Offset position, {double slop = 10}) {
    final offset = position - center;
    final distance = offset.distance;
    if (total <= 0 || distance > radius + slop) return null;
    if (distance < radius - thickness - slop) return null;
    var angle = math.atan2(offset.dy, offset.dx);
    if (angle < -math.pi / 2) angle += math.pi * 2;
    for (var i = 0; i < sweeps.length; i++) {
      if (sweeps[i] > 0 &&
          angle >= starts[i] &&
          angle < starts[i] + sweeps[i]) {
        return i;
      }
    }
    return null;
  }
}

class _CalloutDonutPainter extends CustomPainter {
  _CalloutDonutPainter({
    required this.geometry,
    required this.slices,
    required this.thickness,
    required this.reveal,
    required this.lines,
    required this.alphas,
    required this.explode,
    required this.track,
  });
  final _Geometry geometry;
  final List<ChartEntry> slices;
  final double thickness, reveal, lines;
  final List<double> alphas, explode;
  final Color track;

  static const _pop = 6.0;

  @override
  void paint(Canvas canvas, Size size) {
    final g = geometry;
    final rect = Rect.fromCircle(
      center: g.center,
      radius: g.radius - thickness / 2,
    );
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = thickness;
    canvas.drawArc(rect, 0, math.pi * 2, false, ring..color = track);
    if (g.total <= 0) return;

    final limit = -math.pi / 2 + reveal * math.pi * 2;
    // A 2px separator where the eye reads the boundary: the ring's middle.
    final gap = 2 / rect.width * 2;
    for (var i = 0; i < slices.length; i++) {
      final sweep = math.min(g.sweeps[i], limit - g.starts[i]);
      if (sweep <= 0) continue;
      final shift = g.direction(g.mid(i)) * (explode[i] * _pop);
      canvas.drawArc(
        rect.shift(shift),
        g.starts[i],
        math.max(0, sweep - math.min(gap, sweep * .12)),
        false,
        ring
          ..color = slices[i].color.withValues(alpha: alphas[i])
          ..strokeWidth = thickness + explode[i] * 4,
      );
    }

    if (lines <= 0) return;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final fill = Paint()..style = PaintingStyle.fill;
    for (final callout in g.callouts) {
      final i = callout.index;
      final shift = g.direction(g.mid(i)) * (explode[i] * _pop);
      final anchor =
          g.center +
          g.direction(g.anchorAngle(callout)) * (g.radius + 4) +
          shift;
      final badge = g.badgeCenter(callout);
      final toBadge = badge - anchor;
      final length = toBadge.distance;
      if (length < _Geometry.badge / 2 + 10) continue;
      final end = badge - toBadge / length * (_Geometry.badge / 2 + 3);
      final color = slices[i].color.withValues(alpha: .85 * lines * alphas[i]);
      canvas.drawLine(end, anchor, stroke..color = color);
      // The arrowhead points into the slice the badge is naming.
      final unit = -toBadge / length;
      final base = anchor - unit * 6;
      final across = Offset(-unit.dy, unit.dx) * 3.5;
      canvas.drawPath(
        Path()
          ..moveTo(anchor.dx, anchor.dy)
          ..lineTo(base.dx + across.dx, base.dy + across.dy)
          ..lineTo(base.dx - across.dx, base.dy - across.dy)
          ..close(),
        fill..color = color,
      );
    }
  }

  @override
  bool shouldRepaint(_CalloutDonutPainter old) =>
      old.reveal != reveal ||
      old.lines != lines ||
      old.thickness != thickness ||
      old.track != track ||
      old.geometry.size != geometry.size ||
      !listEquals(old.alphas, alphas) ||
      !listEquals(old.explode, explode) ||
      !listEquals(old.slices, slices);
}
