import 'package:simple_money/state/vibration_settings.dart';

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'frosted_modal_surface.dart';
import 'app_back_button.dart';
import 'popup_zoom.dart';

/// One action in a [MorePopupButton].
///
/// [dividerBefore] groups related actions without making callers construct
/// their own mixture of menu rows and separators.
class MorePopupItem<T> {
  const MorePopupItem({
    required this.value,
    required this.label,
    this.icon,
    this.dividerBefore = false,
  });

  final T value;
  final String label;
  final IconData? icon;
  final bool dividerBefore;
}

/// A reusable, compact overflow window that zooms out of its three-dot button.
/// The surface, shadow and reveal are all drawn in code so the menu keeps the
/// same origin and weight everywhere it is used.
class MorePopupButton<T> extends StatefulWidget {
  const MorePopupButton({
    super.key,
    required this.items,
    required this.onSelected,
    this.tooltip = 'More options',
    this.icon,
    this.fitContent = false,
  });

  final List<MorePopupItem<T>> items;
  final ValueChanged<T> onSelected;
  final String tooltip;
  final Widget? icon;

  /// Sizes the menu to its widest row instead of the usual fixed width, so a
  /// menu with one short action has no empty space beside it.
  final bool fitContent;

  @override
  State<MorePopupButton<T>> createState() => _MorePopupButtonState<T>();
}

