import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/ui/components/menu_list.dart';
import 'package:simple_money/state/vibration_settings.dart';
import 'package:simple_money/ui/more/settings/settings_screen.dart';
import 'package:simple_money/ui/components/number_keypad.dart';
import 'package:simple_money/ui/components/scroll_edge_haptics.dart';

void main() {
  final feedback = <Object?>[];
  const haptics = MethodChannel('simple_money/haptics');
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await VibrationSettings.instance.restore();
    feedback.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(haptics, (call) async {
          feedback.add(call.method);
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            feedback.add(call.arguments);
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(haptics, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('Vibrations default on, toggle persists and gates feedback', (
    tester,
  ) async {
    expect(VibrationSettings.instance.enabled, isTrue);
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));
    expect(find.text('Vibrations'), findsOneWidget);
    // Settings has more than one switch now: the one in the Vibrations row.
    final vibrations = find.descendant(
      of: find.widgetWithText(MenuSwitchRow, 'Vibrations'),
      matching: find.byType(Switch),
    );
    await tester.tap(vibrations);
    await tester.pumpAndSettle();
    expect(find.text('Disabled'), findsOneWidget);
    await VibrationSettings.instance.restore();
    expect(VibrationSettings.instance.enabled, isFalse);
    await VibrationSettings.selectionClick();
    await VibrationSettings.lightImpact();
    await VibrationSettings.softTick();
    expect(feedback, isEmpty);
    await tester.tap(vibrations);
    await tester.pumpAndSettle();
    await VibrationSettings.selectionClick();
    expect(feedback, ['HapticFeedbackType.selectionClick']);
  });

  testWidgets('keypad ticks once, disabled decimal stays silent', (
    tester,
  ) async {
    var digits = '';
    var cleared = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NumberKeypad(
            onDigit: (digit) => digits += digit,
            onDecimalPoint: () {},
            onBackspace: () {},
            onClear: () => cleared = true,
            decimalEnabled: false,
          ),
        ),
      ),
    );
    await tester.tap(find.text('1'));
    await tester.tap(find.text('.'));
    await tester.pump();
    expect(digits, '1');
    expect(feedback, ['softTick']);
    await tester.longPress(find.byIcon(Icons.backspace_outlined));
    await tester.pump();
    expect(cleared, isTrue);
    expect(feedback.last, 'softTick');
    expect(feedback.length, 2);
    await VibrationSettings.instance.setEnabled(false);
    feedback.clear();
    await tester.tap(find.text('2'));
    await tester.longPress(find.byIcon(Icons.backspace_outlined));
    expect(digits, '12');
    expect(feedback, isEmpty);
  });

  for (final physics in <ScrollPhysics>[
    const ClampingScrollPhysics(),
    const BouncingScrollPhysics(),
  ]) {
    testWidgets('scroll edges tick once with ${physics.runtimeType}', (
      tester,
    ) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: ScrollEdgeHaptics(
            child: ListView.builder(
              controller: controller,
              physics: physics,
              itemExtent: 60,
              itemCount: 40,
              itemBuilder: (_, index) => Text('Row $index'),
            ),
          ),
        ),
      );
      controller.jumpTo(100);
      await tester.pumpAndSettle();
      expect(feedback, isEmpty);
      final gesture = await tester.startGesture(const Offset(200, 200));
      await gesture.moveBy(const Offset(0, 200));
      await tester.pump();
      await gesture.moveBy(const Offset(0, 60));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();
      expect(feedback, ['softTick']);
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(feedback.length, 1);
      // Ticks closer than 600 ms (wall clock) are merged into one.
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 650)),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(feedback.length, 2);
      await VibrationSettings.instance.setEnabled(false);
      feedback.clear();
      await tester.drag(find.byType(ListView), const Offset(0, -150));
      await tester.pumpAndSettle();
      expect(feedback, isEmpty);
    });
  }
}
