import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/data/device_screen_lock.dart';
import 'package:simple_money/state/security_controller.dart';
import 'package:simple_money/ui/components/app_lock_gate.dart';
import 'package:simple_money/ui/components/private_amount.dart';
import 'package:simple_money/ui/more/settings/security_screen.dart';

class FakeAuthentication extends LocalAuthentication {
  bool result = true;
  Object? failure;
  Completer<bool>? pending;
  int calls = 0;

  @override
  Future<bool> authenticate({
    required String localizedReason,
    Iterable<dynamic> authMessages = const [],
    bool biometricOnly = false,
    bool sensitiveTransaction = true,
    bool persistAcrossBackgrounding = false,
  }) async {
    calls++;
    expect(
      biometricOnly,
      isFalse,
      reason: 'Device credentials must be allowed',
    );
    expect(persistAcrossBackgrounding, isTrue);
    if (failure != null) throw failure!;
    return pending == null ? result : await pending!.future;
  }
}

class FakeScreenLock implements ScreenLockWatcher {
  bool available = true;
  bool screenOff = false;

  @override
  Future<bool> get supported async => available;

  @override
  Future<bool> consumeScreenOff() async {
    final seen = screenOff;
    screenOff = false;
    return seen;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAuthentication auth;
  late FakeScreenLock screenLock;
  late SecurityController security;
  late DateTime clock;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    auth = FakeAuthentication();
    screenLock = FakeScreenLock();
    clock = DateTime(2026, 9, 12, 9);
    security = SecurityController(
      authentication: auth,
      screenLock: screenLock,
      now: () => clock,
    );
  });
  tearDown(() => security.dispose());

  test('amount protection requires authentication and persists', () async {
    await security.initialize();
    expect(await security.authorizeAmountReveal(), isTrue);
    expect(auth.calls, 0);
    auth.result = false;
    await security.setAuthenticateToRevealAmounts(true);
    expect(security.authenticateToRevealAmounts, isFalse);
    auth.result = true;
    await security.setAuthenticateToRevealAmounts(true);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(SecurityController.revealAmountsPreferenceKey),
      isTrue,
    );
    auth.result = false;
    expect(await security.authorizeAmountReveal(), isFalse);
    await security.setAuthenticateToRevealAmounts(false);
    expect(security.authenticateToRevealAmounts, isTrue);
    auth.result = true;
    expect(await security.authorizeAmountReveal(), isTrue);
  });

  testWidgets('amounts start hidden, authenticate, and hide on background', (
    tester,
  ) async {
    await security.initialize();
    await security.setAuthenticateToRevealAmounts(true);
    await tester.pumpWidget(
      MaterialApp(
        home: SecurityScope(
          controller: security,
          child: const Scaffold(
            body: PrivateAmount(label: 'Total balance', child: Text('12345')),
          ),
        ),
      ),
    );
    expect(find.text('12345'), findsNothing);
    auth.result = false;
    await tester.tap(find.byTooltip('Show total balance'));
    await tester.pumpAndSettle();
    expect(find.text('12345'), findsNothing);
    auth.result = true;
    await tester.tap(find.byTooltip('Show total balance'));
    await tester.pumpAndSettle();
    expect(find.text('12345'), findsOneWidget);
    await tester.tap(find.byTooltip('Hide total balance'));
    await tester.pumpAndSettle();
    expect(find.text('12345'), findsNothing);
    await tester.tap(find.byTooltip('Show total balance'));
    await tester.pumpAndSettle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(find.text('12345'), findsNothing);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(find.text('12345'), findsNothing);
  });

  test('amount reveal waits for focus after native authentication', () async {
    await security.initialize();
    await security.setAuthenticateToRevealAmounts(true);
    auth.pending = Completer<bool>();
    var completed = false;
    final reveal = security.authorizeAmountReveal().then((value) {
      completed = true;
      return value;
    });
    security.handleLifecycle(AppLifecycleState.inactive);
    auth.pending!.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(completed, isFalse);
    expect(security.busy, isTrue);
    security.handleLifecycle(AppLifecycleState.resumed);
    expect(await reveal, isTrue);
    expect(security.busy, isFalse);
  });

  testWidgets(
    'amount toggle keeps height and consumes parent navigation taps',
    (tester) async {
      var navigation = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: InkWell(
              onTap: () => navigation++,
              child: const SizedBox(
                width: 300,
                child: PrivateAmount(
                  label: 'Net savings',
                  child: Text('123456', style: TextStyle(fontSize: 36)),
                ),
              ),
            ),
          ),
        ),
      );
      final amount = find.byType(PrivateAmount);
      final hiddenSize = tester.getSize(amount);
      await tester.tap(find.byTooltip('Show net savings'));
      await tester.pumpAndSettle();
      expect(tester.getSize(amount), hiddenSize);
      expect(find.text('123456'), findsOneWidget);
      await tester.tap(find.text('123456'));
      await tester.pumpAndSettle();
      expect(navigation, 0);
      expect(tester.getSize(amount), hiddenSize);
      expect(find.text('123456'), findsNothing);
    },
  );

  test('enabling and disabling require successful authentication', () async {
    await security.initialize();
    expect(security.enabled, isFalse);
    expect(auth.calls, 0);
    auth.result = false;
    await security.setEnabled(true);
    expect(security.enabled, isFalse);
    auth.result = true;
    await security.setEnabled(true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(SecurityController.preferenceKey), isTrue);
    auth.result = false;
    await security.setEnabled(false);
    expect(security.enabled, isTrue);
    expect(prefs.getBool(SecurityController.preferenceKey), isTrue);
    auth.result = true;
    await security.setEnabled(false);
    expect(prefs.getBool(SecurityController.preferenceKey), isFalse);
  });

  test('restart locks; cancellation and errors never unlock', () async {
    SharedPreferences.setMockInitialValues({
      SecurityController.preferenceKey: true,
    });
    expect(security.covered, isTrue);
    await security.initialize();
    expect(security.covered, isTrue);
    auth.result = false;
    await security.unlock();
    expect(security.covered, isTrue);
    auth.failure = const LocalAuthException(
      code: LocalAuthExceptionCode.temporaryLockout,
    );
    await security.unlock();
    expect(security.covered, isTrue);
    expect(security.error, contains('locked'));
    auth.failure = null;
    auth.result = true;
    await security.unlock();
    expect(security.covered, isFalse);
  });

  test('missing screen lock leaves app lock disabled with guidance', () async {
    await security.initialize();
    auth.failure = const LocalAuthException(
      code: LocalAuthExceptionCode.noCredentialsSet,
    );
    await security.setEnabled(true);
    expect(security.enabled, isFalse);
    expect(security.error, contains('device settings'));
  });

  test('background return relocks and prevents overlapping prompts', () async {
    await security.initialize();
    await security.setEnabled(true);
    security.handleLifecycle(AppLifecycleState.inactive);
    expect(security.covered, isFalse);
    security.handleLifecycle(AppLifecycleState.resumed);
    expect(security.covered, isFalse);
    security.handleLifecycle(AppLifecycleState.paused);
    auth.pending = Completer<bool>();
    security.handleLifecycle(AppLifecycleState.resumed);
    expect(security.covered, isTrue);
    await security.unlock();
    expect(auth.calls, 2);
    auth.pending!.complete(true);
    await Future<void>.delayed(Duration.zero);
    expect(security.covered, isFalse);
  });

  test('cancelled disable after backgrounding keeps the app locked', () async {
    await security.initialize();
    await security.setEnabled(true);
    auth.pending = Completer<bool>();
    final disabling = security.setEnabled(false);
    security.handleLifecycle(AppLifecycleState.paused);
    security.handleLifecycle(AppLifecycleState.resumed);
    auth.pending!.complete(false);
    await disabling;
    expect(security.enabled, isTrue);
    expect(security.covered, isTrue);
  });

  testWidgets('gate protects pushed routes and provides an unlock retry', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      SecurityController.preferenceKey: true,
    });
    auth.result = false;
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        builder: (_, child) => AppLockGate(controller: security, child: child!),
        home: const Scaffold(body: Text('Private ledger')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Private ledger'), findsNothing);
    expect(find.text('Unlock'), findsOneWidget);
    auth.result = true;
    await tester.tap(find.text('Unlock'));
    await tester.pumpAndSettle();
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Private details')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Private details'), findsOneWidget);
    security.handleLifecycle(AppLifecycleState.paused);
    await tester.pumpAndSettle();
    expect(find.text('Private details'), findsNothing);
    expect(find.text('Unlock to continue'), findsOneWidget);
    security.handleLifecycle(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Private details'), findsOneWidget);
  });

  testWidgets('Security switch reflects saved preference', (tester) async {
    await security.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: SecurityScope(
          controller: security,
          child: const SecurityScreen(),
        ),
      ),
    );
    final appLock = find.widgetWithText(SwitchListTile, 'App lock');
    await tester.tap(appLock);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(appLock).value, isTrue);
    await tester.tap(appLock);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(appLock).value, isFalse);
  });

  test('a dismissed prompt waits to be asked again', () async {
    SharedPreferences.setMockInitialValues({
      SecurityController.preferenceKey: true,
    });
    await security.initialize();
    auth.result = false;
    await security.unlock();
    expect(auth.calls, 1);
    expect(security.covered, isTrue);
    expect(security.needsUserAction, isTrue);
    expect(security.error, isNull, reason: 'backing out is not a failure');

    // Returning to the app must not throw the prompt straight back up.
    security.handleLifecycle(AppLifecycleState.paused);
    security.handleLifecycle(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(auth.calls, 1, reason: 'no prompt the user did not ask for');
    expect(security.covered, isTrue);

    // Only the Unlock button asks again.
    auth.result = true;
    await security.unlock();
    expect(auth.calls, 2);
    expect(security.covered, isFalse);
    expect(security.needsUserAction, isFalse);
  });

  test('a short trip out of the app comes straight back in', () async {
    await security.initialize();
    await security.setEnabled(true);
    await security.setTiming(LockTiming.after5Minutes);
    security.handleLifecycle(AppLifecycleState.paused);
    expect(
      security.covered,
      isFalse,
      reason: 'the preview is visible by default during the grace period',
    );
    clock = clock.add(const Duration(minutes: 1));
    security.handleLifecycle(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(security.covered, isFalse);
    expect(auth.calls, 1, reason: 'only the prompt that enabled the lock');

    security.handleLifecycle(AppLifecycleState.paused);
    clock = clock.add(const Duration(minutes: 6));
    security.handleLifecycle(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(auth.calls, 2, reason: 'the grace period ran out');
    expect(security.covered, isFalse);
  });

  test(
    'one-minute timing still applies with lock on app close enabled',
    () async {
      await security.initialize();
      await security.setEnabled(true);
      await security.setTiming(LockTiming.afterMinute);
      expect(security.lockOnAppClose, isTrue);

      security.handleLifecycle(AppLifecycleState.paused);
      clock = clock.add(const Duration(seconds: 59));
      security.handleLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(security.requiresUnlock, isFalse);
      expect(auth.calls, 1);

      auth.result = false;
      security.handleLifecycle(AppLifecycleState.paused);
      clock = clock.add(const Duration(minutes: 1));
      security.handleLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(security.requiresUnlock, isTrue);
      expect(auth.calls, 2);
    },
  );

  group('a fresh start after the app was closed', () {
    /// The app reopened from scratch â€” swiped out of recents, or reclaimed
    /// by the system â€” reading the preferences the last run left behind.
    Future<SecurityController> restart() async {
      final restarted = SecurityController(
        authentication: auth,
        screenLock: screenLock,
        now: () => clock,
      );
      addTearDown(restarted.dispose);
      await restarted.initialize();
      await pumpEventQueue();
      return restarted;
    }

    Future<void> leaveUnlocked(LockTiming timing, {bool onClose = true}) async {
      await security.initialize();
      await security.setEnabled(true);
      await security.setTiming(timing);
      await security.setLockOnAppClose(onClose);
      security.handleLifecycle(AppLifecycleState.paused);
      await pumpEventQueue();
    }

    test('clearing the app locks before the one-minute limit', () async {
      await leaveUnlocked(LockTiming.afterMinute);
      clock = clock.add(const Duration(seconds: 30));
      expect((await restart()).requiresUnlock, isTrue);
    });

    test('with the option off, the time away decides', () async {
      await leaveUnlocked(LockTiming.after5Minutes, onClose: false);
      clock = clock.add(const Duration(minutes: 1));
      final soon = await restart();
      expect(soon.requiresUnlock, isFalse);
      expect(soon.covered, isFalse);
      expect(auth.calls, 1, reason: 'only the prompt that enabled the lock');
    });

    test('with the option off, an expired grace still locks', () async {
      await leaveUnlocked(LockTiming.after5Minutes, onClose: false);
      clock = clock.add(const Duration(minutes: 6));
      expect((await restart()).requiresUnlock, isTrue);
    });

    test('screen-off still locks within the restart grace period', () async {
      await leaveUnlocked(LockTiming.after5Minutes, onClose: false);
      screenLock.screenOff = true;
      clock = clock.add(const Duration(seconds: 10));
      expect((await restart()).requiresUnlock, isTrue);
    });

    test('restart ignores screen-off when that trigger is disabled', () async {
      await leaveUnlocked(LockTiming.after5Minutes, onClose: false);
      await security.setLockOnScreenOff(false);
      screenLock.screenOff = true;
      expect((await restart()).requiresUnlock, isFalse);
    });

    test('one recorded session cannot unlock two starts', () async {
      await leaveUnlocked(LockTiming.after5Minutes, onClose: false);
      clock = clock.add(const Duration(minutes: 1));
      expect((await restart()).requiresUnlock, isFalse);
      expect((await restart()).requiresUnlock, isTrue);
    });

    test('a start with no session behind it locks', () async {
      SharedPreferences.setMockInitialValues({
        SecurityController.preferenceKey: true,
        SecurityController.appClosePreferenceKey: false,
        SecurityController.timingPreferenceKey: LockTiming.never.name,
      });
      expect((await restart()).requiresUnlock, isTrue);
    });

    test('a clock that moved backwards is not trusted', () async {
      await leaveUnlocked(LockTiming.after5Minutes, onClose: false);
      clock = clock.subtract(const Duration(hours: 2));
      expect((await restart()).requiresUnlock, isTrue);
    });

    test('swiping away straight from the app keeps the session', () async {
      await security.initialize();
      await security.setEnabled(true);
      await security.setTiming(LockTiming.never);
      await security.setLockOnAppClose(false);
      // Recents opened from the foreground: only inactive, then the swipe.
      security.handleLifecycle(AppLifecycleState.inactive);
      await pumpEventQueue();
      clock = clock.add(const Duration(hours: 2));
      expect((await restart()).requiresUnlock, isFalse);
    });

    test('a trip out and back does not erase the session record', () async {
      await security.initialize();
      await security.setEnabled(true);
      await security.setTiming(LockTiming.never);
      await security.setLockOnAppClose(false);
      security.handleLifecycle(AppLifecycleState.paused);
      security.handleLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(security.requiresUnlock, isFalse);
      security.handleLifecycle(AppLifecycleState.inactive);
      await pumpEventQueue();
      expect((await restart()).requiresUnlock, isFalse);
    });

    test('coming back after the grace ran out cannot refresh it', () async {
      await leaveUnlocked(LockTiming.after5Minutes, onClose: false);
      clock = clock.add(const Duration(minutes: 6));
      // The inactive that precedes resumed on the way back in.
      security.handleLifecycle(AppLifecycleState.inactive);
      await pumpEventQueue();
      expect((await restart()).requiresUnlock, isTrue);
    });

    test('a locked app never hands its session to the next start', () async {
      await leaveUnlocked(LockTiming.immediately, onClose: false);
      expect(security.requiresUnlock, isTrue);
      expect((await restart()).requiresUnlock, isTrue);
    });
  });

  test('a screen lock ends a session that time alone would not', () async {
    await security.initialize();
    await security.setEnabled(true);
    await security.setTiming(LockTiming.never);
    security.handleLifecycle(AppLifecycleState.paused);
    clock = clock.add(const Duration(hours: 3));
    security.handleLifecycle(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(security.covered, isFalse);
    expect(auth.calls, 1);

    screenLock.screenOff = true;
    security.handleLifecycle(AppLifecycleState.paused);
    security.handleLifecycle(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(auth.calls, 2);
    expect(
      screenLock.screenOff,
      isFalse,
      reason: 'one screen lock must relock exactly once',
    );
  });

  test('turning off screen-lock relocking leaves only the time away', () async {
    await security.initialize();
    await security.setEnabled(true);
    await security.setTiming(LockTiming.never);
    await security.setLockOnScreenOff(false);
    screenLock.screenOff = true;
    security.handleLifecycle(AppLifecycleState.paused);
    security.handleLifecycle(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(security.covered, isFalse, reason: 'the screen lock was ignored');
    expect(auth.calls, 1);
    expect(security.relocksOnlyOnRestart, isTrue);
  });

  test('a device that cannot report screen-off relies on time away', () async {
    screenLock.available = false;
    await security.initialize();
    await pumpEventQueue();
    expect(security.screenLockSupported, isFalse);
    await security.setEnabled(true);
    await security.setTiming(LockTiming.afterMinute);
    screenLock.screenOff = true;
    security.handleLifecycle(AppLifecycleState.paused);
    security.handleLifecycle(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(security.covered, isFalse);
    security.handleLifecycle(AppLifecycleState.paused);
    clock = clock.add(const Duration(minutes: 2));
    security.handleLifecycle(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(auth.calls, 2, reason: 'the time away still relocks');
  });

  test(
    'successful unlock clears screen-off events from the old session',
    () async {
      SharedPreferences.setMockInitialValues({
        SecurityController.preferenceKey: true,
        SecurityController.timingPreferenceKey: LockTiming.after5Minutes.name,
      });
      await security.initialize();
      screenLock.screenOff = true;
      await security.unlock();
      expect(screenLock.screenOff, isFalse);
      security.handleLifecycle(AppLifecycleState.paused);
      clock = clock.add(const Duration(seconds: 10));
      security.handleLifecycle(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(auth.calls, 1);
      expect(security.requiresUnlock, isFalse);
    },
  );

  /// Whether the app is drawn through the Recents blur.
  bool blurredPreview(WidgetTester tester) =>
      tester.widget<ImageFiltered>(find.byType(ImageFiltered).first).enabled;

  testWidgets(
    'five-minute grace never shows Unlock during a short app switch',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        SecurityController.preferenceKey: true,
        SecurityController.timingPreferenceKey: LockTiming.after5Minutes.name,
        SecurityController.screenOffPreferenceKey: true,
        SecurityController.hidePreviewPreferenceKey: true,
      });
      await tester.pumpWidget(
        MaterialApp(
          builder: (_, child) =>
              AppLockGate(controller: security, child: child!),
          home: const Scaffold(body: Text('Private ledger')),
        ),
      );
      await tester.pumpAndSettle();
      expect(auth.calls, 1);
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
      ]) {
        security.handleLifecycle(state);
        await tester.pump();
        expect(find.text('Unlock'), findsNothing);
        expect(find.text('Unlock to continue'), findsNothing);
        // Still drawn, but blurred with the icon over it.
        expect(blurredPreview(tester), isTrue);
        expect(find.byKey(const Key('app-privacy-cover')), findsOneWidget);
      }
      clock = clock.add(const Duration(minutes: 1));
      security.handleLifecycle(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.text('Private ledger'), findsOneWidget);
      expect(auth.calls, 1);

      // At the exact configured boundary, authentication is required.
      auth.result = false;
      security.handleLifecycle(AppLifecycleState.paused);
      clock = clock.add(const Duration(minutes: 5));
      security.handleLifecycle(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(auth.calls, 2);
      expect(find.text('Unlock'), findsOneWidget);
      expect(find.text('Private ledger'), findsNothing);
    },
  );

  testWidgets('preview is optional and does not bypass the app lock', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      SecurityController.preferenceKey: true,
      SecurityController.timingPreferenceKey: LockTiming.after5Minutes.name,
    });
    await tester.pumpWidget(
      MaterialApp(
        builder: (_, child) => AppLockGate(controller: security, child: child!),
        home: const Scaffold(body: Text('Private ledger')),
      ),
    );
    await tester.pumpAndSettle();
    expect(security.hideAppPreview, isFalse);
    security.handleLifecycle(AppLifecycleState.paused);
    await tester.pump();
    expect(find.text('Private ledger'), findsOneWidget);
    expect(find.byKey(const Key('app-privacy-cover')), findsNothing);
    security.handleLifecycle(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    await security.setHideAppPreview(true);
    security.handleLifecycle(AppLifecycleState.paused);
    await tester.pump();
    expect(blurredPreview(tester), isTrue);
    expect(find.byKey(const Key('app-privacy-cover')), findsOneWidget);
    security.handleLifecycle(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(blurredPreview(tester), isFalse);
    await security.setHideAppPreview(false);
    auth.result = false;
    security.handleLifecycle(AppLifecycleState.paused);
    clock = clock.add(const Duration(minutes: 5));
    security.handleLifecycle(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.text('Unlock'), findsOneWidget);
    expect(find.text('Private ledger'), findsNothing);
  });

  testWidgets('preview setting works and persists without app lock', (
    tester,
  ) async {
    await security.initialize();
    await tester.pumpWidget(
      MaterialApp(
        home: SecurityScope(
          controller: security,
          child: const SecurityScreen(),
        ),
      ),
    );
    final toggle = find.widgetWithText(SwitchListTile, 'Hide app preview');
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    final restored = SecurityController(
      authentication: auth,
      screenLock: screenLock,
    );
    addTearDown(restored.dispose);
    await restored.initialize();
    expect(restored.hideAppPreview, isTrue);
    expect(restored.enabled, isFalse);
    restored.handleLifecycle(AppLifecycleState.paused);
    expect(restored.covered, isTrue);
    expect(restored.requiresUnlock, isFalse);
  });

  test('both choices are remembered', () async {
    await security.initialize();
    await security.setTiming(LockTiming.after15Minutes);
    await security.setLockOnScreenOff(false);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString(SecurityController.timingPreferenceKey),
      LockTiming.after15Minutes.name,
    );
    expect(prefs.getBool(SecurityController.screenOffPreferenceKey), isFalse);
  });

  testWidgets('Security offers both triggers, separately, once lock is on', (
    tester,
  ) async {
    await security.initialize();
    // No pumpEventQueue here: it waits on a real timer the widget binding's
    // fake clock never advances. The screen-lock probe resolves on a
    // microtask, so it has landed by the first build.
    await tester.pumpWidget(
      MaterialApp(
        home: SecurityScope(
          controller: security,
          child: const SecurityScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Lock after time away'), findsNothing);
    await tester.tap(find.widgetWithText(SwitchListTile, 'App lock'));
    await tester.pumpAndSettle();
    final screenOff = find.widgetWithText(
      SwitchListTile,
      'Lock when the screen turns off',
    );
    expect(screenOff, findsOneWidget);
    expect(find.text('Lock after time away'), findsOneWidget);
    expect(find.text('Immediately'), findsOneWidget);

    // Each is set on its own and leaves the other alone.
    await tester.tap(screenOff);
    await tester.pumpAndSettle();
    expect(security.lockOnScreenOff, isFalse);
    expect(security.enabled, isTrue);
    expect(security.timing, LockTiming.immediately);

    await tester.ensureVisible(find.text('Lock after time away'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Lock after time away'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('After 5 minutes'));
    await tester.pumpAndSettle();
    expect(security.timing, LockTiming.after5Minutes);
    expect(security.lockOnScreenOff, isFalse);
    expect(find.text('After 5 minutes'), findsOneWidget);
  });
}
