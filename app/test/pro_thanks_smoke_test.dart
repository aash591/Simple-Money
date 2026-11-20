import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/ui/more/pro/pro_thanks.dart';

void main() {
  testWidgets('thank-you view renders and animates cleanly', (tester) async {
    tester.view.physicalSize = const Size(1080, 2340);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    late AnimationController confetti;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, _) => _Host(onController: (c) => confetti = c),
          ),
        ),
      ),
    );
    confetti.forward(from: 0);
    for (var i = 0; i < 30; i++) {
      await tester.pump(const Duration(milliseconds: 150));
    }
    expect(tester.takeException(), isNull);
    expect(find.text('You’re a supporter'), findsOneWidget);
    expect(find.text('No ads'), findsOneWidget);
  });
}

class _Host extends StatefulWidget {
  const _Host({required this.onController});
  final ValueChanged<AnimationController> onController;
  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> with SingleTickerProviderStateMixin {
  late final c = AnimationController(
    vsync: this,
    duration: ConfettiBurst.burstDuration,
  );
  @override
  void initState() {
    super.initState();
    widget.onController(c);
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Column(
        children: [
          Container(
            height: 240,
            color: Colors.deepPurple,
            child: const Stack(
              alignment: Alignment.center,
              children: [
                Positioned.fill(child: SparkleField()),
                SupporterBadge(size: 64, lifetime: true),
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(22),
              children: [
                ProThanksBody(
                  lifetime: false,
                  onReview: () {},
                  perks: const [
                    ThanksPerk(
                      Icons.star,
                      Colors.purple,
                      'AI assistant',
                      'Ask about your money',
                    ),
                    ThanksPerk(
                      Icons.pie_chart,
                      Colors.teal,
                      'Unlimited budgets',
                      'Add as many as you like',
                    ),
                    ThanksPerk(
                      Icons.palette,
                      Colors.pink,
                      'Every look',
                      'All styles and colors, your own shade and picture',
                    ),
                    ThanksPerk(
                      Icons.block,
                      Colors.orange,
                      'No ads',
                      'Never see an ad, anywhere',
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      Positioned.fill(child: ConfettiBurst(controller: c, originY: 240)),
    ],
  );
}
