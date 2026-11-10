import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../state/appearance_controller.dart' show AppearanceScope;
import '../theme/app_theme.dart' show AppChrome, usesAurora, usesGlass;
import 'glass_surface.dart' show glassCardFill;

/// Hand-drawn 3D artwork for the app's empty states: chunky, extruded
/// shapes with a lit front face, a darker body showing their depth, a
/// light catch along the top edge, and raised white details.
///
/// Every shape is drawn in a 100 × 100 box from paths below — no icon font —
/// and coloured from [tint] (the theme accent by default), so the artwork
/// recolours with the theme.
enum EmptyArt {
  folder,
  wallet,
  coins,
  grid,
  swapCards,
  bank,
  receipt,
  calendar,
  chat,
  chatRead,
  archive,
  warning,
  people,
  transfer,
  search,
}

/// The artwork drawn for the Material icon an empty state was given, so
/// call sites keep naming the icon that describes them.
EmptyArt emptyArtFor(IconData icon) =>
    _byIcon[icon.codePoint] ?? EmptyArt.folder;

final _byIcon = <int, EmptyArt>{
  Icons.savings_outlined.codePoint: EmptyArt.coins,
  Icons.archive_outlined.codePoint: EmptyArt.archive,
  Icons.account_balance_wallet_outlined.codePoint: EmptyArt.wallet,
  Icons.account_balance_wallet_rounded.codePoint: EmptyArt.wallet,
  Icons.error_outline_rounded.codePoint: EmptyArt.warning,
  Icons.groups_outlined.codePoint: EmptyArt.people,
  Icons.grid_view_rounded.codePoint: EmptyArt.grid,
  Icons.handshake_outlined.codePoint: EmptyArt.swapCards,
  Icons.sms_outlined.codePoint: EmptyArt.chat,
  Icons.account_balance_outlined.codePoint: EmptyArt.bank,
  Icons.receipt_long_outlined.codePoint: EmptyArt.receipt,
  Icons.autorenew_rounded.codePoint: EmptyArt.calendar,
  Icons.mark_chat_read_outlined.codePoint: EmptyArt.chatRead,
  Icons.search_off_rounded.codePoint: EmptyArt.search,
  Icons.swap_vert_rounded.codePoint: EmptyArt.transfer,
};

class EmptyArtwork extends StatelessWidget {
  const EmptyArtwork(this.art, {super.key, this.size = 64, this.tint});
  final EmptyArt art;
  final double size;
  final Color? tint;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: CustomPaint(
      size: Size.square(size),
      painter: _ArtPainter(art, tint ?? Theme.of(context).colorScheme.primary),
    ),
  );
}

/// A solid piece of the artwork. [soft] pieces sit behind or beside the
/// main ones in a paler tone.
class _Part {
  const _Part(this.path, {this.soft = false});
  final Path path;
  final bool soft;
}

class _Drawing {
  const _Drawing(this.parts, {this.detail, this.detailStroke});
  final List<_Part> parts;

  /// Raised white marks on the front faces.
  final Path? detail;

  /// Draws [detail] as a round-capped line of this width, not a fill.
  final double? detailStroke;
}

Path _rr(double l, double t, double r, double b, double radius) =>
    Path()..addRRect(RRect.fromLTRBR(l, t, r, b, Radius.circular(radius)));

Path _circle(double x, double y, double r) =>
    Path()..addOval(Rect.fromCircle(center: Offset(x, y), radius: r));

Path _poly(List<double> xy) => Path()
  ..addPolygon([
    for (var i = 0; i < xy.length; i += 2) Offset(xy[i], xy[i + 1]),
  ], true);

Path _union(List<Path> paths) =>
    paths.reduce((a, b) => Path.combine(PathOperation.union, a, b));

Path _minus(Path a, Path b) => Path.combine(PathOperation.difference, a, b);

Path _rotated(Path path, double degrees, Offset around) {
  final a = degrees * math.pi / 180;
  final m = Matrix4.identity()
    ..translateByDouble(around.dx, around.dy, 0, 1)
    ..rotateZ(a)
    ..translateByDouble(-around.dx, -around.dy, 0, 1);
  return path.transform(m.storage);
}

