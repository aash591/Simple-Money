import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../state/appearance_controller.dart' show AppearanceScope;
import '../theme/app_theme.dart' show AppChrome, usesAurora, usesGlass;
import 'dashed_outline.dart' show dashPath, paintCached;
import 'glass_blur.dart';
import 'glass_surface.dart' show glassCardFill;

/// Hand-drawn glass artwork for the app's empty states and menu icons.
///
/// Every piece follows one recipe: a big frosted glass shape that is mostly
/// see-through, with a small solid blob of the accent peeking out from
/// behind it (seen blurred through the glass), a light rim and a soft white
/// glow along the inner top edge, and a faint cast shadow. On a dark page the
/// glass turns to tinted smoke with a small glow of the accent.
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
  handshake,
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
  upload,
  sparkles,
  gear,
  history,
  help,
  info,
  premium,
  currency,
  cloud,
  download,
  shield,
  document,
  code,
  lock,
  palette,
  image,
  vibration,
  bell,
  phone,
  table,
  star,
  check,
  cloudOff,
  blur,
  qr,
  layers,
  sun,
  moon,
  moonStars,
  autoTheme,
  pie,
  noAds,
  eyeOff,
  fingerprint,
  chart,
}

/// The artwork drawn for the Material icon an empty state was given, so
/// call sites keep naming the icon that describes them.
EmptyArt emptyArtFor(IconData icon) =>
    _byIcon[icon.codePoint] ?? EmptyArt.folder;

/// The artwork for a menu row's [icon], or null when it has none yet and the
/// row keeps its plain icon tile.
EmptyArt? menuArtFor(IconData icon) => _byIcon[icon.codePoint];

final _byIcon = <int, EmptyArt>{
  Icons.savings_outlined.codePoint: EmptyArt.coins,
  Icons.archive_outlined.codePoint: EmptyArt.archive,
  Icons.account_balance_wallet_outlined.codePoint: EmptyArt.wallet,
  Icons.account_balance_wallet_rounded.codePoint: EmptyArt.wallet,
  Icons.error_outline_rounded.codePoint: EmptyArt.warning,
  Icons.groups_outlined.codePoint: EmptyArt.people,
  Icons.grid_view_rounded.codePoint: EmptyArt.grid,
  Icons.category_rounded.codePoint: EmptyArt.grid,
  Icons.handshake_outlined.codePoint: EmptyArt.handshake,
  Icons.handshake_rounded.codePoint: EmptyArt.handshake,
  Icons.sms_outlined.codePoint: EmptyArt.chat,
  Icons.account_balance_outlined.codePoint: EmptyArt.bank,
  Icons.account_balance_rounded.codePoint: EmptyArt.bank,
  Icons.receipt_long_outlined.codePoint: EmptyArt.receipt,
  Icons.autorenew_rounded.codePoint: EmptyArt.calendar,
  Icons.mark_chat_read_outlined.codePoint: EmptyArt.chatRead,
  Icons.search_off_rounded.codePoint: EmptyArt.search,
  Icons.swap_vert_rounded.codePoint: EmptyArt.transfer,
  Icons.upload_file_rounded.codePoint: EmptyArt.upload,
  Icons.auto_awesome_rounded.codePoint: EmptyArt.sparkles,
  Icons.settings_rounded.codePoint: EmptyArt.gear,
  Icons.history_rounded.codePoint: EmptyArt.history,
  Icons.help_rounded.codePoint: EmptyArt.help,
  Icons.info_rounded.codePoint: EmptyArt.info,
  Icons.workspace_premium_rounded.codePoint: EmptyArt.premium,
  Icons.currency_exchange_rounded.codePoint: EmptyArt.currency,
  Icons.cloud_rounded.codePoint: EmptyArt.cloud,
  Icons.sms_rounded.codePoint: EmptyArt.chat,
  Icons.privacy_tip_rounded.codePoint: EmptyArt.shield,
  Icons.gavel_rounded.codePoint: EmptyArt.document,
  Icons.code_rounded.codePoint: EmptyArt.code,
  Icons.lock_rounded.codePoint: EmptyArt.lock,
  Icons.palette_rounded.codePoint: EmptyArt.palette,
  Icons.wallpaper_outlined.codePoint: EmptyArt.image,
  Icons.vibration_rounded.codePoint: EmptyArt.vibration,
  Icons.notifications_active_rounded.codePoint: EmptyArt.bell,
  Icons.phone_android_rounded.codePoint: EmptyArt.phone,
  Icons.table_chart_rounded.codePoint: EmptyArt.table,
  Icons.star_rounded.codePoint: EmptyArt.star,
  Icons.rate_review_outlined.codePoint: EmptyArt.star,
  Icons.task_alt_rounded.codePoint: EmptyArt.check,
  Icons.cloud_off_rounded.codePoint: EmptyArt.cloudOff,
  Icons.blur_on_rounded.codePoint: EmptyArt.blur,
  Icons.qr_code_scanner_rounded.codePoint: EmptyArt.qr,
  Icons.file_download_rounded.codePoint: EmptyArt.download,
  Icons.file_upload_rounded.codePoint: EmptyArt.upload,
  Icons.receipt_long_rounded.codePoint: EmptyArt.receipt,
  Icons.groups_rounded.codePoint: EmptyArt.people,
  Icons.folder_rounded.codePoint: EmptyArt.folder,
  Icons.auto_awesome_outlined.codePoint: EmptyArt.sparkles,
  Icons.dashboard_customize_rounded.codePoint: EmptyArt.grid,
  Icons.manage_search_rounded.codePoint: EmptyArt.search,
  Icons.sms_failed_rounded.codePoint: EmptyArt.warning,
  Icons.layers_outlined.codePoint: EmptyArt.layers,
  Icons.light_mode_rounded.codePoint: EmptyArt.sun,
  Icons.dark_mode_rounded.codePoint: EmptyArt.moon,
  Icons.nightlight_rounded.codePoint: EmptyArt.moonStars,
  Icons.brightness_auto_rounded.codePoint: EmptyArt.autoTheme,
  Icons.pie_chart_rounded.codePoint: EmptyArt.pie,
  Icons.web_asset_off_rounded.codePoint: EmptyArt.noAds,
  Icons.visibility_off_outlined.codePoint: EmptyArt.eyeOff,
  Icons.fingerprint_rounded.codePoint: EmptyArt.fingerprint,
  Icons.show_chart_rounded.codePoint: EmptyArt.chart,
  Icons.candlestick_chart_rounded.codePoint: EmptyArt.chart,
  Icons.lock_outline_rounded.codePoint: EmptyArt.lock,
  Icons.phonelink_lock_outlined.codePoint: EmptyArt.phone,
  Icons.layers_clear_outlined.codePoint: EmptyArt.layers,
  Icons.timer_outlined.codePoint: EmptyArt.history,
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
      painter: _ArtPainter(
        art,
        tint ?? Theme.of(context).colorScheme.primary,
        dark: Theme.of(context).brightness == Brightness.dark,
        pixelRatio: MediaQuery.maybeDevicePixelRatioOf(context) ?? 1,
        // Only Glassy and Aurora get the glass artwork; Simple keeps the
        // original extruded 3D artwork.
        classic: !usesGlass(context),
      ),
    ),
  );
}

