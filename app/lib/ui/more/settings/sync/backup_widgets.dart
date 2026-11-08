import 'dart:math';

import 'package:flutter/material.dart';

import '../../../components/common.dart';
import '../../../theme/app_theme.dart';

/// Google's four-colour "G", drawn so it needs no bitmap asset.
class GoogleLogo extends StatelessWidget {
  const GoogleLogo({super.key, this.size = 20});
  final double size;
  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: const CustomPaint(painter: _GoogleLogoPainter()),
  );
}

class _GoogleLogoPainter extends CustomPainter {
  const _GoogleLogoPainter();
  static const _blue = Color(0xff4285f4);
  static const _red = Color(0xffea4335);
  static const _yellow = Color(0xfffbbc05);
  static const _green = Color(0xff34a853);

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * .2;
    final center = size.center(Offset.zero);
    final radius = (size.width - stroke) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);
    double deg(double d) => d * pi / 180;
    Paint paint(Color color) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas
      ..drawArc(rect, deg(-140), deg(100), false, paint(_red))
      ..drawArc(rect, deg(140), deg(80), false, paint(_yellow))
      ..drawArc(rect, deg(40), deg(100), false, paint(_green))
      ..drawArc(rect, deg(0), deg(40), false, paint(_blue))
      ..drawRect(
        Rect.fromLTRB(
          center.dx,
          center.dy - stroke / 2,
          center.dx + radius + stroke / 2,
          center.dy + stroke / 2,
        ),
        Paint()..color = _blue,
      );
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Follows Google's sign-in button branding: neutral pill, logo, dark mode.
class GoogleSignInButton extends StatelessWidget {
  const GoogleSignInButton({
    super.key,
    required this.onPressed,
    this.busy = false,
    this.busyLabel,
    this.label = 'Sign in with Google',
  });
  final VoidCallback? onPressed;
  final bool busy;
  final String? busyLabel;

  /// One of Google's approved wordings, e.g. "Continue with Google".
  final String label;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final background = dark ? const Color(0xff131314) : Colors.white;
    final foreground = dark ? const Color(0xffe3e3e3) : const Color(0xff1f1f1f);
    return SizedBox(
      width: double.infinity,
      height: 54,
      child: OutlinedButton(
        onPressed: busy ? null : onPressed,
        style: OutlinedButton.styleFrom(
          backgroundColor: background,
          disabledBackgroundColor: background,
          foregroundColor: foreground,
          disabledForegroundColor: foreground.withValues(alpha: .6),
          side: BorderSide(
            color: dark ? const Color(0xff8e918f) : const Color(0xffc4c7c5),
          ),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (busy)
              const SizedBox.square(
                dimension: 20,
                child: CircularProgressIndicator(strokeWidth: 2.2),
              )
            else
              const GoogleLogo(),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                busy ? busyLabel ?? 'Connecting…' : label,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The app icon on a tile: white with a soft accent glow in light mode,
/// frosted glass in dark mode, where white would glare.
class AppLogoTile extends StatelessWidget {
  const AppLogoTile({super.key, this.size = 110});
  final double size;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * .08),
      decoration: BoxDecoration(
        color: dark ? null : Colors.white,
        gradient: dark
            ? LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.white.withValues(alpha: .2),
                  Colors.white.withValues(alpha: .07),
                ],
              )
            : null,
        border: dark
            ? Border.all(color: Colors.white.withValues(alpha: .2))
            : null,
        borderRadius: BorderRadius.circular(size * .28),
        boxShadow: [
          BoxShadow(
            color: Theme.of(context).colorScheme.primary.withValues(alpha: .14),
            blurRadius: size * .35,
            offset: Offset(0, size * .08),
          ),
        ],
      ),
      child: Image.asset('assets/images/app_icon.webp'),
    );
  }
}

/// The app icon lifted on a card, with a cloud badge and a soft glow.
class BackupHero extends StatelessWidget {
  const BackupHero({super.key, this.size = 110});
  final double size;

  @override
  Widget build(BuildContext context) {
    final surface = Theme.of(context).colorScheme.surface;
    Widget dot(double diameter, Color color) => Container(
      width: diameter,
      height: diameter,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
    );
    return ExcludeSemantics(
      child: SizedBox(
        width: size * 1.9,
        height: size * 1.45,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    colors: [
                      Theme.of(context).colorScheme.primary
                          .withValues(alpha: .18),
                      Theme.of(context).colorScheme.primary
                          .withValues(alpha: 0),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: size * .16,
              top: size * .3,
              child: dot(size * .09, green.withValues(alpha: .7)),
            ),
            Positioned(
              right: size * .2,
              top: size * .12,
              child: dot(
                size * .065,
                Theme.of(context).colorScheme.primary.withValues(alpha: .55),
              ),
            ),
            Positioned(
              left: size * .36,
              bottom: size * .06,
              child: dot(
                size * .05,
                Theme.of(context).colorScheme.primary.withValues(alpha: .35),
              ),
            ),
            AppLogoTile(size: size),
            Positioned(
              right: size * .3,
              bottom: size * .06,
              child: Container(
                width: size * .44,
                height: size * .44,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xff3ea6ff),
                      Theme.of(context).colorScheme.primary,
                    ],
                  ),
                  border: Border.all(color: surface, width: size * .04),
                ),
                child: Icon(
                  Icons.cloud_done_rounded,
                  color: Colors.white,
                  size: size * .21,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class BenefitRow extends StatelessWidget {
  const BenefitRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    this.color,
  });
  final IconData icon;
  final String title, subtitle;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MenuRowIcon(icon, color: color, size: 42),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 2),
              Text(title, style: text.titleMedium?.copyWith(fontSize: 15)),
              const SizedBox(height: 4),
              Text(subtitle, style: text.bodySmall?.copyWith(height: 1.45)),
            ],
          ),
        ),
      ],
    );
  }
}

/// What sync does, in three lines, for the welcome screen.
const backupBenefits = [
  BenefitRow(
    icon: Icons.cloud_sync_outlined,
    title: 'Syncs as you go',
    subtitle: 'Every change is saved to Google Drive automatically.',
  ),
  BenefitRow(
    icon: Icons.lock_outline_rounded,
    title: 'Private to you',
    subtitle: 'Stored in your own Drive. No servers of ours.',
    color: green,
  ),
  BenefitRow(
    icon: Icons.phonelink_setup_rounded,
    title: 'Lost your phone?',
    subtitle: 'Sign in on the new one and everything comes back.',
  ),
];

class ErrorBanner extends StatelessWidget {
  const ErrorBanner(this.message, {super.key});
  final String message;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: coral.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline_rounded, color: coral, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: const TextStyle(color: coral, fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    ),
  );
}
