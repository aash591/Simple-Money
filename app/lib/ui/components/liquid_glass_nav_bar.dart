import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../data/device_performance.dart';

/// One tab of a [LiquidGlassNavBar].
class LiquidGlassDestination {
  const LiquidGlassDestination({
    required this.icon,
    required this.selectedIcon,
    required this.label,
  });
  final IconData icon;
  final IconData selectedIcon;
  final String label;
}

/// A floating capsule tab bar made of refracting glass: whatever scrolls
/// behind it bends at the rim, and the selected tab sits in a pill that
/// springs between tabs and turns into a glass droplet while pressed or
/// dragged.
///
/// The look follows the bottom tabs of Kyant's AndroidLiquidGlass. That
/// library draws with Jetpack Compose and can't see Flutter's pixels, so the
/// glass here is its shader ported to a backdrop filter. Where shader filters
/// aren't available (Skia, tests), and on low-end phones, the bar falls back
/// to frosted glass.
///
/// The host [Scaffold] needs `extendBody: true`, or nothing is behind the bar
/// to refract.
class LiquidGlassNavBar extends StatefulWidget {
  const LiquidGlassNavBar({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<LiquidGlassDestination> destinations;

  @override
  State<LiquidGlassNavBar> createState() => _LiquidGlassNavBarState();
}

class _LiquidGlassNavBarState extends State<LiquidGlassNavBar>
    with TickerProviderStateMixin {
  static const _height = 56.0;
  // The gap between the bar's rim and the resting pill, the same on every
  // side: the pill's corners are then concentric with the bar's.
  static const _inset = 2.0;
  static const _margin = EdgeInsets.fromLTRB(16, 8, 16, 10);
  static const _maxWidth = 520.0;
  // Reference proportions: a close-fitting resting pill and a modest raised
  // lens on press. Keep these independent of the tabs' content padding.
  static const _handleHeight = _height - 2 * _inset;

  /// A full semicircle at each end: the bar's radius less the gap between
  /// the two.
  static const _pillRadius = _handleHeight / 2;
  static const _pressedHandleHeight = _height * 1.12;
  static const _pressedScaleX = 1.12;
  static const _pressedScaleY = _pressedHandleHeight / _handleHeight;
  static final _spring = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 420,
    ratio: .78,
  );

  static Future<ui.FragmentProgram>? _program;

  /// The pill's place along the bar, in tabs: 1.5 is halfway between the
  /// second and third.
  late final _position = AnimationController.unbounded(
    vsync: this,
    value: widget.selectedIndex.toDouble(),
  );
  late final _press = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
    reverseDuration: const Duration(milliseconds: 320),
  );

  /// The jelly: how far the whole bar has swollen under a press (0 to 1,
  /// overshooting both ways as it wobbles), and how far a drag has tugged it
  /// sideways, in logical pixels.
  late final _squish = AnimationController.unbounded(vsync: this);
  late final _pull = AnimationController.unbounded(vsync: this);
  static final _wobble = SpringDescription.withDampingRatio(
    mass: 1,
    stiffness: 340,
    ratio: .75,
  );

  /// The pill's own jelly. Its body hangs on a soft spring behind
  /// [_position], so it trails whichever way it is moving and swings past
  /// when that stops. [_lag] is how far behind it is, in tabs.
  late final Ticker _trailTicker = createTicker(_followPosition);
  late double _trail = _position.value;
  double _trailVelocity = 0;
  Duration _trailTime = Duration.zero;
  final _lag = ValueNotifier<double>(0);
  // A small, quickly settling stretch keeps the raised lens feeling soft.
  static const _trailStiffness = 240.0;
  static const _trailDamping = 24.0;
  ui.FragmentShader? _barShader;
  ui.FragmentShader? _pillShader;

  int get _last => widget.destinations.length - 1;

  @override
  void initState() {
    super.initState();
    _position.addListener(_wakeTrail);
    // The lens is a second full backdrop pass on every frame the page moves
    // behind the bar; low-end phones keep the single-pass frosted glass.
    if (ui.ImageFilter.isShaderFilterSupported && !DevicePerformance.lowEnd) {
      _loadShaders();
    }
  }

  Future<void> _loadShaders() async {
    try {
      final program = await (_program ??= ui.FragmentProgram.fromAsset(
        'shaders/liquid_glass.frag',
      ));
      if (!mounted) return;
      setState(() {
        _barShader = program.fragmentShader();
        _pillShader = program.fragmentShader();
      });
    } catch (_) {
      // The frosted fallback stays in place.
    }
  }

