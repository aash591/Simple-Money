import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../components/common.dart' show appCardGap;
import '../../components/menu_list.dart';

/// The colours the celebration is made of: warm gold, the perks' own hues
/// and a soft pink, so it reads festive on both the hero and the page.
const _festive = [
  Color(0xffffc93c),
  Color(0xfff5a623),
  Color(0xff7c4dff),
  Color(0xff0f9d7a),
  Color(0xffe0457b),
  Color(0xff2f80ed),
  Color(0xffff8fb1),
];

// ---------------------------------------------------------------------------
// Confetti
// ---------------------------------------------------------------------------

/// Fires ribbons and paper confetti from both sides of [originY] each time
/// [controller] runs forward from zero. Draws nothing while it is idle, and
/// never takes taps.
class ConfettiBurst extends StatefulWidget {
  const ConfettiBurst({
    super.key,
    required this.controller,
    required this.originY,
  });

  /// Runs 0 → 1 over one burst ([burstDuration]).
  final AnimationController controller;

  /// How far down the overlay the two cannons sit.
  final double originY;

  static const burstDuration = Duration(milliseconds: 4200);

  @override
  State<ConfettiBurst> createState() => _ConfettiBurstState();
}

class _ConfettiBurstState extends State<ConfettiBurst> {
  var _seed = 7;
  late List<_Piece> _pieces = _Piece.burst(_seed);

  @override
  void initState() {
    super.initState();
    widget.controller.addStatusListener(_onStatus);
  }

  @override
  void didUpdateWidget(ConfettiBurst old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeStatusListener(_onStatus);
      widget.controller.addStatusListener(_onStatus);
    }
  }

  @override
  void dispose() {
    widget.controller.removeStatusListener(_onStatus);
    super.dispose();
  }

  // A fresh scatter for every replay, so no two bursts look the same.
  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.forward && widget.controller.value == 0) {
      setState(() => _pieces = _Piece.burst(++_seed));
    }
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _ConfettiPainter(
            pieces: _pieces,
            progress: widget.controller,
            originY: widget.originY,
          ),
        ),
      ),
    );
  }
}

/// One piece of confetti. Its whole flight is worked out from time alone
/// (gravity with air drag), so the painter keeps no state between frames.
class _Piece {
  _Piece({
    required this.left,
    required this.vx,
    required this.vy,
    required this.drag,
    required this.color,
    required this.ribbon,
    required this.size,
    required this.spin,
    required this.flip,
    required this.phase,
    required this.sway,
    required this.delay,
  });

  final bool left, ribbon;
  final double vx, vy, drag, size, spin, flip, phase, sway, delay;
  final Color color;

  static const _gravity = 980.0;

  static List<_Piece> burst(int seed) {
    final r = math.Random(seed);
    double between(double a, double b) => a + r.nextDouble() * (b - a);
    return [
      for (var i = 0; i < 120; i++)
        () {
          final ribbon = r.nextDouble() < .38;
          // Aim up and inward, fanned out.
          final angle = between(-1.32, -.42); // radians above horizontal
          final speed = between(620, 1250);
          return _Piece(
            left: i.isEven,
            vx: math.cos(angle) * speed,
            vy: math.sin(angle) * speed,
            // Ribbons catch more air and drift down slower.
            drag: ribbon ? between(2.4, 3.2) : between(1.7, 2.6),
            color: _festive[r.nextInt(_festive.length)],
            ribbon: ribbon,
            size: ribbon ? between(22, 36) : between(6, 11),
            spin: between(-7, 7),
            flip: between(5, 12),
            phase: between(0, math.pi * 2),
            sway: between(10, 34),
            delay: between(0, .32),
          );
        }(),
    ];
  }

  /// Where the piece is [t] seconds after leaving the cannon at [origin].
  Offset at(double t, Offset origin, double width) {
    final k = drag;
    final decay = (1 - math.exp(-k * t)) / k;
    final dx = vx * decay + sway * math.sin(t * 3 + phase) * (1 - math.exp(-t));
    final dy = (_gravity / k) * t + (vy - _gravity / k) * decay;
    return Offset(
      left ? origin.dx + dx : width - origin.dx - dx,
      origin.dy + dy,
    );
  }
}

