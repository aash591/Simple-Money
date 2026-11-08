// flutter test tool/amount_sheet_screenshot_test.dart
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/ui/components/adaptive_sheet.dart';
import 'package:simple_money/ui/components/frosted_modal_surface.dart';
import 'package:simple_money/ui/transactions/transaction_pages.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

void main() {
  for (final dark in [false, true]) {
    testWidgets('Capture amount sheet ${dark ? 'dark' : 'light'}', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(bottom: 34);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      debugDisableShadows = false;
      addTearDown(() => debugDisableShadows = true);
      await tester.runAsync(() async {
        final path = Platform.environment['QA_FONT'];
        if (path != null) {
          for (final family in ['Roboto', 'Ahem']) {
            await (FontLoader(family)..addFont(
                  File(path)
                      .readAsBytes()
                      .then((bytes) => ByteData.sublistView(bytes)),
                ))
                .load();
          }
        }
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      final capture = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: capture,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: appTheme(dark ? Brightness.dark : Brightness.light),
            home: Scaffold(
              body: Builder(
                builder: (context) => Center(
                  child: TextButton(
                    onPressed: () => showAdaptiveSheet<void>(
                      context,
                      entrance: SheetEntrance.fadeRise,
                      builder: (context) => AmountPage(
                        type: TransactionType.expense,
                        amountText: '125',
                        digits: 2,
                        currency: 'USD',
                        onDigit: (_) {},
                        onDecimalPoint: () {},
                        onBackspace: () {},
                        onClear: () {},
                        onBack: () {},
                        onCancel: () => Navigator.pop(context),
                        onContinue: () {},
                      ),
                    ),
                    child: const Text('Open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getBottomLeft(find.byType(FrostedModalSurface)).dy,
        844 - 34 - 12,
      );
      await tester.runAsync(() async {
        final boundary =
            capture.currentContext!.findRenderObject() as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File(
          'build/qa/amount-sheet-${dark ? 'dark' : 'light'}.png',
        );
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      tester.view.physicalSize = const Size(320, 640);
      tester.platformDispatcher.textScaleFactorTestValue = 1.6;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      debugDisableShadows = true;
    });
  }
}
