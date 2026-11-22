// Frame timings for scrolling Home on a real phone. Run in profile mode,
// which installs a separate app with its own sample ledger:
//
//   flutter drive --profile --driver=test/test_driver/integration_driver.dart \
//     --target=test/integration/home_scroll_perf.dart
// Add --dart-define=BIG_LEDGER=true for about 20,000 transactions.
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:simple_money/app.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/device_performance.dart';
import 'package:simple_money/data/repositories/home_repository.dart';
import 'package:simple_money/domain/currency_scope.dart';
import 'package:simple_money/state/onboarding.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('scroll Home', (tester) async {
    if (!kProfileMode) {
      throw StateError(
        'Run with --profile: this test modifies its sample ledger.',
      );
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(Onboarding.doneKey, true);
    // The look to measure: --dart-define=STYLE=aurora, THEME=dark, and
    // WALLPAPER=<path to a picture on the phone> with WALLPAPER_DIM.
    const style = String.fromEnvironment('STYLE');
    const theme = String.fromEnvironment('THEME');
    const wallpaper = String.fromEnvironment('WALLPAPER');
    if (style.isNotEmpty) await prefs.setString('ui_style', style);
    if (theme.isNotEmpty) await prefs.setString('theme_mode', theme);
    if (wallpaper.isEmpty) {
      await prefs.remove('aurora_wallpaper');
    } else {
      await prefs.setString('aurora_wallpaper', wallpaper);
      await prefs.setDouble(
        'aurora_wallpaper_dim',
        double.parse(
          const String.fromEnvironment('WALLPAPER_DIM', defaultValue: '.45'),
        ),
      );
    }
    await DevicePerformance.restore();
    if (const bool.fromEnvironment('BIG_LEDGER')) await _growLedger();
    final rows = await _prepareCurrentMonth();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    await tester.pumpWidget(const SimpleMoneyApp());
    // The first launch seeds the sample ledger.
    await Future<void>.delayed(const Duration(seconds: 6));

    final list = find.byType(ListView).first;
    expect(list, findsOneWidget);

    // First-use image decodes, chart layout and entrance animations matter
    // too. Report them separately instead of discarding the first traversal.
    final cold = await _measureScroll(tester, list, passes: 1);
    final warm = await _measureScroll(tester, list, passes: 3);
    binding.reportData = {
      'big_ledger': const bool.fromEnvironment('BIG_LEDGER'),
      'ledger_rows': rows,
      'first_scroll': _report('first scroll', cold),
      'warm_scroll': _report('warm scroll', warm),
    };
  });
}

// The bundled seed uses fixed dates. Keep its populated month on Home even
// when the benchmark is run later, so the spending chart is actually tested.
Future<int> _prepareCurrentMonth() async {
  final db = AppDatabase();
  try {
    final latest =
        (await db
                .customSelect(
                  "SELECT MAX(date) AS latest FROM transactions WHERE type = 'expense'",
                )
                .getSingle())
            .read<int>('latest');
    final seeded = DateTime.fromMillisecondsSinceEpoch(latest);
    final now = DateTime.now();
    final month = DateTime(now.year, now.month);
    final shift =
        month.millisecondsSinceEpoch -
        DateTime(seeded.year, seeded.month).millisecondsSinceEpoch;
    if (shift != 0) {
      await db.customStatement('UPDATE transactions SET date = date + ?', [
        shift,
      ]);
    }
    final summary = await HomeRepository(db)
        .loadScope(month, const SingleCurrency('INR', 2));
    expect(
      summary.spent,
      greaterThan(0),
      reason: 'Benchmark a populated spending chart',
    );
    return (await db
            .customSelect('SELECT COUNT(*) AS n FROM transactions')
            .getSingle())
        .read<int>('n');
  } finally {
    await db.close();
  }
}

