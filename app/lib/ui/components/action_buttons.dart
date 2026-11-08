import 'package:flutter/material.dart';

import '../theme/sheet_colors.dart';
import 'glass_button.dart';

/// The app's action pill, drawn as a [GlassButton]: solid accent glass for
/// the main action (Continue, Save), neutral grey glass for the quiet one
/// beside it (usually Cancel). A null [onPressed] shows it disabled.
class PillButton extends StatelessWidget {
  const PillButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = true,
    this.color,
    this.backgroundColor,
    this.loading = false,
  });
  final String label;
  final VoidCallback? onPressed;

  /// Shows a spinner beside [label] and ignores taps, keeping the button's
  /// colour while its action runs.
  final bool loading;

  /// False for the neutral secondary style.
  final bool primary;

  /// The primary fill, when it shouldn't be the accent.
  final Color? color;

  /// An optional fill for a secondary button.
  final Color? backgroundColor;

  static const _textStyle = TextStyle(
    fontSize: 15,
    fontWeight: FontWeight.w600,
    letterSpacing: 0,
  );

  @override
  Widget build(BuildContext context) {
    // In light mode the neutral glass is near-white on near-white frost, so
    // quiet and disabled buttons use the keypad's solid grey with a soft
    // shadow to stay visible.
    final light = Theme.of(context).brightness == Brightness.light;
    final neutral = !primary || onPressed == null && !loading;
    final raised = light && neutral && backgroundColor == null;
    return GlassButton(
      onPressed: onPressed,
      color: primary ? color ?? SheetColors.of(context).primary : null,
      fill: raised
          ? const Color(0xffeff0f2)
          : (primary ? null : backgroundColor),
      shadow: raised,
      foregroundColor: primary ? null : color,
      textStyle: _textStyle,
      busy: loading,
      child: loading
          ? Builder(
              builder: (context) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      strokeCap: StrokeCap.round,
                      color: IconTheme.of(context).color,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Flexible(child: Text(label)),
                ],
              ),
            )
          : Text(label),
    );
  }
}

/// The row of pill buttons at the bottom of a sheet or page: a secondary
/// action (usually Cancel) and/or a primary one (Continue, Save), sharing
/// the width equally. A null callback shows that button disabled.
class ActionButtonBar extends StatelessWidget {
  const ActionButtonBar({
    super.key,
    this.secondaryLabel,
    this.onSecondary,
    this.primaryLabel,
    this.onPrimary,
    this.primaryColor,
    this.secondaryForegroundColor,
    this.secondaryBackgroundColor,
    this.padding = const EdgeInsets.all(16),
  });
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final String? primaryLabel;
  final VoidCallback? onPrimary;
  final Color? primaryColor;
  final Color? secondaryForegroundColor;
  final Color? secondaryBackgroundColor;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final buttons = [
      if (secondaryLabel != null)
        PillButton(
          label: secondaryLabel!,
          onPressed: onSecondary,
          primary: false,
          color: secondaryForegroundColor,
          backgroundColor: secondaryBackgroundColor,
        ),
      if (primaryLabel != null)
        PillButton(
          label: primaryLabel!,
          onPressed: onPrimary,
          color: primaryColor,
        ),
    ];
    return Padding(
      padding: padding,
      child: Row(
        children: [
          for (var i = 0; i < buttons.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: buttons[i]),
          ],
        ],
      ),
    );
  }
}
