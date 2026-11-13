import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../state/appearance_controller.dart' show AppearanceScope;
import '../theme/app_theme.dart'
    show AppChrome, auroraDarkPage, usesGlass, usesAurora;
import 'glass_button.dart' show GlassRim;
import 'inner_glow.dart';

/// The app's calm glass look: a quiet, cool-grey page with frosted grey
/// surfaces only a shade lighter than it, each set apart by a bright
/// hairline rim and a soft shadow rather than by colour. The accent is kept
/// for what is active or important.
///
/// Built from plain gradients, with no backdrop blur, so long scrolling
/// lists of glass cards cost what solid cards did.

/// The page background: a cool grey, a touch lighter at the top, with soft,
/// heavily blurred ribbons of colour drifting across it — the accent and its
/// two hue neighbours, muted towards grey so the page stays calm. Through
/// the see-through cards they read as a frosted photo behind glass.
///
/// It is painted once and kept in its own layer, so scrolling the page
/// above it never repaints the blur.
class GlassBackdrop extends StatelessWidget {
  const GlassBackdrop({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    if (!usesGlass(context)) {
      return ColoredBox(color: theme.scaffoldBackgroundColor);
    }
    final accent = theme.colorScheme.primary;
    final black = theme.extension<AppChrome>()?.cardBorder != null;
    if (usesAurora(context)) {
      final appearance = AppearanceScope.maybeOf(context);
      final wallpaper = appearance?.wallpaperPath;
      if (wallpaper != null && !black) {
        final dim = appearance!.wallpaperDim;
        return _SnapshotBackdrop(
          id: ('wallpaper', wallpaper, dim, dark),
          builder: (ready) => _WallpaperBackdrop(
            path: wallpaper,
            dim: dim,
            dark: dark,
            onReady: ready,
          ),
        );
      }
      return _SnapshotBackdrop(
        id: ('aurora', accent, dark, black),
        builder: (ready) {
          ready();
          return CustomPaint(
            size: Size.infinite,
            painter: _AuroraPainter(accent: accent, dark: dark, black: black),
          );
        },
      );
    }
    // The true-black theme stays black, with dimmer ribbons.
    final colors = dark
        ? (black
              ? const [Color(0xff000000), Color(0xff000000)]
              : const [Color(0xff131315), Color(0xff0b0b0d)])
        : const [Color(0xfff6f5f3), Color(0xffefeff3)];
    return _SnapshotBackdrop(
      id: ('glassy', accent, dark, black),
      builder: (ready) {
        ready();
        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: colors,
            ),
          ),
          child: CustomPaint(
            size: Size.infinite,
            painter: _WavesPainter(
              accent: accent,
              dark: dark,
              // Dark needs far more: a muted ribbon on near-black at the
              // light-mode strength can't be seen, and glass with nothing
              // behind it is just a grey card.
              strength: dark ? (black ? .2 : .62) : .24,
            ),
          ),
        );
      },
    );
  }
}

/// Paints [builder]'s backdrop live once, then copies the result into an
/// image and shows only that image.
///
/// Impeller keeps no raster cache, so a [RepaintBoundary] alone still
/// redraws the full-screen glow (three screen-sized gradients, or a blurred
/// photo) on every frame of every scroll. One image of the same pixels costs
/// a single texture draw. Images are shared by every page showing the same
/// backdrop at the same size, so a page pushed later draws it at once.
///
/// [builder] calls its argument once the backdrop has everything it needs
/// on screen (a picture decoded), so a half-loaded one is never kept.
class _SnapshotBackdrop extends StatefulWidget {
  const _SnapshotBackdrop({required this.id, required this.builder});

  /// What the backdrop shows, apart from its size; equal ids paint alike.
  final Object id;
  final Widget Function(VoidCallback ready) builder;

  @override
  State<_SnapshotBackdrop> createState() => _SnapshotBackdropState();
}

class _SnapshotBackdropState extends State<_SnapshotBackdrop> {
  /// Recent snapshots by (id, size, pixel ratio). Pages hold their own
  /// clones, so evicting one never pulls an image out from under a page.
  static final _cache = <(Object, Size, double), ui.Image>{};
  static const _cacheSize = 4;