Future<List<FrameTiming>> _measureScroll(
  WidgetTester tester,
  Finder list, {
  required int passes,
}) async {
  final timings = <FrameTiming>[];
  // Flush the preceding phase's batched frame timings before subscribing.
  await Future<void>.delayed(const Duration(seconds: 2));
  void collect(List<FrameTiming> frames) => timings.addAll(frames);
  SchedulerBinding.instance.addTimingsCallback(collect);
  try {
    for (var i = 0; i < passes; i++) {
      await _scrollThrough(tester, list);
    }
    await Future<void>.delayed(const Duration(seconds: 2));
  } finally {
    SchedulerBinding.instance.removeTimingsCallback(collect);
  }
  expect(timings, isNotEmpty, reason: 'The phone must supply frame timings');
  return timings;
}

Map<String, Object> _report(String phase, List<FrameTiming> timings) {
  final hz = PlatformDispatcher.instance.views.first.display.refreshRate;
  final budget = 1000 / hz;
  List<double> ms(Duration Function(FrameTiming) f) =>
      timings.map((t) => f(t).inMicroseconds / 1000).toList()..sort();
  double pct(List<double> v, double p) =>
      v.isEmpty ? 0 : v[((v.length - 1) * p).round()];
  final build = ms((t) => t.buildDuration);
  final raster = ms((t) => t.rasterDuration);
  final jank = timings
      .where(
        (t) =>
            t.buildDuration.inMicroseconds / 1000 > budget ||
            t.rasterDuration.inMicroseconds / 1000 > budget,
      )
      .length;
  String row(String name, List<double> v) =>
      '$name p50 ${pct(v, .5).toStringAsFixed(2)}  '
      'p90 ${pct(v, .9).toStringAsFixed(2)}  '
      'p99 ${pct(v, .99).toStringAsFixed(2)}  '
      'max ${v.isEmpty ? 0 : v.last.toStringAsFixed(2)} ms';
  debugPrint(
    'PERF $phase: ${hz.round()}Hz, ${timings.length} frames, '
    '$jank over the ${budget.toStringAsFixed(1)} ms budget',
  );
  debugPrint('PERF ${row('build ', build)}');
  debugPrint('PERF ${row('raster', raster)}');
  Map<String, double> stats(List<double> values) => {
    'p50_ms': pct(values, .5),
    'p90_ms': pct(values, .9),
    'p99_ms': pct(values, .99),
    'max_ms': values.isEmpty ? 0 : values.last,
  };
  return {
    'refresh_rate_hz': hz,
    'frames': timings.length,
    'over_budget': jank,
    'build': stats(build),
    'raster': stats(raster),
  };
}

/// Copies the sample ledger back month by month until it holds years of
/// history, about the size of a ledger built from SMS imports.
Future<void> _growLedger() async {
  final db = AppDatabase();
  try {
    final count =
        (await db
                .customSelect('SELECT COUNT(*) AS n FROM transactions')
                .getSingle())
            .read<int>('n');
    if (count > 5000) return;
    const month = 30 * 24 * 60 * 60 * 1000;
    await db.transaction(() async {
      for (var k = 1; k <= 110; k++) {
        await db.customStatement('''
          INSERT INTO transactions (type, amount_minor, account_id,
            to_account_id, to_amount_minor, category_id, title, note, date,
            created_at)
          SELECT type, amount_minor, account_id, to_account_id,
            to_amount_minor, category_id, title, note, date - ${k * month},
            created_at
          FROM transactions WHERE id <= $count''');
      }
    });
  } finally {
    await db.close();
  }
}

Future<void> _scrollThrough(WidgetTester tester, Finder list) async {
  for (var i = 0; i < 3; i++) {
    await tester.fling(list, const Offset(0, -600), 2500);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
  }
  for (var i = 0; i < 3; i++) {
    await tester.fling(list, const Offset(0, 600), 2500);
    await Future<void>.delayed(const Duration(milliseconds: 1200));
  }
}