/// The artwork drawn once into bitmaps and kept, so painting an icon is a
/// single image copy: the glass recipe (path unions, several blurs, clips)
/// runs only the first time an icon is shown at a given size, colour and
/// brightness — scrolling a list of them costs next to nothing, even on a
/// slow phone.
abstract final class _ArtCache {
  /// Room round the 100 × 100 box for the shadow and glow, in box units.
  static const margin = 32.0;
  static const _maxImages = 64;

  /// Least recently used first.
  static final _images = <(EmptyArt, int, bool, int, bool), ui.Image>{};

  static ui.Image image(_ArtPainter painter, int pixels) {
    final key = (
      painter.art,
      painter.tint.toARGB32(),
      painter.dark,
      pixels,
      painter.classic,
    );
    final hit = _images.remove(key);
    if (hit != null) return _images[key] = hit;

    const span = 100 + 2 * margin;
    final full = (pixels * span / 100).ceil();
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder)
      ..scale(full / span)
      ..translate(margin, margin);
    painter._paintArt(canvas);
    final picture = recorder.endRecording();
    final image = picture.toImageSync(full, full);
    picture.dispose();

    _images[key] = image;
    if (_images.length > _maxImages) {
      _images.remove(_images.keys.first)!.dispose();
    }
    return image;
  }
}

/// A piece of the artwork. [soft] pieces are the solid blobs behind; the
/// rest are the frosted glass in front.
class _Part {
  const _Part(this.path, {this.soft = false});
  final Path path;
  final bool soft;
}

class _Drawing {
  const _Drawing(this.parts, {this.detail, this.detailStroke});
  final List<_Part> parts;

