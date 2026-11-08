import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/components/native_modal_blur.dart';

void main() {
  testWidgets('native blur tracks only modal bounds and clears on dismissal', (
    tester,
  ) async {
    final calls = <Map<dynamic, dynamic>>[];
    NativeModalBlur.enabled = true;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      NativeModalBlur.channel,
      (call) async {
        calls.add(call.arguments as Map);
        return null;
      },
    );
    addTearDown(() {
      NativeModalBlur.enabled = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        NativeModalBlur.channel,
        null,
      );
    });
    await tester.pumpWidget(
      const MediaQuery(
        data: MediaQueryData(devicePixelRatio: 2),
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: Stack(
            children: [
              Positioned(
                left: 20,
                top: 100,
                width: 200,
                height: 300,
                child: NativeModalBlur(
                  radius: 24,
                  child: ColoredBox(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(calls.last['left'], 40);
    expect(calls.last['top'], 200);
    expect(calls.last['right'], 440);
    expect(calls.last['bottom'], 800);
    expect(calls.last['radius'], 48);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
    expect(calls.last['remove'], true);
  });
}