  @override
  void didUpdateWidget(LiquidGlassNavBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selectedIndex != oldWidget.selectedIndex) {
      _settleOn(widget.selectedIndex);
    }
  }

  @override
  void dispose() {
    _trailTicker.dispose();
    _position.dispose();
    _lag.dispose();
    _press.dispose();
    _squish.dispose();
    _pull.dispose();
    _barShader?.dispose();
    _pillShader?.dispose();
    super.dispose();
  }

  void _settleOn(int index) {
    if (MediaQuery.disableAnimationsOf(context)) {
      _position.value = index.toDouble();
      return;
    }
    _position.animateWith(
      SpringSimulation(
        _spring,
        _position.value,
        index.toDouble(),
        _position.velocity,
      ),
    );
  }

  void _select(int index) {
    _settleOn(index);
    if (index != widget.selectedIndex) widget.onDestinationSelected(index);
  }

  void _wakeTrail() {
    if (MediaQuery.disableAnimationsOf(context)) {
      _trail = _position.value;
      _trailVelocity = 0;
      _lag.value = 0;
      return;
    }
    if (_trailTicker.isActive) return;
    _trailTime = Duration.zero;
    _trailTicker.start();
  }

  void _followPosition(Duration elapsed) {
    // A frame that took too long must not fling the pill across the bar.
    var left = ((elapsed - _trailTime).inMicroseconds / 1e6).clamp(0.0, .05);
    _trailTime = elapsed;
    while (left > 0) {
      final step = left > .004 ? .004 : left;
      left -= step;
      final pull = _trailStiffness * (_position.value - _trail);
      _trailVelocity += (pull - _trailDamping * _trailVelocity) * step;
      _trail += _trailVelocity * step;
    }
    final lag = _position.value - _trail;
    if (!_position.isAnimating &&
        lag.abs() < .002 &&
        _trailVelocity.abs() < .02) {
      _trail = _position.value;
      _trailVelocity = 0;
      _lag.value = 0;
      _trailTicker.stop();
      return;
    }
    _lag.value = lag;
  }

  void _pressDown() {
    _press.forward();
    if (!MediaQuery.disableAnimationsOf(context)) _wobbleTo(_squish, 1);
  }

  void _letGo() {
    _press.reverse();
    _wobbleTo(_squish, 0);
    _wobbleTo(_pull, 0);
  }

  void _wobbleTo(AnimationController controller, double target) =>
      controller.animateWith(
        SpringSimulation(
          _wobble,
          controller.value,
          target,
          controller.velocity,
        ),
      );

  double _tabAt(double dx, double tabWidth) =>
      ((dx - _inset) / tabWidth - .5).clamp(0, _last.toDouble());

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    return Padding(
      padding: _margin.copyWith(bottom: _margin.bottom + bottom),
      child: Center(
        heightFactor: 1,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _maxWidth),
          child: SizedBox(
            height: _height,
            child: LayoutBuilder(
              builder: (context, constraints) => _bar(
                context,
                (constraints.maxWidth - _inset * 2) /
                    widget.destinations.length,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bar(BuildContext context, double tabWidth) {
    final scheme = Theme.of(context).colorScheme;
    final dark = scheme.brightness == Brightness.dark;
    final barTint = dark ? const Color(0xff484848) : const Color(0xfff1f2f0);
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final barShader = _barShader;
    final pillShader = _pillShader;
    final barWidth = tabWidth * widget.destinations.length + _inset * 2;
    // A page sliding in or out carries the bar with it; the glass has to
    // follow every frame of that, or it keeps bending the wrong pixels.
    final route = ModalRoute.of(context);
    final routeMotion = Listenable.merge([
      route?.animation,
      route?.secondaryAnimation,
    ]);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      // Each tab announces itself.
      excludeFromSemantics: true,
      onTapDown: (_) => _pressDown(),
      onTapCancel: _letGo,
      onTapUp: (details) {
        _letGo();
        _select(_tabAt(details.localPosition.dx, tabWidth).round());
      },
      onHorizontalDragStart: (details) {
        _pressDown();
        _position.value = _tabAt(details.localPosition.dx, tabWidth);
      },
      onHorizontalDragUpdate: (details) {
        _position.value = _tabAt(details.localPosition.dx, tabWidth);
        if (!MediaQuery.disableAnimationsOf(context)) {
          _pull.value += details.delta.dx;
        }
      },
      onHorizontalDragEnd: (_) {
        _letGo();
        _select(_position.value.round().clamp(0, _last));
      },
      onHorizontalDragCancel: () {
        _letGo();
        _settleOn(widget.selectedIndex);
      },
      child: AnimatedBuilder(
        animation: Listenable.merge([_squish, _pull]),
        builder: (context, child) {
          // A subtle, uniform press zoom follows the existing release spring.
          final zoom = 1 + .025 * _squish.value;
          final tug = (_pull.value / barWidth).clamp(-1.0, 1.0);
          final lean = tug.sign * Curves.easeOut.transform(tug.abs());
          return Transform(
            alignment: Alignment.center,
            transform: Matrix4.translationValues(2 * lean, 0, 0)
              ..scaleByDouble(zoom + .005 * lean.abs(), zoom, 1, 1),
            child: child,
          );
        },
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Include the blur's overflow in the cached layer's bounds.
            Positioned(
              left: -48,
              top: -48,
              right: -48,
              bottom: -48,
              child: RepaintBoundary(
                child: Padding(
                  padding: const EdgeInsets.all(48),
                  child: CustomPaint(
                    isComplex: true,
                    painter: _CapsuleShadowPainter(dark: dark),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_height / 2),
                child: barShader == null
                    ? _FrostedGlass(color: barTint, dark: dark)
                    // The lens goes over its own blur layer, so it bends pixels
                    // that are already soft. Composing the two into one filter
                    // hands the shader a padded texture it can't line up.
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          BackdropFilter(
                            filter: ui.ImageFilter.blur(sigmaX: 5, sigmaY: 5),
                            child: const SizedBox.expand(),
                          ),
                          _GlassBackdrop(
                            shader: barShader,
                            pixelRatio: pixelRatio,
                            repaint: routeMotion,
                            refractionHeight: 24,
                            refractionAmount: 24,
                            saturation: 1.5,
                            tint: barTint.withValues(alpha: dark ? .42 : .38),
                            highlight: dark ? .28 : .6,
                          ),
                        ],
                      ),
              ),
            ),
            AnimatedBuilder(
              animation: Listenable.merge([_position, _press, _lag]),
              builder: (context, _) {
                final press = Curves.easeOut.transform(_press.value);
                // The pill trails slightly behind the finger.
                final lag = _lag.value.clamp(-.4, .4);
                // Movement flattens the lens and stretches its trailing edge;
                // the spring restores its shape as the finger slows.
                final squish = .08 * lag.abs() / (.08 + lag.abs());
                final scaleX = ui.lerpDouble(1, _pressedScaleX, press)!;
                final scaleY = ui.lerpDouble(1, _pressedScaleY, press)!;
                final stretch = .14 * press * lag.abs() / (.08 + lag.abs());
                final pillScaleX = scaleX * (1 + squish + stretch);
                final pillScaleY = scaleY * (1 - squish);
                // Move half the added width backward so the leading edge
                // stays anchored and the extra jelly trails the movement.
                final trailingShift =
                    -lag.sign * tabWidth * (pillScaleX - scaleX) / 2;
                final pillLeft =
                    _inset +
                    (_position.value - lag * .2) * tabWidth +
                    trailingShift;
                final pillClip = RRect.fromRectAndCorners(
                  Rect.fromCenter(
                    center: Offset(pillLeft + tabWidth / 2, _height / 2),
                    width: tabWidth * pillScaleX,
                    height: _handleHeight * pillScaleY,
                  ),
                  topLeft: Radius.elliptical(
                    _pillRadius * pillScaleX,
                    _pillRadius * pillScaleY,
                  ),
                  topRight: Radius.elliptical(
                    _pillRadius * pillScaleX,
                    _pillRadius * pillScaleY,
                  ),
                  bottomLeft: Radius.elliptical(
                    _pillRadius * pillScaleX,
                    _pillRadius * pillScaleY,
                  ),
                  bottomRight: Radius.elliptical(
                    _pillRadius * pillScaleX,
                    _pillRadius * pillScaleY,
                  ),
                );
                Widget tabs({required bool lit}) => Padding(
                  padding: const EdgeInsets.all(_inset),
                  child: Row(
                    children: [
                      for (var i = 0; i < widget.destinations.length; i++)
                        Expanded(
                          child: _Tab(
                            destination: widget.destinations[i],
                            selected: i == widget.selectedIndex,
                            lit: lit,
                            onTap: () => _select(i),
                          ),
                        ),
                    ],
                  ),
                );
                Widget pill(Widget child, {bool shadow = false}) => Positioned(
                  left: pillLeft,
                  top: (_height - _handleHeight) / 2,
                  width: tabWidth,
                  height: _handleHeight,
                  child: Transform.scale(
                    scaleX: pillScaleX,
                    scaleY: pillScaleY,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(_pillRadius),
                        boxShadow: shadow
                            ? [
                                BoxShadow(
                                  color: const Color(0xff35383e)
                                      .withValues(alpha: .18 * (1 - press)),
                                  blurRadius: 12,
                                  offset: const Offset(0, 5),
                                ),
                              ]
                            : null,
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(_pillRadius),
                        child: child,
                      ),
                    ),
                  ),
                );
                final handle = pill(
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: dark
                          ? const Color(0xff080808).withValues(alpha: 1 - press)
                          : null,
                      gradient: dark
                          ? null
                          : LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                const Color(0xfffcfcfd)
                                    .withValues(alpha: 1 - press),
                                const Color(0xfff0f0f3)
                                    .withValues(alpha: 1 - press),
                              ],
                            ),
                    ),
                  ),
                  shadow: !dark,
                );
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    // Unpressed, the pill is opaque and hides the plain tabs
                    // beneath it, so they need no cut-out. Every frame of a
                    // scroll repaints the bar, and a path clip costs far more
                    // than drawing tabs the pill then covers.
                    if (press > 0) ...[
                      handle,
                      Positioned.fill(
                        child: ClipPath(
                          clipper: _PillContentClipper(pillClip),
                          child: tabs(lit: false),
                        ),
                      ),
                    ] else ...[
                      Positioned.fill(child: tabs(lit: false)),
                      handle,
                    ],
                    // Reveal the selected artwork spatially as the pill passes,
                    // rather than switching a whole tab at its midpoint.
                    Positioned.fill(
                      child: ExcludeSemantics(
                        child: IgnorePointer(
                          child: ClipRRect(
                            clipper: _PillClipper(pillClip),
                            child: tabs(lit: true),
                          ),
                        ),
                      ),
                    ),
                    // The droplet goes over the tabs so it bends them too.
                    if (pillShader != null && press > 0)
                      pill(
                        _GlassBackdrop(
                          shader: pillShader,
                          pixelRatio: pixelRatio,
                          repaint: routeMotion,
                          refractionHeight: 10 * press,
                          refractionAmount: 14 * press,
                          dispersion: 1,
                          magnification: ui.Offset(
                            1 / (1 + .08 * press),
                            1 / (1 + .18 * press * (1 - squish)),
                          ),
                          tint: Colors.black.withValues(alpha: .03 * press),
                          highlight: (dark ? .4 : .7) * press,
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// The pill's own shape. A rounded rectangle, so it takes the cheap
/// rounded-rect clip rather than a path.
class _PillClipper extends CustomClipper<RRect> {
  const _PillClipper(this.pill);

  final RRect pill;

  @override
  RRect getClip(Size size) => pill;

  @override
  bool shouldReclip(_PillClipper oldClipper) => pill != oldClipper.pill;
}

/// Everything but the pill, while it is see-through under a press.
class _PillContentClipper extends CustomClipper<Path> {
  const _PillContentClipper(this.pill);

  final RRect pill;

  @override
  Path getClip(Size size) => Path.combine(
    PathOperation.difference,
    Path()..addRect(Offset.zero & size),
    Path()..addRRect(pill),
  );

  @override
  bool shouldReclip(_PillContentClipper oldClipper) => pill != oldClipper.pill;
}

class _Tab extends StatelessWidget {
  const _Tab({
    required this.destination,
    required this.selected,
    required this.lit,
    required this.onTap,
  });
  final LiquidGlassDestination destination;
  final bool selected;

  final bool lit;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = scheme.brightness == Brightness.light
        ? const Color(0xff171817)
        : lit
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            lit ? destination.selectedIcon : destination.icon,
            size: 24,
            color: color,
          ),
          const SizedBox(height: 2),
          if (lit)
            RichText(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textScaler: MediaQuery.textScalerOf(context),
              text: TextSpan(
                text: destination.label,
                style: DefaultTextStyle.of(context).style.copyWith(
                  fontSize: 11,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            )
          else
            Text(
              destination.label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                height: 1.2,
                fontWeight: lit ? FontWeight.w700 : FontWeight.w500,
                color: color,
              ),
            ),
        ],
      ),
    );
  }
}

