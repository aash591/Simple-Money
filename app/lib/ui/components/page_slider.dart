import 'package:flutter/material.dart';

/// Steps between [pages] inside one screen with the app's left/right slide:
/// a later page comes in from the right, an earlier one from the left. The
/// current page fills the space given; reduced motion swaps instantly.
class PageSlider extends StatefulWidget {
  const PageSlider({super.key, required this.index, required this.pages});
  final int index;
  final List<Widget> pages;

  @override
  State<PageSlider> createState() => _PageSliderState();
}

class _PageSliderState extends State<PageSlider> {
  static const _duration = Duration(milliseconds: 320);
  int _direction = 1;

  @override
  void didUpdateWidget(PageSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _direction = widget.index > oldWidget.index ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : _duration;
    return ClipRect(
      child: AnimatedSwitcher(
        duration: duration,
        reverseDuration: duration,
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [...previousChildren, ?currentChild],
        ),
        transitionBuilder: (child, animation) {
          final pageIndex = (child.key! as ValueKey<int>).value;
          final begin = pageIndex == widget.index
              ? Offset(_direction.toDouble(), 0)
              : Offset(pageIndex < widget.index ? -1 : 1, 0);
          return SlideTransition(
            position: Tween<Offset>(
              begin: begin,
              end: Offset.zero,
            ).animate(animation),
            // A page on its way out still sits under the finger for the
            // length of the slide; a quick second tap must not land on it.
            // Always wrapped, so the page keeps its state as it leaves.
            child: IgnorePointer(
              ignoring: pageIndex != widget.index,
              child: child,
            ),
          );
        },
        child: KeyedSubtree(
          key: ValueKey<int>(widget.index),
          child: widget.pages[widget.index],
        ),
      ),
    );
  }
}
