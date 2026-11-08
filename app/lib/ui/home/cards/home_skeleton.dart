import 'package:flutter/material.dart';

import '../../components/common.dart';
import '../../components/skeleton.dart';

/// Home's layout in outline — metrics, the spending chart and recent
/// transactions — so the real numbers land where the eye already is.
class HomeSkeleton extends StatelessWidget {
  const HomeSkeleton({super.key});

  @override
  Widget build(BuildContext context) => const Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MoneyCard(
        child: Shimmer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Bone(width: 80, height: 12),
              SizedBox(height: 10),
              Bone(width: 150, height: 26),
              SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: Bone(height: 52, radius: 16)),
                  SizedBox(width: 10),
                  Expanded(child: Bone(height: 52, radius: 16)),
                ],
              ),
              SizedBox(height: 18),
              Bone(height: 6),
            ],
          ),
        ),
      ),
      SizedBox(height: homeCardGap),
      MoneyCard(
        child: Shimmer(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Bone(width: 180, height: 16),
              SizedBox(height: 18),
              Row(
                children: [
                  Bone.circle(120),
                  SizedBox(width: 20),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _LegendBone(.9),
                        _LegendBone(.7),
                        _LegendBone(.8),
                        _LegendBone(.55),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      SizedBox(height: homeCardGap),
      SkeletonCards(cards: 1, rows: 3),
    ],
  );
}

class _LegendBone extends StatelessWidget {
  const _LegendBone(this.width);
  final double width;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: FractionallySizedBox(
      widthFactor: width,
      child: const Bone(height: 12),
    ),
  );
}
