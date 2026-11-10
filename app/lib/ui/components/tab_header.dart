import 'package:flutter/material.dart';

import 'app_back_button.dart';

/// The one-line title bar at the top of a main tab, sized and placed exactly
/// like Home's (see HomeHeader): a 24dp title in a 48dp row, its text 4dp in
/// from the page margin, and [actions] as 44dp square icon buttons at the
/// end. The tab's page supplies the 18dp side margin.
class TabHeader extends StatelessWidget {
  const TabHeader({
    super.key,
    required this.title,
    this.actions = const [],
    this.roundActions = false,
    this.trailing,
    this.leading,
  });
  final String title;

  /// A back button when the tab's page is pushed on top of another.
  final Widget? leading;
  final List<Widget> actions;

  /// A wider control at the end, such as a [GlassPillButton] month picker,
  /// laid out as is rather than in an action's square.
  final Widget? trailing;

  /// The [actions] are [GlassCircleButton]s: the last disc, rather than its
  /// tap square, ends on the page margin.
  final bool roundActions;

  /// The page margin the header sits within.
  static const sideMargin = 18.0;

  @override
  Widget build(BuildContext context) => IconButtonTheme(
    data: IconButtonThemeData(
      style: IconButton.styleFrom(
        fixedSize: const Size(44, 44),
        minimumSize: const Size(44, 44),
        padding: EdgeInsets.zero,
      ),
    ),
    child: SizedBox(
      height: 48,
      child: Row(
        children: [
          ?leading,
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    fontSize: 24,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.5,
                    height: 1.2,
                  ),
                ),
              ),
            ),
          ),
          if (roundActions)
            Transform.translate(
              offset: const Offset(GlassCircleButton.edgeInset, 0),
              child: Row(mainAxisSize: MainAxisSize.min, children: actions),
            )
          else
            for (final a in actions) GlassActionSlot(child: a),
          if (trailing != null)
            Transform.translate(
              offset: const Offset(GlassCircleButton.edgeInset, 0),
              child: Padding(
                padding: const EdgeInsets.only(left: 8),
                child: trailing,
              ),
            ),
        ],
      ),
    ),
  );
}