Path _plus(double x, double y, double arm, double w) => _union([
  _rr(x - w / 2, y - arm, x + w / 2, y + arm, w / 2),
  _rr(x - arm, y - w / 2, x + arm, y + w / 2, w / 2),
]);

/// A four-pointed sparkle centred on [x], [y].
Path _sparkle(double x, double y, double r) {
  final k = r * .28;
  return Path()
    ..moveTo(x, y - r)
    ..quadraticBezierTo(x + k * .4, y - k * .4, x + r, y)
    ..quadraticBezierTo(x + k * .4, y + k * .4, x, y + r)
    ..quadraticBezierTo(x - k * .4, y + k * .4, x - r, y)
    ..quadraticBezierTo(x - k * .4, y - k * .4, x, y - r)
    ..close();
}

_Drawing _draw(EmptyArt art) {
  switch (art) {
    case EmptyArt.folder:
      return _Drawing([
        _Part(
          _union([_rr(16, 18, 48, 36, 6), _rr(16, 26, 84, 76, 9)]),
          soft: true,
        ),
        _Part(_rr(10, 36, 90, 84, 10)),
      ], detail: _plus(50, 60, 12, 6.5));
    case EmptyArt.wallet:
      return _Drawing([
        _Part(
          _rotated(_rr(20, 16, 74, 46, 8), -8, const Offset(47, 31)),
          soft: true,
        ),
        _Part(_rr(10, 32, 86, 84, 13)),
      ], detail: _minus(_rr(58, 49, 94, 67, 9), _circle(69, 58, 3.6)));
    case EmptyArt.coins:
      return _Drawing(
        [
          _Part(_rr(20, 66, 80, 84, 9)),
          _Part(_rr(14, 48, 74, 66, 9)),
          _Part(_rr(24, 30, 84, 48, 9)),
        ],
        detail: _union([
          _sparkle(80, 15, 9),
          _rr(32, 37, 54, 41, 2),
          _rr(22, 55, 44, 59, 2),
          _rr(28, 73, 50, 77, 2),
        ]),
      );
    case EmptyArt.grid:
      return _Drawing([
        _Part(_rr(54, 12, 88, 46, 11), soft: true),
        _Part(_rr(12, 54, 46, 88, 11), soft: true),
        _Part(_rr(12, 12, 46, 46, 11)),
        _Part(_rr(54, 54, 88, 88, 11)),
      ], detail: _plus(71, 71, 9, 5.5));
    case EmptyArt.swapCards:
      return _Drawing(
        [
          _Part(_rr(28, 14, 90, 52, 11), soft: true),
          _Part(_rr(10, 38, 72, 84, 11)),
        ],
        detail: _union([
          _rr(20, 51, 52, 56.5, 2.75),
          _poly([50, 46, 60, 53.75, 50, 61.5]),
          _rr(30, 66, 62, 71.5, 2.75),
          _poly([32, 61, 22, 68.75, 32, 76.5]),
        ]),
      );
    case EmptyArt.bank:
      return _Drawing([
        _Part(_rr(19, 38, 31, 74, 4), soft: true),
        _Part(_rr(44, 38, 56, 74, 4), soft: true),
        _Part(_rr(69, 38, 81, 74, 4), soft: true),
        _Part(
          _union([
            _poly([50, 8, 92, 30, 8, 30]),
            _rr(8, 26, 92, 38, 5),
          ]),
        ),
        _Part(_rr(8, 74, 92, 88, 6)),
      ], detail: _circle(50, 25, 5.5));
    case EmptyArt.receipt:
      final body = Path()
        ..moveTo(18, 22)
        ..quadraticBezierTo(18, 10, 30, 10)
        ..lineTo(70, 10)
        ..quadraticBezierTo(82, 10, 82, 22)
        ..lineTo(82, 90);
      for (var x = 82.0; x > 18; x -= 8) {
        body
          ..lineTo(x - 4, 84)
          ..lineTo(x - 8, 90);
      }
      body.close();
      return _Drawing(
        [_Part(body)],
        detail: _union([
          _rr(30, 24, 70, 30, 3),
          _rr(30, 38, 60, 44, 3),
          _rr(30, 52, 50, 58, 3),
          _rr(58, 52, 70, 58, 3),
          _rr(30, 66, 70, 70, 2),
        ]),
      );
    case EmptyArt.calendar:
      return _Drawing(
        [
          _Part(_rr(12, 20, 88, 88, 13)),
          _Part(_rr(28, 10, 37, 32, 4.5), soft: true),
          _Part(_rr(63, 10, 72, 32, 4.5), soft: true),
        ],
        detail: Path()
          ..moveTo(34, 58)
          ..lineTo(46, 70)
          ..lineTo(68, 46),
        detailStroke: 8,
      );
    case EmptyArt.chat:
    case EmptyArt.chatRead:
      final bubble = _union([
        _rr(10, 14, 90, 68, 20),
        _poly([22, 60, 18, 86, 44, 64]),
      ]);
      if (art == EmptyArt.chatRead) {
        return _Drawing(
          [_Part(bubble)],
          detail: Path()
            ..moveTo(34, 41)
            ..lineTo(45, 52)
            ..lineTo(66, 31),
          detailStroke: 8,
        );
      }
      return _Drawing(
        [_Part(bubble)],
        detail: _union([
          _circle(32, 41, 5.5),
          _circle(50, 41, 5.5),
          _circle(68, 41, 5.5),
        ]),
      );
    case EmptyArt.archive:
      return _Drawing([
        _Part(_rr(16, 34, 84, 86, 10)),
        _Part(_rr(8, 16, 92, 36, 8), soft: true),
      ], detail: _rr(38, 48, 62, 57, 4.5));
    case EmptyArt.warning:
      return _Drawing([
        _Part(_rotated(_rr(22, 22, 78, 78, 13), 45, const Offset(50, 50))),
      ], detail: _union([_rr(45.5, 28, 54.5, 56, 4.5), _circle(50, 67, 5)]));
    case EmptyArt.people:
      return _Drawing([
        _Part(_circle(66, 28, 12), soft: true),
        _Part(_rr(46, 44, 90, 80, 18), soft: true),
        _Part(_circle(38, 34, 14)),
        _Part(_rr(10, 54, 66, 90, 20)),
      ], detail: _sparkle(84, 14, 7));
    case EmptyArt.transfer:
      return _Drawing(
        [_Part(_rr(12, 12, 88, 88, 24))],
        detail: _union([
          _rr(34, 34, 42, 70, 4),
          _poly([25, 41, 38, 26, 51, 41]),
          _rr(58, 30, 66, 66, 4),
          _poly([49, 59, 62, 74, 75, 59]),
        ]),
      );
    case EmptyArt.search:
      return _Drawing([
        _Part(_poly([60.8, 70.2, 69.2, 61.8, 91.2, 83.8, 82.8, 92.2])),
        _Part(_circle(42, 42, 19), soft: true),
        _Part(_minus(_circle(42, 42, 30), _circle(42, 42, 19))),
      ], detail: _rotated(_rr(28, 29, 35, 45, 3.5), 40, const Offset(31, 37)));
  }
}