class _ConfettiPainter extends CustomPainter {
  _ConfettiPainter({
    required this.pieces,
    required this.progress,
    required this.originY,
  }) : super(repaint: progress);

  final List<_Piece> pieces;
  final Animation<double> progress;
  final double originY;

  @override
  void paint(Canvas canvas, Size size) {
    final value = progress.value;
    if (value <= 0 || value >= 1) return;
    final seconds = value * ConfettiBurst.burstDuration.inMilliseconds / 1000;
    final origin = Offset(-6, originY);
    final paint = Paint()..isAntiAlias = true;
    final stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    for (final p in pieces) {
      final t = seconds - p.delay;
      if (t <= 0) continue;
      final pos = p.at(t, origin, size.width);
      if (pos.dy > size.height + 40) continue;
      // Fade over the last stretch of the burst.
      final fade = ((1 - value) / .3).clamp(0.0, 1.0);
      final color = p.color.withValues(alpha: fade);

      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(p.spin * t * .35 + p.phase);
      if (p.ribbon) {
        // A curling streamer: a wave whose curl travels along it.
        final path = Path();
        const steps = 10;
        for (var s = 0; s <= steps; s++) {
          final f = s / steps;
          final x = (f - .5) * p.size;
          final y = math.sin(f * math.pi * 2 + t * p.flip) * p.size * .16;
          s == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
        }
        stroke
          ..color = color
          ..strokeWidth = 3.4 + 1.4 * math.cos(t * p.flip).abs();
        canvas.drawPath(path, stroke);
      } else {
        // A paper square tumbling in 3D: it narrows as it turns edge-on,
        // and darkens on its back.
        final turn = math.cos(t * p.flip + p.phase);
        final back = turn < 0;
        paint.color = back
            ? Color.lerp(color, Colors.black, .18)!.withValues(alpha: fade)
            : color;
        canvas.scale(turn.abs().clamp(.08, 1.0), 1);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset.zero,
              width: p.size,
              height: p.size * .62,
            ),
            const Radius.circular(1.5),
          ),
          paint,
        );
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(_ConfettiPainter old) =>
      old.pieces != pieces || old.originY != originY;
}

// ---------------------------------------------------------------------------
// Sparkles
// ---------------------------------------------------------------------------

/// Four-pointed stars twinkling and drifting slowly up across the hero.

class SparkleField extends StatefulWidget {
  const SparkleField({super.key, this.count = 22});
  final int count;

  @override
  State<SparkleField> createState() => _SparkleFieldState();
}

class _SparkleFieldState extends State<SparkleField>
    with SingleTickerProviderStateMixin {
  static const _period = 12.0; // seconds per loop

  late final _clock = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: (_period * 1000).round()),
  );

  late final List<_Sparkle> _sparkles = () {
    final r = math.Random(42);
    return [
      for (var i = 0; i < widget.count; i++)
        _Sparkle(
          x: r.nextDouble(),
          y: r.nextDouble(),
          size: 3 + r.nextDouble() * (i % 5 == 0 ? 9 : 5),
          // Whole cycles per loop, so the loop is seamless.
          twinkle: (1 + r.nextInt(3)).toDouble(),
          phase: r.nextDouble() * math.pi * 2,
          gold: r.nextDouble() < .35,
        ),
    ];
  }();

  @override
  void initState() {
    super.initState();
    _clock.repeat();
  }

  @override
  void dispose() {
    _clock.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
    child: RepaintBoundary(
      child: CustomPaint(
        size: Size.infinite,
        painter: _SparklePainter(_sparkles, _clock),
      ),
    ),
  );
}

class _Sparkle {
  const _Sparkle({
    required this.x,
    required this.y,
    required this.size,
    required this.twinkle,
    required this.phase,
    required this.gold,
  });
  final double x, y, size, twinkle, phase;
  final bool gold;
}

class _SparklePainter extends CustomPainter {
  _SparklePainter(this.sparkles, this.clock) : super(repaint: clock);
  final List<_Sparkle> sparkles;
  final Animation<double> clock;

