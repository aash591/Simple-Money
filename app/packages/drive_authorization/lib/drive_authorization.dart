import 'package:flutter/services.dart';

class DriveAuthorization {
  static const _channel = MethodChannel('simple_money/drive_authorization');

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
