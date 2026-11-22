import '../../data/platform_info.dart';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../state/appearance_controller.dart' show AppearanceScope;
import '../theme/app_theme.dart' show AppChrome, usesAurora;

/// Whether the glass discs, pills and search fields below blur what shows
/// through them. They do unless told otherwise.
class GlassBlur extends InheritedWidget {
  const GlassBlur({
    super.key,
    required this.enabled,
    this.onPage = false,
    required super.child,
  });
  final bool enabled;

  /// The controls sit straight on the page backdrop; see [OnPageBackdrop].
  final bool onPage;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassBlur>()?.enabled ?? true;

  static bool onPageOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<GlassBlur>()?.onPage ?? false;

  @override
  bool updateShouldNotify(GlassBlur old) =>
      enabled != old.enabled || onPage != old.onPage;
}

/// For glass controls that sit straight on the page backdrop, with nothing
/// ever scrolling beneath them: a page's header.
///
/// The backdrop is already a soft glow, so blurring it again changes no
/// pixel, yet each blur is a full backdrop pass on every frame anything on
/// the page moves. Only over a chosen picture, which still has detail to
/// frost, do the controls keep their frost; a [Frosted] one takes it from
/// the page's ready-made [PageFrost].
class OnPageBackdrop extends StatelessWidget {
  const OnPageBackdrop({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => GlassBlur(
    enabled:
        usesAurora(context) &&
        Theme.of(context).extension<AppChrome>()?.cardBorder == null &&
        AppearanceScope.maybeOf(context)?.wallpaperPath != null,
    onPage: true,
    child: child,
  );
}

/// The page's picture, already frosted: one copy as blurred as a card makes
/// it and one as blurred as a header disc does.
class FrostImages {
  FrostImages._(this.size, this._card, this._control);

  /// What a card and a header control blur by, in logical pixels.
  static const cardSigma = 50.0, controlSigma = 6.0;

  /// Blurs [backdrop], a picture of the whole page backdrop at [ratio]
  /// device pixels a logical one, covering [size].
  ///
  /// The copies are kept at one pixel a logical pixel: nothing that soft has
  /// finer detail, and it keeps each to about a megabyte.
  factory FrostImages.of(ui.Image backdrop, Size size, double ratio) =>
      FrostImages._(
        size,
        blurredCopy(backdrop, ratio, cardSigma),
        blurredCopy(backdrop, ratio, controlSigma),
      );

  /// The logical size of the backdrop both copies cover.
  final Size size;
  final ui.Image _card, _control;

  /// The copy blurred by [sigma], if there is one.
  ui.Image? blurredBy(double sigma) => sigma == cardSigma
      ? _card
      : sigma == controlSigma
      ? _control
      : null;

  FrostImages clone() => FrostImages._(size, _card.clone(), _control.clone());

  void dispose() {
    _card.dispose();
    _control.dispose();
  }
}

/// [source], a picture at [ratio] device pixels a logical one, blurred by
/// [sigma] logical pixels. Kept at one pixel a logical pixel: nothing that
/// soft has finer detail, and it keeps the copy small.
ui.Image blurredCopy(ui.Image source, double ratio, double sigma) {
  final recorder = ui.PictureRecorder();
  Canvas(recorder)
    ..scale(1 / ratio)
    ..drawImage(
      source,
      Offset.zero,
      Paint()
        ..filterQuality = FilterQuality.low
        // Mirrored at the edges, as the live blur of the screen is.
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma * ratio,
          sigmaY: sigma * ratio,
          tileMode: TileMode.mirror,
        ),
    );
  final picture = recorder.endRecording();
  final image = picture.toImageSync(
    (source.width / ratio).ceil(),
    (source.height / ratio).ceil(),
  );
  picture.dispose();
  return image;
}

/// [source], a picture at [ratio] device pixels a logical one, blurred by
/// [sigma] logical pixels, made in two plain steps: shrunk to one pixel a
/// logical pixel first, then blurred at 1:1.
///
/// Blurring while shrinking ([blurredCopy]) leaves how the blur's size
/// meets the shrink to the renderer, and on the phone it came out weaker
/// than the live blur a sheet shows, so a frozen sheet looked hazy. Two
/// steps leave nothing to interpret.
ui.Image blurredCopyExact(ui.Image source, double ratio, double sigma) {
  final width = (source.width / ratio).ceil();
  final height = (source.height / ratio).ceil();
  final small = () {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImageRect(
      source,
      Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      Paint()..filterQuality = FilterQuality.medium,
    );
    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    picture.dispose();
    return image;
  }();
  try {
    final recorder = ui.PictureRecorder();
    Canvas(recorder).drawImage(
      small,
      Offset.zero,
      Paint()
        ..imageFilter = ui.ImageFilter.blur(
          sigmaX: sigma,
          sigmaY: sigma,
          tileMode: TileMode.mirror,
        ),
    );
    final picture = recorder.endRecording();
    final image = picture.toImageSync(width, height);
    picture.dispose();
    return image;
  } finally {
    small.dispose();
  }
}

/// What a page's glass draws instead of blurring the picture behind it.
///
/// A backdrop blur re-reads and re-blurs the whole screen on every frame
/// the page moves, though the picture under the glass never changes. So the
/// backdrop frosts its picture once, and each piece of glass shows the part
/// of that copy it sits over. [link] pins the copy to the backdrop in the
/// compositor, so it stays put while the glass scrolls, slides or zooms
/// without anything being painted again.
class PageFrost {
  final link = LayerLink();

