import '../theme/app_theme.dart' show usesGlass;

import 'package:simple_money/state/vibration_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'glass_button.dart';
import 'modal_transition.dart';
import 'frosted_modal_surface.dart';

/// A bottom-aligned frosted confirmation with equally sized pill actions.
/// Dismissing the barrier or pressing Back is equivalent to Cancel.
Future<bool> showConfirmationAlert(
  BuildContext context, {
  required String title,
  String? message,
  Widget? content,
  String confirmLabel = 'Delete',
  String cancelLabel = 'Cancel',
  VoidCallback? onCancel,
  String? extraActionLabel,
  VoidCallback? onExtraAction,
  bool destructive = true,
  bool confirmFirst = false,
  ValueListenable<bool>? confirmEnabled,
  bool autofocusCancel = true,
  bool showCancel = true,
}) async {
  assert(
    message != null || content != null,
    'An alert needs something under its title.',
  );
  VibrationSettings.lightImpact();
  return await Navigator.of(context, rootNavigator: true).push<bool>(
        _AlertRoute<bool>(
          barrierColor: Colors.transparent,
          barrierDismissible: true,
          barrierLabel: MaterialLocalizations.of(context)
              .modalBarrierDismissLabel,
          transitionDuration: ModalTransition.duration,
          transitionBuilder: (context, animation, secondaryAnimation, child) =>
              ModalTransition(animation: animation, child: child),
          pageBuilder: (_, animation, secondaryAnimation) => SafeArea(
            child: ConfirmationAlert(
              title: title,
              message: message,
              content: content,
              confirmLabel: confirmLabel,
              cancelLabel: cancelLabel,
              onCancel: onCancel,
              extraActionLabel: extraActionLabel,
              onExtraAction: onExtraAction,
              destructive: destructive,
              confirmFirst: confirmFirst,
              confirmEnabled: confirmEnabled,
              autofocusCancel: autofocusCancel,
              showCancel: showCancel,
            ),
          ),
        ),
      ) ??
      false;
}

/// A dialog route that closes faster than it opens.
class _AlertRoute<T> extends RawDialogRoute<T> {
  _AlertRoute({
    required super.pageBuilder,
    super.barrierDismissible,
    super.barrierColor,
    super.barrierLabel,
    super.transitionDuration,
    super.transitionBuilder,
  });

  @override
  Duration get reverseTransitionDuration => ModalTransition.reverseDuration;
}

/// A notice with one button, for telling the user something went well.
Future<void> showNoticeAlert(
  BuildContext context, {
  required String title,
  required String message,
  String buttonLabel = 'Done',
}) => showConfirmationAlert(
  context,
  title: title,
  message: message,
  confirmLabel: buttonLabel,
  destructive: false,
  showCancel: false,
);

/// Confirms a permanent delete in two steps: [title] and [message] explain
/// what goes, then a second alert asks again because it can't be undone.
/// True only when both are confirmed.
Future<bool> showDeleteConfirmation(
  BuildContext context, {
  required String title,
  required String message,
  String confirmLabel = 'Delete',
}) async {
  if (!await showConfirmationAlert(
    context,
    title: title,
    message: message,
    confirmLabel: confirmLabel,
  )) {
    return false;
  }
  if (!context.mounted) return false;
  return showConfirmationAlert(
    context,
    title: 'Are you sure?',
    message: 'This can’t be undone.',
    confirmLabel: 'Yes, ${confirmLabel.toLowerCase()}',
    confirmFirst: true,
  );
}

/// One consequence of the action being confirmed, written to be taken in at a
/// glance: a few words against an icon, not a sentence. Build a list of them
/// into [ConfirmationFacts] and hand that to an alert's `content`.
class ConfirmationFact {
  const ConfirmationFact(this.icon, this.text, {this.grave = false});
  final IconData icon;

  /// Four or five words. What is lost or kept, and how much of it — the
  /// reasoning belongs in the title, not here.
  final String text;

  /// Draws the row in the destructive colour. For the one line that is the
  /// actual loss, so it does not read at the same weight as the rest.
  final bool grave;
}

/// [ConfirmationFact]s as a grouped list, in place of a paragraph. An alert is
/// read in the second before a decision, so the consequences are stacked one
/// per line where they can be counted rather than parsed.
class ConfirmationFacts extends StatelessWidget {
  const ConfirmationFacts({super.key, required this.facts, this.subtitle});
  final List<ConfirmationFact> facts;

