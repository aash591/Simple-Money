import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/keep_alive_phones.dart';
import 'package:simple_money/data/keep_alive_platform.dart';
import 'package:simple_money/ui/more/smart_tracking/keep_working/keep_working_screen.dart';
import 'package:simple_money/ui/more/smart_tracking/smart_tracking_screen.dart';

/// Plays back what a phone would report, through the real parsing.
class _FakeKeepAlive extends KeepAlivePlatform {
  String family = 'colorOs';
  bool battery = false, background = true;
  bool? access = false;
  final confirmed = <String>{};
  final opened = <String>[];

  @override
  bool get supported => true;
  @override
  Future<KeepAliveState> state() async => KeepAlivePlatform.parseState({
    'family': family,
    'battery': battery,
    'background': background,
    'access': access,
    'confirmed': confirmed.toList(),
  });
  @override
  Future<void> open(String stepId) async => opened.add(stepId);
  @override
  Future<void> setConfirmed(String stepId, bool done) async =>
      done ? confirmed.add(stepId) : confirmed.remove(stepId);
}

void main() {
  testWidgets('Smart tracking groups SMS, notifications, and teaching', (
    tester,
  ) async {
    // Tall enough that the whole list is on screen.
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    var taught = 0;
    await tester.pumpWidget(
      MaterialApp(home: SmartTrackingScreen(onTeach: () => taught++)),
    );
    expect(find.textContaining('right on this phone'), findsOneWidget);
    // Keeping it running first, then SMS, notifications, and teaching.
    expect(find.text('Keep it working'), findsOneWidget);
    expect(find.text('SMS'), findsOneWidget);
    expect(find.text('Teach a missed SMS'), findsOneWidget);
    expect(find.text('APP NOTIFICATIONS'), findsOneWidget);
    expect(find.text('Transactions from notifications'), findsOneWidget);
    expect(find.text('TEACH AND SHARE'), findsOneWidget);
    // Nothing shared to list without the community, nor a switch off Android.
    expect(find.text('Shared fixes'), findsNothing);
    expect(find.text('Transactions from SMS'), findsNothing);

    await tester.tap(find.text('Teach with AI'));
    expect(taught, 1);
  });

  testWidgets('Keep it working is on top while there is something to do, '
      'and last once every step is done', (tester) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = _FakeKeepAlive();
    double top(String text) => tester.getTopLeft(find.text(text)).dy;

    await tester.pumpWidget(
      MaterialApp(
        home: SmartTrackingScreen(keepAlive: fake, onTeach: () {}),
      ),
    );
    await tester.pumpAndSettle();
    // Steps are open: above everything else.
    expect(find.text('3 left'), findsOneWidget);
    expect(top('Keep it working'), lessThan(top('SMS')));

    // Everything done: the card sinks below the last group.
    fake
      ..battery = true
      ..access = true
      ..confirmed.add('autostart');
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('3 left'), findsNothing);
    expect(find.textContaining('All set'), findsOneWidget);
    expect(top('Keep it working'), greaterThan(top('TEACH AND SHARE')));
    expect(top('Keep it working'), greaterThan(top('APP NOTIFICATIONS')));

    // And back to the top if a step comes undone (access taken away).
    fake.access = false;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('1 left'), findsOneWidget);
    expect(top('Keep it working'), lessThan(top('SMS')));
  });

  testWidgets('no teach and share group when there is nothing in it', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: SmartTrackingScreen()));
    expect(find.text('Teach with AI'), findsNothing);
    expect(find.text('TEACH AND SHARE'), findsNothing);
  });

  test('the Settings row is offered only where there is something in it', () {
    expect(SmartTrackingScreen.offered(null, null), isFalse);
  });

  testWidgets('Keep it working lists open steps first and counts them', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = _FakeKeepAlive();
    await tester.pumpWidget(
      MaterialApp(home: KeepWorkingScreen(platform: fake)),
    );
    await tester.pumpAndSettle();
    // Battery, access and the ColorOS autostart are open; background is done.
    expect(find.textContaining('3 steps left'), findsOneWidget);
    expect(find.text('Allow'), findsOneWidget);
    // The phone's own words, not stock Android's.
    expect(
      find.text('Set Simple Money to Allow background activity'),
      findsOneWidget,
    );
    await tester.tap(find.text('Allow'));
    expect(fake.opened, ['battery']);
  });

  testWidgets('what the phone can not say is marked done by the user', (
    tester,
  ) async {
    tester.view
      ..physicalSize = const Size(800, 2400)
      ..devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fake = _FakeKeepAlive();
    await tester.pumpWidget(
      MaterialApp(home: KeepWorkingScreen(platform: fake)),
    );
    await tester.pumpAndSettle();
    // Android says the battery step is off, but this phone's own switch may
    // be on: the user can say so, and take it back.
    await tester.tap(find.byKey(const Key('confirm-battery')));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 steps left'), findsOneWidget);
    expect(find.text('Done · you said so'), findsOneWidget);
    await tester.tap(find.byKey(const Key('undo-battery')));
    await tester.pumpAndSettle();
    expect(find.textContaining('3 steps left'), findsOneWidget);

    // Autostart has no way to be checked at all.
    await tester.tap(find.byKey(const Key('confirm-autostart')));
    await tester.pumpAndSettle();
    expect(find.textContaining('2 steps left'), findsOneWidget);
  });

  testWidgets('Keep it working says all set once every step is done', (
    tester,
  ) async {
    final fake = _FakeKeepAlive()
      ..battery = true
      ..access = true
      ..confirmed.add('autostart');
    await tester.pumpWidget(
      MaterialApp(home: KeepWorkingScreen(platform: fake)),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('All set'), findsOneWidget);
    expect(find.text('Allow'), findsNothing);
  });

  group('each phone maker gets its own steps', () {
    KeepAliveState read(String family, {bool? access = false}) =>
        KeepAlivePlatform.parseState({
          'family': family,
          'battery': false,
          'background': true,
          'access': access,
          'confirmed': <String>[],
        });
    List<String> ids(KeepAliveState s) => [for (final x in s.steps) x.step.id];

    test('a stock phone only has what Android can check', () {
      final state = read('stock');
      expect(ids(state), ['battery', 'background', 'access']);
      // Android's answer is the truth there: nothing to confirm by hand.
      expect(state.steps.any((s) => s.confirmable), isFalse);
    });

    test('each skin adds the switches it has, in its own words', () {
      expect(ids(read('colorOs')), contains('autostart'));
      expect(ids(read('originOs')), containsAll(['highPower', 'autostart']));
      expect(ids(read('hyperOs')), containsAll(['batterySaver', 'autostart']));
      expect(ids(read('oneUi')), contains('neverSleeping'));
      expect(ids(read('emui')), contains('appLaunch'));
      expect(ids(read('transsion')), containsAll(['autostart', 'powerSaving']));
      expect(ids(read('asus')), contains('powerMaster'));
      // A switch no app can read is never "checked".
      for (final f in PhoneFamily.values) {
        for (final s in keepStepsFor(f).where((x) => x.checked)) {
          expect(['battery', 'background', 'access'], contains(s.id));
        }
      }
    });

    test('names follow the phone: ColorOS, One UI', () {
      final color = keepStepsFor(PhoneFamily.colorOs);
      expect(
        color.firstWhere((s) => s.id == 'battery').todo,
        contains('Allow background activity'),
      );
      expect(
        color.firstWhere((s) => s.id == 'access').howTo,
        contains('Manage unused apps'),
      );
      final samsung = keepStepsFor(PhoneFamily.oneUi);
      expect(
        samsung.firstWhere((s) => s.id == 'access').howTo,
        contains('Remove permissions if app isn’t used'),
      );
      expect(
        samsung.firstWhere((s) => s.id == 'neverSleeping').howTo,
        contains('Never auto sleeping apps'),
      );
    });

    test('before Android 11 there is no permission reset step', () {
      expect(ids(read('colorOs', access: null)), isNot(contains('access')));
    });

    test('an unknown maker is treated as stock Android', () {
      expect(PhoneFamily.parse('somethingNew'), PhoneFamily.stock);
      expect(PhoneFamily.parse(null), PhoneFamily.stock);
    });
  });
}
