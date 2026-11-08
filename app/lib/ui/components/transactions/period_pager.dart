import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart' show FrictionSimulation;

import 'period.dart';

/// The period strip ("Sep 2026  Oct 2026  Nov 2026") over pages that swipe
/// between periods. All time and a custom range are a single page under a
/// plain label. Tapping the selected period calls [onSelectRange].
///
/// Expands to fill its parent; put it in an [Expanded].
class PeriodPager extends StatefulWidget {
  const PeriodPager({
    super.key,
    required this.controller,
    required this.pageBuilder,
    required this.onSelectRange,
  });
  final PeriodController controller;

  /// Builds the page for the period containing the given date.
  final Widget Function(BuildContext context, DateTime anchor) pageBuilder;
  final VoidCallback onSelectRange;

  @override
  State<PeriodPager> createState() => _PeriodPagerState();
}

class _PeriodPagerState extends State<PeriodPager>
    with TickerProviderStateMixin {
  static const _pageCenter = 20000;
  static const _stripTabPadding = 10.0;

  PeriodController get _period => widget.controller;
  late final PageController _pageController;
  final _stripLabelSizes = <String, Size>{};

  /// How far (in periods) the user has swiped the strip away from the
  /// selected period to browse other ranges without switching to them.
  late final _stripScroll = AnimationController.unbounded(vsync: this);
  late final _stripPosition = AnimationController.unbounded(vsync: this);
  double _focusedTabExtent = 1;
  late int _resets = _period.resets;
  late PeriodKind _kind = _period.kind;

  bool get _pagingEnabled => _period.kind.pages;
  int get _pageItemCount => _pagingEnabled ? _pageCenter * 2 + 1 : 1;

  @override
  void initState() {
    super.initState();
    _pageController = PageController(
      initialPage: _pagingEnabled ? _pageCenter + _period.offset : 0,
    );
    _stripPosition.value = _period.offset.toDouble();
    _period.addListener(_onPeriodChanged);
  }

  @override
  void didUpdateWidget(covariant PeriodPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_onPeriodChanged);
      widget.controller.addListener(_onPeriodChanged);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Label widths depend on the theme's font and the text scale.
    _stripLabelSizes.clear();
  }

  @override
  void dispose() {
    _period.removeListener(_onPeriodChanged);
    _pageController.dispose();
    _stripScroll.dispose();
    _stripPosition.dispose();
    super.dispose();
  }

  /// A new kind or base period starts the strip and pages over.
  void _onPeriodChanged() {
    if (_period.resets == _resets && _period.kind == _kind) {
      setState(() {});
      return;
    }
    _resets = _period.resets;
    _kind = _period.kind;
    _stripScroll.value = 0;
    _stripPosition.value = 0;
    setState(() {});
    if (_pageController.hasClients) {
      _pageController.jumpToPage(_pagingEnabled ? _pageCenter : 0);
    }
  }

  Size _stripLabelSize(BuildContext context, String label) =>
      _stripLabelSizes.putIfAbsent(label, () {
        // Measured at the selected (bold) weight so a tab's slot never has
        // to change size as it gains or loses emphasis.
        final painter = TextPainter(
          text: TextSpan(
            text: label,
            style: DefaultTextStyle.of(context).style.merge(
              const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          maxLines: 1,
        )..layout();
        final size = Size(painter.width.ceilToDouble(), painter.height);
        painter.dispose();
        return size;
      });

  // Swiping the strip only browses it (with momentum); the selected period
  // changes when a tab is tapped or the pages themselves are swiped.
  void _onStripDragStart(DragStartDetails details) => _stripScroll.stop();

  void _onStripDragUpdate(DragUpdateDetails details) =>
      _stripScroll.value -= (details.primaryDelta ?? 0) / _focusedTabExtent;

  void _onStripDragEnd(DragEndDetails details) {
    final velocity = -(details.primaryVelocity ?? 0) / _focusedTabExtent;
    if (velocity == 0) return;
    _stripScroll.animateWith(
      FrictionSimulation(0.135, _stripScroll.value, velocity),
    );
  }

  /// Glides a browsed strip back so the selected period is centered again.
  void _recenterStrip() {
    if (_stripScroll.value == 0) return;
    _stripScroll.animateTo(
      0,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  /// Slides the swipeable content by [offset] periods with a Material-style
  /// ease-out animation, keeping the period strip in sync via [_onPageChanged].
  void _goToOffset(int offset) {
    if (!_pagingEnabled || !_pageController.hasClients) return;
    // Runs alongside the page animation with the same timing, so a tapped
    // tab slides smoothly from where it was into the center.
    _recenterStrip();
    if (offset == 0) return;
    final current =
        (_pageController.page ?? _pageController.initialPage.toDouble())
            .round();
    _pageController.animateToPage(
      current + offset,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
  }

  void _onPageChanged(int page) {
    _period.showOffset(page - _pageCenter);
    // PageView commits to the next page at the halfway threshold. Keep the
    // strip still until then, and let its transition finish independently
    // of the finger (including when a swipe reverses).
    _stripPosition.animateTo(
      _period.offset.toDouble(),
      duration: const Duration(milliseconds: 420),
      curve: Curves.easeInOutSine,
    );
    // Swiping the pages while the strip is browsed elsewhere recenters it.
    if (!_stripScroll.isAnimating) _recenterStrip();
  }

  @override
  Widget build(BuildContext context) => Column(
    children: [
      _buildPeriodSwitcher(context),
      Expanded(
        child: PageView.builder(
          controller: _pageController,
          physics: _pagingEnabled
              ? const BouncingScrollPhysics()
              : const NeverScrollableScrollPhysics(),
          onPageChanged: _onPageChanged,
          itemCount: _pageItemCount,
          itemBuilder: (context, index) => widget.pageBuilder(
            context,
            _pagingEnabled
                ? _period.dateAt(index - _pageCenter)
                : _period.anchor,
          ),
        ),
      ),
    ],
  );

  Widget _buildPeriodSwitcher(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final muted = scheme.onSurfaceVariant;

    if (_period.kind == PeriodKind.all) {
      return SizedBox(
        key: const Key('transaction-period'),
        height: 40,
        child: Center(
          child: InkWell(
            onTap: widget.onSelectRange,
            borderRadius: BorderRadius.circular(10),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Text(
                _period.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (!_pagingEnabled) {
      return InkWell(
        key: const Key('transaction-period'),
        onTap: widget.onSelectRange,
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  _period.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleMedium
                      ?.copyWith(fontSize: 15),
                ),
              ),
              const SizedBox(width: 5),
              Icon(Icons.keyboard_arrow_down_rounded, size: 19, color: muted),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      key: const Key('transaction-period'),
      height: 40,
      child: AnimatedBuilder(
        animation: Listenable.merge([_stripPosition, _stripScroll]),
        builder: (context, _) {
          final distanceToNow =
              _period.offsetBetween(_period.baseAnchor, DateTime.now()) -
              (_stripPosition.value + _stripScroll.value);
          final showJump = distanceToNow.abs() > .5;
          final jumpLeft = distanceToNow < 0;
          final jumpButton = IconButton(
            tooltip: 'Jump to current period',
            onPressed: () => _goToOffset(
              _period.offsetBetween(_period.anchor, DateTime.now()),
            ),
            icon: Icon(
              jumpLeft ? Icons.skip_previous_rounded : Icons.skip_next_rounded,
            ),
            visualDensity: VisualDensity.compact,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              LayoutBuilder(
                builder: (context, constraints) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragStart: _onStripDragStart,
                  onHorizontalDragUpdate: _onStripDragUpdate,
                  onHorizontalDragEnd: _onStripDragEnd,
                  // The tabs fade out under the jump button rather than it
                  // carrying a backdrop, which would need to match whatever
                  // the header is painted with.
                  child: TweenAnimationBuilder<double>(
                    tween: Tween(end: showJump ? 1 : 0),
                    duration: const Duration(milliseconds: 180),
                    child: _buildStrip(
                      context,
                      constraints.maxWidth,
                      scheme,
                      muted,
                    ),
                    builder: (context, reveal, strip) => ShaderMask(
                      blendMode: BlendMode.dstIn,
                      shaderCallback: (bounds) {
                        final w = bounds.width;
                        final fade = math.min(20 / w, .5);
                        // Hidden under the button, then the usual edge fade.
                        final hide = math.min(28 * reveal / w, .5 - fade);
                        final left = jumpLeft ? hide : 0.0;
                        final right = jumpLeft ? 0.0 : hide;
                        return LinearGradient(
                          colors: const [
                            Colors.transparent,
                            Colors.transparent,
                            Colors.white,
                            Colors.white,
                            Colors.transparent,
                            Colors.transparent,
                          ],
                          stops: [
                            0,
                            left,
                            left + fade,
                            1 - right - fade,
                            1 - right,
                            1,
                          ],
                        ).createShader(bounds);
                      },
                      child: strip,
                    ),
                  ),
                ),
              ),
              Align(
                alignment: jumpLeft
                    ? Alignment.centerLeft
                    : Alignment.centerRight,
                child: IgnorePointer(
                  ignoring: !showJump,
                  child: AnimatedOpacity(
                    opacity: showJump ? 1 : 0,
                    duration: const Duration(milliseconds: 180),
                    child: jumpButton,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  /// Lays out visible tabs around the independently animated strip position,
  /// plus any browsing scroll. Page drags only trigger this animation once
  /// they cross the selection threshold.
  Widget _buildStrip(
    BuildContext context,
    double viewportWidth,
    ColorScheme scheme,
    Color muted,
  ) {
    final live = _stripPosition.value;
    final view = live + _stripScroll.value;
    final base = view.floor();
    final t = view - base;
    final labels = <int, String>{};
    final sizes = <int, Size>{};
    // Tab centers, relative to the center of the `base` tab.
    final centers = <int, double>{};
    void measure(int offset) {
      final label = _period.itemLabel(_period.dateAt(offset));
      labels[offset] = label;
      sizes[offset] = _stripLabelSize(context, label);
    }

    double step(int left, int right) =>
        (sizes[left]!.width + sizes[right]!.width) / 2 + _stripTabPadding * 2;

    measure(base);
    measure(base + 1);
    centers[base] = 0;
    centers[base + 1] = step(base, base + 1);
    final focus = centers[base + 1]! * t;
    final half = viewportWidth / 2;
    bool visible(int offset) =>
        (centers[offset]! - focus).abs() -
            sizes[offset]!.width / 2 -
            _stripTabPadding <
        half;
    for (var offset = base + 2; offset < base + 60; offset++) {
      measure(offset);
      centers[offset] = centers[offset - 1]! + step(offset - 1, offset);
      if (!visible(offset)) break;
    }
    for (var offset = base - 1; offset > base - 60; offset--) {
      measure(offset);
      centers[offset] = centers[offset + 1]! - step(offset, offset + 1);
      if (!visible(offset)) break;
    }

    final baseWidth = sizes[base]!.width;
    _focusedTabExtent =
        baseWidth +
        (sizes[base + 1]!.width - baseWidth) * t +
        _stripTabPadding * 2;

    // Each label owns its bar throughout the transition. Their eased
    // collapse/expansion overlaps, avoiding a midpoint position switch.
    Widget indicator(int offset) {
      final emphasis = (1 - (offset - live).abs()).clamp(0.0, 1.0);
      final progress = ((emphasis - .2) / .8).clamp(0.0, 1.0);
      final extent = progress * progress * (3 - 2 * progress);
      final width = sizes[offset]!.width * extent;
      return Positioned(
        key: ValueKey('transaction-period-indicator-$offset'),
        left: half + centers[offset]! - focus - width / 2,
        width: width,
        bottom: 2,
        height: 4,
        child: Opacity(
          opacity: extent,
          child: ClipPath(
            clipper: const _PeriodIndicatorClipper(),
            child: ColoredBox(color: scheme.onSurface),
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: viewportWidth,
        height: sizes[base]!.height + 16,
        child: Stack(
          children: [
            for (final offset in centers.keys)
              if (visible(offset))
                Positioned(
                  key: ValueKey('transaction-period-label-$offset'),
                  left:
                      half +
                      centers[offset]! -
                      focus -
                      sizes[offset]!.width / 2 -
                      _stripTabPadding,
                  top: 0,
                  bottom: 0,
                  width: sizes[offset]!.width + _stripTabPadding * 2,
                  child: _buildStripTab(
                    offset,
                    labels[offset]!,
                    (1 - (offset - live).abs()).clamp(0.0, 1.0),
                    scheme,
                    muted,
                  ),
                ),
            for (final offset in centers.keys)
              if (visible(offset) && (offset - live).abs() < 1)
                indicator(offset),
          ],
        ),
      ),
    );
  }

  /// [emphasis] is 1 for the centered period and fades to 0 one period away,
  /// so the bold/dark styling crossfades between tabs mid-swipe.
  Widget _buildStripTab(
    int offset,
    String label,
    double emphasis,
    ColorScheme scheme,
    Color muted,
  ) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: _stripTabPadding,
      vertical: 8,
    ),
    child: InkWell(
      onTap: () {
        if (offset == _period.offset) {
          widget.onSelectRange();
        } else {
          _goToOffset(offset - _period.offset);
        }
      },
      borderRadius: BorderRadius.circular(10),
      child: Text(
        label,
        maxLines: 1,
        softWrap: false,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.lerp(
            FontWeight.w500,
            FontWeight.w700,
            emphasis,
          ),
          color: Color.lerp(muted, scheme.onSurface, emphasis),
        ),
      ),
    ),
  );
}

class _PeriodIndicatorClipper extends CustomClipper<Path> {
  const _PeriodIndicatorClipper();

  @override
  Path getClip(Size size) {
    final inset = math.min(size.height * 1.2, size.width / 2);
    return Path()
      ..moveTo(inset, 0)
      ..lineTo(size.width - inset, 0)
      ..cubicTo(
        size.width - inset * .35,
        0,
        size.width - inset * .65,
        size.height,
        size.width,
        size.height,
      )
      ..lineTo(0, size.height)
      ..cubicTo(inset * .65, size.height, inset * .35, 0, inset, 0)
      ..close();
  }

  @override
  bool shouldReclip(_PeriodIndicatorClipper oldClipper) => false;
}