/// The stand-in for the glass where shader filters can't run.
class _FrostedGlass extends StatelessWidget {
  const _FrostedGlass({required this.color, required this.dark});
  final Color color;
  final bool dark;

  @override
  Widget build(BuildContext context) => BackdropFilter(
    filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
    child: DecoratedBox(
      decoration: ShapeDecoration(
        color: color.withValues(alpha: .78),
        shape: StadiumBorder(
          side: BorderSide(
            color: Colors.white.withValues(alpha: dark ? .12 : .6),
            width: .5,
          ),
        ),
      ),
    ),
  );
}

/// A soft drop shadow around the capsule only. Painting it under the glass
/// too would have the glass refract its own shadow.
class _CapsuleShadowPainter extends CustomPainter {
  const _CapsuleShadowPainter({required this.dark});
  final bool dark;

  @override
  void paint(Canvas canvas, Size size) {
    final capsule = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.shortestSide / 2),
    );
    canvas
      ..clipPath(
        Path.combine(
          PathOperation.difference,
          Path()..addRect((Offset.zero & size).inflate(48)),
          Path()..addRRect(capsule),
        ),
      )
      ..drawRRect(
        capsule.shift(const Offset(0, 4)),
        Paint()
          ..color = Colors.black.withValues(alpha: dark ? .32 : .16)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
      );
  }

  @override
  bool shouldRepaint(_CapsuleShadowPainter oldDelegate) =>
      dark != oldDelegate.dark;
}