  ValueListenable<FrostImages?> get images => _images;
  final _images = ValueNotifier<FrostImages?>(null);

  bool _disposed = false, _pending = false;
  FrostImages? _next;

  /// Shows [images], which become this object's to dispose, from the end of
  /// the frame on: it is called while widgets build and lay out, when
  /// nothing may be told to rebuild. Null goes back to the live blur.
  void show(FrostImages? images) {
    if (_disposed) {
      images?.dispose();
      return;
    }
    _next?.dispose();
    _next = images;
    if (_pending) return;
    _pending = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _pending = false;
        if (_disposed) return;
        final old = _images.value;
        _images.value = _next;
        _next = null;
        // Whatever was painted with the old copy keeps its own hold on it.
        old?.dispose();
      })
      ..ensureVisualUpdate();
  }

  void dispose() {
    _disposed = true;
    _next?.dispose();
    _next = null;
    final old = _images.value;
    _images.dispose();
    old?.dispose();
  }
}

/// Gives the page below a [PageFrost] for its backdrop to fill and its
/// glass to draw from.
class PageFrostHost extends StatefulWidget {
  const PageFrostHost({super.key, required this.child});
  final Widget child;

  /// For glass inside a popup or sheet laid over the page. The popup
  /// already frosts the screen behind it, so the glass inside it (cards,
  /// discs, fields) blurs nothing more: over that smooth frost a second
  /// blur changes next to nothing, yet each one redid a blur of the screen
  /// on every frame a sheet's page slid.
  static Widget none({required Widget child}) =>
      _PageFrostScope(frost: null, child: child);

  /// Whether [context] is inside a popup or sheet (see [none]).
  static bool insidePopup(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<_PageFrostScope>();
    return scope != null && scope.frost == null;
  }

  static PageFrost? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_PageFrostScope>()?.frost;

  @override
  State<PageFrostHost> createState() => _PageFrostHostState();
}

class _PageFrostHostState extends State<PageFrostHost> {
  final _frost = PageFrost();

  @override
  void dispose() {
    _frost.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _PageFrostScope(frost: _frost, child: widget.child);
}

class _PageFrostScope extends InheritedWidget {
  const _PageFrostScope({required this.frost, required super.child});
  final PageFrost? frost;