  @override
  void paint(Canvas canvas, Size size) {
    final loop = clock.value;
    final paint = Paint()..isAntiAlias = true;
    final glow = Paint()
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    for (final s in sparkles) {
      final pulse =
          .5 + .5 * math.sin(loop * math.pi * 2 * s.twinkle + s.phase);
      if (pulse < .08) continue;
      // Drift up one full height per loop, wrapping round.
      final y = ((s.y - loop) % 1) * size.height;
      final center = Offset(s.x * size.width, y);
      final r = s.size * (.45 + .55 * pulse);
      final color = s.gold ? const Color(0xffffe08a) : Colors.white;
      glow.color = color.withValues(alpha: .35 * pulse);
      canvas.drawCircle(center, r * .9, glow);
      paint.color = color.withValues(alpha: .25 + .7 * pulse);
      canvas.drawPath(_star(center, r), paint);
    }
  }

  /// A four-pointed sparkle with pinched sides.
  static Path _star(Offset c, double r) {
    final w = r * .22;
    return Path()
      ..moveTo(c.dx, c.dy - r)
      ..quadraticBezierTo(c.dx + w, c.dy - w, c.dx + r, c.dy)
      ..quadraticBezierTo(c.dx + w, c.dy + w, c.dx, c.dy + r)
      ..quadraticBezierTo(c.dx - w, c.dy + w, c.dx - r, c.dy)
      ..quadraticBezierTo(c.dx - w, c.dy - w, c.dx, c.dy - r)
      ..close();
  }

  @override
  bool shouldRepaint(_SparklePainter old) => old.sparkles != sparkles;
}

// ---------------------------------------------------------------------------
// Badge
// ---------------------------------------------------------------------------

/// A gold medal that pops in, breathes gently, and wears a slowly turning
/// halo. Tapping it calls [onTap] (another round of confetti).
class SupporterBadge extends StatefulWidget {
  const SupporterBadge({
    super.key,
    required this.size,
    required this.lifetime,
    this.onTap,
  });
  final double size;
  final bool lifetime;
  final VoidCallback? onTap;

  @override
  State<SupporterBadge> createState() => _SupporterBadgeState();
}