  /// Widget tests can't wait on real timers; they get the live backdrop.
  static final _enabled = !Platform.environment.containsKey('FLUTTER_TEST');

  final _boundary = GlobalKey();
  (Object, Size, double)? _key;
  ui.Image? _image;
  bool _ready = false;
  Timer? _capture;

  @override
  void didUpdateWidget(_SnapshotBackdrop old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id) _ready = false;
  }

  @override
  void dispose() {
    _capture?.cancel();
    _image?.dispose();
    super.dispose();
  }

  void _show((Object, Size, double) key) {
    if (_key == key) return;
    _key = key;
    _capture?.cancel();
    _image?.dispose();
    _image = _cache[key]?.clone();
  }

  /// Called during build; the capture waits for the frame regardless.
  void _markReady() {
    if (_ready) return;
    _ready = true;
    final key = _key;
    if (key != null && _image == null) _schedule(key);
  }

  /// Snapshots once the backdrop has held still for a moment, so a size
  /// that is still animating (the keyboard opening) is never kept.
  void _schedule((Object, Size, double) key) {
    _capture?.cancel();
    _capture = Timer(const Duration(milliseconds: 250), () => _take(key));
  }

  Future<void> _take((Object, Size, double) key) async {
    if (!mounted || _key != key || _image != null || !_ready) return;
    final boundary = _boundary.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return;
    final ui.Image image;
    try {
      image = await boundary.toImage(pixelRatio: key.$3);
    } catch (_) {
      return; // Keep painting it live.
    }
    _cache.remove(key)?.dispose();
    _cache[key] = image;
    while (_cache.length > _cacheSize) {
      _cache.remove(_cache.keys.first)!.dispose();
    }
    if (!mounted || _key != key || _image != null) return;
    setState(() => _image = image.clone());
  }

  @override
  Widget build(BuildContext context) {
    final ratio = MediaQuery.devicePixelRatioOf(context);
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final live = RepaintBoundary(
            key: _boundary,
            child: widget.builder(_markReady),
          );
          if (!_enabled || !size.isFinite || size.isEmpty) return live;
          final key = (widget.id, size, ratio);
          final changed = _key != key;
          _show(key);
          final image = _image;
          if (image != null) {
            return RawImage(
              image: image,
              width: size.width,
              height: size.height,
              fit: BoxFit.fill,
              filterQuality: FilterQuality.low,
            );
          }
          if (changed && _ready) _schedule(key);
          return live;
        },
      ),
    );
  }
}

/// The user's own picture behind Aurora: softened and dimmed (towards black
/// in dark, white in light) so the glass cards and their text stay readable.
class _WallpaperBackdrop extends StatelessWidget {
  const _WallpaperBackdrop({
    required this.path,
    required this.dim,
    required this.dark,
    required this.onReady,
  });
  final String path;
  final double dim;
  final bool dark;

  /// Called once the picture is on screen.
  final VoidCallback onReady;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final pixels = MediaQuery.devicePixelRatioOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: dark ? auroraDarkPage : const Color(0xfff6f5f3)),
        ImageFiltered(
          // Light: the page stays recognisable; the cards frost it further.
          imageFilter: ui.ImageFilter.blur(
            sigmaX: 6,
            sigmaY: 6,
            tileMode: TileMode.mirror,
          ),
          child: Image(
            // Decoded near screen size, not at the photo's full resolution.
            image: ResizeImage(
              FileImage(File(path)),
              width: (size.width * pixels).round(),
              allowUpscaling: false,
            ),
            fit: BoxFit.cover,
            frameBuilder: (context, child, frame, _) {
              if (frame != null) onReady();
              return child;
            },
            errorBuilder: (_, _, _) => const SizedBox.shrink(),
          ),
        ),
        ColoredBox(
          color: (dark ? Colors.black : Colors.white).withValues(alpha: dim),
        ),
      ],
    );
  }
}

