import 'package:flutter/material.dart';

/// Native-currency cards that size themselves to their content and text scale.
class CurrencySummaryCarousel extends StatefulWidget {
  const CurrencySummaryCarousel({
    super.key,
    required this.children,
    required this.selectedIndex,
    required this.onChanged,
  });

  final List<Widget> children;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  @override
  State<CurrencySummaryCarousel> createState() =>
      _CurrencySummaryCarouselState();
}

class _CurrencySummaryCarouselState extends State<CurrencySummaryCarousel> {
  late final ScrollController _controller;
  double _width = 0;

  @override
  void initState() {
    super.initState();
    _controller = ScrollController();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _moveTo(int index) {
    _controller.animateTo(
      index * _width,
      duration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
    );
  }

  @override
  void didUpdateWidget(CurrencySummaryCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedIndex != widget.selectedIndex) _syncPosition();
  }

  void _syncPosition() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controller.hasClients) return;
      final target = widget.selectedIndex * _width;
      if ((_controller.offset - target).abs() > .5) {
        _controller.jumpTo(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_width != constraints.maxWidth) {
          _width = constraints.maxWidth;
          _syncPosition();
        }
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NotificationListener<ScrollEndNotification>(
              onNotification: (notification) {
                if (notification.depth != 0) return false;
                final index = (_controller.offset / _width).round().clamp(
                  0,
                  widget.children.length - 1,
                );
                if (index != widget.selectedIndex) widget.onChanged(index);
                return false;
              },
              child: SingleChildScrollView(
                key: const Key('transaction-currency-summary'),
                controller: _controller,
                scrollDirection: Axis.horizontal,
                physics: const PageScrollPhysics(
                  parent: ClampingScrollPhysics(),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (var i = 0; i < widget.children.length; i++)
                      SizedBox(
                        width: _width,
                        child: ExcludeSemantics(
                          excluding: i != widget.selectedIndex,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 2),
                            child: widget.children[i],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            Semantics(
              label: 'Summary currency',
              value: '${widget.selectedIndex + 1} of ${widget.children.length}',
              increasedValue: widget.selectedIndex < widget.children.length - 1
                  ? '${widget.selectedIndex + 2} of ${widget.children.length}'
                  : null,
              decreasedValue: widget.selectedIndex > 0
                  ? '${widget.selectedIndex} of ${widget.children.length}'
                  : null,
              onIncrease: widget.selectedIndex < widget.children.length - 1
                  ? () => _moveTo(widget.selectedIndex + 1)
                  : null,
              onDecrease: widget.selectedIndex > 0
                  ? () => _moveTo(widget.selectedIndex - 1)
                  : null,
              child: AnimatedBuilder(
                animation: _controller,
                builder: (context, _) {
                  final page = _controller.hasClients && _width > 0
                      ? _controller.offset / _width
                      : widget.selectedIndex.toDouble();
                  return Container(
                    key: const Key('currency-scroll-indicator'),
                    width: 64,
                    height: 4,
                    decoration: BoxDecoration(
                      color: scheme.onSurface.withValues(alpha: .10),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Align(
                      alignment: AlignmentDirectional(
                        -1 +
                            2 *
                                (page / (widget.children.length - 1)).clamp(
                                  0,
                                  1,
                                ),
                        0,
                      ),
                      child: Container(
                        width: 64 / widget.children.length,
                        decoration: BoxDecoration(
                          color: scheme.primary,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}
