import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../state/appearance_controller.dart' show AppearanceScope;
import '../theme/app_theme.dart' show AppChrome;

/// Wraps a screen whose main content is a scroll view that starts right at
/// the top of the screen (no fixed app bar above it) so it would otherwise
/// slide straight up under the status bar with a hard "cut" edge once
/// scrolled. This makes the status bar transparent at rest — content shows
/// straight through it — and fades in a tinted scrim behind it as the
/// content scrolls up, tapering out over [_fadeHeight] instead of stopping
/// at a hard seam. Also flips the status bar icon brightness to match the
/// current theme.
///
/// [builder] must apply the given [ScrollController] to the screen's main
/// scroll view, and should pad that view's top by at least [topInset] so
/// content starts below the (invisible, at rest) status bar.
class StatusBarBlurScope extends StatefulWidget {
  const StatusBarBlurScope({super.key, required this.builder});
  final Widget Function(
    BuildContext context,
    ScrollController controller,
    double topInset,
  )
  builder;
  @override
  State<StatusBarBlurScope> createState() => _StatusBarBlurScopeState();
}

class _StatusBarBlurScopeState extends State<StatusBarBlurScope> {
  static const _blendDistance = 32.0;
  final _controller = ScrollController();
  final _blend = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    _blend.dispose();
    super.dispose();
  }

  void _onScroll() {
    _blend.value = (_controller.offset / _blendDistance).clamp(0, 1);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final topInset = MediaQuery.paddingOf(context).top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(
            statusBarColor: Colors.transparent,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarContrastEnforced: false,
            systemNavigationBarIconBrightness: dark
                ? Brightness.light
                : Brightness.dark,
          ),
      child: Stack(
        children: [
          widget.builder(context, _controller, topInset),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _StatusBarScrim(blend: _blend, topInset: topInset),
          ),
        ],
      ),
    );
  }
}

class _StatusBarScrim extends StatelessWidget {
  const _StatusBarScrim({required this.blend, required this.topInset});
  final ValueListenable<double> blend;
  final double topInset;
  static const _fadeHeight = 28.0;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<double>(
    valueListenable: blend,
    builder: (context, blend, _) {
      final totalHeight = topInset + _fadeHeight;
      // At rest there is nothing to draw.
      if (blend == 0) return SizedBox(height: totalHeight);
      // A near-opaque tint rather than a blur: under this much colour a blur
      // can't be seen, but it costs a full-screen backdrop pass (and the
      // fade, a whole extra layer) on every frame the page scrolls.
      // The page's own top colour, so the scrim reads as more page rather
      // than a grey band laid over the backdrop.
      final theme = Theme.of(context);
      // Over a picture a solid band would look like a dark bar; instead the
      // strip frosts what scrolls under it, strongest at the top.
      if (AppearanceScope.maybeOf(context)?.wallpaperPath != null) {
        return IgnorePointer(
          child: _FrostFade(
            height: totalHeight,
            blend: blend,
            tint: theme.scaffoldBackgroundColor,
          ),
        );
      }
      final tint =
          theme.extension<AppChrome>()?.pageTop ?? theme.colorScheme.surface;
      return IgnorePointer(
        child: SizedBox(
          height: totalHeight,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  tint.withValues(alpha: .94 * blend),
                  tint.withValues(alpha: .94 * blend),
                  tint.withValues(alpha: 0),
                ],
                stops: [0, topInset / totalHeight, 1],
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// A fade from blurred to clear in three steps. Each step is a thin strip
/// with its own blur, so a full-height mask layer is never needed; only
/// the status bar's height is ever blurred, and only while scrolled.
class _FrostFade extends StatelessWidget {
  const _FrostFade({
    required this.height,
    required this.blend,
    required this.tint,
  });
  final double height, blend;
  final Color tint;

  @override
  Widget build(BuildContext context) {
    const sigmas = [14.0, 7.0, 3.0];
    final step = height / sigmas.length;
    return SizedBox(
      height: height,
      child: Column(
        children: [
          for (var i = 0; i < sigmas.length; i++)
            SizedBox(
              height: step,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(
                    sigmaX: sigmas[i] * blend,
                    sigmaY: sigmas[i] * blend,
                    tileMode: TileMode.mirror,
                  ),
                  child: ColoredBox(
                    color: tint.withValues(alpha: .34 * blend * (1 - i / 3)),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
