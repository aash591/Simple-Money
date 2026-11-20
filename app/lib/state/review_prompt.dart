import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// What someone chose when asked to rate the app.
enum ReviewAnswer { rate, feedback, later }

/// Decides when to ask for a rating on Google Play, so the ask comes rarely
/// and only from someone who really uses the app:
///
/// * at least [minDaysInstalled] days after it was first opened,
/// * on at least [minActiveDays] different days,
/// * after at least [minSaves] transactions were added,
/// * and only straight after adding one, never on launch or mid-task.
///
/// "Not now" puts it off by [laterGaps] in turn, and after the last of
/// those it never asks again. Rating or sending feedback ends it for good.
class ReviewPrompt {
  ReviewPrompt._();
  static final instance = ReviewPrompt._();

  static const minDaysInstalled = 7;
  static const minActiveDays = 4;
  static const minSaves = 10;
  static const laterGaps = [Duration(days: 45), Duration(days: 120)];

  /// `--dart-define=REVIEW_PROMPT_NOW=true` asks after the next save in a
  /// debug build, to see the prompt without waiting a week.
  static const _forced =
      kDebugMode && bool.fromEnvironment('REVIEW_PROMPT_NOW');

  static const _firstSeenKey = 'review_first_seen';
  static const _lastDayKey = 'review_last_day';
  static const _activeDaysKey = 'review_active_days';
  static const _savesKey = 'review_saves';
  static const _declinesKey = 'review_declines';
  static const _nextKey = 'review_next';
  static const _doneKey = 'review_done';

  /// Stands in for the clock in tests.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  DateTime? _firstSeen, _next;
  int _activeDays = 0, saves = 0, _declines = 0;
  String? _lastDay;
  bool _done = false;

  static String _day(DateTime t) => '${t.year}-${t.month}-${t.day}';

  /// Loads what has been counted so far and counts today as a day used.
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final today = now();
    final first = prefs.getInt(_firstSeenKey);
    _firstSeen = first == null
        ? today
        : DateTime.fromMillisecondsSinceEpoch(first);
    if (first == null) {
      await prefs.setInt(_firstSeenKey, today.millisecondsSinceEpoch);
    }
    _activeDays = prefs.getInt(_activeDaysKey) ?? 0;
    _lastDay = prefs.getString(_lastDayKey);
    saves = prefs.getInt(_savesKey) ?? 0;
    _declines = prefs.getInt(_declinesKey) ?? 0;
    final next = prefs.getInt(_nextKey);
    _next = next == null ? null : DateTime.fromMillisecondsSinceEpoch(next);
    _done = prefs.getBool(_doneKey) ?? false;
    await _countDay(prefs);
  }

  Future<void> _countDay(SharedPreferences prefs) async {
    final today = _day(now());
    if (_lastDay == today) return;
    _lastDay = today;
    _activeDays++;
    await prefs.setString(_lastDayKey, today);
    await prefs.setInt(_activeDaysKey, _activeDays);
  }

  /// A transaction was added (not edited).
  Future<void> noteSave() async {
    saves++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_savesKey, saves);
    // The app may have stayed open past midnight.
    await _countDay(prefs);
  }

  /// Whether to ask now, having just added a transaction.
  bool get due {
    if (_forced) return true;
    if (_done) return false;
    final first = _firstSeen;
    if (first == null) return false;
    final today = now();
    if (today.difference(first).inDays < minDaysInstalled) return false;
    if (_activeDays < minActiveDays || saves < minSaves) return false;
    final next = _next;
    return next == null || !today.isBefore(next);
  }

  /// Remembers [answer]: rating or feedback ends the asking, "Not now"
  /// puts it off, for good after the last of [laterGaps].
  Future<void> answer(ReviewAnswer answer) async {
    final prefs = await SharedPreferences.getInstance();
    if (answer != ReviewAnswer.later || _declines >= laterGaps.length) {
      _done = true;
      await prefs.setBool(_doneKey, true);
      return;
    }
    _next = now().add(laterGaps[_declines]);
    _declines++;
    await prefs.setInt(_declinesKey, _declines);
    await prefs.setInt(_nextKey, _next!.millisecondsSinceEpoch);
  }
}
