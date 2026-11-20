import 'package:flutter/material.dart';

import '../components/app_back_button.dart';

import '../components/secondary_header.dart';

/// Shared chrome for every money-entry flow: a back/cancel icon, a
/// content-sized sliding step body, and the current step's footer action.
class StepSheetScaffold extends StatefulWidget {
  const StepSheetScaffold({
    super.key,
    required this.currentIndex,
    required this.onBack,
    required this.pages,
    required this.footer,
    this.title,
    this.footerPadding = const EdgeInsets.fromLTRB(20, 8, 20, 16),
  });

  final int currentIndex;

  /// Pops the sheet at the first step, otherwise steps back one page.
  final VoidCallback onBack;
  final List<Widget> pages;
  final Widget footer;
  final String? title;
  final EdgeInsetsGeometry footerPadding;

  @override
  State<StepSheetScaffold> createState() => _StepSheetScaffoldState();
}

class _StepSheetScaffoldState extends State<StepSheetScaffold> {
  static const _duration = Duration(milliseconds: 320);
  int _direction = 1;

  @override
  void didUpdateWidget(StepSheetScaffold oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentIndex != widget.currentIndex) {
      _direction = widget.currentIndex > oldWidget.currentIndex ? 1 : -1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final maxHeight =
        (media.size.height - media.padding.top - media.viewInsets.bottom) * .94;

    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SecondaryHeader(
                title: widget.title ?? '',
                centered: true,
                leading: AppBackButton(
                  close: widget.currentIndex == 0,
                  onPressed: widget.onBack,
                ),
              ),
              Flexible(
                fit: FlexFit.loose,
                child: ClipRect(
                  child: AnimatedSize(
                    duration: _duration,
                    curve: Curves.easeInOutCubic,
                    alignment: Alignment.topCenter,
                    child: AnimatedSwitcher(
                      duration: _duration,
                      reverseDuration: _duration,
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      layoutBuilder: (currentChild, previousChildren) => Stack(
                        alignment: Alignment.topCenter,
                        children: [
                          for (final child in previousChildren)
                            Positioned(left: 0, top: 0, right: 0, child: child),
                          ?currentChild,
                        ],
                      ),
                      transitionBuilder: (child, animation) {
                        final pageIndex = (child.key! as ValueKey<int>).value;
                        final begin = pageIndex == widget.currentIndex
                            ? Offset(_direction.toDouble(), 0)
                            : Offset(
                                pageIndex < widget.currentIndex ? -1 : 1,
                                0,
                              );
                        return SlideTransition(
                          position: Tween<Offset>(
                            begin: begin,
                            end: Offset.zero,
                          ).animate(animation),
                          child: child,
                        );
                      },
                      child: KeyedSubtree(
                        key: ValueKey<int>(widget.currentIndex),
                        child: widget.pages[widget.currentIndex],
                      ),
                    ),
                  ),
                ),
              ),
              Padding(padding: widget.footerPadding, child: widget.footer),
            ],
          ),
        ),
      ),
    );
  }
}
