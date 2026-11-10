import 'package:flutter/services.dart';

/// Match the production font rather than Flutter's block-shaped test font.
Future<void> loadPreviewFonts() async {
  for (final family in ['Manrope', 'Inter']) {
    final loader = FontLoader(family)
      ..addFont(rootBundle.load('assets/fonts/$family.ttf'));
    await loader.load();
  }
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}
