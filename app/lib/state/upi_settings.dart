import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

class UpiSettings extends ChangeNotifier {
  static const preferenceKey = 'upi_payments_enabled';
  bool enabled = true;
  bool loading = true;
  bool saving = false;
  bool _disposed = false;
  int _revision = 0;

  Future<void> restore() async {
    final revision = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || revision != _revision) return;
      enabled = prefs.getBool(preferenceKey) ?? true;
    } catch (_) {
      if (!_disposed && revision == _revision) enabled = true;
    } finally {
      if (!_disposed) {
        loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> setEnabled(bool next) async {
    if (saving) return;
    _revision++;
    saving = true;
    notifyListeners();
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(preferenceKey, next)) {
        throw StateError('Could not save UPI setting.');
      }
      if (!_disposed) enabled = next;
    } finally {
      if (!_disposed) {
        saving = false;
        loading = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class UpiSettingsScope extends InheritedNotifier<UpiSettings> {
  const UpiSettingsScope({
    super.key,
    required UpiSettings settings,
    required super.child,
  }) : super(notifier: settings);

  static UpiSettings? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<UpiSettingsScope>()?.notifier;
}