/// Broad radial light fields need no per-card backdrop blur.
class _AuroraPainter extends CustomPainter {
  const _AuroraPainter({
    required this.accent,
    required this.dark,
    required this.black,
  });
  final Color accent;
  final bool dark, black;
  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final base = dark
        ? (black ? Colors.black : auroraDarkPage)
        : const Color(0xfff6f7fa);
    canvas.drawRect(
      rect,
      Paint()
        ..color = Color.alphaBlend(
          accent.withValues(alpha: dark ? .035 : .025),
          base,
        ),
    );
    final hsl = HSLColor.fromColor(accent);
    final neighbor = hsl.withHue((hsl.hue + 28) % 360).toColor();
    for (final (x, y, radius, color, strength) in [
      (-.12, .17, .95, accent, .42),
      (1.05, .43, .9, neighbor, .30),
      (.15, .87, .95, accent, .32),
    ]) {
      final center = Offset(size.width * x, size.height * y);
      canvas.drawRect(
        rect,
        Paint()
          ..shader =
              RadialGradient(
                colors: [
                  color.withValues(
                    alpha: strength * (dark ? 1 : .28) * (black ? .5 : 1),
                  ),
                  color.withValues(alpha: 0),
                ],
                stops: const [0, 1],
              ).createShader(
                Rect.fromCircle(center: center, radius: size.width * radius),
              ),
      );
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) =>
      accent != old.accent || dark != old.dark || black != old.black;
}

class _WavesPainter extends CustomPainter {
  const _WavesPainter({
    required this.accent,
    required this.dark,
    required this.strength,
  });
  final Color accent;
  final bool dark;
  final double strength;

  /// [accent] turned by [hueShift], muted towards grey for a calm page.
  Color _muted(double hueShift) {
    final hsl = HSLColor.fromColor(accent);
    return hsl
        .withHue((hsl.hue + hueShift) % 360)
        .withSaturation((hsl.saturation * .55).clamp(0, .6))
        .withLightness(dark ? .4 : .74)
        .toColor();
  }

  /// A ribbon between two sine waves that meander across the width.
  Path _ribbon(
    Size size, {
    required double centre,
    required double thickness,
    required double amplitude,
    required double phase,
    double tilt = 0,
  }) {
    final w = size.width, h = size.height;
    double edge(double x, double offset, double extraPhase) =>
        h * (centre + offset + tilt * (x / w - .5)) +
        h *
            amplitude *
            math.sin((x / w) * math.pi * 2 * 1.1 + phase + extraPhase);
    final path = Path()..moveTo(-40, edge(-40, -thickness / 2, 0));
    for (var x = -40.0; x <= w + 40; x += 8) {
      path.lineTo(x, edge(x, -thickness / 2, 0));
    }
    for (var x = w + 40; x >= -40; x -= 8) {
      path.lineTo(x, edge(x, thickness / 2, .9));
    }
    return path..close();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final blur = MaskFilter.blur(BlurStyle.normal, size.shortestSide * .06);
    final alpha = (dark ? .42 : .6) * strength;
    void wave(Path path, Color color, double a) => canvas.drawPath(
      path,
      Paint()
        ..color = color.withValues(alpha: a)
        ..maskFilter = blur,
    );
    wave(
      _ribbon(
        size,
        centre: .12,
        thickness: .16,
        amplitude: .05,
        phase: .4,
        tilt: .1,
      ),
      _muted(0),
      alpha,
    );
    wave(
      _ribbon(
        size,
        centre: .5,
        thickness: .12,
        amplitude: .07,
        phase: 2.2,
        tilt: -.16,
      ),
      _muted(0),
      alpha * .85,
    );
    wave(
      _ribbon(
        size,
        centre: .86,
        thickness: .16,
        amplitude: .05,
        phase: 4,
        tilt: .12,
      ),
      _muted(0),
      alpha * .8,
    );
  }

  @override
  bool shouldRepaint(_WavesPainter old) =>
      accent != old.accent || dark != old.dark || strength != old.strength;
}

