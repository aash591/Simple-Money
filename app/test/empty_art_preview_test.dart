// Golden coverage of the current empty-state artwork.
import 'preview_fonts.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/empty_art.dart';
import 'package:simple_money/ui/components/empty_state.dart';
import 'package:simple_money/ui/components/glass_surface.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

Widget _panel(Brightness b, Color c) => Theme(
  data: appTheme(b, accentColor: c),
  child: Builder(
    builder: (context) => Material(
      type: MaterialType.transparency,
      child: Stack(
        children: [
          const Positioned.fill(child: GlassBackdrop()),
          Column(
            children: [
              SizedBox(
                height: 560,
                child: EmptyState(
                  icon: Icons.account_balance_wallet_outlined,
                  title: 'No accounts yet',
                  message:
                      'Add a bank account, card or wallet to start tracking.',
                  actionLabel: 'Add account',
                  onAction: () {},
                ),
              ),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: [
                  for (final art in EmptyArt.values)
                    GlassLens(size: 76, child: EmptyArtwork(art, size: 42)),
                ],
              ),
            ],
          ),
        ],
      ),
    ),
  ),
);

void main() {
  testWidgets('empty art preview', (tester) async {
    await loadPreviewFonts();
    tester.view.physicalSize = const Size(1200, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Row(
          children: [
            Expanded(child: _panel(Brightness.light, const Color(0xff3d7be0))),
            Expanded(child: _panel(Brightness.dark, accent)),
            Expanded(child: _panel(Brightness.light, const Color(0xffe0703d))),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Row).first,
      matchesGoldenFile('empty_art_preview.png'),
    );
  });
}