/// Runs the liquid glass shader over whatever is already painted behind this
/// box. The shape is always a capsule; the caller clips to it.
class _GlassBackdrop extends LeafRenderObjectWidget {
  const _GlassBackdrop({
    required this.shader,
    required this.pixelRatio,
    required this.repaint,
    required this.refractionHeight,
    required this.refractionAmount,
    required this.tint,
    required this.highlight,
    this.dispersion = 0,
    this.saturation = 1,
    this.magnification = const ui.Offset(1, 1),
  });
  final ui.FragmentShader shader;
  final double pixelRatio;

  /// Ticks whenever the box may have moved on screen without being repainted.
  final Listenable repaint;

  /// Lengths are logical pixels.
  final double refractionHeight;
  final double refractionAmount;
  final double dispersion;
  final double saturation;
  final ui.Offset magnification;
  final Color tint;
  final double highlight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderGlassBackdrop(this);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderGlassBackdrop renderObject,
  ) => renderObject.glass = this;
}

class _RenderGlassBackdrop extends RenderBox {
  _RenderGlassBackdrop(this._glass);

  _GlassBackdrop _glass;
  set glass(_GlassBackdrop value) {
    if (attached && !identical(value.repaint, _glass.repaint)) {
      _glass.repaint.removeListener(markNeedsPaint);
      value.repaint.addListener(markNeedsPaint);
    }
    _glass = value;
    markNeedsPaint();
  }