  @override
  bool updateShouldNotify(_PageFrostScope old) => frost != old.frost;
}

/// Frosts whatever is behind [child], which the caller clips to its shape.
///
/// On a page whose backdrop has frosted its picture ahead of time this
/// draws that copy; anywhere else, and until the copy is ready, it is a
/// live [BackdropFilter] in the nearest [BackdropGroup].
class Frosted extends StatelessWidget {
  const Frosted({
    super.key,
    required this.sigma,
    this.tileMode,
    this.enabled = true,
    this.onPage = false,
    required this.child,
  });
  final double sigma;
  final TileMode? tileMode;
  final bool enabled;

  /// Only the page's picture is ever behind this: a card. Controls say so
  /// through [OnPageBackdrop] instead.
  final bool onPage;
  final Widget child;

  ui.ImageFilter get _filter =>
      ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma, tileMode: tileMode);

  @override
  Widget build(BuildContext context) {
    final frost = enabled && (onPage || GlassBlur.onPageOf(context))
        ? PageFrostHost.maybeOf(context)
        : null;
    if (frost == null) {
      return BackdropFilter.grouped(
        enabled: enabled && !PageFrostHost.insidePopup(context),
        filter: _filter,
        child: child,
      );
    }
    return ValueListenableBuilder<FrostImages?>(
      valueListenable: frost.images,
      child: child,
      builder: (context, images, child) {
        final image = images?.blurredBy(sigma);
        // The same two children either way, so the glass's own contents
        // (a text field, say) keep their state when the copy arrives.
        return Stack(
          fit: StackFit.passthrough,
          children: [
            Positioned.fill(
              child: image == null
                  ? const SizedBox.shrink()
                  : IgnorePointer(
                      child: CompositedTransformFollower(
                        link: frost.link,
                        showWhenUnlinked: false,
                        child: CustomPaint(
                          painter: _FrostPainter(image, images!.size),
                        ),
                      ),
                    ),
            ),
            BackdropFilter.grouped(
              enabled: image == null,
              filter: _filter,
              child: child,
            ),
          ],
        );
      },
    );
  }
}

/// Draws the frosted copy over the whole backdrop. It is painted in the
/// backdrop's own space, so the glass's clip leaves just its part showing.
class _FrostPainter extends CustomPainter {
  const _FrostPainter(this.image, this.size, {this.opacity = 1});
  final ui.Image image;
  final Size size;
  final double opacity;

  @override
  void paint(Canvas canvas, Size _) {
    if (opacity <= 0) return;
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Offset.zero & size,
      Paint()
        ..filterQuality = FilterQuality.low
        ..color = Color.fromRGBO(0, 0, 0, opacity),
    );
  }

  @override
  bool shouldRepaint(_FrostPainter old) =>
      image != old.image || size != old.size || opacity != old.opacity;
}

/// Marks the screen's top-left corner, so a popup or sheet can draw a
/// screen-sized picture lined up with the screen wherever it slides.
class ScreenAnchor extends StatelessWidget {
  const ScreenAnchor({super.key, required this.child});
  final Widget child;

  static final link = LayerLink();
  static final _boundary = GlobalKey();

  /// Widget tests can't render real images; they keep the live blur.
  static final _enabled = !isFlutterTest;

  /// The screen as last drawn, at full sharpness, with its logical size and
  /// pixel ratio; null where it can't be had.
  static Future<(ui.Image, Size, double)?> capture() async {
    if (!_enabled) return null;
    final boundary = _boundary.currentContext?.findRenderObject();
    if (boundary is! RenderRepaintBoundary || !boundary.hasSize) return null;
    final ratio = ui.PlatformDispatcher.instance.implicitView?.devicePixelRatio;
    if (ratio == null) return null;
    try {
      return (await boundary.toImage(pixelRatio: ratio), boundary.size, ratio);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) => CompositedTransformTarget(
    link: link,
    child: RepaintBoundary(key: _boundary, child: child),
  );
}

/// Frosts what is behind [child] (which the caller clips to its shape), by
/// [sigma] times [visibility], for a popup or sheet laid over the screen.
///
/// A live backdrop blur this strong is several passes over the screen on
/// every frame the popup moves, which Snapdragon phones in particular can't
/// keep up with while a sheet slides in. What is behind a popup holds still,
/// so right after its first frame (when it is still out of sight) the screen
/// is captured and blurred once, and that copy is shown pinned to the
/// screen. The live blur stands in until then; both look the same.
class ScreenFrost extends StatefulWidget {
  const ScreenFrost({
    super.key,
    required this.sigma,
    this.visibility = 1,
    required this.child,
  });
  final double sigma;
  final double visibility;
  final Widget child;