  /// A line between the title and the list — what is being acted on, usually
  /// its name and balance.
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textColor = dark ? Colors.white : Colors.black;
    final muted = textColor.withValues(alpha: .55);
    final grave = dark ? const Color(0xffff6961) : const Color(0xffe5352b);
    // The same fill as the confirm button, so the list reads as a panel
    // inside the alert rather than a second alert.
    final fill = dark ? const Color(0xff3a3b40) : const Color(0xffe6e6ea);
    // Wrapping is the norm at large text scales, so rows stop pretending to
    // be single-line and the icon settles against the first line instead.
    final wrapping = MediaQuery.textScalerOf(context).scale(13.5) > 18;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (subtitle != null) ...[
          Text(
            subtitle!,
            style: TextStyle(
              fontSize: 13.5,
              height: 1.3,
              letterSpacing: -0.1,
              color: muted,
            ),
          ),
        ],
        const SizedBox(height: 14),
        DecoratedBox(
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final (index, fact) in facts.indexed) ...[
                if (index > 0)
                  Divider(
                    height: 1,
                    thickness: 1,
                    indent: 44,
                    color: textColor.withValues(alpha: .07),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 14, 11),
                  child: Row(
                    crossAxisAlignment: wrapping
                        ? CrossAxisAlignment.start
                        : CrossAxisAlignment.center,
                    children: [
                      Icon(
                        fact.icon,
                        size: 18,
                        color: fact.grave ? grave : muted,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          fact.text,
                          style: TextStyle(
                            fontSize: 13.5,
                            height: 1.3,
                            letterSpacing: -0.1,
                            fontWeight: fact.grave
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: fact.grave ? grave : textColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class ConfirmationAlert extends StatelessWidget {
  const ConfirmationAlert({
    super.key,
    required this.title,
    this.message,
    this.content,
    this.confirmLabel = 'Delete',
    this.cancelLabel = 'Cancel',
    this.onCancel,
    this.extraActionLabel,
    this.onExtraAction,
    this.destructive = true,
    this.confirmFirst = false,
    this.confirmEnabled,
    this.autofocusCancel = true,
    this.showCancel = true,
  }) : assert(
         message != null || content != null,
         'An alert needs something under its title.',
       );

  final String title;

  /// Prose under the title. [content] replaces it, for an alert whose
  /// consequences read better as a list than as a paragraph.
  final String? message;
  final Widget? content;
  final String confirmLabel;
  final String cancelLabel;

  /// Called only when the secondary button is tapped, never on dismissal.
  final VoidCallback? onCancel;
  final String? extraActionLabel;
  final VoidCallback? onExtraAction;
  final bool destructive;
  final bool confirmFirst;

  /// False for a notice: one button, no choice to make.
  final bool showCancel;

  /// Greys the confirm button out while false, e.g. until a field is filled.
  final ValueListenable<bool>? confirmEnabled;

  /// Cancel takes focus when the alert opens; off for an alert with a field
  /// that should have it instead.
  final bool autofocusCancel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final scheme = theme.colorScheme;
    const radius = BorderRadius.all(Radius.circular(36));
    final textColor = dark ? Colors.white : Colors.black;
    const buttonText = TextStyle(
      fontSize: 17,
      fontWeight: FontWeight.w400,
      letterSpacing: -0.4,
    );
    // The plain style in light mode has no glass: quiet buttons are white on
    // the grey sheet, and the main one carries the accent.
    final plainLight = !usesGlass(context) && !dark;
    final cancel = GlassButton(
      autofocus: autofocusCancel,
      textStyle: buttonText,
      flatFill: plainLight ? Colors.white : null,
      shadow: plainLight,
      onPressed: () {
        VibrationSettings.selectionClick();
        Navigator.pop(context, false);
        onCancel?.call();
      },
      child: Text(cancelLabel),
    );
    // A destructive confirm is glass tinted red with red text, so it reads as
    // different from the neutral Cancel beside it; any other confirm is the
    // main action, in solid accent glass.
    final danger = dark ? const Color(0xffff6961) : const Color(0xffe5352b);
    GlassButton confirmButton(bool enabled) => GlassButton(
      textStyle: buttonText,
      color: destructive ? null : scheme.primary,
      fill: destructive ? danger.withValues(alpha: dark ? .2 : .14) : null,
      // A slight red wash behind the red text, so it stays apart from the
      // white Cancel in the plain light style.
      flatFill: destructive ? danger.withValues(alpha: dark ? .2 : .12) : null,
      foregroundColor: destructive ? danger : null,
      onPressed: enabled
          ? () {
              VibrationSettings.selectionClick();
              Navigator.pop(context, true);
            }
          : null,
      child: Text(confirmLabel),
    );
    final confirm = confirmEnabled == null
        ? confirmButton(true)
        : ValueListenableBuilder<bool>(
            valueListenable: confirmEnabled!,
            builder: (_, enabled, _) => confirmButton(enabled),
          );
    return Dialog(
      alignment: Alignment.bottomCenter,
      constraints: const BoxConstraints(maxWidth: 440),
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      shadowColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.fromLTRB(8, 24, 8, 4),
      shape: const RoundedRectangleBorder(borderRadius: radius),
      child: FrostedModalSurface(
        borderRadius: radius,
        child: SizedBox(
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(10, 28, 10, 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Semantics(
                          namesRoute: true,
                          child: Text(
                            title,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w600,
                              letterSpacing: -0.4,
                              height: 1.3,
                              color: textColor,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        content ??
                            Text(
                              message!,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w400,
                                letterSpacing: -0.1,
                                height: 1.35,
                                color: textColor.withValues(alpha: .85),
                              ),
                            ),
                      ],
                    ),
                  ),
                ),
                if (!showCancel)
                  confirm
                else if (MediaQuery.textScalerOf(context).scale(17) > 24)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      confirmFirst ? confirm : cancel,
                      const SizedBox(height: 8),
                      confirmFirst ? cancel : confirm,
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(child: confirmFirst ? confirm : cancel),
                      const SizedBox(width: 8),
                      Expanded(child: confirmFirst ? cancel : confirm),
                    ],
                  ),
                if (extraActionLabel != null) ...[
                  const SizedBox(height: 8),
                  GlassButton(
                    textStyle: buttonText,
                    flatFill: plainLight ? Colors.white : null,
                    shadow: plainLight,
                    foregroundColor: scheme.primary,
                    onPressed: () {
                      VibrationSettings.selectionClick();
                      Navigator.pop(context, false);
                      onExtraAction?.call();
                    },
                    child: Text(extraActionLabel!),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
