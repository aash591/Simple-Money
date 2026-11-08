import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../ui/theme/app_theme.dart';

class AppearanceController extends ValueNotifier<ThemeMode> {
  AppearanceController() : super(ThemeMode.system);

  Color accentColor = accent;
  AppStyle style = AppStyle.glassy;

  /// Dark with true-black cards; only ever on while the mode is dark.
  bool black = false;
  bool _disposed = false;
  int _revision = 0;

  Future<void> restore() async {
    final revision = _revision;
    final prefs = await SharedPreferences.getInstance();
    if (_disposed || revision != _revision) return;
    style = AppStyle.values.firstWhere(
      (style) => style.name == prefs.getString('ui_style'),
      orElse: () => AppStyle.glassy,
    );
    final savedColor = prefs.getInt('accent_color');
    if (savedColor != null &&
        savedColor >= 0xff000000 &&
        savedColor <= 0xffffffff) {
      accentColor = Color(savedColor);
    }
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

  Future<void> setStyle(AppStyle style) async {
    _revision++;
    this.style = style;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('ui_style', style.name);
  }

  Future<void> setAccent(Color color) async {
    _revision++;
    accentColor = color;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('accent_color', color.toARGB32());
  }

  @override
  void dispose() {
    _disposed = true;
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
