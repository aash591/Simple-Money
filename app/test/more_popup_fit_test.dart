import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/frosted_modal_surface.dart';
import 'package:simple_money/ui/components/more_popup_button.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

/// A menu of one short action can hug its row instead of keeping the usual
/// fixed width; every other menu keeps that width.
void main() {
  Future<double> menuWidth(WidgetTester tester, {required bool fit}) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.light),
        home: Scaffold(
          appBar: AppBar(
            actions: [
              MorePopupButton<int>(
                fitContent: fit,
                items: const [MorePopupItem(value: 1, label: 'Go')],
                onSelected: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.tap(find.byTooltip('More options'));
    await tester.pumpAndSettle();
    return tester.getSize(find.byType(FrostedModalSurface)).width;
  }

  testWidgets('fitContent sizes the menu to its row', (tester) async {
    final fitted = await menuWidth(tester, fit: true);
    expect(fitted, lessThan(120));
    expect(find.text('Go'), findsOneWidget);
  });

  testWidgets('without it the menu keeps its usual width', (tester) async {
    expect(await menuWidth(tester, fit: false), 180);
  });
}
