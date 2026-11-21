// Run explicitly: flutter test tool/screenshots_test.dart
// Optional QA_FONT points to a local TTF for readable design-review captures.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/app.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/repositories/account_repository.dart';
import 'package:simple_money/state/account_store.dart';

void main() {
  testWidgets('Capture More and account screens in both themes', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final fontPath = Platform.environment['QA_FONT'];
    if (fontPath != null) {
      await tester.runAsync(() async {
        for (final family in ['Roboto', 'Ahem']) {
          final font = FontLoader(family)
            ..addFont(
              File(fontPath).readAsBytes().then((b) => ByteData.sublistView(b)),
            );
          await font.load();
        }
      });
    }
    await tester.runAsync(() async {
      final icons = FontLoader('MaterialIcons')
        ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
      await icons.load();
    });
    final db = AppDatabase(NativeDatabase.memory());
    final store = AccountStore(AccountRepository(db));
    await tester.runAsync(() async {
      await store.save(
        name: 'Cash',
        currency: 'INR',
        digits: 2,
        openingBalance: 71400,
      );
      await store.save(
        name: 'HDFC Bank',
        currency: 'INR',
        digits: 2,
        openingBalance: 37088350,
      );
      await store.load();
    });
    const captureKey = Key('capture');
    Future<void> capture(String name) async {
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
        find.byKey(captureKey),
      );
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final data = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('build/qa/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(data!.buffer.asUint8List());
        image.dispose();
      });
    }

    await tester.pumpWidget(
      RepaintBoundary(
        key: captureKey,
        child: SimpleMoneyApp(accountStore: store),
      ),
    );
    await tester.tap(find.text('More'));
    await capture('more-light');
    await tester.tap(find.text('Accounts'));
    await capture('accounts-light');
    await tester.tap(find.text('Cash'));
    await capture('account-settings-light');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add account'));
    await capture('add-account-light');
    await tester.tap(find.text('Currency'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await capture('currencies-light');
    await tester.enterText(find.byType(TextField), 'zzzzzz');
    await tester.pumpAndSettle();
    expect(find.text('No currencies found'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Home'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Switch to dark mode'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('More'));
    await capture('more-dark');
    await tester.tap(find.text('Accounts'));
    await capture('accounts-dark');
    tester.view.physicalSize = const Size(320, 640);
    tester.platformDispatcher.textScaleFactorTestValue = 1.6;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await capture('accounts-small-large-text');
    await tester.tap(find.text('Cash'));
    await capture('settings-small-large-text');
    await tester.pumpWidget(const SizedBox());
    store.dispose();
    await tester.runAsync(db.close);
  });
}