class _SupporterBadgeState extends State<SupporterBadge>
    with TickerProviderStateMixin {
  late final _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );
  late final _loop = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  );

  @override
  void initState() {
    super.initState();
    _enter.forward();
    _loop.repeat();
  }

  @override
  void dispose() {
    _enter.dispose();
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final ring = size + 26;
    return Semantics(
      button: widget.onTap != null,
      label: widget.lifetime ? 'Lifetime supporter' : 'Supporter',
      child: GestureDetector(
        onTap: widget.onTap == null
            ? null
            : () {
                HapticFeedback.lightImpact();
                widget.onTap!();
              },
        child: AnimatedBuilder(
          animation: Listenable.merge([_enter, _loop]),
          builder: (context, _) {
            final pop = Curves.elasticOut.transform(_enter.value);
            final breathe = 1 + .035 * math.sin(_loop.value * math.pi * 4);
            return Transform.scale(
              scale: (.4 + .6 * pop) * breathe,
              child: SizedBox.square(
                dimension: ring,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    // Warm glow behind.
                    Container(
                      width: ring,
                      height: ring,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            const Color(0xffffd76a).withValues(alpha: .55),
                            const Color(0xffffd76a).withValues(alpha: 0),
                          ],
                        ),
                      ),
                    ),
                    // The turning halo.
                    Transform.rotate(
                      angle: _loop.value * math.pi * 2,
                      child: CustomPaint(
                        size: Size.square(size + 12),
                        painter: _HaloPainter(),
                      ),
                    ),
                    // The medal.
                    Container(
                      width: size,
                      height: size,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                          colors: [
                            Color(0xffffeeb0),
                            Color(0xffffc93c),
                            Color(0xffe39a12),
                          ],
                        ),
                        border: Border.all(color: Colors.white, width: 2.5),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xff7a4a00)
                                .withValues(alpha: .35),
                            blurRadius: 16,
                            offset: const Offset(0, 6),
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // A glint sweeping across now and then.
                            Positioned.fill(
                              child: _Glint(progress: _loop.value),
                            ),
                            Icon(
                              widget.lifetime
                                  ? Icons.all_inclusive_rounded
                                  : Icons.favorite_rounded,
                              size: size * .46,
                              color: const Color(0xff9a5b00),
                              shadows: [
                                Shadow(
                                  color: Colors.white.withValues(alpha: .7),
                                  offset: const Offset(0, 1.5),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

class _HaloPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..shader = SweepGradient(
        colors: [
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: .9),
          const Color(0xffffe08a),
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: 0),
          Colors.white.withValues(alpha: .7),
          Colors.white.withValues(alpha: 0),
        ],
        stops: const [0, .18, .3, .45, .55, .75, .95],
      ).createShader(rect);
    canvas.drawCircle(rect.center, size.width / 2 - 2, paint);
    // Two tiny satellites riding the halo.
    final dot = Paint()..color = Colors.white;
    canvas.drawCircle(Offset(size.width / 2, 2), 2.6, dot);
    canvas.drawCircle(Offset(size.width / 2, size.height - 2), 1.8, dot);
  }

  @override
  bool shouldRepaint(_HaloPainter old) => false;
}

/// A diagonal sheen that crosses the medal during the first part of each
/// loop, then rests.
class _Glint extends StatelessWidget {
  const _Glint({required this.progress});
  final double progress;

  @override
  Widget build(BuildContext context) {
    final t = (progress / .35).clamp(0.0, 1.0);
    if (t == 0 || t == 1) return const SizedBox.shrink();
    final x = -1.6 + 3.2 * t;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(x - .5, -1),
          end: Alignment(x + .5, 1),
          colors: [
            Colors.white.withValues(alpha: 0),
            Colors.white.withValues(alpha: .65),
            Colors.white.withValues(alpha: 0),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Body
// ---------------------------------------------------------------------------

/// One thing Pro unlocks. [color] tints its icon.
class ThanksPerk {
  const ThanksPerk(this.icon, this.color, this.title, this.subtitle);
  final IconData icon;
  final Color color;
  final String title, subtitle;
}

/// The page under the hero for someone who has Pro, in the app's own plain
/// style: who they are, what they unlocked as a list like Settings, and a
/// row to leave a review. The hero above does the celebrating.
class ProThanksBody extends StatefulWidget {
  const ProThanksBody({
    super.key,
    required this.lifetime,
    required this.perks,
    this.onReview,
  });
  final bool lifetime;
  final List<ThanksPerk> perks;
  final VoidCallback? onReview;

  @override
  State<ProThanksBody> createState() => _ProThanksBodyState();
}

class _ProThanksBodyState extends State<ProThanksBody>
    with SingleTickerProviderStateMixin {
  late final _enter = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );

  @override
  void initState() {
    super.initState();
    _enter.forward();
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  /// Fades and lifts [child] in a little after the part above it.
  Widget _rise(double start, Widget child) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    final curve = CurvedAnimation(
      parent: _enter,
      curve: Interval(
        start,
        math.min(1, start + .7),
        curve: Curves.easeOutCubic,
      ),
    );
    return FadeTransition(
      opacity: curve,
      child: SlideTransition(
        position: Tween(
          begin: const Offset(0, .04),
          end: Offset.zero,
        ).animate(curve),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final accent = theme.colorScheme.primary;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _rise(
          0,
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.lifetime
                    ? 'You’re a lifetime supporter'
                    : 'You’re a supporter',
                style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
              ),
              const SizedBox(height: 6),
              Text(
                widget.lifetime
                    ? 'Everything below is yours, in every update too. '
                          'Thank you.'
                    : 'Everything below is yours. Thank you for keeping '
                          'SimpleMoney going.',
                style: text.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        _rise(
          .1,
          MenuGroup(
            label: 'Included',
            children: [
              for (final perk in widget.perks)
                MenuRow(
                  icon: perk.icon,
                  tint: perk.color,
                  title: perk.title,
                  subtitle: perk.subtitle,
                  trailing: Icon(
                    Icons.check_circle_rounded,
                    size: 22,
                    color: accent,
                    semanticLabel: 'Included',
                  ),
                ),
            ],
          ),
        ),
        if (widget.onReview != null) ...[
          const SizedBox(height: appCardGap),
          _rise(
            .2,
            MenuGroup(
              children: [
                MenuRow(
                  icon: Icons.star_rounded,
                  tint: const Color(0xfff2a900),
                  title: 'Rate SimpleMoney',
                  subtitle: 'A review helps others find it',
                  external: true,
                  onTap: widget.onReview,
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
