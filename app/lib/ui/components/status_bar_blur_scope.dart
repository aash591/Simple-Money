import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wraps a screen whose main content is a scroll view that starts right at
/// the top of the screen (no fixed app bar above it). The status bar stays
/// transparent in every theme, scrolled or not: nothing is drawn behind it.
/// Also flips the status bar icon brightness to match the current theme.
///
/// [builder] must apply the given [ScrollController] to the screen's main
/// scroll view, and should pad that view's top by at least [topInset] so
/// content starts below the status bar.
class StatusBarBlurScope extends StatefulWidget {
  const StatusBarBlurScope({super.key, required this.builder});
  final Widget Function(
    BuildContext context,
    ScrollController controller,
    double topInset,
  )
  builder;
  @override
  State<StatusBarBlurScope> createState() => _StatusBarBlurScopeState();
}

class _StatusBarBlurScopeState extends State<StatusBarBlurScope> {
  final _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final topInset = MediaQuery.paddingOf(context).top;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(
            statusBarColor: Colors.transparent,
            systemStatusBarContrastEnforced: false,
            systemNavigationBarColor: Colors.transparent,
            systemNavigationBarDividerColor: Colors.transparent,
            systemNavigationBarContrastEnforced: false,
            systemNavigationBarIconBrightness: dark
                ? Brightness.light
                : Brightness.dark,
          ),
      child: widget.builder(context, _controller, topInset),
    );
  }
}
