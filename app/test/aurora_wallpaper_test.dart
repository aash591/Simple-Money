import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/aurora_wallpaper.dart';
import 'package:simple_money/state/appearance_controller.dart';
import 'package:simple_money/ui/components/glass_surface.dart';
import 'package:simple_money/ui/more/settings/customization_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

/// A 1x1 PNG.
final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

void main() {
  late Directory temp;
  late File photo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('wallpaper_');
    photo = File('${temp.path}/photo.png')..writeAsBytesSync(_png);
    AuroraWallpaper.directory = () async => temp;
  });

  tearDown(() => temp.deleteSync(recursive: true));

  test(
    'a chosen picture is copied into the app, under a new name each time',
    () async {
      final first = await AuroraWallpaper.choose(pick: () async => photo.path);
      final second = await AuroraWallpaper.choose(pick: () async => photo.path);
      expect(first, isNot(photo.path));
      expect(File(first!).existsSync(), isTrue);
      expect(second, isNot(first));
      // Backing out of the picker changes nothing.
      expect(await AuroraWallpaper.choose(pick: () async => null), isNull);

      await AuroraWallpaper.tidy(keep: second);
      expect(File(first).existsSync(), isFalse);
      expect(File(second!).existsSync(), isTrue);
    },
  );

  test(
    'the picture and its dimming persist, and a missing file is forgotten',
    () async {
      final saved = (await AuroraWallpaper.choose(
        pick: () async => photo.path,
      ))!;
      final settings = AppearanceController();
      await settings.setWallpaper(saved);
      await settings.setWallpaperDim(.6);

      final restored = AppearanceController();
      await restored.restore();
      expect(restored.wallpaperPath, saved);
      expect(restored.wallpaperDim, closeTo(.6, .001));

      File(saved).deleteSync();
      final gone = AppearanceController();
      await gone.restore();
      expect(gone.wallpaperPath, isNull);
      for (final c in [settings, restored, gone]) {
        c.dispose();
      }
    },
  );

  testWidgets('the section shows only in Aurora, and offers the picture', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final settings = AppearanceController();
    addTearDown(settings.dispose);
    Future<void> show() async {
      await tester.pumpWidget(
        MaterialApp(
          theme: appTheme(Brightness.dark, style: settings.style),
          builder: (context, child) =>
              AppearanceScope(controller: settings, child: child!),
          home: const CustomizationScreen(),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show();
    expect(find.text('Aurora background'), findsNothing);

    await tester.runAsync(() => settings.setStyle(AppStyle.aurora));
    await show();
    expect(find.text('Aurora background'), findsOneWidget);
    expect(find.text('Choose a picture'), findsOneWidget);
    expect(find.text('Dim the picture'), findsNothing);

    final saved = (await tester.runAsync(
      () => AuroraWallpaper.choose(pick: () async => photo.path),
    ))!;
    await tester.runAsync(() => settings.setWallpaper(saved));
    await tester.pumpAndSettle();
    expect(find.text('Change picture'), findsOneWidget);
    expect(find.text('Dim the picture'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Aurora paints the picture behind the page, only when chosen', (
    tester,
  ) async {
    final settings = AppearanceController();
    addTearDown(settings.dispose);
    settings.style = AppStyle.aurora;
    Widget page() => MaterialApp(
      theme: appTheme(Brightness.dark, style: AppStyle.aurora),
      builder: (context, child) =>
          AppearanceScope(controller: settings, child: child!),
      home: const GlassPage(child: Scaffold()),
    );
    await tester.pumpWidget(page());
    expect(find.byType(Image), findsNothing);

    await tester.runAsync(() => settings.setWallpaper(photo.path));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
