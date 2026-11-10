import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/backup/backup_encryption.dart';
import 'package:simple_money/ui/components/action_buttons.dart';
import 'package:simple_money/ui/more/settings/sync/backup_pin_screen.dart';
import 'package:simple_money/ui/theme/app_theme.dart';

Widget app(Widget home) =>
    MaterialApp(theme: appTheme(Brightness.dark), home: home);

PillButton primary(WidgetTester tester) =>
    tester.widget<PillButton>(find.byType(PillButton).first);

void main() {
  testWidgets('setup is three steps: why, choose, confirm', (tester) async {
    String? submitted;
    await tester.pumpWidget(
      app(
        BackupPinScreen(
          purpose: BackupPinPurpose.enable,
          onSubmit: (pin) async => submitted = pin,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Protect your Drive backups'), findsOneWidget);
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Choose a backup PIN'), findsOneWidget);
    expect(primary(tester).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Ab12');
    await tester.pump();
    expect(primary(tester).onPressed, isNull, reason: 'Too short.');
    await tester.enterText(find.byType(TextField), 'Ab12x9');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();

    expect(find.text('Confirm your PIN'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'Ab12x8');
    await tester.pump();
    expect(find.text('The PINs do not match.'), findsOneWidget);
    expect(primary(tester).onPressed, isNull);
    await tester.enterText(find.byType(TextField), 'Ab12x9');
    await tester.pump();
    expect(primary(tester).onPressed, isNull, reason: 'Not acknowledged yet.');
    await tester.ensureVisible(find.byType(CheckboxListTile));
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(primary(tester).onPressed, isNotNull);
    expect(submitted, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('back from confirm returns to choosing, keeping the PIN', (
    tester,
  ) async {
    await tester.pumpWidget(
      app(
        BackupPinScreen(
          purpose: BackupPinPurpose.enable,
          onSubmit: (_) async {},
        ),
      ),
    );
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Ab12x9');
    await tester.pump();
    await tester.tap(find.text('Continue'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Choose a backup PIN'), findsOneWidget);
    expect(primary(tester).onPressed, isNotNull);
  });

  testWidgets('a wrong PIN stays for retry on a narrow screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var attempts = 0;
    await tester.pumpWidget(
      app(
        BackupPinScreen(
          purpose: BackupPinPurpose.unlock,
          onSubmit: (_) async {
            attempts++;
            throw const BackupEncryptionException('Incorrect PIN. Try again.');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Enter your backup PIN'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'wrong1');
    await tester.pump();
    await tester.ensureVisible(find.text('Unlock backup'));
    await tester.tap(find.text('Unlock backup'));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(find.text('Incorrect PIN. Try again.'), findsOneWidget);
    expect(primary(tester).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('as a screen it pops with whether it finished', (tester) async {
    bool? result;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await showBackupPinFlow(
                context,
                purpose: BackupPinPurpose.unlock,
                onSubmit: (_) async {},
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Ab12x9');
    await tester.pump();
    await tester.tap(find.text('Unlock backup'));
    await tester.pumpAndSettle();
    expect(result, isTrue);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('"Not now" leaves an optional setup without enabling', (
    tester,
  ) async {
    bool? result;
    await tester.pumpWidget(
      app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result = await showBackupPinFlow(
                context,
                purpose: BackupPinPurpose.enable,
                optional: true,
                onSubmit: (_) async => fail('Should not be called'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Not now'));
    await tester.tap(find.text('Not now'));
    await tester.pumpAndSettle();
    expect(result, isFalse);
  });
}