class _MorePopupButtonState<T> extends State<MorePopupButton<T>>
    with SingleTickerProviderStateMixin {
  final _buttonKey = GlobalKey();
  final _menuKey = GlobalKey<_MorePopupOverlayState<T>>();
  late final _animation = AnimationController(
    vsync: this,
    duration: PopupZoom.duration,
    reverseDuration: PopupZoom.reverseDuration,
  );
  OverlayEntry? _entry;
  LocalHistoryEntry? _history;
  bool _closing = false;
  Offset? _pressOrigin;
  bool _dragging = false;

  void _showMenu() {
    if (_entry != null || widget.items.isEmpty) return;
    final button = _buttonKey.currentContext?.findRenderObject() as RenderBox?;
    if (button == null || !button.hasSize) return;

    final anchor = button.localToGlobal(Offset.zero) & button.size;
    // An overlay preserves the originating pointer, so a single press can
    // open the panel, scrub its rows, and release to select.
    _entry = OverlayEntry(
      builder: (overlayContext) => InheritedTheme.captureAll(
        context,
        FocusScope(
          autofocus: true,
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () => _close(),
            },
            child: Stack(
              children: [
                ModalBarrier(
                  dismissible: true,
                  onDismiss: () => _close(),
                  semanticsLabel: MaterialLocalizations.of(context)
                      .modalBarrierDismissLabel,
                ),
                _MorePopupOverlay<T>(
                  key: _menuKey,
                  anchor: anchor,
                  animation: _animation,
                  items: widget.items,
                  fitContent: widget.fitContent,
                  onSelected: (value) => _close(value),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    _history = LocalHistoryEntry(
      onRemove: () {
        _history = null;
        _close();
      },
    );
    ModalRoute.of(context)?.addLocalHistoryEntry(_history!);
    Overlay.of(context).insert(_entry!);
    _animation.forward(from: 0);
  }

  Future<void> _close([T? selected]) async {
    if (_entry == null || _closing) return;
    _closing = true;
    _history?.remove();
    _history = null;
    await _animation.reverse();
    if (!mounted) return;
    _entry?.remove();
    _entry?.dispose();
    _entry = null;
    _closing = false;
    if (selected != null) widget.onSelected(selected);
  }

  @override
  void dispose() {
    _closing = true;
    _history?.remove();
    _entry?.remove();
    _entry?.dispose();
    _animation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Listener(
    onPointerDown: (event) {
      _pressOrigin = event.position;
      _dragging = false;
      _showMenu();
    },
    onPointerMove: (event) {
      if (_pressOrigin == null) return;
      _dragging |= (event.position - _pressOrigin!).distance > 8;
      if (_dragging) _menuKey.currentState?.highlightAt(event.position);
    },
    onPointerUp: (event) {
      if (_dragging) {
        _menuKey.currentState?.highlightAt(event.position);
        _menuKey.currentState?.selectHighlighted();
      }
      _pressOrigin = null;
    },
    onPointerCancel: (_) {
      _pressOrigin = null;
      _menuKey.currentState?.clearHighlight();
    },
    // A custom icon (inside a card row, say) stays a plain icon button;
    // otherwise it's the round glass disc headers use.
    child: widget.icon == null
        ? GlassCircleButton(
            key: _buttonKey,
            label: widget.tooltip,
            // Long press is the press-and-drag gesture, not a tooltip.
            showTooltip: false,
            glyph: moreGlyph(Theme.of(context).colorScheme.onSurface),
            onPressed: _showMenu,
          )
        : Tooltip(
            message: widget.tooltip,
            triggerMode: TooltipTriggerMode.manual,
            child: IconButton(
              key: _buttonKey,
              onPressed: _showMenu,
              icon: widget.icon!,
            ),
          ),
  );
}

class _MorePopupOverlay<T> extends StatefulWidget {
  const _MorePopupOverlay({
    super.key,
    required this.anchor,
    required this.animation,
    required this.items,
    required this.onSelected,
    this.fitContent = false,
  });

  final Rect anchor;
  final Animation<double> animation;
  final List<MorePopupItem<T>> items;
  final ValueChanged<T> onSelected;
  final bool fitContent;

  @override
  State<_MorePopupOverlay<T>> createState() => _MorePopupOverlayState<T>();
}

class _MorePopupOverlayState<T> extends State<_MorePopupOverlay<T>> {
  static const _horizontalMargin = 15.0;
  static const _verticalMargin = 8.0;
  static const _preferredWidth = 180.0;
  static const _rowHeight = 50.0;
  static const _menuPadding = 12.0;
  static const _anchorGap = 8.0;
  static const _cornerRadius = 26.0;

  late final _rowKeys = List.generate(widget.items.length, (_) => GlobalKey());
  final _panelKey = GlobalKey();
  int? _highlighted;

  void clearHighlight() {
    if (_highlighted != null) setState(() => _highlighted = null);
  }

  void highlightAt(Offset position) {
    final panel = _panelKey.currentContext?.findRenderObject() as RenderBox?;
    if (panel == null) return;
    final local = panel.globalToLocal(position);
    if (!(Offset.zero & panel.size).inflate(24).contains(local)) {
      clearHighlight();
      return;
    }
    int? nearest;
    var distance = double.infinity;
    for (var i = 0; i < _rowKeys.length; i++) {
      final row = _rowKeys[i].currentContext?.findRenderObject() as RenderBox?;
      if (row == null) continue;
      final dy = (row.globalToLocal(position).dy - row.size.height / 2).abs();
      if (dy < distance) {
        distance = dy;
        nearest = i;
      }
    }
    if (nearest == _highlighted) return;
    setState(() => _highlighted = nearest);
    if (nearest != null) VibrationSettings.selectionClick();
  }

  /// The width the widest row needs: its label (and icon), plus the rows'
  /// own side padding.
  double _contentWidth(ThemeData theme, MediaQueryData media) {
    var widest = 0.0;
    for (final item in widget.items) {
      final label = TextPainter(
        text: TextSpan(
          text: item.label,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w400,
          ),
        ),
        textDirection: TextDirection.ltr,
        textScaler: media.textScaler,
        maxLines: 1,
      )..layout();
      // The icon is 20 wide with a 12 gap, when the row has one.
      widest = math.max(widest, label.width + (item.icon != null ? 32 : 0));
      label.dispose();
    }
    // 16 each side, and a pixel of slack so the label never ellipsizes.
    return (widest + 32 + 1).ceilToDouble();
  }

  void selectHighlighted() {
    final index = _highlighted;
    if (index != null) widget.onSelected(widget.items[index].value);
  }

  @override
  Widget build(BuildContext context) {
    final items = widget.items;
    final anchor = widget.anchor;
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final dark = theme.brightness == Brightness.dark;
    final foreground = dark
        ? const Color(0xfff5f6fa)
        : theme.colorScheme.onSurface;
    final divider = dark
        ? Colors.white.withValues(alpha: .12)
        : theme.colorScheme.onSurface.withValues(alpha: .10);
    final radius = BorderRadius.circular(_cornerRadius);
    final dividerCount = items.where((item) => item.dividerBefore).length;
    final estimatedHeight =
        _menuPadding + (items.length * _rowHeight) + dividerCount;
    final safeTop = media.padding.top + _verticalMargin;
    final safeBottom =
        media.size.height - media.padding.bottom - _verticalMargin;
    final spaceBelow = safeBottom - anchor.bottom - _anchorGap;
    final spaceAbove = anchor.top - safeTop - _anchorGap;
    final opensBelow =
        estimatedHeight <= spaceBelow || spaceBelow >= spaceAbove;
    final widestAllowed = math.min(
      _preferredWidth,
      media.size.width - (_horizontalMargin * 2),
    );
    final menuWidth = widget.fitContent
        ? math.min(_contentWidth(theme, media), widestAllowed)
        : widestAllowed;
    final left = (anchor.right - menuWidth).clamp(
      _horizontalMargin,
      media.size.width - menuWidth - _horizontalMargin,
    );
    final right = media.size.width - left - menuWidth;
    final verticalPosition = opensBelow
        ? math.min(anchor.bottom + _anchorGap, safeBottom - estimatedHeight)
        : math.min(
            media.size.height - anchor.top + _anchorGap,
            media.size.height - safeTop - estimatedHeight,
          );

    return Stack(
      children: [
        Positioned(
          right: right,
          top: opensBelow ? verticalPosition : null,
          bottom: opensBelow ? null : verticalPosition,
          child: PopupZoom(
            animation: widget.animation,
            alignment: opensBelow ? Alignment.topRight : Alignment.bottomRight,
            child: SizedBox(
              key: _panelKey,
              width: menuWidth,
              child: FrostedModalSurface(
                borderRadius: radius,
                blurSigma: 16,
                shadows: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: dark ? .4 : .12),
                    blurRadius: 24,
                    spreadRadius: -4,
                    offset: const Offset(0, 6),
                  ),
                ],
                child: Listener(
                  behavior: HitTestBehavior.opaque,
                  onPointerDown: (event) => highlightAt(event.position),
                  onPointerMove: (event) => highlightAt(event.position),
                  onPointerUp: (event) {
                    highlightAt(event.position);
                    selectHighlighted();
                  },
                  onPointerCancel: (_) => clearHighlight(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      vertical: _menuPadding / 2,
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var index = 0; index < items.length; index++) ...[
                          if (items[index].dividerBefore)
                            Divider(
                              height: 1,
                              thickness: 1,
                              indent: 14,
                              endIndent: 14,
                              color: divider,
                            ),
                          Semantics(
                            button: true,
                            onTap: () => widget.onSelected(items[index].value),
                            child: InkWell(
                              onTap: () =>
                                  widget.onSelected(items[index].value),
                              splashFactory: NoSplash.splashFactory,
                              highlightColor: Colors.transparent,
                              child: ColoredBox(
                                color: _highlighted == index
                                    ? foreground.withValues(
                                        alpha: dark ? .12 : .07,
                                      )
                                    : Colors.transparent,
                                child: SizedBox(
                                  key: _rowKeys[index],
                                  height: _rowHeight,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    child: Row(
                                      children: [
                                        if (items[index].icon != null) ...[
                                          Icon(
                                            items[index].icon,
                                            size: 20,
                                            color: foreground.withValues(
                                              alpha: .78,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                        ],
                                        Expanded(
                                          child: Text(
                                            items[index].label,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: theme.textTheme.bodyMedium
                                                ?.copyWith(
                                                  color: foreground,
                                                  fontWeight: FontWeight.w400,
                                                ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
