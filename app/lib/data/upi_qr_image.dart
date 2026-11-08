import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:qr/qr.dart';

import '../domain/upi_payment.dart';

/// Crisp black-on-white PNG with a four-module quiet zone. The QR contains
/// only validated payment data, never a screenshot of the app or ledger.
Future<Uint8List> generateUpiQrPng(String payload) async {
  UpiRecipient.parse(payload);
  final code = QrImage(
    QrCode(
      payload: QrPayload.fromString(payload),
      errorCorrectLevel: QrErrorCorrectLevel.medium,
    ),
  );
  const quiet = 4;
  final modules = code.moduleCount + quiet * 2;
  final scale = (1024 ~/ modules).clamp(4, 24);
  final size = modules * scale;
  final recorder = ui.PictureRecorder();
  final canvas = ui.Canvas(recorder);
  canvas.drawColor(const ui.Color(0xffffffff), ui.BlendMode.src);
  final ink = ui.Paint()
    ..color = const ui.Color(0xff000000)
    ..isAntiAlias = false;
  for (var row = 0; row < code.moduleCount; row++) {
    for (var column = 0; column < code.moduleCount; column++) {
      if (code.isDark(row, column)) {
        canvas.drawRect(
          ui.Rect.fromLTWH(
            ((column + quiet) * scale).toDouble(),
            ((row + quiet) * scale).toDouble(),
            scale.toDouble(),
            scale.toDouble(),
          ),
          ink,
        );
      }
    }
  }
  final picture = recorder.endRecording();
  try {
    final image = await picture.toImage(size, size);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      if (bytes == null) {
        throw StateError('Could not create the payment QR image.');
      }
      return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    } finally {
      image.dispose();
    }
  } finally {
    picture.dispose();
  }
}
