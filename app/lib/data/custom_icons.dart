import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show PaintingBinding;
import 'package:path_provider/path_provider.dart';

/// Icons the user made themselves (see the "Add your own icon" screen).
///
/// Each one is a transparent 128x128 PNG kept in the app's own storage, named
/// after what the user typed. The stored key is `custom:<name>`, so a saved
/// account or category keeps working the same way it does with a built-in icon.
/// They stay on this device; on another device the icon shows as the default.
class CustomIcons {
  static const keyPrefix = 'custom:';
  static const size = 128;

  /// Where the icons go; tests point it at a temporary folder.
  @visibleForTesting
  static Future<Directory> Function() directory =
      getApplicationSupportDirectory;

  /// Keys of every saved icon, A-Z. Listen to redraw when one is added.
  static final ValueNotifier<List<String>> keys = ValueNotifier(const []);

  static String? _folder;

  /// Reads the saved icons. Call once at start-up so icons can draw at once.
  static Future<void> load() async {
    if (kIsWeb) return;
    try {
      final folder = await _folderPath();
      final dir = Directory(folder);
      if (!await dir.exists()) return;
      final found = <String>[];
      await for (final entry in dir.list()) {
        if (entry is! File || !entry.path.endsWith('.png')) continue;
        final name = entry.uri.pathSegments.last;
        found.add('$keyPrefix${name.substring(0, name.length - 4)}');
      }
      keys.value = found..sort();
    } catch (_) {
      // No saved icons is fine; the picker simply shows none.
    }
  }

  static Future<String> _folderPath() async =>
      _folder ??= '${(await directory()).path}/custom_icons';

