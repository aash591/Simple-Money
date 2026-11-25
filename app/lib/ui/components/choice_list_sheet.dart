import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderAbstractViewport;

import '../theme/sheet_colors.dart';
import 'adaptive_sheet.dart';
import 'search_field.dart';
import 'sheet_scroll_indicator.dart';

/// One row's worth of data for [showChoiceListSheet] — the icon and label
/// are pre-built by the caller (an `AppIcon` for a category/account, plain
/// text for a label) so this stays usable for any kind of choice.
class ChoiceItem<T> {
  const ChoiceItem({
    required this.value,
    required this.icon,
    required this.label,
    this.subtitle,
    this.indent = false,
    this.enabled = true,
    this.showSelectedIndicator = false,
    this.chevron = false,
    this.searchOnly = false,
  });
  final T value;

  /// Hidden until the user types a search; then it can match (shown indented
  /// under its parent). Lets a top-level list also find its subcategories.
  final bool searchOnly;

  /// Drawn inside the row's circular icon tile.
  final Widget icon;
  final String label;

  /// A quiet second line under [label] — an account's balance, say — for
  /// choices where the name alone isn't enough to decide between them.
  final String? subtitle;

  /// True for a subcategory, so it renders indented under its parent.
  final bool indent;

  /// Disabled choices remain visible but are greyed out and cannot be picked.
  final bool enabled;

  /// Shows the selected indicator without making this value selectable.
  final bool showSelectedIndicator;

  /// Shows a plain (non-rotating) chevron instead of the usual check/radio
  /// selection indicator, without changing what tapping the row does. Use
  /// for rows — e.g. a leaf subcategory — where tapping still selects and
  /// advances, but the radio-button look isn't wanted.
  final bool chevron;
}

/// The sheet used whenever picking one thing from a list — a category or
/// an account. It stacks above the sheet that opened it, at most 70% of
/// the screen tall. The current choice is tinted and carries a filled
/// check; tapping an option applies it and closes in one motion. An
/// optional last "Add …" row opens its own screen and returns what it
/// created as the choice.
Future<T?> showChoiceListSheet<T>(
  BuildContext context, {
  required String title,
  required List<ChoiceItem<T>> items,
  required T? selected,
  String? addLabel,
  Future<T?> Function(BuildContext context)? onAdd,
}) => showAdaptiveSheet<T>(
  context,
  maxHeightFactor: .7,
  builder: (_) => _ChoiceListSheet<T>(
    title: title,
    items: items,
    selected: selected,
    addLabel: addLabel,
    onAdd: onAdd,
  ),
);

