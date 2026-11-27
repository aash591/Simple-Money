import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/theme/app_motion.dart';

/// However hard a list is flicked, it moves no faster than the app's limit.
void main() {
  Future<double> flingAt(WidgetTester tester, double speed) async {
    final controller = ScrollController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ListView.builder(
          controller: controller,
          physics: const ElasticScrollPhysics(),
          itemCount: 2000,
          itemExtent: 60,
          itemBuilder: (_, i) => Text('Row $i'),
        ),
      ),
    );
    final start = controller.offset;
    await tester.fling(find.byType(ListView), const Offset(0, -300), speed);
    await tester.pumpAndSettle();
    return controller.offset - start;
  }

  testWidgets('a harder fling goes no faster than the limit', (tester) async {
    final hard = await flingAt(tester, 9000);
    final harder = await flingAt(tester, 20000);
    expect(harder, moreOrLessEquals(hard, epsilon: 1));
    expect(
      const ElasticScrollPhysics().maxFlingVelocity,
      ElasticScrollPhysics.maxFling,
    );
  });
}
