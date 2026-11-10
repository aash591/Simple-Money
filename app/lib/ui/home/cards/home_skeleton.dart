import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../components/common.dart';
import '../../components/skeleton.dart';

/// Home while its numbers load: the same cards, in the same order and at the
/// same sizes as the real ones (month overview, spending donut, money in vs
/// out, accounts, recent transactions), so nothing jumps when they land.
class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _OverviewBones(),
      SizedBox(height: homeCardGap),
      _DonutBones(),
      SizedBox(height: homeCardGap),
      _CashFlowBones(),
      SizedBox(height: homeCardGap),
      _AccountsBones(),
      SizedBox(height: homeCardGap),
      _RecentBones(),
    ],
  );
}

/// A card's title line, as [SectionTitle] sets it.
class _Title extends StatelessWidget {
  const _Title(this.width, {this.action = false});
  final double width;
  final bool action;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 24,
    child: Row(
      children: [
        Bone(width: width, height: 16),
        const Spacer(),
        if (action) const Bone(width: 44, height: 12),
      ],
    ),
  );
}

/// Net savings, the verdict chip, the in/out bar and its two totals, then
/// the budget row.
class _OverviewBones extends StatelessWidget {
  const _OverviewBones();

  @override
  Widget build(BuildContext context) {
    final divider = Theme.of(context).colorScheme.outlineVariant;
    return MoneyCard(
      featured: true,
      padding: EdgeInsets.zero,
      child: Shimmer(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(
                    height: 22,
                    child: Row(
                      children: [
                        Bone(width: 84, height: 14),
                        Spacer(),
                        Bone(width: 12, height: 14),
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  // The 48pt hero amount.
                  const SizedBox(
                    height: 52,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Bone(width: 190, height: 38, radius: 12),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Bone(width: 176, height: 22, radius: 11),
                  const SizedBox(height: 12),
                  const Bone(height: 6, radius: 3),
                  const SizedBox(height: 10),
                  const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: _Flow()),
                      SizedBox(width: 16),
                      Expanded(child: _Flow(end: true)),
                    ],
                  ),
                ],
              ),
            ),
            Divider(
              height: 1,
              indent: 20,
              endIndent: 20,
              color: divider.withValues(alpha: .35),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 20),
              child: Row(
                children: [
                  Bone.circle(44),
                  SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            Bone(width: 70, height: 12),
                            Spacer(),
                            Bone(width: 110, height: 14),
                          ],
                        ),
                        SizedBox(height: 10),
                        Bone(height: 6, radius: 3),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// "Money in" / "Money out": a small arrowed label over its total.
class _Flow extends StatelessWidget {
  const _Flow({this.end = false});
  final bool end;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: end ? CrossAxisAlignment.end : CrossAxisAlignment.start,
    children: const [
      Bone(width: 72, height: 12),
      SizedBox(height: 8),
      Bone(width: 92, height: 18),
    ],
  );
}

/// The spending donut: a ring with its total in the middle and a callout on
/// each side.
class _DonutBones extends StatelessWidget {
  const _DonutBones();

  @override
  Widget build(BuildContext context) => MoneyCard(
    child: Shimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Title(170, action: true),
          const SizedBox(height: 14),
          SizedBox(
            height: 250,
            child: Stack(
              alignment: Alignment.center,
              children: const [
                SizedBox.square(dimension: 170, child: _Ring()),
                Bone(width: 70, height: 18),
                Positioned(top: 18, left: 0, child: _Callout()),
                Positioned(top: 18, right: 0, child: _Callout(end: true)),
                Positioned(bottom: 18, left: 0, child: _Callout()),
                Positioned(bottom: 18, right: 0, child: _Callout(end: true)),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

/// A ring drawn as a stroke, so its hole stays empty under the shimmer.
class _Ring extends StatelessWidget {
  const _Ring();

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _RingPainter());
}

class _RingPainter extends CustomPainter {
  const _RingPainter();

  @override
  void paint(Canvas canvas, Size size) {
    const thickness = 26.0;
    final rect = Offset.zero & size;
    canvas.drawArc(
      rect.deflate(thickness / 2),
      -math.pi / 2,
      math.pi * 2,
      false,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = thickness,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) => false;
}

/// A category's round badge beside its name and share.
class _Callout extends StatelessWidget {
  const _Callout({this.end = false});
  final bool end;

  @override
  Widget build(BuildContext context) {
    final label = Column(
      crossAxisAlignment: end
          ? CrossAxisAlignment.end
          : CrossAxisAlignment.start,
      children: const [
        Bone(width: 54, height: 12),
        SizedBox(height: 6),
        Bone(width: 36, height: 10),
      ],
    );
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: end
          ? [label, const SizedBox(width: 8), const Bone.circle(32)]
          : [const Bone.circle(32), const SizedBox(width: 8), label],
    );
  }
}

/// Six months of paired bars, with a legend above.
class _CashFlowBones extends StatelessWidget {
  const _CashFlowBones();

  static const _in = [.55, .7, .5, .85, .62, .75];
  static const _out = [.42, .48, .6, .4, .52, .46];

  @override
  Widget build(BuildContext context) => MoneyCard(
    child: Shimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Title(190),
          const SizedBox(height: 14),
          const Row(
            children: [
              Bone.circle(10),
              SizedBox(width: 6),
              Bone(width: 56, height: 11),
              SizedBox(width: 16),
              Bone.circle(10),
              SizedBox(width: 6),
              Bone(width: 62, height: 11),
            ],
          ),
          const SizedBox(height: 14),
          SizedBox(
            height: 150,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                for (var i = 0; i < _in.length; i++)
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Bone(width: 12, height: 120 * _in[i], radius: 4),
                      const SizedBox(width: 3),
                      Bone(width: 12, height: 120 * _out[i], radius: 4),
                    ],
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              for (var i = 0; i < 6; i++) const Bone(width: 24, height: 10),
            ],
          ),
        ],
      ),
    ),
  );
}

/// The total, then a strip of account tiles that runs off the edge.
class _AccountsBones extends StatelessWidget {
  const _AccountsBones();

  @override
  Widget build(BuildContext context) => MoneyCard(
    padding: const EdgeInsets.symmetric(vertical: 20),
    child: Shimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Bone(width: 88, height: 12),
                      SizedBox(height: 8),
                      Bone(width: 150, height: 26),
                    ],
                  ),
                ),
                Bone(width: 12, height: 14),
              ],
            ),
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 82,
            child: ListView(
              scrollDirection: Axis.horizontal,
              physics: const NeverScrollableScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 20),
              children: const [
                _AccountTile(),
                SizedBox(width: 10),
                _AccountTile(),
                SizedBox(width: 10),
                _AccountTile(),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}

class _AccountTile extends StatelessWidget {
  const _AccountTile();

  @override
  Widget build(BuildContext context) =>
      const SizedBox(width: 150, child: Bone(height: 82, radius: 18));
}

/// The title, then the month's latest rows: round icon, two lines, amount.
class _RecentBones extends StatelessWidget {
  const _RecentBones();

  static const _titles = [.62, .5, .7, .44];
  static const _subtitles = [.4, .32, .36, .3];

  @override
  Widget build(BuildContext context) => MoneyCard(
    child: Shimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Title(150, action: true),
          for (var i = 0; i < 4; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  const Bone.circle(36),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FractionallySizedBox(
                          widthFactor: _titles[i],
                          child: const Bone(height: 14),
                        ),
                        const SizedBox(height: 7),
                        FractionallySizedBox(
                          widthFactor: _subtitles[i],
                          child: const Bone(height: 11),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Bone(width: 70, height: 14),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}
