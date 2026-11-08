import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/device_screen_lock.dart';

/// How long the app may be left before it asks to unlock again. Works
/// alongside [SecurityController.lockOnScreenOff], which is a separate
/// trigger rather than a timing.
enum LockTiming {
  immediately('Immediately', Duration.zero),
  afterMinute('After 1 minute', Duration(minutes: 1)),
  after5Minutes('After 5 minutes', Duration(minutes: 5)),
  after15Minutes('After 15 minutes', Duration(minutes: 15)),

  /// Time away alone never relocks: only a screen lock (when that is on)
  /// or a fresh start does.
  never('Never', null);

  const LockTiming(this.label, this.grace);

  final String label;

  /// How long the app may sit in the background before it relocks. Null
  /// means time away never relocks it on its own.
  final Duration? grace;
}

/// Device-local preference; never included in ledger exports or Drive backups.
class SecurityController extends ChangeNotifier {
  SecurityController({
    LocalAuthentication? authentication,
    ScreenLockWatcher? screenLock,
    DateTime Function()? now,
  }) : _authentication = authentication ?? LocalAuthentication(),
       _screenLock = screenLock ?? const PlatformScreenLockWatcher(),
       _now = now ?? DateTime.now;

  static const preferenceKey = 'app_lock_enabled';
  static const timingPreferenceKey = 'app_lock_timing';
  static const screenOffPreferenceKey = 'app_lock_on_screen_off';
  static const appClosePreferenceKey = 'app_lock_on_app_close';
  static const hidePreviewPreferenceKey = 'hide_app_preview';
  static const revealAmountsPreferenceKey = 'authenticate_to_reveal_amounts';
  bool authenticateToRevealAmounts = false;
  int amountPrivacyRevision = 0;

  /// When the app was last left unlocked, written down so a cold start can
  /// tell a quick swipe out of recents from a return hours later.
  static const leftAtPreferenceKey = 'app_lock_left_at';
  final LocalAuthentication _authentication;
  final ScreenLockWatcher _screenLock;
  final DateTime Function() _now;
  bool ready = false;
  bool enabled = false;
  bool locked = true;
  bool busy = false;
  bool hideAppPreview = false;
  LockTiming timing = LockTiming.immediately;

  /// Whether locking the phone also relocks the app, independently of how
  /// long it was left. Only meaningful where [screenLockSupported].
  bool lockOnScreenOff = true;

  /// Whether closing the app — swiping it out of recent apps, or the system
  /// reclaiming it — ends the session. With this off, a fresh start is
  /// judged by [timing] like any other trip away.
  bool lockOnAppClose = true;

  /// Whether this device can report that its screen turned off.
  bool screenLockSupported = false;
  bool _foreground = true;
  Completer<void>? _amountRevealResume;
  bool _disposed = false;

  /// True while we work out whether the time away ended the session. The
  /// ledger stays covered meanwhile, so it cannot flash into view first.
  bool _checking = false;

  /// Set when a prompt closed without unlocking — usually the user swiping
  /// it away. The app then stops asking on its own and waits to be told,
  /// rather than throwing the prompt straight back up.
  bool needsUserAction = false;

  /// When the app was last backgrounded, for the elapsed-time rules.
  DateTime? _leftAt;

  /// The in-flight "can this device report screen-off?" question. Anything
  /// that depends on the answer waits for it; nothing else does.
  Future<void>? _screenLockProbe;
  String? error;

  /// Authentication UI is only relevant once a lock rule has fired.
  bool get requiresUnlock => ready && enabled && locked;

  bool get covered =>
      !ready ||
      (enabled && (locked || _checking)) ||
      (hideAppPreview && !_foreground);

  /// Covered only to keep Recents private: the app can show blurred rather
  /// than gone. Never while a lock rule or startup has the ledger hidden.
  bool get blursPreview =>
      ready && hideAppPreview && !_foreground && !(enabled && (locked || _checking));

