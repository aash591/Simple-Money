// Temporary visual preview of header actions; not part of the suite.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/app_back_button.dart';
import 'package:simple_money/ui/components/glass_surface.dart';
import 'package:simple_money/ui/components/secondary_header.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

Future<void> _font(String family, String path) async {
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await loader.load();
}

Widget _panel(Brightness b) => Theme(
  data: appTheme(b),
  child: Material(
    type: MaterialType.transparency,
    child: Stack(children: [
      const Positioned.fill(child: GlassBackdrop()),
      Padding(
        padding: const EdgeInsets.only(top: 20),
        child: SecondaryHeader(
          title: 'Category settings',
          leading: const AppBackButton(),
          actions: [
            IconButton(onPressed: () {}, icon: const Icon(Icons.delete_outline_rounded)),
            AppSearchButton(onPressed: () {}),
          ],
        ),
      ),
    ]),
  ),
);

void main() {
  testWidgets('header preview', (tester) async {
    await _font('Inter', 'assets/fonts/Inter.ttf');
    await _font('MaterialIcons',
        'C:/Users/ADMIN/develop/flutter/bin/cache/artifacts/material_fonts/materialicons-regular.otf');
    tester.view.physicalSize = const Size(800, 100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Row(children: [
        Expanded(child: _panel(Brightness.light)),
        Expanded(child: _panel(Brightness.dark)),
      ]),
    ));
    await tester.pumpAndSettle();
    await expectLater(find.byType(Row).first, matchesGoldenFile('header_preview.png'));
  });
}