  /// White marks on the glass.
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

/// A full, even cloud: two shoulders and a tall centre on a flat base.
Path _cloudShape() => _union([
  _circle(30, 52, 17),
  _circle(52, 36, 24),
  _circle(70, 46, 17),
  _rr(8, 46, 87, 74, 14),
]);

/// Two arrows chasing each other round [c], the usual sync mark, as one
/// filled shape: a curved band of [width] ending in a triangular head.
Path _syncArrows(Offset c, double r, double width) {
  Offset at(double deg, double radius) {
    final a = deg * math.pi / 180;
    return c + Offset(math.cos(a), math.sin(a)) * radius;
  }

  final parts = <Path>[];
  for (final start in const [205.0, 25.0]) {
    const sweep = 115.0;
    final end = start + sweep;
    final outer = Rect.fromCircle(center: c, radius: r + width / 2);
    final inner = Rect.fromCircle(center: c, radius: r - width / 2);
    final band = Path()
      ..arcTo(outer, start * math.pi / 180, sweep * math.pi / 180, true)
      ..arcTo(inner, end * math.pi / 180, -sweep * math.pi / 180, false)
      ..close();
    final tail = at(start, r);
    final head = _roundedPoly([
      at(end, r + width * 1.15),
      at(end + 40, r),
      at(end, r - width * 1.15),
    ], 1.2);
    parts.addAll([band, _circle(tail.dx, tail.dy, width / 2), head]);
  }
  return _union(parts);
}

Path _minus(Path a, Path b) => Path.combine(PathOperation.difference, a, b);

Path _rotated(Path path, double degrees, Offset around) {
  final a = degrees * math.pi / 180;
  final m = Matrix4.identity()
    ..translateByDouble(around.dx, around.dy, 0, 1)
    ..rotateZ(a)
    ..translateByDouble(-around.dx, -around.dy, 0, 1);
  return path.transform(m.storage);
}

/// A polygon through [points] with every corner rounded by [radius].
Path _roundedPoly(List<Offset> points, double radius) {
  final path = Path();
  final n = points.length;
  for (var i = 0; i < n; i++) {
    final prev = points[(i - 1 + n) % n];
    final at = points[i];
    final next = points[(i + 1) % n];
    Offset toward(Offset to) {
      final d = to - at;
      return at + d / d.distance * math.min(radius, d.distance / 2);
    }

    final a = toward(prev), b = toward(next);
    i == 0 ? path.moveTo(a.dx, a.dy) : path.lineTo(a.dx, a.dy);
    path.quadraticBezierTo(at.dx, at.dy, b.dx, b.dy);
  }
  return path..close();
}

/// A chunky horizontal arrow along [y], its tail at [from] and its point at
/// [tip], with every corner rounded.
Path _arrow({
  required double y,
  required double from,
  required double tip,
  double shaft = 21,
  double head = 50,
  double length = 31,
}) {
  final dir = tip > from ? 1.0 : -1.0;
  final neck = tip - dir * length;
  // The shaft runs a little into the head so the two join smoothly.
  final joint = neck + dir * 6;
  final tail = math.min(from, joint), end = math.max(from, joint);
  return _union([
    _rr(tail, y - shaft / 2, end, y + shaft / 2, shaft / 2),
    _roundedPoly([
      Offset(tip, y),
      Offset(neck, y + head / 2),
      Offset(neck, y - head / 2),
    ], 6),
  ]);
}

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

/// A solid blob peeking out from behind the glass.
_Part _blob(double x, double y, double r) =>
    _Part(_circle(x, y, r), soft: true);

/// A line through [points] as one open path, for stroked marks.
Path _line(List<double> xy) {
  final path = Path()..moveTo(xy[0], xy[1]);
  for (var i = 2; i < xy.length; i += 2) {
    path.lineTo(xy[i], xy[i + 1]);
  }
  return path;
}

_Drawing _draw(EmptyArt art) {
  switch (art) {
    case EmptyArt.folder:
      return _Drawing(
        [
          _blob(80, 24, 13),
          _Part(_union([_rr(10, 22, 46, 42, 8), _rr(10, 32, 90, 84, 13)])),
        ],
        detail: _line([50, 50, 50, 72])
          ..addPath(_line([39, 61, 61, 61]), Offset.zero),
        detailStroke: 6.5,
      );
    case EmptyArt.wallet:
      return _Drawing([
        _blob(24, 24, 14),
        _Part(_rr(10, 30, 90, 86, 15)),
      ], detail: _union([_circle(72, 58, 5.5), _rr(58, 55.5, 66, 60.5, 2.5)]));
    case EmptyArt.coins:
      return _Drawing([
        _blob(82, 18, 12),
        _Part(_rr(12, 66, 84, 86, 10)),
        _Part(_rr(18, 46, 90, 66, 10)),
        _Part(_rr(10, 26, 82, 46, 10)),
      ]);
    case EmptyArt.grid:
      return _Drawing(
        [
          _Part(_rr(54, 12, 88, 46, 12), soft: true),
          _Part(_rr(12, 12, 46, 46, 12)),
          _Part(_rr(12, 54, 46, 88, 12)),
          _Part(_rr(54, 54, 88, 88, 12)),
        ],
        detail: _line([71, 64, 71, 78])
          ..addPath(_line([64, 71, 78, 71]), Offset.zero),
        detailStroke: 5,
      );
    case EmptyArt.swapCards:
      // Money going both ways: two arrows passing each other, one piece.
      return _Drawing([
        _blob(26, 27, 16),
        _Part(
          _union([
            _arrow(y: 35, from: 14, tip: 88, shaft: 17, head: 38, length: 28),
            _arrow(y: 67, from: 86, tip: 12, shaft: 17, head: 38, length: 28),
          ]),
        ),
      ]);
    case EmptyArt.handshake:
      // Two cuffs and two hands rising to meet in a clasp.
      return _Drawing(
        [
          _Part(_rr(2, 30, 18, 72, 6), soft: true),
          _Part(_rr(82, 30, 98, 72, 6), soft: true),
          _Part(
            _union([
              _rotated(_rr(16, 34, 64, 64, 15), -22, const Offset(40, 49)),
              _rotated(_rr(36, 34, 84, 64, 15), 22, const Offset(60, 49)),
              _rr(34, 44, 66, 80, 14),
            ]),
          ),
        ],
        // The fingers wrapping over.
        detail: _line([42, 62, 52, 72])
          ..addPath(_line([50, 54, 60, 64]), Offset.zero)
          ..addPath(_line([58, 46, 68, 56]), Offset.zero),
        detailStroke: 4.5,
      );
    case EmptyArt.bank:
      return _Drawing([
        _blob(18, 26, 11),
        _Part(
          _roundedPoly(const [Offset(50, 8), Offset(92, 34), Offset(8, 34)], 5),
        ),
        _Part(_rr(18, 42, 32, 76, 5)),
        _Part(_rr(43, 42, 57, 76, 5)),
        _Part(_rr(68, 42, 82, 76, 5)),
        _Part(_rr(8, 80, 92, 92, 6)),
      ]);
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
        [_blob(20, 20, 13), _Part(body)],
        detail: _line([32, 28, 68, 28])
          ..addPath(_line([32, 44, 58, 44]), Offset.zero)
          ..addPath(_line([32, 60, 50, 60]), Offset.zero),
        detailStroke: 5,
      );
    case EmptyArt.calendar:
      return _Drawing(
        [
          _Part(_rr(26, 6, 38, 32, 6), soft: true),
          _Part(_rr(62, 6, 74, 32, 6), soft: true),
          _Part(_rr(12, 20, 88, 88, 15)),
        ],
        detail: _line([34, 58, 46, 70, 68, 46]),
        detailStroke: 8,
      );
    case EmptyArt.chat:
    case EmptyArt.chatRead:
      final bubble = _union([
        _rr(10, 16, 90, 70, 20),
        _poly([22, 62, 18, 88, 44, 66]),
      ]);
      return _Drawing(
        [_blob(80, 20, 12), _Part(bubble)],
        detail: art == EmptyArt.chatRead
            ? _line([34, 43, 45, 54, 66, 33])
            : _union([
                _circle(32, 43, 5.5),
                _circle(50, 43, 5.5),
                _circle(68, 43, 5.5),
              ]),
        detailStroke: art == EmptyArt.chatRead ? 8 : null,
      );
    case EmptyArt.archive:
      return _Drawing(
        [
          _Part(_rr(16, 32, 84, 88, 12), soft: true),
          _Part(_rr(8, 14, 92, 42, 11)),
        ],
        detail: _line([40, 56, 60, 56]),
        detailStroke: 7,
      );
    case EmptyArt.warning:
      return _Drawing([
        _blob(82, 22, 11),
        _Part(_rotated(_rr(20, 20, 80, 80, 14), 45, const Offset(50, 50))),
      ], detail: _union([_rr(45.5, 28, 54.5, 56, 4.5), _circle(50, 67, 5)]));
    case EmptyArt.people:
      return _Drawing([
        _blob(70, 28, 12),
        _Part(_rr(48, 44, 92, 80, 18), soft: true),
        _Part(_circle(38, 34, 15)),
        _Part(_rr(10, 54, 66, 90, 20)),
      ]);
    case EmptyArt.transfer:
      return _Drawing(
        [_blob(80, 20, 12), _Part(_rr(12, 14, 88, 90, 26))],
        detail: _union([
          _rr(34, 36, 42, 72, 4),
          _poly([25, 43, 38, 28, 51, 43]),
          _rr(58, 32, 66, 68, 4),
          _poly([49, 61, 62, 76, 75, 61]),
        ]),
      );
    case EmptyArt.chart:
      // Three bars climbing, with a trend arrow rising over them.
      return _Drawing(
        [
          _blob(20, 22, 12),
          _Part(_rr(10, 62, 32, 90, 7)),
          _Part(_rr(39, 48, 61, 90, 7)),
          _Part(_rr(68, 32, 90, 90, 7)),
        ],
        detail: _line([14, 46, 38, 28, 52, 38, 82, 10])
          ..addPath(_line([66, 10, 82, 10, 82, 26]), Offset.zero),
        detailStroke: 5.5,
      );
    case EmptyArt.search:
      return _Drawing([
        _Part(_poly([60.8, 70.2, 69.2, 61.8, 91.2, 83.8, 82.8, 92.2])),
        _blob(72, 22, 11),
        _Part(_circle(42, 42, 30)),
      ]);
    case EmptyArt.upload:
      return _Drawing([
        _blob(82, 24, 11),
        _Part(
          _union([
            _rr(14, 54, 29, 88, 8),
            _rr(71, 54, 86, 88, 8),
            _rr(14, 74, 86, 88, 8),
          ]),
        ),
        _Part(
          _union([
            _rr(43, 34, 57, 68, 7),
            _roundedPoly(const [
              Offset(50, 10),
              Offset(74, 40),
              Offset(26, 40),
            ], 6),
          ]),
        ),
      ]);
    case EmptyArt.sparkles:
      return _Drawing([
        _Part(_sparkle(76, 24, 17), soft: true),
        _Part(_sparkle(44, 58, 38)),
        _Part(_sparkle(20, 22, 10)),
      ]);
    case EmptyArt.gear:
      final teeth = [
        for (var i = 0; i < 8; i++)
          _rotated(_rr(42, 8, 58, 30, 5), i * 45.0, const Offset(50, 50)),
      ];
      return _Drawing([
        _blob(82, 18, 11),
        _Part(
          _minus(_union([_circle(50, 50, 31), ...teeth]), _circle(50, 50, 12)),
        ),
      ]);
    case EmptyArt.history:
      return _Drawing(
        [_blob(22, 24, 13), _Part(_circle(52, 54, 36))],
        detail: _line([52, 34, 52, 54, 66, 62]),
        detailStroke: 6,
      );
    case EmptyArt.help:
      return _Drawing(
        [_blob(80, 20, 11), _Part(_circle(50, 52, 38))],
        detail: Path()
          ..moveTo(38, 42)
          ..cubicTo(38, 27, 62, 27, 62, 41)
          ..cubicTo(62, 51, 50, 51, 50, 62)
          ..moveTo(50, 74)
          ..lineTo(50, 74.01),
        detailStroke: 7,
      );
    case EmptyArt.info:
      return _Drawing(
        [_blob(80, 20, 11), _Part(_circle(50, 52, 38))],
        detail: Path()
          ..moveTo(50, 34)
          ..lineTo(50, 34.01)
          ..moveTo(50, 48)
          ..lineTo(50, 72),
        detailStroke: 8,
      );
    case EmptyArt.currency:
      return _Drawing(
        [_blob(78, 22, 11), _Part(_circle(50, 54, 36))],
        detail: _line([34, 44, 66, 44, 58, 37])
          ..addPath(_line([66, 44, 58, 51]), Offset.zero)
          ..addPath(_line([66, 64, 34, 64, 42, 57]), Offset.zero)
          ..addPath(_line([34, 64, 42, 71]), Offset.zero),
        detailStroke: 5.5,
      );
    case EmptyArt.cloud:
      // A cloud with a round sync badge at its lower right, set in a
      // notch so the two read apart.
      const badge = Offset(75, 73);
      return _Drawing([
        _Part(_minus(_cloudShape(), _circle(badge.dx, badge.dy, 24))),
        _Part(_circle(badge.dx, badge.dy, 18.5), soft: true),
      ], detail: _syncArrows(badge, 9.5, 4.4));
    case EmptyArt.download:
      return _Drawing([
        _blob(82, 24, 11),
        _Part(
          _union([
            _rr(14, 54, 29, 88, 8),
            _rr(71, 54, 86, 88, 8),
            _rr(14, 74, 86, 88, 8),
          ]),
        ),
        _Part(
          _union([
            _rr(43, 12, 57, 46, 7),
            _roundedPoly(const [
              Offset(50, 70),
              Offset(26, 40),
              Offset(74, 40),
            ], 6),
          ]),
        ),
      ]);
    case EmptyArt.shield:
      return _Drawing(
        [
          _blob(84, 16, 10),
          _Part(
            _roundedPoly(const [
              Offset(50, 8),
              Offset(88, 22),
              Offset(86, 56),
              Offset(50, 92),
              Offset(14, 56),
              Offset(12, 22),
            ], 10),
          ),
        ],
        detail: Path()
          ..moveTo(50, 33)
          ..lineTo(50, 33.01)
          ..moveTo(50, 46)
          ..lineTo(50, 66),
        detailStroke: 7.5,
      );
    case EmptyArt.document:
      return _Drawing(
        [_blob(22, 18, 11), _Part(_rr(18, 8, 82, 92, 13))],
        detail: _line([32, 34, 68, 34])
          ..addPath(_line([32, 50, 68, 50]), Offset.zero)
          ..addPath(_line([32, 66, 52, 66]), Offset.zero),
        detailStroke: 5.5,
      );
    case EmptyArt.code:
      return _Drawing(
        [_blob(80, 18, 11), _Part(_rr(10, 16, 90, 84, 18))],
        detail: _line([38, 38, 26, 50, 38, 62])
          ..addPath(_line([62, 38, 74, 50, 62, 62]), Offset.zero)
          ..addPath(_line([55, 36, 45, 64]), Offset.zero),
        detailStroke: 6.5,
      );
    case EmptyArt.lock:
      return _Drawing([
        _Part(
          _minus(_rr(28, 8, 72, 58, 22), _rr(40, 20, 60, 58, 10)),
          soft: true,
        ),
        _Part(_rr(16, 42, 84, 90, 14)),
      ], detail: _union([_circle(50, 62, 6), _rr(47, 62, 53, 76, 3)]));
    case EmptyArt.palette:
      return _Drawing(
        [
          _blob(20, 20, 11),
          _Part(_minus(_circle(50, 52, 38), _circle(68, 72, 9))),
        ],
        detail: _union([
          _circle(30, 50, 5),
          _circle(42, 32, 5),
          _circle(62, 32, 5),
          _circle(74, 50, 5),
        ]),
      );
    case EmptyArt.image:
      return _Drawing(
        [_blob(20, 16, 10), _Part(_rr(10, 20, 90, 84, 14))],
        detail: _union([
          _roundedPoly(const [
            Offset(20, 74),
            Offset(40, 48),
            Offset(54, 64),
            Offset(64, 54),
            Offset(80, 74),
          ], 3),
          _circle(68, 36, 6),
        ]),
      );
    case EmptyArt.vibration:
      return _Drawing([
        _Part(_rr(8, 28, 18, 72, 5), soft: true),
        _Part(_rr(82, 28, 92, 72, 5), soft: true),
        _Part(_rr(30, 10, 70, 90, 13)),
      ]);
    case EmptyArt.bell:
      return _Drawing([
        _blob(50, 86, 9),
        _Part(
          _roundedPoly(const [
            Offset(40, 10),
            Offset(60, 10),
            Offset(78, 56),
            Offset(92, 72),
            Offset(8, 72),
            Offset(22, 56),
          ], 10),
        ),
      ]);
    case EmptyArt.phone:
      return _Drawing(
        [_blob(76, 22, 10), _Part(_rr(26, 8, 74, 92, 15))],
        detail: _line([42, 22, 58, 22]),
        detailStroke: 5,
      );
    case EmptyArt.table:
      return _Drawing(
        [_blob(82, 18, 10), _Part(_rr(10, 18, 90, 84, 13))],
        detail: _line([16, 40, 84, 40])
          ..addPath(_line([16, 62, 84, 62]), Offset.zero)
          ..addPath(_line([42, 40, 42, 78]), Offset.zero),
        detailStroke: 4.5,
      );
    case EmptyArt.star:
      return _Drawing([
        _blob(84, 16, 9),
        _Part(
          _roundedPoly([
            for (var i = 0; i < 10; i++)
              Offset(
                50 +
                    (i.isEven ? 42 : 19) *
                        math.cos(-math.pi / 2 + i * math.pi / 5),
                54 +
                    (i.isEven ? 42 : 19) *
                        math.sin(-math.pi / 2 + i * math.pi / 5),
              ),
          ], 6),
        ),
      ]);
    case EmptyArt.check:
      return _Drawing(
        [_blob(80, 18, 11), _Part(_circle(50, 52, 38))],
        detail: _line([32, 52, 44, 64, 68, 40]),
        detailStroke: 8,
      );
    case EmptyArt.cloudOff:
      return _Drawing(
        [_blob(84, 20, 10), _Part(_cloudShape())],
        detail: _line([24, 20, 80, 84]),
        detailStroke: 7,
      );
    case EmptyArt.blur:
      return _Drawing([
        _blob(80, 20, 11),
        _Part(_circle(38, 40, 24)),
        _Part(_circle(64, 44, 24)),
        _Part(_circle(48, 66, 24)),
      ]);
    case EmptyArt.qr:
      return _Drawing(
        [
          _Part(_rr(44, 44, 56, 56, 5), soft: true),
          _Part(_rr(12, 12, 42, 42, 9)),
          _Part(_rr(58, 12, 88, 42, 9)),
          _Part(_rr(12, 58, 42, 88, 9)),
        ],
        detail: _union([
          _rr(60, 60, 70, 70, 3),
          _rr(76, 60, 88, 70, 3),
          _rr(60, 76, 70, 88, 3),
          _rr(76, 76, 88, 88, 3),
        ]),
      );
    case EmptyArt.layers:
      return _Drawing([
        _Part(
          _roundedPoly(const [
            Offset(50, 46),
            Offset(92, 66),
            Offset(50, 86),
            Offset(8, 66),
          ], 9),
          soft: true,
        ),
        _Part(
          _roundedPoly(const [
            Offset(50, 14),
            Offset(92, 36),
            Offset(50, 58),
            Offset(8, 36),
          ], 9),
        ),
      ]);
    case EmptyArt.sun:
      return _Drawing([
        _Part(
          _union([
            for (var i = 0; i < 8; i++)
              _rotated(_rr(45, 6, 55, 22, 5), i * 45.0, const Offset(50, 50)),
          ]),
          soft: true,
        ),
        _Part(_circle(50, 50, 25)),
      ]);
    case EmptyArt.moon:
    case EmptyArt.moonStars:
      final crescent = _minus(_circle(44, 56, 36), _circle(72, 34, 31));
      return _Drawing([
        if (art == EmptyArt.moonStars) ...[
          _Part(_sparkle(76, 26, 13), soft: true),
          _Part(_sparkle(88, 52, 7), soft: true),
        ] else
          _blob(78, 26, 9),
        _Part(crescent),
      ]);
    case EmptyArt.autoTheme:
      return _Drawing(
        [_blob(80, 20, 11), _Part(_circle(50, 52, 38))],
        detail: _line([36, 70, 50, 34, 64, 70])
          ..addPath(_line([41, 58, 59, 58]), Offset.zero),
        detailStroke: 6.5,
      );
    case EmptyArt.pie:
      // A glass pie with its top-right slice pulled out, solid.
      Path wedge(double x, double y, double r) => Path()
        ..moveTo(x, y)
        ..arcTo(
          Rect.fromCircle(center: Offset(x, y), radius: r),
          -math.pi / 2,
          math.pi / 2,
          false,
        )
        ..close();
      return _Drawing([
        _Part(wedge(55, 47, 36), soft: true),
        _Part(_minus(_circle(46, 56, 36), wedge(46, 56, 40))),
      ]);
    case EmptyArt.noAds:
      return _Drawing(
        [_blob(84, 16, 10), _Part(_rr(10, 20, 90, 82, 14))],
        detail: _line([24, 26, 76, 76]),
        detailStroke: 7,
      );
    case EmptyArt.eyeOff:
      return _Drawing(
        [
          _blob(50, 50, 15),
          _Part(
            Path()
              ..moveTo(6, 50)
              ..quadraticBezierTo(50, 4, 94, 50)
              ..quadraticBezierTo(50, 96, 6, 50)
              ..close(),
          ),
        ],
        detail: _line([34, 32, 66, 68]),
        detailStroke: 7,
      );
    case EmptyArt.fingerprint:
      final ridges = Path();
      for (final r in const [10.0, 19.0, 28.0]) {
        ridges.arcTo(
          Rect.fromCircle(center: const Offset(50, 52), radius: r),
          math.pi * .92,
          math.pi * 1.16,
          true,
        );
      }
      ridges
        ..moveTo(50, 52)
        ..lineTo(50, 72);
      return _Drawing(
        [_blob(80, 18, 10), _Part(_circle(50, 52, 40))],
        detail: ridges,
        detailStroke: 5,
      );
    case EmptyArt.premium:
      return _Drawing([
        _blob(50, 14, 10),
        _Part(
          _roundedPoly(const [
            Offset(10, 34),
            Offset(32, 54),
            Offset(50, 22),
            Offset(68, 54),
            Offset(90, 34),
            Offset(82, 82),
            Offset(18, 82),
          ], 6),
        ),
      ]);
  }
}