  /// "Hair Cut!" becomes "hair_cut". Empty when nothing usable is left.
  static String slug(String name) => name
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '_')
      .replaceAll(RegExp(r'^_+|_+$'), '');

  static bool isCustomKey(String? key) =>
      key != null && key.startsWith(keyPrefix);

  /// The picture for [key], or null when it isn't a saved custom icon.
  static File? fileFor(String? key) {
    if (kIsWeb || _folder == null || !isCustomKey(key)) return null;
    if (!keys.value.contains(key)) return null;
    return File('$_folder/${key!.substring(keyPrefix.length)}.png');
  }

  /// A readable name for [key], e.g. `custom:hair_cut` -> "hair cut".
  static String label(String key) =>
      key.substring(keyPrefix.length).replaceAll('_', ' ');

  /// Turns [source] (any picture the app can open) into an icon named [name]
  /// and saves it. Returns its key. Throws [FormatException] for a name with
  /// no letters or digits, or a file that isn't a picture.
  static Future<String> save(String name, Uint8List source) async {
    final id = slug(name);
    if (id.isEmpty) throw const FormatException('Type a name first');
    final png = await makeIcon(source);
    final folder = await _folderPath();
    await Directory(folder).create(recursive: true);
    await File('$folder/$id.png').writeAsBytes(png, flush: true);
    // Replacing an icon with the same name must not show the old picture.
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    final key = '$keyPrefix$id';
    if (!keys.value.contains(key)) {
      keys.value = [...keys.value, key]..sort();
    }
    return key;
  }

  /// The app's icon format: a transparent 128x128 PNG with the artwork
  /// cropped to its edges and centred. A plain background (what most AI
  /// image tools give instead of a transparent one) is removed.
  @visibleForTesting
  static Future<Uint8List> makeIcon(Uint8List source) async {
    final ui.ImageDescriptor descriptor;
    try {
      descriptor = await ui.ImageDescriptor.encoded(
        await ui.ImmutableBuffer.fromUint8List(source),
      );
    } catch (_) {
      throw const FormatException('That file isn’t a picture');
    }
    // 512 is plenty to downscale from, and keeps big pictures cheap.
    final wide = descriptor.width >= descriptor.height;
    final big = math.max(descriptor.width, descriptor.height) > 512;
    final codec = await descriptor.instantiateCodec(
      targetWidth: big && wide ? 512 : null,
      targetHeight: big && !wide ? 512 : null,
    );
    final frame = (await codec.getNextFrame()).image;
    final w = frame.width, h = frame.height;
    final data = await frame.toByteData(format: ui.ImageByteFormat.rawRgba);
    frame.dispose();
    descriptor.dispose();
    if (data == null) throw const FormatException('That file isn’t a picture');

    final pixels = Uint8List.fromList(data.buffer.asUint8List());
    _removePlainBackground(pixels, w, h);
    final box = _contentBox(pixels, w, h);
    if (box == null) {
      throw const FormatException('The picture looks empty');
    }

    final cropped = await _fromPixels(pixels, w, h);
    final inner = size * .88; // a little clear space on every side
    final scale = inner / math.max(box.width, box.height);
    final target = ui.Rect.fromCenter(
      center: const ui.Offset(size / 2, size / 2),
      width: box.width * scale,
      height: box.height * scale,
    );
    final recorder = ui.PictureRecorder();
    ui.Canvas(recorder).drawImageRect(
      cropped,
      box,
      target,
      ui.Paint()
        ..filterQuality = ui.FilterQuality.high
        ..isAntiAlias = true,
    );
    final picture = recorder.endRecording();
    final out = await picture.toImage(size, size);
    // Only now: a release build rasterizes on the GPU after toImage, and an
    // image freed before that can read back whatever the memory held (it
    // showed the screen behind).
    picture.dispose();
    cropped.dispose();
    final png = await out.toByteData(format: ui.ImageByteFormat.png);
    out.dispose();
    return png!.buffer.asUint8List();
  }

  static Future<ui.Image> _fromPixels(Uint8List pixels, int w, int h) {
    final done = Completer<ui.Image>();
    ui.decodeImageFromPixels(
      pixels,
      w,
      h,
      ui.PixelFormat.rgba8888,
      done.complete,
    );
    return done.future;
  }

  /// Makes a solid edge-to-edge background see-through. Only runs when all four
  /// corners are the same opaque colour, so a picture that is already
  /// transparent (or has no plain backdrop) is left alone.
  static void _removePlainBackground(Uint8List p, int w, int h) {
    int at(int x, int y) => (y * w + x) * 4;
    final corners = [at(0, 0), at(w - 1, 0), at(0, h - 1), at(w - 1, h - 1)];
    if (corners.any((i) => p[i + 3] < 250)) return;
    final r = p[corners[0]], g = p[corners[0] + 1], b = p[corners[0] + 2];
    bool near(int i, int tolerance) =>
        (p[i] - r).abs() <= tolerance &&
        (p[i + 1] - g).abs() <= tolerance &&
        (p[i + 2] - b).abs() <= tolerance;
    if (corners.any((i) => !near(i, 24))) return;

    const tolerance = 36;
    final seen = Uint8List(w * h);
    final stack = <int>[];
    void push(int x, int y) {
      if (x < 0 || y < 0 || x >= w || y >= h) return;
      final n = y * w + x;
      if (seen[n] == 1 || !near(n * 4, tolerance)) return;
      seen[n] = 1;
      stack.add(n);
    }

    for (var x = 0; x < w; x++) {
      push(x, 0);
      push(x, h - 1);
    }
    for (var y = 0; y < h; y++) {
      push(0, y);
      push(w - 1, y);
    }
    while (stack.isNotEmpty) {
      final n = stack.removeLast();
      p[n * 4 + 3] = 0;
      final x = n % w, y = n ~/ w;
      push(x + 1, y);
      push(x - 1, y);
      push(x, y + 1);
      push(x, y - 1);
    }
  }

  /// The smallest box holding every visible pixel, or null if none.
  static ui.Rect? _contentBox(Uint8List p, int w, int h) {
    var minX = w, minY = h, maxX = -1, maxY = -1;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if (p[(y * w + x) * 4 + 3] > 12) {
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (maxX < 0) return null;
    return ui.Rect.fromLTRB(
      minX.toDouble(),
      minY.toDouble(),
      maxX + 1.0,
      maxY + 1.0,
    );
  }
}