class _ArtPainter extends CustomPainter {
  _ArtPainter(this.art, this.tint);
  final EmptyArt art;
  final Color tint;

  static const _depth = 7;

  @override
  void paint(Canvas canvas, Size size) {
    final drawing = _draw(art);
    canvas.save();
    canvas.scale(size.width / 100, size.height / 100);

    final deep = Color.lerp(tint, Colors.black, .32)!;
    final all = _union([for (final p in drawing.parts) p.path]);
    final bounds = all.getBounds();

    // A soft contact shadow under the whole piece.
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(bounds.center.dx + 3, bounds.bottom + 6),
        width: bounds.width * .8,
        height: 9,
      ),
      Paint()
        ..color = deep.withValues(alpha: .3)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    for (final part in drawing.parts) {
      final front = part.soft
          ? [
              Color.lerp(tint, Colors.white, .72)!,
              Color.lerp(tint, Colors.white, .5)!,
            ]
          : [Color.lerp(tint, Colors.white, .32)!, tint];
      final side = part.soft
          ? Color.lerp(tint, Colors.white, .25)!
          : Color.lerp(tint, Colors.black, .22)!;

      // The body's depth: the face stacked back down and to the right.
      final sidePaint = Paint()..color = side;
      for (var i = _depth; i > 0; i--) {
        canvas.drawPath(part.path.shift(Offset(i * .45, i * .7)), sidePaint);
      }

      final r = part.path.getBounds();
      canvas.drawPath(
        part.path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: front,
          ).createShader(r),
      );

