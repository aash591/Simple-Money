import 'package:flutter/material.dart';

import 'app_back_button.dart';
import 'glass_surface.dart';

import 'secondary_header.dart';

/// Both pages slide together; reduced-motion settings skip the transition.
class FeatureRoute<T> extends PageRouteBuilder<T> {
  FeatureRoute(Widget page)
    : super(
        transitionDuration: const Duration(milliseconds: 320),
        reverseTransitionDuration: const Duration(milliseconds: 280),
        pageBuilder: (_, animation, secondaryAnimation) => page,
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          if (MediaQuery.disableAnimationsOf(context)) return child;
          return SlideTransition(
            position: Tween(begin: Offset.zero, end: const Offset(-1, 0))
                .animate(
                  CurvedAnimation(
                    parent: secondaryAnimation,
                    curve: Curves.easeInOutCubic,
                  ),
                ),
            child: SlideTransition(
              position: Tween(begin: const Offset(1, 0), end: Offset.zero)
                  .animate(
                    CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeInOutCubic,
                    ),
                  ),
              child: child,
            ),
          );
        },
      );
}

class FeaturePage extends StatelessWidget {
  const FeaturePage({
    super.key,
    required this.title,
    required this.child,
    this.actions,
    this.bottom,
    this.floatingActionButton,
    this.header,
    this.showHeader = true,
  });
  final String title;
  final Widget? header;
  final bool showHeader;
  final Widget child;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final Widget? floatingActionButton;
  @override
  Widget build(BuildContext context) => GlassPage(child: _scaffold(context));

  Widget _scaffold(BuildContext context) => Scaffold(
    appBar: !showHeader
        ? null
        : PreferredSize(
            preferredSize: Size.fromHeight(
              SecondaryHeader.height + (bottom?.preferredSize.height ?? 0),
            ),
            child: SafeArea(
              bottom: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  header ??
                      SecondaryHeader(
                        title: title,
                        leading: Navigator.of(context).canPop()
                            ? const AppBackButton()
                            : null,
                        actions: actions ?? const [],
                      ),
                  ?bottom,
                ],
              ),
            ),
          ),
    floatingActionButton: floatingActionButton,
    body: SafeArea(
      top: !showHeader,
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 620),
          child: child,
        ),
      ),
    ),
  );
}
