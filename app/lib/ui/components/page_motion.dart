import 'package:flutter/material.dart';

/// The page transitions used across the app.
///
/// Every screen has the same background, so the background never moves:
/// only the content does. Opening a page, its background fades in over the
/// old one (the same picture, so nothing seems to change) while the old
/// content drifts aside and fades out, and the new content glides in a short
/// way from the side and fades in. Going back plays it the other way.
///
/// Nothing slides at the page level, so no edge ever opens onto the empty
/// window behind.
abstract final class PageMotion {
  static const duration = Duration(milliseconds: 450);
  static const reverseDuration = Duration(milliseconds: 380);

  /// The whole page, background included, fades in over the first half of
  /// opening, and out over the first part of going back (this runs from 1 to
  /// 0). The backgrounds match, so only the content shows these fades: the
  /// content beneath is hidden gradually rather than at once, giving an even
  /// crossfade. The content does its own fade inside ([PageMotionContent]).
  static const pageIn = Interval(0, 0.55, curve: Curves.easeInOut);
  static const pageOutBack = Interval(0.4, 1, curve: Curves.easeInOut);

  /// How far, as a share of the width, the arriving content travels, and how
  /// far the covered content drifts the other way.
  static const contentShift = 0.18;
  static const coveredShift = 0.08;

  /// Content moving: quick to start, gentle to stop, both ways. As reverse
  /// curves (they run from 1 down to 0) the ease-in curves also start quick.
  static const glide = Curves.easeOutCubic;
  static const glideBack = Curves.easeInCubic;

  /// The content fades are slow and even, easing in and out, so nothing
  /// appears or disappears at once. Arriving content fades in across most of
  /// the move; leaving content fades over the first part of going back.
  static const contentIn = Interval(0.1, 0.9, curve: Curves.easeInOut);
  static const contentOutBack = Interval(0.4, 1, curve: Curves.easeInOut);

  /// Covered content fades out over the first part of the move; uncovered
  /// (going back, this runs from 1 to 0) it fades back in across most of it.
  static const coveredOut = Interval(0, 0.6, curve: Curves.easeInOut);
  static const uncoveredIn = Interval(0.1, 0.9, curve: Curves.easeInOut);

  // Switching tabs: a short glide with a crossfade. The tabs share one
  // backdrop, so they can fade without the window showing through.
  // A short glide that eases in and out, with the same timing as the tab
  // bar's pill, so page and pill move as one. The fades are eased at both
  // ends and staggered: the old page is mostly gone before the new one is
  // mostly there, so the two never sit half-visible on top of each other.
  static const tabDuration = Duration(milliseconds: 400);
  static const tabEnterShift = 0.06;
  static const tabLeaveShift = 0.04;
  static const tabSlide = Curves.easeInOutCubic;
  static const tabFadeIn = Interval(.15, .8, curve: Curves.easeInOut);
  static const tabFadeOut = Interval(0, .5, curve: Curves.easeInOut);
}

/// Uses [PageMotion] for every page route, the app's first page included, in
/// place of the platform's own transitions.
class PageMotionTransitionsBuilder extends PageTransitionsBuilder {
  const PageMotionTransitionsBuilder();

  @override
  Duration get transitionDuration => PageMotion.duration;

  @override
  Duration get reverseTransitionDuration => PageMotion.reverseDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => PageMotionTransition(animation: animation, child: child);
}

