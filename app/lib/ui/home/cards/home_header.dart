import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../components/app_back_button.dart';
import '../../components/app_toast.dart';

ThemeMode _nextThemeMode(ThemeMode mode) => switch (mode) {
  ThemeMode.light => ThemeMode.dark,
  ThemeMode.dark => ThemeMode.system,
  ThemeMode.system => ThemeMode.light,
};

IconData _themeModeIcon(ThemeMode mode) => switch (mode) {
  ThemeMode.light => Icons.light_mode_outlined,
  ThemeMode.dark => Icons.dark_mode_outlined,
  ThemeMode.system => Icons.contrast_rounded,
};

String _themeModeLabel(ThemeMode mode) => switch (mode) {
  ThemeMode.light => 'Light mode',
  ThemeMode.dark => 'Dark mode',
  ThemeMode.system => 'System default',
};

/// Home's one-line header: the month it is showing as the title (tap to pick
/// another), then its transactions and a button cycling light, dark and
/// system.
class HomeHeader extends StatelessWidget {
  const HomeHeader({
    super.key,
    required this.month,
    required this.anchorKey,
    required this.picking,
    required this.onPickMonth,
    required this.onOpenTransactions,
    required this.themeMode,
    required this.onChangeThemeMode,
  });
  final DateTime month;

  /// Where the month picker popup anchors.
  final GlobalKey anchorKey;

  /// Whether the picker is open, which flips the arrow.
  final bool picking;
  final VoidCallback onPickMonth;
  final VoidCallback onOpenTransactions;
  final ValueListenable<ThemeMode> themeMode;
  final ValueChanged<ThemeMode> onChangeThemeMode;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    const buttonSize = BoxConstraints.tightFor(width: 44, height: 44);
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: anchorKey,
              onPressed: onPickMonth,
              style: TextButton.styleFrom(
                foregroundColor: colors.onSurface,
                padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
                minimumSize: const Size(0, 48),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      DateFormat.yMMMM().format(month),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.headlineMedium
                          ?.copyWith(
                            fontSize: 24,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.5,
                            height: 1.2,
                          ),
                    ),
                  ),
                  const SizedBox(width: 2),
                  Icon(
                    picking
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 24,
                    color: colors.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
        ),
        GlassActionSlot(
          child: IconButton(
            tooltip: 'View month transactions',
            onPressed: onOpenTransactions,
            icon: const Icon(Icons.format_list_bulleted_rounded),
            constraints: buttonSize,
            padding: EdgeInsets.zero,
          ),
        ),
        ValueListenableBuilder<ThemeMode>(
          valueListenable: themeMode,
          builder: (context, mode, _) => GlassActionSlot(
            child: IconButton(
              tooltip: 'Theme: ${_themeModeLabel(mode)}',
              onPressed: () {
                final next = _nextThemeMode(mode);
                onChangeThemeMode(next);
                showAppToast(
                  context,
                  _themeModeLabel(next),
                  icon: _themeModeIcon(next),
                );
              },
              icon: Icon(_themeModeIcon(mode)),
              constraints: buttonSize,
              padding: EdgeInsets.zero,
            ),
          ),
        ),
      ],
    );
  }
}
