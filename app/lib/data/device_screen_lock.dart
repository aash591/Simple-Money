import 'package:flutter/services.dart';

/// Tells whether the device's screen turned off while the app was away.
///
/// The Flutter lifecycle cannot separate "the phone was locked" from "the
/// user switched apps" — both arrive as paused — so the app lock's timing
/// options ask the platform instead. Android answers; anywhere else this
/// reports unsupported and only elapsed time is used.
abstract class ScreenLockWatcher {
  /// Whether this device can report screen-off events at all.
  Future<bool> get supported;

  /// Whether the screen turned off since this was last called, clearing the
  /// flag so one screen lock relocks the app exactly once.
  Future<bool> consumeScreenOff();
}

class PlatformScreenLockWatcher implements ScreenLockWatcher {
  const PlatformScreenLockWatcher();

  static const _channel = MethodChannel('simple_money/screen_lock');

  @override
  Future<bool> get supported => _ask('supported');

  @override
  Future<bool> consumeScreenOff() => _ask('consumeScreenOff');

  /// A platform that cannot answer is treated as "no screen lock seen": the
  /// elapsed-time rules still apply, so silence never unlocks anything.
  Future<bool> _ask(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } catch (_) {
      return false;
    }
  }
}
