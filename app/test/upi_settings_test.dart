import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/state/upi_settings.dart';
import 'package:simple_money/ui/components/app_toast.dart';

void main() {
  test(
    'UPI defaults on and turning it off persists across controller recreation',
    () async {
      final first = UpiSettings();
      expect(first.enabled, isTrue);
      await first.restore();
      expect(first.enabled, isTrue);
      await first.setEnabled(false);
      first.dispose();
      final second = UpiSettings();
      await second.restore();
      expect(second.enabled, isFalse);
      await second.setEnabled(true);
      second.dispose();
      final third = UpiSettings();
      await third.restore();
      expect(third.enabled, isTrue);
      third.dispose();
    },
  );

  testWidgets('limit toast stays for four seconds', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showAppToast(
                context,
                'Maximum ₹2,000 for QR-image payments in Google Pay',
                duration: const Duration(seconds: 4),
                dismissOnTap: false,
              ),
              child: const Text('Show limit'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show limit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 3900));
    expect(find.textContaining('Maximum ₹2,000'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(find.textContaining('Maximum ₹2,000'), findsNothing);
  });
}