class _ArtPainter extends CustomPainter {
  _ArtPainter(
    this.art,
    this.tint, {
    this.dark = false,
    this.pixelRatio = 1,
    this.classic = false,
  });

  /// The original extruded 3D artwork, not the glass (the Simple style).
  final bool classic;

  static const _depth = 7;

  /// Draws the art in the 100 × 100 box, in whichever style is asked for.
  void _paintArt(Canvas canvas) {
    if (!classic) return _paintGlass(canvas, _draw(art));
    _paintExtruded(canvas, _classicDraw(art) ?? _classicDraw(EmptyArt.folder)!);
  }

  /// On a dark page, where shadows are drawn as faint light instead.
  final bool dark;
  final EmptyArt art;
  final Color tint;

  /// Device pixels per logical pixel, so the cached bitmap is sharp.
  final double pixelRatio;

  static final _blit = Paint()..filterQuality = FilterQuality.medium;

  @override
  void paint(Canvas canvas, Size size) {
    // Always square, centred in whatever box the parent gives, so the art is
    // never stretched.
    final side = math.min(size.width, size.height);
    if (side <= 0) return;
    final image = _ArtCache.image(this, (side * pixelRatio).ceil());
    final unit = side / 100;
    const m = _ArtCache.margin;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(
        (size.width - side) / 2 - m * unit,
        (size.height - side) / 2 - m * unit,
        (100 + 2 * m) * unit,
        (100 + 2 * m) * unit,
      ),
      _blit,
    );
  }

  /// The original look, in the 100 × 100 box: chunky extruded shapes with a
  /// lit front face, a darker body showing their depth, a light catch along
  /// the top edge, and raised white details.
  void _paintExtruded(Canvas canvas, _Drawing drawing) {
    canvas.save();
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

  /// The glass look, in the 100 × 100 box: a soft cast shadow,
  /// solid gradient shapes at the back, frosted panes in front lit along
  /// their top edge and rimmed with light, and white marks on top.
  void _paintGlass(Canvas canvas, _Drawing drawing) {
    final deep = Color.lerp(tint, Colors.black, .3)!;
    final back = [
      for (final p in drawing.parts)
        if (p.soft) p.path,
    ];
    final panes = [
      for (final p in drawing.parts)
        if (!p.soft) p.path,
    ];
    Paint blurred(Color color, double sigma) => Paint()
      ..color = color
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, sigma);

    final bounds = _union([for (final p in drawing.parts) p.path]).getBounds();

    // On a dark page, a small glow of the tint just behind the piece, so
    // the glass seems lit from within.
    if (dark) {
      final radius = bounds.longestSide * .72;
      canvas.drawCircle(
        bounds.center,
        radius,
        Paint()
          ..shader =
              RadialGradient(
                colors: [
                  tint.withValues(alpha: .42),
                  tint.withValues(alpha: .16),
                  tint.withValues(alpha: 0),
                ],
                stops: const [0, .5, 1],
              ).createShader(
                Rect.fromCircle(center: bounds.center, radius: radius),
              ),
      );
    }

    // The panes are see-through, so nothing sharp may sit under them:
    // shadows and the back shapes are drawn only outside the panes, and
    // seen through a pane only blurred.
    final behindPanes = panes.isEmpty
        ? null
        : _minus(Path()..addRect(bounds.inflate(60)), _union(panes));
    canvas.save();
    if (behindPanes != null) canvas.clipPath(behindPanes);

    // A soft shadow the whole piece casts below it: the tint's shade on a
    // light page, a faint white light on a dark one.
    canvas.drawPath(
      _union([for (final p in drawing.parts) p.path])
          .shift(const Offset(0, 10)),
      blurred(
        dark ? Colors.white.withValues(alpha: .1) : deep.withValues(alpha: .18),
        8,
      ),
    );
    // Each pane's shadow, falling on what is behind it.
    for (final path in panes) {
      canvas.drawPath(
        path.shift(const Offset(0, 6)),
        blurred(deep.withValues(alpha: dark ? .12 : .14), 5),
      );
    }

    for (final path in back) {
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              Color.lerp(tint, Colors.white, .3)!,
              Color.lerp(tint, Colors.black, .08)!,
            ],
          ).createShader(path.getBounds()),
      );
      _innerLight(canvas, path, .5);
      _rim(canvas, path);
    }
    canvas.restore();

    for (final path in panes) {
      final r = path.getBounds();
      canvas.save();
      canvas.clipPath(path);
      // The body. On a light page, milky frost: a pale pastel of the tint,
      // paler at the lit corner. On a dark page, tinted smoke: mostly
      // see-through, deepening toward the bottom right, so it doesn't glare.
      canvas.drawPath(
        path,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? [
                    Color.lerp(tint, Colors.white, .3)!.withValues(alpha: .42),
                    Color.lerp(tint, Colors.white, .1)!.withValues(alpha: .32),
                  ]
                : [
                    Color.lerp(tint, Colors.white, .6)!.withValues(alpha: .85),
                    Color.lerp(tint, Colors.white, .3)!.withValues(alpha: .82),
                  ],
          ).createShader(r),
      );
      // The solid shape behind, blurred by the frosting.
      for (final b in back) {
        canvas.drawPath(
          b,
          blurred(tint.withValues(alpha: dark ? .95 : .8), 5.5),
        );
      }
      // A soft glow all round the inside edge, thicker at the top: white on
      // a light page, a light tint on a dark one.
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 6
          ..color = dark
              ? Color.lerp(tint, Colors.white, .55)!.withValues(alpha: .35)
              : Colors.white.withValues(alpha: .5)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5),
      );
      _innerLight(canvas, path, dark ? .5 : .9);
      // A little depth along the bottom inner edge.
      if (!dark) {
        canvas.drawPath(
          _minus(
            Path()..addRect(r.inflate(24)),
            path,
          ).shift(const Offset(0, -3)),
          blurred(deep.withValues(alpha: .14), 4),
        );
      }
      canvas.restore();
      _rim(canvas, path);
    }

    final detail = drawing.detail;
    if (detail == null) return;
    final stroke = drawing.detailStroke;
    Paint style(Paint p) => stroke == null
        ? p
        : (p
            ..style = PaintingStyle.stroke
            ..strokeWidth = stroke
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round);
    canvas.drawPath(
      detail.shift(const Offset(0, 2)),
      style(blurred(deep.withValues(alpha: dark ? .3 : .5), 1.6)),
    );
    canvas.drawPath(
      detail,
      style(
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.white.withValues(alpha: .98),
              Color.lerp(tint, Colors.white, .88)!.withValues(alpha: .92),
            ],
          ).createShader(detail.getBounds().inflate(stroke ?? 0)),
      ),
    );
  }

  /// A thin light rim round [path], brightest where the light comes from.
  static void _rim(Canvas canvas, Path path) => canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.1
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.white.withValues(alpha: .95),
          Colors.white.withValues(alpha: .15),
        ],
      ).createShader(path.getBounds()),
  );

  /// White light inside [path] along its top edge: the glass's inner shadow,
  /// offset down and blurred.
  static void _innerLight(Canvas canvas, Path path, double alpha) {
    canvas.save();
    canvas.clipPath(path);
    canvas.drawPath(
      _minus(
        Path()..addRect(path.getBounds().inflate(24)),
        path,
      ).shift(const Offset(0, 3.5)),
      Paint()
        ..color = Colors.white.withValues(alpha: alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_ArtPainter old) =>
      art != old.art ||
      tint != old.tint ||
      dark != old.dark ||
      classic != old.classic ||
      pixelRatio != old.pixelRatio;
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
          ? Frosted(
              sigma: FrostImages.cardSigma,
              tileMode: TileMode.mirror,
              onPage: true,
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
        gradient: glass ? glassCardFill(context, deeper: true) : null,
      ),
      child: Padding(
        padding: padding ?? const EdgeInsets.fromLTRB(24, 24, 24, 32),
        child: child,
      ),
    );
    if (frosted) {
      panel = ClipPath(
        clipper: const _NotchClipper(),
        child: Frosted(
          sigma: FrostImages.cardSigma,
          tileMode: TileMode.mirror,
          onPage: true,
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
  void paint(Canvas canvas, Size size) => paintCached(
    canvas,
    size,
    // A gradient's look is fixed by its value: its hash keys the image.
    'notch:${stroke.toARGB32()}:${fill.toARGB32()}:${gradient?.hashCode}',
    (canvas) => _draw(canvas, size),
    overflow: _notch + 2,
  );

  void _draw(Canvas canvas, Size size) {
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
    canvas.drawPath(dashPath(path, dash: 6), dash);
  }

  @override
  bool shouldRepaint(_DashedNotchPainter old) =>
      stroke != old.stroke || fill != old.fill || gradient != old.gradient;
}

/// The size menu rows draw their artwork at, so warmed bitmaps match.
const menuArtSize = 36.8;

/// Pieces the app shows soon after starting: the More page menu, and the
/// empty transactions list.
const _warmJobs = [
  (EmptyArt.wallet, menuArtSize),
  (EmptyArt.grid, menuArtSize),
  (EmptyArt.swapCards, menuArtSize),
  (EmptyArt.bank, menuArtSize),
  (EmptyArt.calendar, menuArtSize),
  (EmptyArt.upload, menuArtSize),
  (EmptyArt.sparkles, menuArtSize),
  (EmptyArt.gear, menuArtSize),
  (EmptyArt.history, menuArtSize),
  (EmptyArt.help, menuArtSize),
  (EmptyArt.info, menuArtSize),
  (EmptyArt.premium, menuArtSize),
  (EmptyArt.receipt, 96.0),
  (EmptyArt.search, 96.0),
];

final _warmed = <(int, bool, double)>{};

/// Draws the artwork shown most into the cache ahead of time, lazily: it
/// starts after the first frame and draws one piece after each frame the
/// app draws anyway, so it never adds work to a frame. Runs once per accent,
/// brightness and pixel ratio; pieces already drawn are skipped.
void warmEmptyArt(BuildContext context) {
  if (!usesGlass(context)) return;
  final theme = Theme.of(context);
  final tint = theme.colorScheme.primary;
  final dark = theme.brightness == Brightness.dark;
  final ratio = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1;
  if (!_warmed.add((tint.toARGB32(), dark, ratio))) return;
  // One piece after each frame the app draws anyway: no timers, no extra
  // frames, and nothing at all while the app sits still.
  var next = 0;
  void step(Duration _) {
    if (next >= _warmJobs.length) return;
    final (art, size) = _warmJobs[next++];
    _ArtCache.image(
      _ArtPainter(art, tint, dark: dark, pixelRatio: ratio),
      (size * ratio).ceil(),
    );
    SchedulerBinding.instance.addPostFrameCallback(step);
  }

  SchedulerBinding.instance.addPostFrameCallback(step);
}

/// Warms the artwork cache for the current theme once the app is up; see
/// [warmEmptyArt]. Wrap the app's content in it.
class EmptyArtWarmup extends StatefulWidget {
  const EmptyArtWarmup({super.key, required this.child});
  final Widget child;

  @override
  State<EmptyArtWarmup> createState() => _EmptyArtWarmupState();
}

class _EmptyArtWarmupState extends State<EmptyArtWarmup> {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    warmEmptyArt(context);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// An icon for a list tile's leading or secondary slot: the glass artwork
/// when [icon] has some, otherwise the plain icon in the accent colour.
class GlassGlyph extends StatelessWidget {
  const GlassGlyph(this.icon, {super.key, this.size = 40, this.tint});
  final IconData icon;
  final double size;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final art = usesAurora(context) ? menuArtFor(icon) : null;
    if (art == null) {
      return Icon(
        icon,
        size: size * .6,
        color: tint ?? Theme.of(context).colorScheme.primary,
      );
    }
    return SizedBox.square(
      dimension: size,
      child: Center(
        child: EmptyArtwork(art, size: size * .92, tint: tint),
      ),
    );
  }
}

/// The original extruded artwork's shapes, for the Simple style; null for
/// the pieces drawn only as glass.
_Drawing? _classicDraw(EmptyArt art) {
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
    case EmptyArt.pie:
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
    case EmptyArt.handshake:
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
    default:
      return null;
  }
}

Path _plus(double x, double y, double arm, double w) => _union([
  _rr(x - w / 2, y - arm, x + w / 2, y + arm, w / 2),
  _rr(x - arm, y - w / 2, x + arm, y + w / 2, w / 2),
]);
