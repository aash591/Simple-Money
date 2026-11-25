import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// One option of a [SegmentedPill]. [tone] colours the label and icon while
/// the segment is selected, such as green for Add and red for Subtract.
class PillSegment<T extends Object> {
  const PillSegment(
    this.value,
    this.label, {
    this.icon,
    this.trailingIcon,
    this.tone,
  });
  final T value;
  final String label;
  final IconData? icon;

  /// Shown after the label, such as an arrow to the next step.
  final IconData? trailingIcon;
  final Color? tone;
}

/// The app's segmented control: equal-width segments in a soft pill track,
/// with a thumb that slides to the selected one, in the manner of iOS.
///
/// A null [value] shows no thumb, for a question not answered yet. A null
/// [onChanged] dims the control and keeps the selection.
class SegmentedPill<T extends Object> extends StatelessWidget {
  const SegmentedPill({
    super.key,
    required this.segments,
    required this.value,
    required this.onChanged,
  });
  final List<PillSegment<T>> segments;
  final T? value;
  final ValueChanged<T>? onChanged;

  @override
  Widget build(BuildContext context) {
    assert(segments.length >= 2);
    assert(segments.map((s) => s.value).toSet().length == segments.length);
    final index = segments.indexWhere((s) => s.value == value);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: index < 0 ? 0 : index.toDouble()),
      duration: _duration(context),
      curve: Curves.easeOutCubic,
      builder: (context, position, _) => _PillTrack(
        segments: segments,
        selected: index,
        position: position,
        onTap: onChanged == null
            ? null
            : (i) {
                if (i == index) return;
                HapticFeedback.selectionClick();
                onChanged!(segments[i].value);
              },
      ),
    );
  }
}

/// A [SegmentedPill] driving a [TabController], in place of a [TabBar]: the
/// thumb follows the finger while the [TabBarView] below is swiped.
class SegmentedPillTabBar extends StatelessWidget {
  const SegmentedPillTabBar({
    super.key,
    required this.labels,
    this.icons,
    this.controller,
  });
  final List<String> labels;
  final List<IconData>? icons;

  /// Defaults to the enclosing [DefaultTabController].
  final TabController? controller;

  @override
  Widget build(BuildContext context) {
    final tabs = controller ?? DefaultTabController.of(context);
    assert(tabs.length == labels.length);
    final segments = [
      for (final (i, label) in labels.indexed)
        PillSegment(i, label, icon: icons?[i]),
    ];
    return AnimatedBuilder(
      animation: tabs.animation!,
      builder: (context, _) => _PillTrack(
        segments: segments,
        selected: tabs.index,
        position: tabs.animation!.value,
        onTap: (i) {
          if (i == tabs.index) return;
          HapticFeedback.selectionClick();
          tabs.animateTo(i);
        },
      ),
    );
  }
}

Duration _duration(BuildContext context) =>
    MediaQuery.disableAnimationsOf(context)
    ? Duration.zero
    : const Duration(milliseconds: 240);

/// The track, the thumb at fractional [position], and the segments. A
/// [selected] of -1 hides the thumb.
class _PillTrack<T extends Object> extends StatelessWidget {
  const _PillTrack({
    required this.segments,
    required this.selected,
    required this.position,
    required this.onTap,
  });
  final List<PillSegment<T>> segments;
  final int selected;
  final double position;
  final ValueChanged<int>? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    // Translucent, so the track reads the same on a page, a card or glass.
    final track = dark ? const Color(0x1FFFFFFF) : const Color(0x1F767680);
    final thumb = dark ? const Color(0xFF4A4A4E) : Colors.white;
    final text = theme.colorScheme.onSurface;
    // Dark mode keeps every label bright, the thumb alone marks the choice.
    final muted = dark
        ? text.withValues(alpha: .82)
        : theme.colorScheme.onSurfaceVariant;
    final duration = _duration(context);
    return Opacity(
      opacity: onTap == null ? .5 : 1,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: track,
          borderRadius: BorderRadius.circular(100),
        ),
        child: Padding(
          padding: const EdgeInsets.all(2),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth / segments.length;
              void dragTo(double dx) {
                final i = (dx / width).floor().clamp(0, segments.length - 1);
                final rtl = Directionality.of(context) == TextDirection.rtl;
                onTap!(rtl ? segments.length - 1 - i : i);
              }

              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragUpdate: onTap == null
                    ? null
                    : (d) => dragTo(d.localPosition.dx),
                child: Stack(
                  children: [
                    if (selected >= 0)
                      PositionedDirectional(
                        start: position * width,
                        top: 0,
                        bottom: 0,
                        width: width,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: thumb,
                            // A soft sheen from the top, as on a raised key.
                            gradient: dark
                                ? const LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0xFF5C5C61),
                                      Color(0xFF444448),
                                    ],
                                  )
                                : null,
                            borderRadius: BorderRadius.circular(100),
                            border: Border.all(
                              color: dark
                                  ? Colors.white.withValues(alpha: .08)
                                  : Colors.black.withValues(alpha: .04),
                              width: .5,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: dark ? .25 : .10,
                                ),
                                blurRadius: 6,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                        ),
                      ),
                    Row(
                      children: [
                        for (final (i, segment) in segments.indexed)
                          Expanded(
                            child: _Segment(
                              segment: segment,
                              selected: i == selected,
                              color: i == selected
                                  ? segment.tone ?? text
                                  : muted,
                              duration: duration,
                              onTap: onTap == null ? null : () => onTap!(i),
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Swiping [child] sideways picks the next or previous of [values]: for a
/// page whose content a [SegmentedPill] switches. Vertical scrolling inside
/// is unaffected.
class SegmentSwipe<T extends Object> extends StatelessWidget {
  const SegmentSwipe({
    super.key,
    required this.values,
    required this.value,
    required this.onChanged,
    required this.child,
  });
  final List<T> values;
  final T value;
  final ValueChanged<T> onChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.translucent,
    onHorizontalDragEnd: (details) {
      final velocity = details.primaryVelocity ?? 0;
      if (velocity.abs() < 300) return;
      final rtl = Directionality.of(context) == TextDirection.rtl;
      final step = (velocity < 0) != rtl ? 1 : -1;
      final next = values.indexOf(value) + step;
      if (next < 0 || next >= values.length) return;
      HapticFeedback.selectionClick();
      onChanged(values[next]);
    },
    child: child,
  );
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.segment,
    required this.selected,
    required this.color,
    required this.duration,
    required this.onTap,
  });
  final PillSegment segment;
  final bool selected;
  final Color color;
  final Duration duration;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    inMutuallyExclusiveGroup: true,
    enabled: onTap != null,
    child: GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 32),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (segment.icon != null) ...[
                TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: color),
                  duration: duration,
                  builder: (context, color, _) =>
                      Icon(segment.icon, size: 15, color: color),
                ),
                const SizedBox(width: 5),
              ],
              Flexible(
                child: AnimatedDefaultTextStyle(
                  duration: duration,
                  style: TextStyle(
                    color: color,
                    fontSize: 13,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    letterSpacing: -.1,
                  ),
                  child: Text(
                    segment.label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
              if (segment.trailingIcon != null) ...[
                const SizedBox(width: 4),
                TweenAnimationBuilder<Color?>(
                  tween: ColorTween(end: color),
                  duration: duration,
                  builder: (context, color, _) =>
                      Icon(segment.trailingIcon, size: 14, color: color),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
  );
}
