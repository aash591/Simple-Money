import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../state/security_controller.dart';

/// Sits above the Navigator, so pushed routes and sheets are also protected.
class AppLockGate extends StatefulWidget {
  const AppLockGate({super.key, required this.controller, required this.child});
  final SecurityController controller;
  final Widget child;

  @override
  State<AppLockGate> createState() => _AppLockGateState();
}

class _AppLockGateState extends State<AppLockGate> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    await widget.controller.initialize();
    if (mounted) await widget.controller.unlock();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    widget.controller.handleLifecycle(state);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SecurityScope(
    controller: widget.controller,
    child: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final security = widget.controller;
        final blurred = security.blursPreview;
        return Stack(
          fit: StackFit.expand,
          children: [
            // Same widgets whether blurred or not, so the app keeps its state.
            Offstage(
              offstage: security.covered && !blurred,
              child: TickerMode(
                enabled: !security.covered,
                child: ExcludeFocus(
                  excluding: security.covered,
                  child: IgnorePointer(
                    ignoring: blurred,
                    child: ImageFiltered(
                      enabled: blurred,
                      imageFilter: ImageFilter.blur(
                        sigmaX: _previewBlur,
                        sigmaY: _previewBlur,
                        tileMode: TileMode.mirror,
                      ),
                      child: widget.child,
                    ),
                  ),
                ),
              ),
            ),
            if (security.requiresUnlock ||
                (!security.ready && security.error != null))
              _LockScreen(security: security, onRetry: _start)
            else if (security.covered)
              security.hideAppPreview
                  ? _PrivacyCover(blurred: blurred)
                  : ColoredBox(
                      color: Theme.of(context).scaffoldBackgroundColor,
                    ),
          ],
        );
      },
    ),
  );
}

/// Strong enough that no figure or name can be read in Recents.
const _previewBlur = 14.0;

/// Hide financial details in Recents without claiming the session is locked:
/// the app blurred, with its icon in the middle. A plain cover is the
/// fallback while the app itself can't show.
class _PrivacyCover extends StatelessWidget {
  const _PrivacyCover({required this.blurred});
  final bool blurred;

  @override
  Widget build(BuildContext context) => ColoredBox(
    key: const Key('app-privacy-cover'),
    // A veil over the blur, so nothing underneath stands out.
    color: Theme.of(context).scaffoldBackgroundColor
        .withValues(alpha: blurred ? .4 : 1),
    child: Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Image.asset(
          'assets/images/app_icon.webp',
          width: 80,
          height: 80,
          semanticLabel: 'SimpleMoney',
        ),
      ),
    ),
  );
}

/// The only thing shown while the ledger is hidden: the app's own mark, one
/// line of guidance, and a single way forward.
class _LockScreen extends StatelessWidget {
  const _LockScreen({required this.security, required this.onRetry});
  final SecurityController security;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final failed = security.error != null;
    // Authenticating, or still reading the lock preference at startup.
    final waiting = security.busy || (!security.ready && !failed);
    return Scaffold(
      body: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.center,
            colors: [
              scheme.primary.withValues(alpha: .1),
              theme.scaffoldBackgroundColor,
            ],
          ),
        ),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: _FadeIn(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const _LockedAppIcon(),
                      const SizedBox(height: 30),
                      Text(
                        'SimpleMoney',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        security.error ?? 'Unlock to continue',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          height: 1.5,
                          color: failed
                              ? scheme.error
                              : scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 30),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: waiting
                            ? const Center(
                                child: SizedBox.square(
                                  dimension: 26,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                  ),
                                ),
                              )
                            : FilledButton.icon(
                                onPressed: security.ready
                                    ? () => security.unlock()
                                    : onRetry,
                                icon: const Icon(
                                  Icons.lock_open_rounded,
                                  size: 20,
                                ),
                                label: Text(
                                  security.ready ? 'Unlock' : 'Try again',
                                ),
                              ),
                      ),
                      const SizedBox(height: 22),
                      Text(
                        'Your money data stays on this device.',
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The launcher mark on a raised plate, with a lock badge instead of the
/// plain padlock the screen used to lead with.
class _LockedAppIcon extends StatelessWidget {
  const _LockedAppIcon();

  static const _plate = 104.0;
  static const _badge = 38.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return SizedBox(
      width: _plate + 12,
      height: _plate + 6,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            child: Container(
              width: _plate,
              height: _plate,
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(28),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: .22),
                    blurRadius: 34,
                    offset: const Offset(0, 14),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: .12),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Image.asset(
                'assets/images/app_icon.webp',
                fit: BoxFit.cover,
                semanticLabel: 'SimpleMoney',
              ),
            ),
          ),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: _badge,
              height: _badge,
              decoration: BoxDecoration(
                color: scheme.primary,
                shape: BoxShape.circle,
                // Keeps the badge readable where it overlaps the plate.
                border: Border.all(
                  color: theme.scaffoldBackgroundColor,
                  width: 3,
                ),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: .35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Icon(
                Icons.lock_rounded,
                size: 18,
                color: scheme.onPrimary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Softens the jump from the app to the lock screen; reduced-motion settings
/// skip it.
class _FadeIn extends StatelessWidget {
  const _FadeIn({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 420),
    curve: Curves.easeOutCubic,
    builder: (context, t, child) => Opacity(
      opacity: t,
      child: Transform.translate(offset: Offset(0, 16 * (1 - t)), child: child),
    ),
    child: child,
  );
}
