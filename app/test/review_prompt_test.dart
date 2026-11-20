import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/state/review_prompt.dart';

/// The rating prompt asks rarely, and only someone who really uses the app.
void main() {
  final review = ReviewPrompt.instance;
  var today = DateTime(2026, 1, 1, 10);

  /// Opens the app on [day] (counted from the first) and adds [saves].
  Future<void> use(int day, {int saves = 0}) async {
    today = DateTime(2026, 1, 1 + day, 10);
    await review.restore();
    for (var i = 0; i < saves; i++) {
      await review.noteSave();
    }
  }

  /// Someone a week in, on their fourth day, with ten transactions added.
  Future<void> regular() async {
    await use(0, saves: 3);
    await use(2, saves: 3);
    await use(5, saves: 3);
    await use(8, saves: 1);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    today = DateTime(2026, 1, 1, 10);
    review.now = () => today;
  });

  tearDown(() => review.now = DateTime.now);

  test('waits for a week, four days of use and ten transactions', () async {
    await use(0, saves: 30);
    expect(review.due, isFalse, reason: 'first day');
    await use(8);
    expect(review.due, isFalse, reason: 'only two days used');
    await use(9);
    await use(10);
    expect(review.due, isTrue);
  });

  test('a busy first week is not enough on its own', () async {
    for (var day = 0; day < 6; day++) {
      await use(day, saves: 5);
    }
    expect(review.due, isFalse);
  });

  test('few transactions never ask', () async {
    for (var day = 0; day < 30; day++) {
      await use(day);
    }
    await review.noteSave();
    expect(review.due, isFalse);
  });

  test('opening twice in a day counts it once', () async {
    await use(0, saves: 10);
    await use(8);
    await use(8);
    await use(8);
    expect(review.due, isFalse);
  });

  test('"Not now" waits longer each time, and the third ends it', () async {
    await regular();
    expect(review.due, isTrue);

    await review.answer(ReviewAnswer.later);
    await use(8 + 44);
    expect(review.due, isFalse);
    await use(8 + 45);
    expect(review.due, isTrue);

    await review.answer(ReviewAnswer.later);
    await use(53 + 119);
    expect(review.due, isFalse);
    await use(53 + 120);
    expect(review.due, isTrue);

    await review.answer(ReviewAnswer.later);
    await use(173 + 1000);
    expect(review.due, isFalse);
  });

  for (final answer in [ReviewAnswer.rate, ReviewAnswer.feedback]) {
    test('${answer.name} ends the asking for good', () async {
      await regular();
      await review.answer(answer);
      await use(400, saves: 50);
      expect(review.due, isFalse);
    });
  }

  test('what was counted survives a restart', () async {
    await regular();
    await review.answer(ReviewAnswer.later);
    // Same stored values, read fresh.
    await use(20);
    expect(review.due, isFalse);
    await use(60);
    expect(review.due, isTrue);
  });
}