/// The page-level part of [PageMotion]: the page fades in over the one
/// beneath, and out again going back. It never moves.
class PageMotionTransition extends StatefulWidget {
  const PageMotionTransition({
    super.key,
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  @override
  State<PageMotionTransition> createState() => _PageMotionTransitionState();
}

class _PageMotionTransitionState extends State<PageMotionTransition> {
  late CurvedAnimation _fade;

  @override
  void initState() {
    super.initState();
    _curve();
  }

  @override
  void didUpdateWidget(PageMotionTransition old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation) {
      _fade.dispose();
      _curve();
    }
  }

  void _curve() => _fade = CurvedAnimation(
    parent: widget.animation,
    curve: PageMotion.pageIn,
    reverseCurve: PageMotion.pageOutBack,
  );

  @override
  void dispose() {
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FadeTransition(
    opacity: MediaQuery.disableAnimationsOf(context)
        ? kAlwaysCompleteAnimation
        : _fade,
    child: widget.child,
  );
}

/// The moving part of [PageMotion]: wrap a page's content (not its
/// background) in it. The content glides in from the side and fades in as
/// its page arrives; drifts aside and fades out while another page covers
/// it; and plays each of those backwards going back.
///
/// Light to run: the content is kept as one painted picture, and only its
/// place and transparency change from frame to frame; nothing rebuilds.
class PageMotionContent extends StatefulWidget {
  const PageMotionContent({super.key, this.travel = 1, required this.child});
  final Widget child;

  /// How far this part travels, as a share of the content's travel. A
  /// header uses less, so it moves gently while the content glides past it.
  final double travel;

  @override
  State<PageMotionContent> createState() => _PageMotionContentState();
}

class _PageMotionContentState extends State<PageMotionContent> {
  ModalRoute<Object?>? _route;
  final _curves = <CurvedAnimation>[];
  Animation<double>? _shown;
  Animation<double>? _uncovered;
  Animation<Offset>? _arrive;
  Animation<Offset>? _drift;
  double _side = 1;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final side = Directionality.of(context) == TextDirection.rtl ? -1.0 : 1.0;
    final route = ModalRoute.of(context);
    if (route == _route && side == _side) return;
    _route = route;
    _side = side;
    _curveFor(route, side);
  }

  @override
  void didUpdateWidget(PageMotionContent old) {
    super.didUpdateWidget(old);
    if (old.travel != widget.travel) _curveFor(_route, _side);
  }

  void _curveFor(ModalRoute<Object?>? route, double side) {
    _dispose();
    final animation = route?.animation;
    final covered = route?.secondaryAnimation;
    if (animation == null || covered == null) return;
    CurvedAnimation curve(Animation<double> parent, Curve c, Curve back) {
      final curved = CurvedAnimation(
        parent: parent,
        curve: c,
        reverseCurve: back,
      );
      _curves.add(curved);
      return curved;
    }

    _shown = curve(animation, PageMotion.contentIn, PageMotion.contentOutBack);
    _uncovered = ReverseAnimation(
      curve(covered, PageMotion.coveredOut, PageMotion.uncoveredIn),
    );
    _arrive = Tween(
      begin: Offset(PageMotion.contentShift * widget.travel * side, 0),
      end: Offset.zero,
    ).animate(curve(animation, PageMotion.glide, PageMotion.glideBack));
    _drift = Tween(
      begin: Offset.zero,
      end: Offset(-PageMotion.coveredShift * widget.travel * side, 0),
    ).animate(curve(covered, PageMotion.glide, PageMotion.glideBack));
  }

  void _dispose() {
    for (final curve in _curves) {
      curve.dispose();
    }
    _curves.clear();
    _shown = _uncovered = null;
    _arrive = _drift = null;
  }

  @override
  void dispose() {
    _dispose();
    super.dispose();
  }

  static const _still = AlwaysStoppedAnimation(Offset.zero);

  @override
  Widget build(BuildContext context) {
    final off = MediaQuery.disableAnimationsOf(context) || _shown == null;
    // The structure stays the same in every case, so the content keeps its
    // state; at rest these add no layers.
    return SlideTransition(
      position: off ? _still : _drift!,
      child: SlideTransition(
        position: off ? _still : _arrive!,
        child: FadeTransition(
          opacity: off ? kAlwaysCompleteAnimation : _shown!,
          child: FadeTransition(
            opacity: off ? kAlwaysCompleteAnimation : _uncovered!,
            child: RepaintBoundary(child: widget.child),
          ),
        ),
      ),
    );
  }
}
