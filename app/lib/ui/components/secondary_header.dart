import 'package:flutter/material.dart';

import 'app_back_button.dart';
import 'tab_header.dart';

/// Shared title bar for secondary pages and sheet steps.
/// Place below the safe area; the header owns its spacing and typography.
class SecondaryHeader extends StatelessWidget {
  const SecondaryHeader({
    super.key,
    required this.title,
    this.leading,
    this.titleStyle,
    this.actions = const [],
  });

  // Keeps secondary page titles and actions comfortably separated from content.
  static const double height = 56;

  /// Puts a round button's disc on the page margin the cards keep.
  static const _roundInset = TabHeader.sideMargin - GlassCircleButton.edgeInset;
  final String title;
  final TextStyle? titleStyle;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IconTheme(
      data: IconThemeData(size: 22, color: scheme.onSurface),
      child: SizedBox(
        height: height,
        child: Padding(
          padding: EdgeInsets.only(
            left: leading == null ? 4 : _roundInset,
            right: actions.isEmpty ? 4 : _roundInset,
          ),
          // The glass buttons blur what is behind them in one shared pass.
          child: BackdropGroup(
            child: Row(
              children: [
                if (leading != null)
                  SizedBox(width: 48, height: 48, child: leading),
                SizedBox(width: leading == null ? 12 : 8),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(
                            fontSize: 22,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.3,
                            height: 1.2,
                            color: scheme.onSurface,
                          )
                          .merge(titleStyle),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                for (final action in actions)
                  SizedBox(width: 48, height: 48, child: action),
                if (actions.isEmpty) const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
