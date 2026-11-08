import 'package:flutter/material.dart';

import 'common.dart';

/// Sweeps a soft highlight across the [Bone]s below it while content loads.
///
/// Bones are only masks: whatever they paint is replaced by the shimmer's
/// colours, so the gaps between them keep showing the card underneath.
/// Reduced-motion settings get the resting colour with no sweep.
class Shimmer extends StatefulWidget {
  const Shimmer({super.key, required this.child});
  final Widget child;

  @override
  State<Shimmer> createState() => _ShimmerState();
}

class _ShimmerState extends State<Shimmer> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _controller.value = 0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: .07),
      scheme.surface,
    );
    final highlight = Color.alphaBlend(
      scheme.onSurface.withValues(alpha: .02),
      scheme.surface,
    );
    return Semantics(
      label: 'Loading',
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: _controller,
            child: widget.child,
            builder: (context, child) => ShaderMask(
              blendMode: BlendMode.srcATop,
              shaderCallback: (rect) => LinearGradient(
                colors: [base, highlight, base],
                stops: const [.3, .5, .7],
                transform: _Sweep(_controller.value),
              ).createShader(rect),
              child: child,
            ),
          ),
        ),
      ),
    );
  }
}

/// Moves the highlight from just off the left edge to just off the right.
class _Sweep extends GradientTransform {
  const _Sweep(this.progress);
  final double progress;

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) =>
      Matrix4.translationValues(bounds.width * (progress * 2 - 1), 0, 0);
}

/// One placeholder shape inside a [Shimmer].
class Bone extends StatelessWidget {
  const Bone({super.key, this.width, required this.height, this.radius = 8});
  const Bone.circle(double size, {super.key})
    : width = size,
      height = size,
      radius = size / 2;
  final double? width;
  final double height, radius;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: width,
    height: height,
    child: DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(radius),
      ),
    ),
  );
}

/// The shape of a list row: icon, title over subtitle, trailing amount.
/// [variant] only varies the line lengths, so a stack of rows looks like
/// real content rather than a repeated stamp.
class SkeletonTile extends StatelessWidget {
  const SkeletonTile({super.key, this.variant = 0});
  final int variant;

  @override
  Widget build(BuildContext context) {
    const titles = [.62, .46, .7, .54];
    const subtitles = [.34, .42, .28, .38];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          const Bone.circle(40),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FractionallySizedBox(
                  widthFactor: titles[variant % titles.length],
                  child: const Bone(height: 14),
                ),
                const SizedBox(height: 8),
                FractionallySizedBox(
                  widthFactor: subtitles[variant % subtitles.length],
                  child: const Bone(height: 11),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          const Bone(width: 64, height: 14),
        ],
      ),
    );
  }
}

/// [cards] shimmering cards of [rows] list rows, sized by their content.
class SkeletonCards extends StatelessWidget {
  const SkeletonCards({super.key, this.cards = 2, this.rows = 3});
  final int cards, rows;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      for (var card = 0; card < cards; card++)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: MoneyCard(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Shimmer(
              child: Column(
                children: [
                  for (var row = 0; row < rows; row++)
                    SkeletonTile(variant: card * rows + row),
                ],
              ),
            ),
          ),
        ),
    ],
  );
}

/// A whole loading page body: [SkeletonCards] that never scroll or overflow.
class SkeletonList extends StatelessWidget {
  const SkeletonList({
    super.key,
    this.cards = 2,
    this.rows = 3,
    this.padding = const EdgeInsets.fromLTRB(18, 12, 18, 0),
  });
  final int cards, rows;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => ListView(
    physics: const NeverScrollableScrollPhysics(),
    padding: padding,
    children: [SkeletonCards(cards: cards, rows: rows)],
  );
}
