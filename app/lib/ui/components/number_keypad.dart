import 'package:simple_money/state/vibration_settings.dart';
import 'package:flutter/material.dart';

import '../theme/sheet_colors.dart';
import 'glass_button.dart';

/// The custom number pad used to type a money amount — large, evenly sized
/// keys instead of the system keyboard, built just for entering numbers.
class NumberKeypad extends StatelessWidget {
  const NumberKeypad({
    super.key,
    required this.onDigit,
    required this.onDecimalPoint,
    required this.onBackspace,
    this.onClear,
    this.decimalEnabled = true,
    this.onOperation,
  });
  final ValueChanged<String> onDigit;
  final VoidCallback onDecimalPoint;
  final VoidCallback onBackspace;

  /// Called when backspace is long-pressed, to clear the whole amount.
  final VoidCallback? onClear;

  /// False once a decimal point has already been typed (or the amount's
  /// currency has no decimal places), so a second one can't be entered.
  final bool decimalEnabled;
  final ValueChanged<String>? onOperation;

  static const _gap = 10.0;
  static const _digitRows = [
    ['7', '8', '9'],
    ['4', '5', '6'],
    ['1', '2', '3'],
  ];

  @override
  Widget build(BuildContext context) {
    final rows = onOperation != null
        ? [
            for (final labels in const [
              ['AC', '%', '÷', '⌫'],
              ['7', '8', '9', '×'],
              ['4', '5', '6', '−'],
              ['1', '2', '3', '+'],
              ['±', '0', '.', '='],
            ])
              [
                for (final label in labels)
                  _Key(
                    label: label == '⌫' ? null : label,
                    icon: label == '⌫' ? Icons.backspace_outlined : null,
                    semanticLabel: switch (label) {
                      'AC' => 'Clear all',
                      '⌫' => 'Delete',
                      '×' => 'Multiply',
                      '÷' => 'Divide',
                      '−' => 'Subtract',
                      '+' => 'Add',
                      '%' => 'Percent',
                      '±' => 'Change sign',
                      '=' => 'Equals',
                      '.' => 'Decimal point',
                      _ => label,
                    },
                    compact: true,
                    onTap: switch (label) {
                      'AC' => onClear,
                      '⌫' => onBackspace,
                      '.' => decimalEnabled ? onDecimalPoint : null,
                      '0' ||
                      '1' ||
                      '2' ||
                      '3' ||
                      '4' ||
                      '5' ||
                      '6' ||
                      '7' ||
                      '8' ||
                      '9' => () => onDigit(label),
                      _ => () => onOperation!(label),
                    },
                  ),
              ],
          ]
        : [
            for (final row in _digitRows)
              [for (final d in row) _Key(label: d, onTap: () => onDigit(d))],
            [
              _Key(
                label: '.',
                semanticLabel: 'Decimal point',
                onTap: decimalEnabled ? onDecimalPoint : null,
              ),
              _Key(label: '0', onTap: () => onDigit('0')),
              _Key(
                icon: Icons.backspace_outlined,
                semanticLabel: 'Delete',
                onTap: onBackspace,
                onLongPress: onClear,
              ),
            ],
          ];
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) const SizedBox(height: _gap),
          Row(
            children: [
              for (var k = 0; k < rows[r].length; k++) ...[
                if (k > 0) const SizedBox(width: _gap),
                Expanded(child: rows[r][k]),
              ],
            ],
          ),
        ],
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({
    this.label,
    this.icon,
    this.semanticLabel,
    required this.onTap,
    this.onLongPress,
    this.compact = false,
  }) : assert(label != null || icon != null);
  final String? label;
  final bool compact;
  final IconData? icon;
  final String? semanticLabel;

  /// Null shows the key disabled.
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final primary = SheetColors.of(context).primary;
    final operator = compact && const {'AC', '%', '÷', '×', '−', '+', '='}
        .contains(label);
    // Operators are solid accent pills with white text, like the app's main
    // action buttons.
    final opFill = primary;
    return GlassButton(
      // Calculator keys are flat, wide pills like a phone dialer's.
      height: compact ? 38 : 56,
      // Subtler than an action button in dark mode, so a full grid of keys
      // stays calm. In light mode a translucent key vanishes into the white
      // frost, so keys are solid light grey, raised off the sheet by a soft
      // shadow, like a phone dialer's.
      fill: dark
          ? Colors.white.withValues(alpha: operator ? .11 : .06)
          : (operator ? opFill : Colors.white),
      flatFill: dark ? null : (operator ? opFill : Colors.white),
      shadow: !dark,
      foregroundColor: onTap == null
          ? SheetColors.of(context).muted.withValues(alpha: .4)
          : (operator && !dark
                ? ThemeData.estimateBrightnessForColor(primary) ==
                          Brightness.dark
                      ? Colors.white
                      : Colors.black
                : null),
      textStyle: TextStyle(
        fontSize: compact ? 22 : 28,
        fontWeight: operator ? FontWeight.w600 : FontWeight.w500,
      ),
      onPressed: onTap == null
          ? null
          : () {
              VibrationSettings.softTick();
              onTap!();
            },
      onLongPress: onLongPress == null
          ? null
          : () {
              VibrationSettings.softTick();
              onLongPress!();
            },
      child: label != null
          ? Text(label!, semanticsLabel: semanticLabel)
          : Icon(icon, semanticLabel: semanticLabel),
    );
  }
}