  @override
  void attach(PipelineOwner owner) {
    super.attach(owner);
    _glass.repaint.addListener(markNeedsPaint);
  }

  @override
  void detach() {
    _glass.repaint.removeListener(markNeedsPaint);
    super.detach();
  }

  @override
  BackdropFilterLayer? get layer => super.layer as BackdropFilterLayer?;

  @override
  bool get alwaysNeedsCompositing => true;

  @override
  bool get sizedByParent => true;

  @override
  Size computeDryLayout(BoxConstraints constraints) => constraints.biggest;

  @override
  void paint(PaintingContext context, Offset offset) {
    // The shader works in the backdrop's own pixels, so it needs to know
    // where on screen this box has ended up, scale and all.
    final rect = MatrixUtils.transformRect(
      getTransformTo(null),
      Offset.zero & size,
    );
    final ratio = _glass.pixelRatio;
    final tint = _glass.tint;
    _glass.shader
      ..setFloat(2, rect.left * ratio)
      ..setFloat(3, rect.top * ratio)
      ..setFloat(4, rect.width * ratio)
      ..setFloat(5, rect.height * ratio)
      ..setFloat(6, rect.shortestSide / 2 * ratio)
      ..setFloat(7, _glass.refractionHeight * ratio)
      ..setFloat(8, _glass.refractionAmount * ratio)
      ..setFloat(9, _glass.dispersion)
      ..setFloat(10, _glass.saturation)
      ..setFloat(11, tint.r)
      ..setFloat(12, tint.g)
      ..setFloat(13, tint.b)
      ..setFloat(14, tint.a)
      ..setFloat(15, _glass.highlight)
      ..setFloat(16, ratio)
      ..setFloat(17, _glass.magnification.dx)
      ..setFloat(18, _glass.magnification.dy);
    layer ??= BackdropFilterLayer();
    layer!.filter = ui.ImageFilter.shader(_glass.shader);
    context.pushLayer(layer!, (_, _) {}, offset);
  }
}
