import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/state/upi_settings.dart';
import 'package:simple_money/ui/components/app_toast.dart';

void main() {
  test(
    'UPI defaults on and turning it off persists across controller recreation',
    () async {
      final first = UpiSettings(region: 'IN');
      expect(first.enabled, isTrue);
      await first.restore();
      expect(first.enabled, isTrue);
      await first.setEnabled(false);
      first.dispose();
      final second = UpiSettings(region: 'IN');
      await second.restore();
      expect(second.enabled, isFalse);
      await second.setEnabled(true);
      second.dispose();
      final third = UpiSettings(region: 'IN');
      await third.restore();
      expect(third.enabled, isTrue);
      third.dispose();
    },
  );

  test('UPI is off by default outside India but can be turned on', () async {
    SharedPreferences.setMockInitialValues({});
    final settings = UpiSettings(region: 'US');
    expect(settings.enabled, isFalse);
    await settings.restore();
    expect(settings.enabled, isFalse);
    await settings.setEnabled(true);
    settings.dispose();
    final again = UpiSettings(region: 'US');
    await again.restore();
    expect(again.enabled, isTrue);
    again.dispose();
  });

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
