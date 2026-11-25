import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/custom_icons.dart';

void main() {
  test('slug keeps letters and digits only', () {
    expect(CustomIcons.slug(' Hair Cut! '), 'hair_cut');
    expect(CustomIcons.slug('!!!'), '');
  });

  testWidgets('makeIcon removes a plain background and fits 128px', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      canvas.drawRect(
        const ui.Rect.fromLTWH(0, 0, 200, 100),
        ui.Paint()..color = const ui.Color(0xFFFFFFFF),
      );
      canvas.drawRect(
        const ui.Rect.fromLTWH(60, 20, 80, 60),
        ui.Paint()..color = const ui.Color(0xFFE53935),
      );
      final source = await recorder.endRecording().toImage(200, 100);
      final png = (await source.toByteData(format: ui.ImageByteFormat.png))!;
      final out = await CustomIcons.makeIcon(png.buffer.asUint8List());
      final codec = await ui.instantiateImageCodec(out);
      final image = (await codec.getNextFrame()).image;
      expect(image.width, 128);
      expect(image.height, 128);
      final px = (await image.toByteData())!;
      int alpha(int x, int y) => px.getUint8((y * 128 + x) * 4 + 3);
      expect(alpha(1, 1), 0);
      expect(alpha(64, 64), 255);
    });
  });
}