      // Light caught along the top-left inner edge.
      canvas.save();
      canvas.clipPath(part.path);
      canvas.drawPath(
        part.path.shift(const Offset(1.4, 2)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3
          ..color = Colors.white.withValues(alpha: part.soft ? .55 : .42),
      );
      canvas.restore();
    }

    final detail = drawing.detail;
    if (detail != null) {
      final stroke = drawing.detailStroke;
      Paint style(Paint p) => stroke == null
          ? p
          : (p
              ..style = PaintingStyle.stroke
              ..strokeWidth = stroke
              ..strokeCap = StrokeCap.round
              ..strokeJoin = StrokeJoin.round);
      // Raised: a shadow cast down-right, then the white mark.
      canvas.drawPath(
        detail.shift(const Offset(1.2, 1.8)),
        style(Paint()..color = deep.withValues(alpha: .45)),
      );
      canvas.drawPath(
        detail,
        style(
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.white, Color.lerp(tint, Colors.white, .82)!],
            ).createShader(detail.getBounds().inflate(stroke ?? 0)),
        ),
      );
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArtPainter old) => art != old.art || tint != old.tint;
}

/// The big glass lens an [EmptyArtwork] rests in: a pale, accent-tinted
/// disc with a bright rim and a broad coloured shadow.
class GlassLens extends StatelessWidget {
  const GlassLens({super.key, required this.child, this.size = 128});
  final Widget child;
  final double size;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final accent = theme.colorScheme.primary;
    if (usesGlass(context) &&
        theme.extension<AppChrome>()?.cardBorder == null) {
      return _glass(context, dark, accent);
    }
    final fill = dark
        ? [
            Color.lerp(const Color(0xff2a2a30), accent, .28)!,
            Color.lerp(const Color(0xff18181c), accent, .14)!,
          ]
        : [
            Color.lerp(accent, Colors.white, .95)!,
            Color.lerp(accent, Colors.white, .8)!,
          ];
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          center: const Alignment(-.3, -.4),
          radius: 1,
          colors: fill,
        ),
        border: Border.all(
          color: Colors.white.withValues(alpha: dark ? .16 : .95),
          width: 2,
        ),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: dark ? .3 : .22),
            blurRadius: size * .4,
            offset: Offset(0, size * .08),
            spreadRadius: -size * .1,
          ),
        ],
      ),
      child: child,
    );
  }

  /// The glass styles: a pale disc of the accent with a soft light ring and a
  /// faint glow. The page colour sits under the tint so the panel's dashed
  /// edge never shows through; over a picture the disc is frosted as well.
  Widget _glass(BuildContext context, bool dark, Color accent) {
    final theme = Theme.of(context);
    final frosted =
        usesAurora(context) &&
        AppearanceScope.maybeOf(context)?.wallpaperPath != null;
    Color white(double a) => Colors.white.withValues(alpha: a);
    final base = theme.scaffoldBackgroundColor.withValues(
      alpha: frosted ? .5 : 1,
    );
    Widget disc = DecoratedBox(
      decoration: BoxDecoration(shape: BoxShape.circle, color: base),
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          // A pale wash of the accent, lit from the top left.
          gradient: RadialGradient(
            center: const Alignment(-.35, -.5),
            radius: 1.1,
            colors: dark
                ? [
                    Color.alphaBlend(accent.withValues(alpha: .30), white(.07)),
                    accent.withValues(alpha: .09),
                  ]
                : [
                    Color.lerp(accent, Colors.white, .9)!,
                    Color.lerp(accent, Colors.white, .78)!,
                  ],
          ),
        ),
        child: Center(child: child),
      ),
    );
    disc = ClipOval(
      child: frosted
          ? BackdropFilter(
              filter: ui.ImageFilter.blur(
                sigmaX: 22,
                sigmaY: 22,
                tileMode: TileMode.mirror,
              ),
              child: disc,
            )
          : disc,
    );
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        // A soft light ring round the glass, and a faint glow under it.
        color: white(dark ? .26 : .95),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: dark ? .22 : .18),
            blurRadius: size * .4,
            offset: Offset(0, size * .08),
            spreadRadius: -size * .1,
          ),
        ],
      ),
      child: disc,
    );
  }
}

