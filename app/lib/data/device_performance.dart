import 'package:flutter/services.dart';

/// Whether this phone is too slow for live backdrop effects. Read once at
/// start.
class DevicePerformance {
  DevicePerformance._();

  static const _channel = MethodChannel('simple_money/device');

  /// `--dart-define=LOW_END=true` forces the low-end look on any phone, to
  /// check it on a fast one.
  static const _forced = bool.fromEnvironment('LOW_END');
  static bool lowEnd = _forced;

  static Future<void> restore() async {
    try {
      lowEnd =
          _forced || (await _channel.invokeMethod<bool>('lowEnd') ?? false);
    } on MissingPluginException {
      // Not Android: keep the full effects.
    } on PlatformException {
      // Keep the full effects.
    }
  }
}
