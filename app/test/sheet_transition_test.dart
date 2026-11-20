import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/adaptive_sheet.dart';
import 'package:simple_money/ui/components/modal_transition.dart';
import 'package:simple_money/ui/components/popup_zoom.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

/// Sheets open the way iOS sheets do: whole from the first frame, sliding up
/// from out of sight on a spring that never overshoots, with nothing fading.
void main() {
  test('the spring lands exactly in place without overshooting', () {
    const curve = CriticallyDampedCurve();
    expect(curve.transform(0), 0);
    expect(curve.transform(1), 1);
    var last = 0.0;
    for (var i = 1; i <= 100; i++) {
      final v = curve.transform(i / 100);
      expect(v, greaterThanOrEqualTo(last));
      expect(v, lessThanOrEqualTo(1));
      last = v;
    }
    // Most of the way there early on, then a long glide.
    expect(curve.transform(.3), greaterThan(.7));
  });

  testWidgets('a sheet slides up from below the screen and never fades', (
    tester,
  ) async {
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        theme: appTheme(Brightness.dark, style: AppStyle.aurora),
        home: Builder(
          builder: (context) {
            page = context;
            return const Scaffold();
          },
        ),
      ),
    );
    showAdaptiveSheet<void>(
      page,
      builder: (_) => const SizedBox(key: Key('content'), height: 300),
    );
    await tester.pump();
    final screen = tester.getSize(find.byType(Scaffold));
    // First frame: whole, but out of sight.
    expect(find.byKey(const Key('content')), findsOneWidget);
    expect(
      tester.getTopLeft(find.byKey(const Key('content'))).dy,
      greaterThanOrEqualTo(screen.height),
    );
    expect(find.byType(PopupReveal), findsNothing);

    // Partway: moving up, still not faded.
    await tester.pump(const Duration(milliseconds: 120));
    final top = tester.getTopLeft(find.byKey(const Key('content'))).dy;
    expect(top, lessThan(screen.height));
    expect(find.byType(PopupReveal), findsNothing);

    await tester.pumpAndSettle();
    expect(
      tester.getBottomLeft(find.byKey(const Key('content'))).dy,
      lessThan(screen.height),
    );
  });
}