class _ChoiceListSheet<T> extends StatelessWidget {
  const _ChoiceListSheet({
    required this.title,
    required this.items,
    required this.selected,
    required this.addLabel,
    required this.onAdd,
  });
  final String title;
  final List<ChoiceItem<T>> items;
  final T? selected;
  final String? addLabel;
  final Future<T?> Function(BuildContext context)? onAdd;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final canAdd = addLabel != null && onAdd != null;
    return SheetPage(
      header: SheetHeader(title),
      body: SheetCard(
        child: Column(
          children: [
            for (var i = 0; i < items.length; i++) ...[
              if (i > 0)
                Divider(
                  height: 1,
                  thickness: 1,
                  indent: items[i].indent ? 84 : 66,
                  color: colors.divider,
                ),
              _ChoiceRow(
                item: items[i],
                selected:
                    items[i].value == selected ||
                    items[i].showSelectedIndicator,
                onTap: items[i].enabled
                    ? () => Navigator.pop(context, items[i].value)
                    : null,
              ),
            ],
            if (canAdd) ...[
              if (items.isNotEmpty)
                Divider(height: 1, thickness: 1, color: colors.divider),
              ListTile(
                minTileHeight: 60,
                contentPadding: const EdgeInsets.symmetric(horizontal: 12),
                horizontalTitleGap: 12,
                leading: const SheetIconTile(icon: Icons.add_rounded),
                title: Text(
                  addLabel!,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: colors.primary,
                  ),
                ),
                onTap: () async {
                  final created = await onAdd!(context);
                  if (created != null && context.mounted) {
                    Navigator.pop(context, created);
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// A step page for picking one item right inside a multi-step sheet: the
/// same rows as [showChoiceListSheet], with the shared [SearchField] pinned
/// at the bottom. The search field only raises the keyboard once tapped.
/// Tapping a row hands its value to [onSelected] (the sheet moves on).
///
/// With [fillHeight] the page takes all the height the sheet allows, so
/// the list doesn't jump as a search narrows it; otherwise it is as tall
/// as its rows, up to that same limit, after which the list scrolls.
class ChoicePickerPage<T> extends StatefulWidget {
  const ChoicePickerPage({
    super.key,
    required this.header,
    required this.items,
    required this.selected,
    required this.onSelected,
    required this.searchHint,
    this.fillHeight = false,
    this.addLabel,
    this.onAdd,
    this.summary,
    this.heading,
  });

  /// The sheet's title bar. In a step flow it names the flow, and the step's
  /// own question goes in [heading].
  final Widget header;
  final Widget? summary;

  /// What this step asks for — "Pay from" — shown as a [SheetStepHeading]
  /// directly above the list it labels, under any [summary].
  final String? heading;
  final List<ChoiceItem<T>> items;
  final T? selected;
  final ValueChanged<T> onSelected;
  final String searchHint;
  final bool fillHeight;
  final String? addLabel;
  final Future<T?> Function(BuildContext context)? onAdd;

  @override
  State<ChoicePickerPage<T>> createState() => _ChoicePickerPageState<T>();
}

class _ChoicePickerPageState<T> extends State<ChoicePickerPage<T>> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _scroll = ScrollController();
  final _listKey = GlobalKey();

  /// While searching, the list is scrolled up to the top so the summary and
  /// heading give their room to it above the keyboard — until the person
  /// scrolls it themselves.
  bool _followList = false;

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(() {
      _followList = _searchFocus.hasFocus;
      if (_followList) _revealList(animate: true);
    });
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// Scrolls so the list's card sits at the top of the visible area, as far
  /// as the content allows.
  void _revealList({required bool animate}) {
    final box = _listKey.currentContext?.findRenderObject();
    if (box == null || !_scroll.hasClients) return;
    final viewport = RenderAbstractViewport.maybeOf(box);
    if (viewport == null) return;
    final position = _scroll.position;
    final target = viewport
        .getOffsetToReveal(box, 0)
        .offset
        .clamp(position.minScrollExtent, position.maxScrollExtent);
    if ((target - position.pixels).abs() < .5) return;
    if (animate) {
      _scroll.animateTo(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    } else {
      _scroll.jumpTo(target);
    }
  }

  /// A drag by the person hands the list back to them.
  bool _onScroll(ScrollNotification notification) {
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _followList = false;
    }
    return false;
  }

  /// Keeps each top-level item together with its indented children: a
  /// group whose parent matches shows whole, otherwise only its matching
  /// children show, under their parent for context.
  List<ChoiceItem<T>> get _visibleItems {
    final query = _search.text.trim().toLowerCase();
    if (query.isEmpty) {
      return [
        for (final item in widget.items)
          if (!item.searchOnly) item,
      ];
    }
    bool matches(ChoiceItem<T> item) =>
        item.label.toLowerCase().contains(query);
    final visible = <ChoiceItem<T>>[];
    for (final group in _blocksOf(widget.items)) {
      if (matches(group.first)) {
        visible.addAll(group);
      } else {
        final children = group.skip(1).where(matches).toList();
        if (children.isNotEmpty) visible.addAll([group.first, ...children]);
      }
    }
    return visible;
  }

  /// Groups a flat, already-visible list back into parent rows with their
  /// following indented children, so each group's children can be wrapped
  /// in one [AnimatedSize] that grows/shrinks as it expands or collapses.
  List<List<ChoiceItem<T>>> _blocksOf(List<ChoiceItem<T>> items) {
    final blocks = <List<ChoiceItem<T>>>[];
    for (var i = 0; i < items.length;) {
      final block = [items[i]];
      for (i++; i < items.length && items[i].indent; i++) {
        block.add(items[i]);
      }
      blocks.add(block);
    }
    return blocks;
  }

  Widget _row(ChoiceItem<T> item) => _ChoiceRow(
    item: item,
    selected: item.value == widget.selected || item.showSelectedIndicator,
    onTap: item.enabled ? () => widget.onSelected(item.value) : null,
  );

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    final items = _visibleItems;
    final blocks = _blocksOf(items);
    final canAdd = widget.addLabel != null && widget.onAdd != null;
    final page = Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        widget.header,
        Flexible(
          fit: widget.fillHeight ? FlexFit.tight : FlexFit.loose,
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: NotificationListener<ScrollMetricsNotification>(
              onNotification: (_) {
                // The keyboard is still sliding in: keep the list in place.
                if (_followList) _revealList(animate: false);
                return false;
              },
              child: SheetScrollIndicator(
                child: SingleChildScrollView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (widget.summary != null) ...[
                        widget.summary!,
                        const SizedBox(height: 20),
                      ],
                      if (widget.heading != null) ...[
                        SheetStepHeading(widget.heading!),
                        const SizedBox(height: 14),
                      ],
                      SheetCard(
                        key: _listKey,
                        child: Column(
                          children: [
                            if (items.isEmpty)
                              Padding(
                                padding: const EdgeInsets.all(20),
                                child: Text(
                                  'No matches',
                                  style: TextStyle(
                                    fontSize: 14,
                                    color: colors.muted,
                                  ),
                                ),
                              ),
                            for (var b = 0; b < blocks.length; b++) ...[
                              if (b > 0)
                                Divider(
                                  height: 1,
                                  thickness: 1,
                                  indent: 66,
                                  color: colors.divider,
                                ),
                              _row(blocks[b].first),
                              AnimatedSize(
                                duration: const Duration(milliseconds: 200),
                                curve: Curves.easeInOut,
                                alignment: Alignment.topCenter,
                                child: blocks[b].length == 1
                                    ? const SizedBox(width: double.infinity)
                                    : Column(
                                        children: [
                                          for (
                                            var c = 1;
                                            c < blocks[b].length;
                                            c++
                                          ) ...[
                                            Divider(
                                              height: 1,
                                              thickness: 1,
                                              indent: 84,
                                              color: colors.divider,
                                            ),
                                            _row(blocks[b][c]),
                                          ],
                                        ],
                                      ),
                              ),
                            ],
                            if (canAdd) ...[
                              Divider(
                                height: 1,
                                thickness: 1,
                                color: colors.divider,
                              ),
                              ListTile(
                                minTileHeight: 60,
                                contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12,
                                ),
                                horizontalTitleGap: 12,
                                leading: const SheetIconTile(
                                  icon: Icons.add_rounded,
                                ),
                                title: Text(
                                  widget.addLabel!,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: colors.primary,
                                  ),
                                ),
                                onTap: () async {
                                  final created = await widget.onAdd!(context);
                                  if (created != null && mounted) {
                                    widget.onSelected(created);
                                  }
                                },
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: SearchField(
            controller: _search,
            focusNode: _searchFocus,
            onChanged: (_) => setState(() {}),
            hintText: widget.searchHint,
            fillColor: colors.card,
          ),
        ),
      ],
    );
    if (!widget.fillHeight) return page;
    return LayoutBuilder(
      builder: (context, constraints) =>
          SizedBox(height: constraints.maxHeight, child: page),
    );
  }
}

class _ChoiceRow<T> extends StatelessWidget {
  const _ChoiceRow({
    required this.item,
    required this.selected,
    required this.onTap,
  });
  final ChoiceItem<T> item;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = SheetColors.of(context);
    return ListTile(
      enabled: item.enabled,
      minTileHeight: 60,
      contentPadding: EdgeInsets.only(left: item.indent ? 36 : 12, right: 16),
      horizontalTitleGap: 12,
      leading: Opacity(
        opacity: item.enabled ? 1 : .45,
        child: SheetIconTile(size: item.indent ? 36 : 42, child: item.icon),
      ),
      title: Text(
        item.label,
        style: TextStyle(
          fontSize: 15,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: item.enabled ? colors.text : colors.muted,
        ),
      ),
      subtitle: item.subtitle == null
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                item.subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 13, color: colors.muted),
              ),
            ),
      trailing: item.chevron
          ? Icon(
              Icons.chevron_right_rounded,
              size: 24,
              color: item.enabled ? colors.outline : colors.muted,
            )
          : Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked,
              size: 22,
              color: !item.enabled
                  ? colors.muted
                  : selected
                  ? colors.primary
                  : colors.outline,
            ),
      selected: selected,
      selectedTileColor: item.enabled
          ? colors.primary.withValues(alpha: .07)
          : colors.muted.withValues(alpha: .07),
      onTap: item.enabled ? onTap : null,
    );
  }
}
