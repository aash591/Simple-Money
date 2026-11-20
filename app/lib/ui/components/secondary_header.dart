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
    this.centered = false,
    this.actions = const [],
    this.titleIcon,
  });

  /// A small mark before the title, e.g. a bank or broker's logo. Only for
  /// the usual left-aligned title.
  final Widget? titleIcon;

  // Keeps secondary page titles and actions comfortably separated from content.
  static const double height = 56;

  /// Puts a round button's disc on the page margin the cards keep.
  static const _roundInset = TabHeader.sideMargin - GlassCircleButton.edgeInset;
  final String title;
  final TextStyle? titleStyle;

  /// A smaller title in the middle, for a plain sheet with nothing at its
  /// sides.
  final bool centered;
  final Widget? leading;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Three or more buttons would run under a title centred on the bar, so
    // then the title takes the room between them instead.
    if (centered &&
        (leading != null || actions.isNotEmpty) &&
        actions.length <= 2) {
      // Title truly centred on the sheet: the buttons float at the sides
      // instead of pushing the title off-centre.
      return IconTheme(
        data: IconThemeData(size: 22, color: scheme.onSurface),
        child: SizedBox(
          height: height,
          child: BackdropGroup(
            child: Stack(
              alignment: Alignment.center,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 64),
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      maxLines: 1,
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            letterSpacing: -0.3,
                            height: 1.2,
                            color: scheme.onSurface,
                          )
                          .merge(titleStyle),
                    ),
                  ),
                ),
                if (leading != null)
                  Positioned(
                    left: _roundInset,
                    child: SizedBox(width: 48, height: 48, child: leading),
                  ),
                if (actions.isNotEmpty)
                  Positioned(
                    right: _roundInset,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final action in actions)
                          GlassActionSlot(child: action),
                      ],
                    ),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    return IconTheme(
      data: IconThemeData(size: 22, color: scheme.onSurface),
      child: SizedBox(
        // A centred sheet title sits tighter under the drag handle.
        height: centered && leading == null && actions.isEmpty ? 40 : height,
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
                if (titleIcon != null) ...[
                  titleIcon!,
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title,
                      maxLines: 1,
                      textAlign: centered ? TextAlign.center : null,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleLarge
                          ?.copyWith(
                            fontSize: centered ? 17 : 22,
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
                for (final action in actions) GlassActionSlot(child: action),
                if (actions.isEmpty) const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
