import 'package:flutter/services.dart';

class DriveAuthorization {
  static const _channel = MethodChannel('simple_money/drive_authorization');

  /// The phone's name as its owner set it, or its model.
  /// The phone's Android API level (e.g. 31 for Android 12).
  Future<int> sdkInt() async =>
      (await _channel.invokeMethod<int>('sdkInt')) ?? 0;

  Future<String> deviceName() async =>
      (await _channel.invokeMethod<String>('deviceName')) ?? '';

  Future<String> installationId() async =>
      (await _channel.invokeMethod<String>('installationId'))!;

  /// Interactive consent is only allowed after the user presses Connect.
  Future<String> token({String? email, bool interactive = false}) async {
    final token = await _channel.invokeMethod<String>('authorize', {
      'email': email,
      'interactive': interactive,
    });
    if (token == null || token.isEmpty) {
      throw PlatformException(code: 'authorization_required');
    }
    return token;
  }
}