  @override
  State<ScreenFrost> createState() => _ScreenFrostState();
}

class _ScreenFrostState extends State<ScreenFrost> {
  (ui.Image, Size)? _copy;

  @override
  void initState() {
    super.initState();
    SchedulerBinding.instance.addPostFrameCallback((_) => _freeze());
  }

  Future<void> _freeze() async {
    if (!mounted) return;
    final shot = await ScreenAnchor.capture();
    if (shot == null) return;
    final (screen, size, ratio) = shot;
    final ui.Image copy;
    try {
      copy = blurredCopyExact(screen, ratio, widget.sigma);
    } catch (_) {
      return;
    } finally {
      screen.dispose();
    }
    if (!mounted) return copy.dispose();
    setState(() => _copy = (copy, size));
  }

  @override
  void dispose() {
    _copy?.$1.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final copy = _copy;
    final sigma = widget.sigma * widget.visibility;
    // The same two children either way, so the content keeps its state when
    // the copy arrives.
    return Stack(
      fit: StackFit.passthrough,
      children: [
        Positioned.fill(
          child: copy == null
              ? const SizedBox.shrink()
              : IgnorePointer(
                  child: CompositedTransformFollower(
                    link: ScreenAnchor.link,
                    showWhenUnlinked: false,
                    child: CustomPaint(
                      painter: _FrostPainter(
                        copy.$1,
                        copy.$2,
                        opacity: widget.visibility,
                      ),
                    ),
                  ),
                ),
        ),
        BackdropFilter(
          enabled: copy == null && sigma > .5,
          filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
          child: widget.child,
        ),
      ],
    );
  }
}

/// The page backdrop now on screen, as one image: the Aurora glow, or the
/// chosen picture already frosted. Low-end phones show it through their
/// popups and sheets instead of blurring the screen live.
class ShownBackdrop {
  ShownBackdrop._();

  static ValueListenable<(ui.Image, Size)?> get image => _image;
  static final _image = ValueNotifier<(ui.Image, Size)?>(null);

  static (ui.Image, Size)? _next;
  static var _pending = false;

  /// Shows [image], which becomes this class's to dispose, covering [size]
  /// of the screen, from the end of the frame on.
  static void show(ui.Image image, Size size) {
    _next?.$1.dispose();
    _next = (image, size);
    if (_pending) return;
    _pending = true;
    SchedulerBinding.instance
      ..addPostFrameCallback((_) {
        _pending = false;
        final old = _image.value;
        _image.value = _next;
        _next = null;
        // Whatever was painted with the old one keeps its own hold on it.
        old?.$1.dispose();
      })
      ..ensureVisualUpdate();
  }
}

/// [ShownBackdrop] under a popup or sheet, lined up with the screen through
/// [ScreenAnchor] so it stays put while the popup moves. [opacity] fades it
/// with the popup. Nothing until a backdrop has been shown.
class ShownBackdropFill extends StatelessWidget {
  const ShownBackdropFill({super.key, this.opacity = 1});
  final double opacity;

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<(ui.Image, Size)?>(
        valueListenable: ShownBackdrop.image,
        builder: (context, shown, _) => shown == null
            ? const SizedBox.shrink()
            : IgnorePointer(
                child: CompositedTransformFollower(
                  link: ScreenAnchor.link,
                  showWhenUnlinked: false,
                  child: CustomPaint(
                    painter: _FrostPainter(
                      shown.$1,
                      shown.$2,
                      opacity: opacity,
                    ),
                  ),
                ),
              ),
      );
}