  /// True when nothing short of a restart will ask again — worth saying out
  /// loud in the UI.
  bool get relocksOnlyOnRestart =>
      lockOnAppClose &&
      timing.grace == null &&
      !(lockOnScreenOff && screenLockSupported);

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> initialize() async {
    if (ready || _disposed) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      enabled = prefs.getBool(preferenceKey) ?? false;
      timing = LockTiming.values.firstWhere(
        (option) => option.name == prefs.getString(timingPreferenceKey),
        orElse: () => LockTiming.immediately,
      );
      lockOnScreenOff = prefs.getBool(screenOffPreferenceKey) ?? true;
      lockOnAppClose = prefs.getBool(appClosePreferenceKey) ?? true;
      hideAppPreview = prefs.getBool(hidePreviewPreferenceKey) ?? false;
      authenticateToRevealAmounts =
          prefs.getBool(revealAmountsPreferenceKey) ?? false;
      locked = enabled && _startsLocked(prefs.getInt(leftAtPreferenceKey));
      // A saved grace period only satisfies the timing rule. Check the
      // independent screen-off rule before exposing a restored session.
      if (enabled && !locked && lockOnScreenOff) {
        await (_screenLockProbe ??= _probeScreenLock());
        if (screenLockSupported) {
          locked = await _screenLock.consumeScreenOff();
        }
      }
      // One start, one answer: a stale timestamp must not unlock a later one.
      await _rememberLeftAt(null);
      ready = true;
      error = null;
    } catch (_) {
      // Never reveal the ledger if we cannot read its lock preference.
      error = 'Could not load security settings. Please try again.';
    }
    _changed();
    // An already locked or unprotected start does not need to wait for the
    // platform. Restoring an unlocked session checks the trigger above.
    _screenLockProbe ??= _probeScreenLock();
  }

  /// Whether a fresh start of the app asks to unlock. Anything unknown —
  /// no recorded session, a clock that moved backwards — counts as locked,
  /// so silence never opens the ledger.
  bool _startsLocked(int? leftAtMillis) {
    if (lockOnAppClose || leftAtMillis == null) return true;
    final grace = timing.grace;
    if (grace == null) return false;
    final away = _now().difference(
      DateTime.fromMillisecondsSinceEpoch(leftAtMillis),
    );
    return away.isNegative || away >= grace;
  }

  /// Records when the unlocked session was last left, or clears it. The
  /// write is best-effort: a start that cannot read one simply locks.
  Future<void> _rememberLeftAt(DateTime? at) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (at == null) {
        await prefs.remove(leftAtPreferenceKey);
      } else {
        await prefs.setInt(leftAtPreferenceKey, at.millisecondsSinceEpoch);
      }
    } catch (_) {
      // Losing the timestamp only costs an extra unlock, never a session.
    }
  }

  Future<void> _probeScreenLock() async {
    final supported = await _screenLock.supported;
    if (_disposed || supported == screenLockSupported) return;
    screenLockSupported = supported;
    _changed();
  }

  void handleLifecycle(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) amountPrivacyRevision++;
    final wasForeground = _foreground;
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground) {
      _amountRevealResume?.complete();
      _amountRevealResume = null;
    }
    final left =
        state == AppLifecycleState.paused || state == AppLifecycleState.hidden;
    if (left && enabled && !locked) {
      if (timing == LockTiming.immediately) {
        locked = true;
        unawaited(_rememberLeftAt(null));
      } else if (_leftAt == null) {
        _leftAt = _now();
        unawaited(_rememberLeftAt(_leftAt));
      }
    } else if (state == AppLifecycleState.inactive &&
        wasForeground &&
        enabled &&
        !locked &&
        timing != LockTiming.immediately) {
      // Opening recents straight from the app is often only "inactive", and
      // a swipe then kills the process before paused ever arrives. Only a
      // step out of the foreground counts: the inactive on the way back in
      // must not refresh a trip that may already have run out.
      unawaited(_rememberLeftAt(_now()));
    }
    _changed();
    if (!_foreground || !ready || !enabled) return;
    if (locked) {
      if (!busy) unlock(byUser: false);
    } else if (_leftAt != null) {
      unawaited(_endTripOut());
    }
  }

  /// Decides, on return to the foreground, whether this trip out of the app
  /// went on long enough — or crossed a screen lock — to ask again.
  Future<void> _endTripOut() async {
    final leftAt = _leftAt;
    if (_checking || leftAt == null) return;
    _checking = true;
    _changed();
    await _screenLockProbe;
    // Consumed on every return, so a stale flag cannot relock a later trip.
    final screenOff =
        screenLockSupported && await _screenLock.consumeScreenOff();
    final grace = timing.grace;
    final expired = grace != null && _now().difference(leftAt) >= grace;
    _checking = false;
    _leftAt = null;
    if (_disposed) return;
    // The two triggers are independent: either one ends the session.
    if ((lockOnScreenOff && screenOff) || expired) {
      locked = true;
      unawaited(_rememberLeftAt(null));
    }
    // A session that survived keeps its record. Clearing it here raced the
    // next trip to recents, leaving a later swipe-away with nothing to go on.
    _changed();
    if (locked && _foreground && !busy) await unlock(byUser: false);
  }

  Future<bool> _authenticate(String reason) async {
    try {
      final success = await _authentication.authenticate(
        localizedReason: reason,
        biometricOnly: false,
        persistAcrossBackgrounding: true,
      );
      // Backing out of the prompt is a choice, not a failure: say nothing
      // and let the Unlock button stand there waiting.
      return success;
    } on LocalAuthException catch (exception) {
      error = switch (exception.code) {
        LocalAuthExceptionCode.noCredentialsSet ||
        LocalAuthExceptionCode.noBiometricsEnrolled =>
          'Set up a screen lock in your device settings, then try again.',
        LocalAuthExceptionCode.temporaryLockout ||
        LocalAuthExceptionCode.biometricLockout =>
          'Authentication is locked. Use your device PIN or try again later.',
        LocalAuthExceptionCode.userCanceled ||
        LocalAuthExceptionCode.systemCanceled => null,
        _ => 'Device authentication is unavailable. Please try again.',
      };
    } catch (_) {
      error = 'Device authentication is unavailable. Please try again.';
    }
    return false;
  }

  /// [byUser] is the Unlock button; everything else (opening the app,
  /// returning to it) asks on its own only while the user has not already
  /// dismissed a prompt.
  Future<void> unlock({bool byUser = true}) async {
    if (_disposed || busy || !ready || !enabled || !locked || !_foreground) {
      return;
    }
    if (!byUser && needsUserAction) return;
    busy = true;
    error = null;
    _changed();
    final success = await _authenticate('Unlock SimpleMoney');
    if (success) {
      await _clearScreenOff();
      if (_disposed) return;
      locked = false;
      _leftAt = null;
      await _rememberLeftAt(null);
    }
    // One dismissal is enough to stop asking until the user comes back to it.
    needsUserAction = !success;
    busy = false;
    _changed();
  }

  /// A successful authentication starts a new session. Screen-off events
  /// from before it have already been satisfied by that authentication.
  Future<void> _clearScreenOff() async {
    await _screenLockProbe;
    if (!_disposed && screenLockSupported) {
      await _screenLock.consumeScreenOff();
    }
  }

  Future<void> setEnabled(bool value) async {
    if (_disposed || busy || !ready || value == enabled || covered) return;
    busy = true;
    error = null;
    _changed();
    try {
      if (await _authenticate(
        value ? 'Enable SimpleMoney app lock' : 'Turn off SimpleMoney app lock',
      )) {
        final prefs = await SharedPreferences.getInstance();
        if (!await prefs.setBool(preferenceKey, value)) {
          throw StateError('Could not save app lock');
        }
        await _clearScreenOff();
        if (_disposed) return;
        enabled = value;
        locked = false;
        _leftAt = null;
        await _rememberLeftAt(null);
      }
    } catch (_) {
      error = 'Could not save security settings. Please try again.';
    }
    busy = false;
    _changed();
  }

  /// Only reachable from inside the unlocked app, so this needs no prompt
  /// of its own.
  Future<void> setTiming(LockTiming value) async {
    if (_disposed || !ready || value == timing) return;
    timing = value;
    // The trip that is under way was measured against the old rule.
    _leftAt = null;
    await _rememberLeftAt(null);
    await _save(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(timingPreferenceKey, value.name);
    });
  }

  Future<void> setHideAppPreview(bool value) async {
    if (_disposed || !ready || value == hideAppPreview) return;
    error = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(hidePreviewPreferenceKey, value)) {
        throw StateError('Could not save app preview preference');
      }
      hideAppPreview = value;
    } catch (_) {
      error = 'Could not save security settings. Please try again.';
    }
    _changed();
  }

  Future<bool> authorizeAmountReveal() async {
    if (_disposed || !ready || busy || covered) return false;
    if (!authenticateToRevealAmounts) return true;
    busy = true;
    error = null;
    _changed();
    final success = await _authenticate('Show hidden amounts in SimpleMoney');
    // Native authentication may resolve before its window returns focus to us.
    // Keep this request pending until resumed instead of rejecting a valid scan.
    if (success && !_disposed && !_foreground) {
      final resumed = _amountRevealResume = Completer<void>();
      await resumed.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () {},
      );
      if (identical(_amountRevealResume, resumed)) _amountRevealResume = null;
    }
    busy = false;
    _changed();
    return success && !_disposed && !covered && _foreground;
  }

  Future<void> setAuthenticateToRevealAmounts(bool value) async {
    if (_disposed ||
        !ready ||
        busy ||
        covered ||
        value == authenticateToRevealAmounts) {
      return;
    }
    busy = true;
    error = null;
    _changed();
    try {
      if (await _authenticate(
        value
            ? 'Protect hidden amounts'
            : 'Remove authentication for hidden amounts',
      )) {
        final prefs = await SharedPreferences.getInstance();
        if (!await prefs.setBool(revealAmountsPreferenceKey, value)) {
          throw StateError('Could not save');
        }
        authenticateToRevealAmounts = value;
        amountPrivacyRevision++;
      }
    } catch (_) {
      error = 'Could not save security settings. Please try again.';
    }
    busy = false;
    _changed();
  }

  Future<void> setLockOnScreenOff(bool value) async {
    if (_disposed || !ready || value == lockOnScreenOff) return;
    lockOnScreenOff = value;
    await _save(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(screenOffPreferenceKey, value);
    });
  }

  Future<void> setLockOnAppClose(bool value) async {
    if (_disposed || !ready || value == lockOnAppClose) return;
    lockOnAppClose = value;
    await _save(() async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(appClosePreferenceKey, value);
    });
  }

  Future<void> _save(Future<void> Function() write) async {
    error = null;
    _changed();
    try {
      await write();
    } catch (_) {
      error = 'Could not save security settings. Please try again.';
      _changed();
    }
  }

  @override
  void dispose() {
    _amountRevealResume?.complete();
    _amountRevealResume = null;
    _disposed = true;
    super.dispose();
  }
}

class SecurityScope extends InheritedNotifier<SecurityController> {
  const SecurityScope({
    super.key,
    required SecurityController controller,
    required super.child,
  }) : super(notifier: controller);

  static SecurityController of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SecurityScope>()!.notifier!;

  static SecurityController? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SecurityScope>()?.notifier;
}
