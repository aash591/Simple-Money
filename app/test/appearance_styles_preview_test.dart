// Temporary visual preview of the calm glass styling; not part of the suite.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/app_back_button.dart';
import 'package:simple_money/ui/components/common.dart';
import 'package:simple_money/ui/components/glass_surface.dart';
import 'package:simple_money/ui/components/menu_list.dart';
import 'package:simple_money/ui/components/secondary_header.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

Future<void> _font(String family, String path) async {
  final loader = FontLoader(family)
    ..addFont(Future.value(ByteData.sublistView(File(path).readAsBytesSync())));
  await loader.load();
}

void _noop() {}

Widget _screen(Brightness b, Color accent, AppStyle style) {
  final theme = appTheme(b, accentColor: accent, style: style);
  final t = theme.textTheme;
  return Theme(
    data: theme,
    child: Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          const Positioned.fill(child: GlassBackdrop()),
          ListView(
            padding: const EdgeInsets.fromLTRB(0, 40, 0, 18),
            children: [
              SecondaryHeader(
                title: 'Overview',
                actions: [
                  IconButton(
                    onPressed: _noop,
                    icon: const Icon(Icons.calendar_today_outlined),
                  ),
                  AppSearchButton(onPressed: _noop),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MoneyCard(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('Spent this month', style: t.bodySmall),
                          const SizedBox(height: 6),
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              Text('₹12,651', style: t.headlineLarge),
                              const SizedBox(width: 8),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text(
                                  '/ ₹20,000',
                                  style: t.bodySmall?.copyWith(fontSize: 15),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 14),
                          Row(
                            children: [
                              for (final (label, value) in [
                                ('Food', '₹4,210'),
                                ('Bills', '₹3,100'),
                                ('Travel', '₹1,960'),
                              ]) ...[
                                Expanded(
                                  child: MoneyCard(
                                    padding: const EdgeInsets.all(12),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(label, style: t.labelMedium),
                                        const SizedBox(height: 4),
                                        Text(value, style: t.bodySmall),
                                      ],
                                    ),
                                  ),
                                ),
                                if (label != 'Travel') const SizedBox(width: 8),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 22),
                    Text('Settings', style: t.titleMedium),
                    const SizedBox(height: 10),
                    const MenuGroup(
                      children: [
                        MenuRow(
                          icon: Icons.tune_rounded,
                          title: 'Preferences',
                          onTap: _noop,
                        ),
                        MenuRow(
                          icon: Icons.person_outline_rounded,
                          title: 'Account',
                          subtitle: 'Backup, sync and devices',
                          onTap: _noop,
                        ),
                        MenuRow(
                          icon: Icons.auto_awesome_outlined,
                          title: 'AI companion',
                          highlight: true,
                          onTap: _noop,
                        ),
                        MenuRow(
                          icon: Icons.delete_outline_rounded,
                          title: 'Delete data',
                          tint: coral,
                          onTap: _noop,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    ),
  );
}

void main() {
  testWidgets('appearance styles preview', (tester) async {
    await _font('Manrope', 'assets/fonts/Manrope.ttf');
    await _font(
      'MaterialIcons',
      '${File(Platform.resolvedExecutable).parent.parent.parent.path}/material_fonts/materialicons-regular.otf',
    );
    tester.view.physicalSize = const Size(4 * 400, 820);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Row(
          children: [
            Expanded(child: _screen(Brightness.light, accent, AppStyle.glassy)),
            Expanded(child: _screen(Brightness.dark, accent, AppStyle.glassy)),
            Expanded(child: _screen(Brightness.light, accent, AppStyle.simple)),
            Expanded(child: _screen(Brightness.dark, accent, AppStyle.simple)),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Row).first,
      matchesGoldenFile('appearance_styles_preview.png'),
    );
  });
}
