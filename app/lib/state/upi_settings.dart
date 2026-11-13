import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../domain/currency.dart';

class UpiSettings extends ChangeNotifier {
  /// [region] is the country the phone is set up for; the phone's own
  /// setting when null.
  UpiSettings({String? region}) : _defaultEnabled = _inIndia(region);

  static const preferenceKey = 'upi_payments_enabled';

  /// UPI, and the Google Pay or PhonePe apps it opens, are an Indian
  /// service, so it is on by default only there. Anyone can switch it on or
  /// off in More › Settings, and that choice is kept.
  static bool _inIndia(String? region) =>
      (region ?? Currency.deviceRegion()) == 'IN';

  final bool _defaultEnabled;
  late bool enabled = _defaultEnabled;
  bool loading = true;
  bool saving = false;
  bool _disposed = false;
  int _revision = 0;

  Future<void> restore() async {
    final revision = _revision;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (_disposed || revision != _revision) return;
      enabled = prefs.getBool(preferenceKey) ?? _defaultEnabled;
    } catch (_) {
      if (!_disposed && revision == _revision) enabled = _defaultEnabled;
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