/// A [Scaffold] laid over a [GlassBackdrop], for pages that build their own.
class GlassPage extends StatelessWidget {
  const GlassPage({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Stack(
    fit: StackFit.expand,
    children: [
      const GlassBackdrop(),
      // Frosted cards over a picture share one blur of it.
      BackdropGroup(
        child: Theme(
          data: Theme.of(context)
              .copyWith(scaffoldBackgroundColor: Colors.transparent),
          child: child,
        ),
      ),
    ],
  );
}

/// The card body: frosted grey glass, a shade lighter than the page and
/// lightest at the top-left where the light falls. [color] replaces the
/// neutral body.
Gradient glassCardFill(BuildContext context, {Color? color}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final List<Color> colors;
  if (usesAurora(context) && color == null) {
    final accent = Theme.of(context).colorScheme.primary;
    if (dark) {
      // A clear, faintly frosted pane: the pools behind give the colour, so
      // the card itself stays neutral instead of a muddy slate.
      final black =
          Theme.of(context).extension<AppChrome>()?.cardBorder != null;
      if (black) {
        return LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            const Color(0xff141418).withValues(alpha: .9),
            const Color(0xff0e0e10).withValues(alpha: .86),
          ],
        );
      }
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(
            accent.withValues(alpha: .10),
            Colors.white,
          ).withValues(alpha: .11),
          Colors.white.withValues(alpha: .055),
          Color.alphaBlend(
            accent.withValues(alpha: .25),
            Colors.white,
          ).withValues(alpha: .075),
        ],
        stops: const [0, .55, 1],
      );
    }
    const base = Colors.white;
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.alphaBlend(
          accent.withValues(alpha: dark ? .10 : .035),
          base,
        ).withValues(alpha: dark ? .78 : .97),
        base.withValues(alpha: dark ? .58 : .88),
        Color.alphaBlend(
          accent.withValues(alpha: dark ? .18 : .07),
          base,
        ).withValues(alpha: dark ? .68 : .95),
      ],
      stops: const [0, .55, 1],
    );
  }
  if (color != null) {
    colors = [
      Color.alphaBlend(
        Colors.white.withValues(alpha: dark ? .04 : .25),
        color.withValues(alpha: .92),
      ),
      color.withValues(alpha: .84),
    ];
  } else if (dark) {
    colors = [
      const Color(0xff252528).withValues(alpha: .84),
      const Color(0xff1c1c1f).withValues(alpha: .8),
    ];
  } else {
    colors = [
      const Color(0xfffdfdff).withValues(alpha: .90),
      const Color(0xfff8f8fb).withValues(alpha: .84),
    ];
  }
  return LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: colors,
  );
}

/// A soft sheen across the top of the glass, fading out before the middle.
class GlassCardWash extends StatelessWidget {
  const GlassCardWash({super.key, required this.radius, required this.child});
  final BorderRadius radius;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return CustomPaint(
      painter: _WashPainter(radius: radius, alpha: dark ? .02 : .12),
      child: child,
    );
  }
}

/// The sheen is clear from 40% of the way down, so only that top part is
/// drawn: blending a fully clear gradient over the rest of every card cost
/// fill rate on each frame for nothing.
class _WashPainter extends CustomPainter {
  const _WashPainter({required this.radius, required this.alpha});
  final BorderRadius radius;
  final double alpha;
  static const _fade = .4;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          Colors.white.withValues(alpha: alpha),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const [0, _fade],
      ).createShader(rect);
    final shape = radius.toRRect(rect);
    final cut = size.height * _fade;
    // The top part has the card's own top corners as long as neither the
    // top corners reach below the cut nor the bottom ones above it.
    final fits =
        shape.tlRadiusY <= cut &&
        shape.trRadiusY <= cut &&
        shape.blRadiusY <= size.height - cut &&
        shape.brRadiusY <= size.height - cut;
    canvas.drawRRect(
      fits
          ? RRect.fromLTRBAndCorners(
              0,
              0,
              size.width,
              cut,
              topLeft: shape.tlRadius,
              topRight: shape.trRadius,
            )
          : shape,
      paint,
    );
  }

  @override
  bool shouldRepaint(_WashPainter old) =>
      radius != old.radius || alpha != old.alpha;
}

/// A wide, soft lift under a glass card, plus a tight contact shadow.
List<BoxShadow> glassCardShadows(Brightness brightness) {
  final dark = brightness == Brightness.dark;
  return [
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? .16 : .025),
      blurRadius: 28,
      offset: const Offset(0, 10),
      spreadRadius: -6,
    ),
    BoxShadow(
      color: Colors.black.withValues(alpha: dark ? .12 : .015),
      blurRadius: 3,
      offset: const Offset(0, 1),
    ),
  ];
}

