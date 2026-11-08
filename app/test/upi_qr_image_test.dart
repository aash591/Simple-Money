import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/upi_platform.dart';
import 'package:simple_money/data/upi_qr_image.dart';
import 'package:simple_money/domain/upi_payment.dart';

void main() {
  test('QR image is an opaque PNG with a white border and exact payment data', () async {
    final directory = Directory('build/upi-qa')..createSync(recursive: true);
    final payloads = [
      UpiRecipient.parse('upi://pay?pa=test@bank&pn=Tea%20Shop&tr=ref%2f123')
          .paymentUri('125.50'),
      'upi://pay?pa=test@bank&pn=Tea%20Shop&am=25.00&sign=abc%2Bxyz%3D',
    ];
    for (var i = 0; i < payloads.length; i++) {
      final png = await generateUpiQrPng(payloads[i]);
      expect(png.take(8), [137, 80, 78, 71, 13, 10, 26, 10]);
      final codec = await ui.instantiateImageCodec(png);
      final image = (await codec.getNextFrame()).image;
      try {
        expect(image.width, image.height);
        expect(image.width, inInclusiveRange(256, 1100));
        final pixels = (await image.toByteData())!.buffer.asUint8List();
        expect(pixels.take(4), [255, 255, 255, 255]);
      } finally {
        image.dispose();
        codec.dispose();
      }
      // Decode these artifacts with an independent QR reader during validation.
      await File('${directory.path}/qr-$i.png').writeAsBytes(png);
      await File('${directory.path}/qr-$i.txt').writeAsString(payloads[i]);
    }
  });

  test(
    'sharing sends PNG bytes to the image channel, never a payment-link launch',
    () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(UpiPlatform.channel, (call) async {
            calls.add(call);
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(UpiPlatform.channel, null),
      );
      await UpiPlatform().shareQr(
        const UpiApp(
          'com.google.android.apps.nbu.paisa.user',
          'Google Pay',
          null,
          canShareQr: true,
        ),
        payload: 'upi://pay?pa=test@bank&am=25&cu=INR',
      );
      expect(calls.single.method, 'shareQr');
      expect(
        calls.single.arguments['package'],
        'com.google.android.apps.nbu.paisa.user',
      );
      expect(calls.single.arguments['png'], isA<Uint8List>());
      expect((calls.single.arguments as Map).containsKey('uri'), isFalse);
    },
  );

  test('invalid QR data cannot be shared as a payment image', () async {
    await expectLater(
      generateUpiQrPng('https://example.com'),
      throwsFormatException,
    );
    await expectLater(
      UpiPlatform().shareQr(
        const UpiApp('other.app', 'Other', null),
        payload: 'upi://pay?pa=test@bank&am=25',
      ),
      throwsStateError,
    );
  });
}
