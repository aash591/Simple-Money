import 'package:flutter/material.dart';

import 'app_back_button.dart';
import 'glass_blur.dart';
import 'glass_surface.dart';
import 'page_motion.dart';

import 'secondary_header.dart';

/// Opens a page with the app's one page transition (see `page_motion.dart`),
/// which the app theme sets for every page route. Being a [MaterialPageRoute], it also
/// animates the page it covers (and is animated by pages opened over it)
/// whatever kind of page route that is.
class FeatureRoute<T> extends MaterialPageRoute<T> {
  FeatureRoute(Widget page) : super(builder: (_) => page);
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
    this.titleIcon,
  });
  final String title;

  /// A small mark shown before the title (see [SecondaryHeader.titleIcon]).
  final Widget? titleIcon;
  final Widget? header;
  final bool showHeader;
  final Widget child;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final Widget? floatingActionButton;
  @override
  Widget build(BuildContext context) =>
      GlassPage(fadeContent: false, child: _scaffold(context));

  Widget _scaffold(BuildContext context) => Scaffold(
    appBar: !showHeader
        ? null
        : PreferredSize(
            preferredSize: Size.fromHeight(
              SecondaryHeader.height + (bottom?.preferredSize.height ?? 0),
            ),
            // The header moves with the content, but less far.
            child: PageMotionContent(
              travel: 0.4,
              child: SafeArea(
                bottom: false,
                // The page's body starts below the bar, never under it.
                child: OnPageBackdrop(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      header ??
                          SecondaryHeader(
                            title: title,
                            titleIcon: titleIcon,
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
            ),
          ),
    floatingActionButton: floatingActionButton,
    // The header comes in solid with the page; the content fades in.
    body: PageMotionContent(
      child: SafeArea(
        top: !showHeader,
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 620),
            child: child,
          ),
        ),
      ),
    ),
  );
}