/// A glass card's edge: a hairline bright along the top-left and fading
/// towards the bottom-right, over a thin inner glow.
class GlassCardRim extends Decoration {
  const GlassCardRim({required this.dark, required this.radius, this.accent});
  final Color? accent;
  final bool dark;
  final BorderRadius radius;

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _CardRimPainter(this);
}

class _CardRimPainter extends BoxPainter {
  _CardRimPainter(this.rim);
  final GlassCardRim rim;

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final rect = offset & configuration.size!;
    final dark = rim.dark;
    paintInnerGlow(
      canvas,
      rim.radius.toRRect(rect),
      opacity: rim.accent != null ? (dark ? .05 : .14) : (dark ? .02 : .06),
      falloff: const [.6, .35, .15, .05],
    );
    canvas.drawRRect(
      rim.radius.toRRect(rect.deflate(.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Colors.white.withValues(
              // Aurora's lit edge catches light at the top-left; a bright
              // line all the way round reads as an outlined box.
              alpha: rim.accent != null
                  ? (dark ? .30 : .95)
                  : (dark ? .12 : .65),
            ),
            Colors.white.withValues(
              alpha: rim.accent != null ? .08 : (dark ? .03 : .18),
            ),
            (rim.accent == null
                    ? Colors.white
                    : Color.lerp(rim.accent, Colors.white, .65)!)
                .withValues(
                  alpha: rim.accent != null
                      ? (dark ? .2 : .18)
                      : (dark ? .06 : .3),
                ),
          ],
          stops: const [0, .6, 1],
        ).createShader(rect),
    );
  }
}

/// A small round glass disc holding a plain icon: the icon for settings and
/// menu rows. Neutral grey with a dark glyph, so a list stays calm; [tint]
/// colours the glyph only (red for something that deletes), and [filled]
/// makes the disc solid accent with a white glyph, to stand out.
class GlassIconTile extends StatelessWidget {
  const GlassIconTile(
    this.icon, {
    super.key,
    this.size = 40,
    this.tint,
    this.filled = false,
  });
  final IconData icon;
  final double size;
  final Color? tint;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = tint ?? theme.colorScheme.primary;
    final glyph = dark && tint != null
        ? Color.lerp(accent, Colors.white, .25)!
        : accent;
    final radius = BorderRadius.circular(size / 2);
    if (!usesGlass(context)) {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: radius,
          color: filled
              ? accent
              : theme.colorScheme.onSurface.withValues(alpha: .06),
        ),
        child: Icon(
          icon,
          size: size * .5,
          color: filled
              ? Colors.white
              : tint == null
              ? theme.colorScheme.onSurface
              : glyph,
        ),
      );
    }
    final List<Color> fill = filled
        ? [Color.lerp(accent, Colors.white, .06)!, accent]
        : dark && usesAurora(context)
        // Clear glass on Aurora, so the disc takes the card's tint instead
        // of punching a charcoal hole in it.
        ? [
            Color.alphaBlend(
              accent.withValues(alpha: .14),
              Colors.white,
            ).withValues(alpha: .13),
            Colors.white.withValues(alpha: .06),
          ]
        : dark
        ? const [Color(0xff313135), Color(0xff26262a)]
        : const [Color(0xffeeeef1), Color(0xffe4e4e8)];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: radius,
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: fill,
        ),
        boxShadow: [
          BoxShadow(
            color: (filled ? accent : Colors.black).withValues(
              alpha: filled ? .12 : (dark ? .12 : .025),
            ),
            blurRadius: filled ? 10 : 4,
            offset: Offset(0, filled ? 3 : 1),
          ),
        ],
      ),
      foregroundDecoration: GlassRim(dark: dark, solid: filled, radius: radius),
      child: Icon(
        icon,
        size: size * .5,
        color: filled
            ? Colors.white
            : tint == null
            ? theme.colorScheme.onSurface.withValues(alpha: .85)
            : glyph,
      ),
    );
  }
}
