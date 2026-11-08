import 'package:flutter/material.dart';

import '../../state/ad_gate.dart';
import '../more/pro/pro_screen.dart';
import 'confirmation_alert.dart';
import 'feature_page.dart';

/// [AdGate.watch] with a "Loading ad…" indicator over the screen while an ad
/// is fetched, so the app never looks frozen. It closes just before the ad
/// opens, or when none can show.
///
/// Offline, an ad can't load, so it asks for the internet first rather than
/// letting the action through free. Returns false when the user chose not to
/// go on (offline and declined, or went to Pro); the caller should stop.
Future<bool> watchAd(BuildContext context) async {
  while (await AdGate.instance.blockedOffline) {
    if (!context.mounted) return false;
    void openPro() =>
        Navigator.of(context).push(FeatureRoute<void>(const ProScreen()));
    final retry = await showConfirmationAlert(
      context,
      title: 'Turn on the internet',
      message:
          'A short ad needs an internet connection. Turn on Wi‑Fi or mobile '
          'data, then try again. With Pro, no ads and no internet needed.',
      confirmLabel: 'Try again',
      cancelLabel: 'Not now',
      extraActionLabel: 'Get Pro instead',
      onExtraAction: openPro,
      destructive: false,
    );
    if (!retry) return false;
  }
  if (!context.mounted) return false;
  final navigator = Navigator.of(context, rootNavigator: true);
  var open = false;
  void close() {
    if (open && navigator.mounted) navigator.pop();
    open = false;
  }

  if (AdGate.instance.mayWait) {
    open = true;
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      useRootNavigator: true,
      barrierColor: Colors.black38,
      builder: (_) => const PopScope(canPop: false, child: _LoadingAd()),
    );
  }
  try {
    await AdGate.instance.watch(onShowing: close);
  } finally {
    close();
  }
  return true;
}

class _LoadingAd extends StatelessWidget {
  const _LoadingAd();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Material(
        color: theme.colorScheme.surface,
        elevation: 6,
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
              const SizedBox(height: 14),
              Text('Loading ad…', style: theme.textTheme.bodyMedium),
            ],
          ),
        ),
      ),
    );
  }
}
