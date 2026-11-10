import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/aurora_wallpaper.dart';
import '../ui/theme/app_theme.dart';
import 'pro_controller.dart';

/// The looks a free user can try for an hour.
enum PreviewLook { accent, style, wallpaper }

class AppearanceController extends ValueNotifier<ThemeMode> {
  AppearanceController() : super(ThemeMode.system);

  Color accentColor = accent;
  AppStyle style = AppStyle.glassy;

  /// Dark with true-black cards; only ever on while the mode is dark.
  bool black = false;

  /// A picture shown behind the Aurora style instead of its glow, and how
  /// much it is dimmed (0 to 1) so text stays easy to read.
  String? wallpaperPath;
  double wallpaperDim = defaultWallpaperDim;
  static const defaultWallpaperDim = .45;

  bool _disposed = false;
  int _revision = 0;

  /// How long a Pro look stays on for someone without Pro.
  /// Stands in for the clock in tests.
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  static const previewLength = Duration(hours: 1);

  // The last free look: what comes back when a preview ends. Only this is
  // saved, so a preview also ends when the app is closed from recents.
  Color _freeAccent = accent;
  AppStyle _freeStyle = freeStyle;

  /// The one free style; Glassy and Aurora are Pro, tried for an hour.
  static const freeStyle = AppStyle.simple;
  final _previewEnds = <PreviewLook, DateTime>{};
  Timer? _previewTimer;

  /// When [look] is a Pro preview, the time it ends.
  DateTime? previewEnd(PreviewLook look) => _previewEnds[look];

  /// The soonest preview end, for "N min left".
  DateTime? get nextPreviewEnd => _previewEnds.values.isEmpty
      ? null
      : _previewEnds.values.reduce((a, b) => a.isBefore(b) ? a : b);

  /// Puts back the free look for every preview that has run out. Called by a
  /// timer, and when the app comes back to the front.
  Future<void> expirePreviews() async {
    final now = clock();
    final over = [
      for (final e in _previewEnds.entries)
        if (!e.value.isAfter(now) || ProController.instance.featuresUnlocked)
          e.key,
    ];
    for (final look in over) {
      _previewEnds.remove(look);
      if (ProController.instance.featuresUnlocked) {
        // Pro arrived meanwhile: keep the look and save it.
        await _save(look);
        continue;
      }
      switch (look) {
        case PreviewLook.accent:
          accentColor = _freeAccent;
        case PreviewLook.style:
          style = _freeStyle;
        case PreviewLook.wallpaper:
          wallpaperPath = null;
          await AuroraWallpaper.tidy();
      }
    }
    _schedulePreviewTimer();
    if (over.isNotEmpty && !_disposed) notifyListeners();
  }

  Future<void> _save(PreviewLook look) async {
    final prefs = await SharedPreferences.getInstance();
    switch (look) {
      case PreviewLook.accent:
        _freeAccent = accentColor;
        await prefs.setInt('accent_color', accentColor.toARGB32());
      case PreviewLook.style:
        _freeStyle = style;
        await prefs.setString('ui_style', style.name);
      case PreviewLook.wallpaper:
        if (wallpaperPath != null) {
          await prefs.setString('aurora_wallpaper', wallpaperPath!);
        }
    }
  }

  void _startPreview(PreviewLook look) {
    _previewEnds[look] = clock().add(previewLength);
    _schedulePreviewTimer();
  }

  void _schedulePreviewTimer() {
    _previewTimer?.cancel();
    _previewTimer = null;
    final next = nextPreviewEnd;
    if (next == null) return;
    final wait = next.difference(clock());
    _previewTimer = Timer(
      wait.isNegative ? Duration.zero : wait + const Duration(seconds: 1),
      expirePreviews,
    );
  }

  Future<void> restore() async {
    final revision = _revision;
    final prefs = await SharedPreferences.getInstance();
    if (_disposed || revision != _revision) return;
    style = AppStyle.values.firstWhere(
      (style) => style.name == prefs.getString('ui_style'),
      orElse: () =>
          ProController.instance.featuresUnlocked ? AppStyle.glassy : freeStyle,
    );
    final savedColor = prefs.getInt('accent_color');
    if (savedColor != null &&
        savedColor >= 0xff000000 &&
        savedColor <= 0xffffffff) {
      accentColor = Color(savedColor);
    }
    _freeAccent = accentColor;
    _freeStyle = ProController.instance.featuresUnlocked ? style : freeStyle;
    final wallpaper = prefs.getString('aurora_wallpaper');
    // A picture that has since gone is simply forgotten.
    wallpaperPath = wallpaper != null && File(wallpaper).existsSync()
        ? wallpaper
        : null;
    wallpaperDim =
        (prefs.getDouble('aurora_wallpaper_dim') ?? defaultWallpaperDim).clamp(
          0.0,
          .85,
        );
    // Left behind by the removed Home glow switch; the glow is always on now.
    prefs.remove('home_glow');
    value = ThemeMode.values.firstWhere(
      (mode) => mode.name == prefs.getString('theme_mode'),
      orElse: () => ThemeMode.system,
    );
    black = value == ThemeMode.dark && (prefs.getBool('black_theme') ?? false);
    notifyListeners();
  }

  /// [black] picks the true-black style of dark; any other mode drops it.
  Future<void> setMode(ThemeMode mode, {bool black = false}) async {
    _revision++;
    final modeChanged = value != mode;
    this.black = mode == ThemeMode.dark && black;
    value = mode; // Notifies when the mode changed.
    if (!modeChanged) notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('theme_mode', mode.name);
    await prefs.setBool('black_theme', this.black);
  }

  /// A [preview] is a Pro look tried for an hour: it is not saved.
  Future<void> setStyle(AppStyle style, {bool preview = false}) async {
    _revision++;
    this.style = style;
    if (preview) {
      _startPreview(PreviewLook.style);
      notifyListeners();
      return;
    }
    _previewEnds.remove(PreviewLook.style);
    _schedulePreviewTimer();
    _freeStyle = style;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ui_style', style.name);
  }

  /// Shows [path] behind the Aurora style, or the glow again when null.
  Future<void> setWallpaper(String? path, {bool preview = false}) async {
    _revision++;
    wallpaperPath = path;
    if (preview && path != null) {
      _startPreview(PreviewLook.wallpaper);
      notifyListeners();
      return;
    }
    _previewEnds.remove(PreviewLook.wallpaper);
    _schedulePreviewTimer();
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (path == null) {
      await prefs.remove('aurora_wallpaper');
    } else {
      await prefs.setString('aurora_wallpaper', path);
    }
  }

  Future<void> setWallpaperDim(double dim) async {
    _revision++;
    wallpaperDim = dim.clamp(0.0, .85);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble('aurora_wallpaper_dim', wallpaperDim);
  }

  Future<void> setAccent(Color color, {bool preview = false}) async {
    _revision++;
    accentColor = color;
    if (preview) {
      _startPreview(PreviewLook.accent);
      notifyListeners();
      return;
    }
    _previewEnds.remove(PreviewLook.accent);
    _schedulePreviewTimer();
    _freeAccent = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('accent_color', color.toARGB32());
  }

  @override
  void dispose() {
    _disposed = true;
    _previewTimer?.cancel();
    super.dispose();
  }
}

class AppearanceScope extends InheritedNotifier<AppearanceController> {
  const AppearanceScope({
    super.key,
    required AppearanceController controller,
    required super.child,
  }) : super(notifier: controller);

  static AppearanceController of(BuildContext context) => maybeOf(context)!;

  static AppearanceController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<AppearanceScope>()?.notifier;
}