/// A dashed rounded outline with a small speech-bubble notch at the bottom
/// centre, over a faint glass fill.
class DashedNotchPanel extends StatelessWidget {
  const DashedNotchPanel({super.key, required this.child, this.padding});
  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final glass =
        usesGlass(context) && theme.extension<AppChrome>()?.cardBorder == null;
    final frosted =
        glass &&
        usesAurora(context) &&
        AppearanceScope.maybeOf(context)?.wallpaperPath != null;
    Widget panel = CustomPaint(
      painter: _DashedNotchPainter(
        stroke: theme.colorScheme.onSurface.withValues(alpha: dark ? .2 : .18),
        fill: Colors.white.withValues(alpha: dark ? .03 : .4),
        // On glass: the same see-through fill as the cards around it.
        gradient: glass ? glassCardFill(context) : null,
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: child,
      ),
    );
    if (frosted) {
      panel = ClipPath(
        clipper: const _NotchClipper(),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: 22,
            sigmaY: 22,
            tileMode: TileMode.mirror,
          ),
          child: panel,
        ),
      );
    }
    return panel;
  }
}

/// The panel's outline, without the notch, for clipping the frosted blur.
class _NotchClipper extends CustomClipper<Path> {
  const _NotchClipper();

  @override
  Path getClip(Size size) => Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        Offset.zero & size,
        const Radius.circular(_DashedNotchPainter._radius),
      ),
    );

  @override
  bool shouldReclip(_NotchClipper oldClipper) => false;
}

class _DashedNotchPainter extends CustomPainter {
  const _DashedNotchPainter({
    required this.stroke,
    required this.fill,
    this.gradient,
  });
  final Color stroke, fill;
  final Gradient? gradient;

  static const _radius = 28.0;
  static const _notch = 9.0;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height, r = _radius;
    const corner = Radius.circular(_radius);
    final path = Path()
      ..moveTo(r, 0)
      ..lineTo(w - r, 0)
      ..arcToPoint(Offset(w, r), radius: corner)
      ..lineTo(w, h - r)
      ..arcToPoint(Offset(w - r, h), radius: corner)
      ..lineTo(w / 2 + _notch, h)
      ..lineTo(w / 2, h + _notch)
      ..lineTo(w / 2 - _notch, h)
      ..lineTo(r, h)
      ..arcToPoint(Offset(0, h - r), radius: corner)
      ..lineTo(0, r)
      ..arcToPoint(Offset(r, 0), radius: corner)
      ..close();
    canvas.drawPath(
      path,
      gradient == null
          ? (Paint()..color = fill)
          : (Paint()..shader = gradient!.createShader(Offset.zero & size)),
    );

    final dash = Paint()
      ..color = stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    for (final metric in path.computeMetrics()) {
      for (var d = 0.0; d < metric.length; d += 11) {
        canvas.drawPath(metric.extractPath(d, d + 6), dash);
      }
    }
  }

  @override
  bool shouldRepaint(_DashedNotchPainter old) =>
      stroke != old.stroke || fill != old.fill || gradient != old.gradient;
}
