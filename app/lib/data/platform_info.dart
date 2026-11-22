import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;

/// Web-safe platform checks: `Platform` throws in the browser.
final bool isAndroidPlatform = !kIsWeb && Platform.isAndroid;

/// True while running under `flutter test`.
final bool isFlutterTest =
    !kIsWeb && Platform.environment.containsKey('FLUTTER_TEST');
