import 'package:flutter/material.dart';

import '../../data/upi_platform.dart';
import '../components/action_buttons.dart';
import 'privacy_card.dart';

/// What the Google Pay option does, in a few plain steps. Shown full screen
/// the first time it is opened, and as a step of the first-open setup.
class UpiIntroContent extends StatelessWidget {
  const UpiIntroContent({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const HeroSlot(child: RoundIcon(Icons.qr_code_scanner_rounded)),
        const SizedBox(height: 24),
        Text(
          'Pay with Google Pay',
          textAlign: TextAlign.center,
          style: text.headlineMedium,
        ),
        const SizedBox(height: 10),
        Text(
          'Some banks don’t send an SMS for payments. For those, scan the shop’s QR code here.',
          textAlign: TextAlign.center,
          style: text.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 24),
        const PrivacyCard(
          title: 'How it works',
          points: [
            'Scan the shop’s QR code',
            'Google Pay opens with the amount filled in (up to ₹2,000)',
            'Simple Money remembers the payment',
            'A notification asks if it was paid',
            'Tap a category to save it',
          ],
        ),
        const SizedBox(height: 14),
        Text(
          'Allow the camera to scan, and precise location and notifications to note where you paid.',
          textAlign: TextAlign.center,
          style: text.bodySmall,
        ),
      ],
    );
  }
}

/// Asks for what the option uses (precise location, notifications) and notes
/// the intro as seen, so it isn't shown again.
Future<void> setUpUpi(UpiPlatform platform, {required bool permissions}) async {
  try {
    if (permissions) {
      final granted = await platform.requestPermissions();
      if (granted.location != 'denied') await platform.preparePlace();
    }
    await platform.markIntroSeen();
  } catch (_) {
    /* The scanner works without them. */
  }
}

/// The intro as its own full screen, with Skip at the top right and the
/// permissions button at the bottom. Pops when either is chosen.
class UpiIntroScreen extends StatefulWidget {
  const UpiIntroScreen({super.key, required this.platform});
  final UpiPlatform platform;

  @override
  State<UpiIntroScreen> createState() => _UpiIntroScreenState();
}

class _UpiIntroScreenState extends State<UpiIntroScreen> {
  bool _busy = false;
  bool _granted = false;

  @override
  void initState() {
    super.initState();
    widget.platform.permissions().then((p) {
      if (mounted) setState(() => _granted = p.allGranted);
    });
  }

  Future<void> _done({required bool permissions}) async {
    if (_busy) return;
    setState(() => _busy = true);
    await setUpUpi(widget.platform, permissions: permissions && !_granted);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _done(permissions: false);
      },
      child: Scaffold(
        body: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.center,
              colors: [
                theme.colorScheme.primary.withValues(alpha: .1),
                theme.scaffoldBackgroundColor,
              ],
            ),
          ),
          child: SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  children: [
                    Align(
                      alignment: Alignment.centerRight,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(0, 8, 8, 0),
                        child: TextButton(
                          onPressed: _busy
                              ? null
                              : () => _done(permissions: false),
                          child: const Text('Skip'),
                        ),
                      ),
                    ),
                    const Expanded(
                      child: SingleChildScrollView(
                        padding: EdgeInsets.symmetric(horizontal: 24),
                        child: UpiIntroContent(),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                      child: SizedBox(
                        width: double.infinity,
                        child: PillButton(
                          label: _granted ? 'Continue' : 'Set up permissions',
                          loading: _busy,
                          onPressed: () => _done(permissions: true),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
