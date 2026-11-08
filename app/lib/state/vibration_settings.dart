import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

class VibrationSettings extends ChangeNotifier {
  static final instance = VibrationSettings();
  static const preferenceKey = 'vibrations_enabled';
  static const _haptics = MethodChannel('simple_money/haptics');

  bool enabled = true;
  bool saving = false;

  Future<void> restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(preferenceKey) ?? true;
    } catch (_) {
      enabled = true;
    }
    notifyListeners();
  }

  Future<void> setEnabled(bool value) async {
    if (saving) return;
    saving = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(preferenceKey, value)) {
        throw StateError('Could not save vibration setting.');
      }
      enabled = value;
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  static Future<void> selectionClick() async {
    if (instance.enabled) await HapticFeedback.selectionClick();
  }

  /// Gentle feedback for frequent keypad presses and scroll boundaries.
  static Future<void> softTick() async {
    if (!instance.enabled) return;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _haptics.invokeMethod<void>('softTick');
        return;
      } on MissingPluginException {
        // Other hosts can still use Flutter's standard selection feedback.
      }
    }
    await selectionClick();
  }

  static Future<void> lightImpact() async {
    if (instance.enabled) await HapticFeedback.lightImpact();
  }
}
