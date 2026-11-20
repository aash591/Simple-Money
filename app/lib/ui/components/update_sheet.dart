import 'package:flutter/material.dart';

import '../../state/app_update.dart';
import '../theme/sheet_colors.dart';
import 'adaptive_sheet.dart';

/// Shows the update sheet matching what [AppUpdate] knows: "new version
/// available" with an Update button, or — once the background download has
/// finished — "ready to install" with a Restart button.
Future<void> showUpdateSheet(BuildContext context) =>
    showAdaptiveSheet<void>(context, builder: (_) => const _UpdateSheet());

/// Opens the sheet once per launch when something is worth saying: an update
/// that hasn't been declined, or one that has finished downloading.
Future<void> maybeShowUpdateSheet(BuildContext context) async {
  final update = AppUpdate.instance;
  await update.check();
  if (!context.mounted) return;
  final worthShowing =
      update.stage == AppUpdateStage.ready ||
      (update.stage == AppUpdateStage.available && !update.skipped);
  if (worthShowing) await showUpdateSheet(context);
}

class _UpdateSheet extends StatelessWidget {
  const _UpdateSheet();

  @override
  Widget build(BuildContext context) {
    final update = AppUpdate.instance;
    final colors = SheetColors.of(context);
    return ListenableBuilder(
      listenable: update,
      builder: (context, _) {
        final stage = update.stage;
        final (icon, title, message, action) = switch (stage) {
          AppUpdateStage.ready => (
            Icons.check_circle_rounded,
            'Update ready',
            'The new version has finished downloading. Restart to start using it.',
            'Restart to update',
          ),
          AppUpdateStage.downloading => (
            Icons.downloading_rounded,
            'Downloading update',
            'It downloads in the background. Keep using SimpleMoney, and '
                'we’ll tell you when it’s ready.',
            null,
          ),
          _ => (
            Icons.system_update_rounded,
            'New version available',
            'A newer SimpleMoney is on Google Play. It downloads in the '
                'background while you keep using the app.',
            'Update',
          ),
        };
        return SheetPage(
          header: const SheetHeader('Update'),
          bodyPadding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          body: Column(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.primary.withValues(alpha: .12),
                ),
                child: Icon(icon, size: 32, color: colors.primary),
              ),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, height: 1.45, color: colors.muted),
              ),
              if (stage == AppUpdateStage.downloading) ...[
                const SizedBox(height: 18),
                const ClipRRect(
                  borderRadius: BorderRadius.all(Radius.circular(4)),
                  child: LinearProgressIndicator(minHeight: 6),
                ),
              ],
            ],
          ),
          actions: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (action != null)
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(52),
                      ),
                      onPressed: () async {
                        if (stage == AppUpdateStage.ready) {
                          await update.install();
                        } else {
                          // Play's own consent dialog appears over the app;
                          // once accepted the download carries on unseen.
                          final nav = Navigator.of(context);
                          await update.start();
                          if (nav.mounted) nav.pop();
                        }
                      },
                      child: Text(action),
                    ),
                  ),
                TextButton(
                  onPressed: () {
                    if (stage == AppUpdateStage.available) update.skip();
                    Navigator.of(context).pop();
                  },
                  child: Text(
                    stage == AppUpdateStage.downloading ? 'Close' : 'Later',
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
