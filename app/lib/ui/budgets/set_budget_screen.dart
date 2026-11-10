import 'dart:async';

import 'package:flutter/material.dart';

import '../components/app_back_button.dart';

import 'package:intl/intl.dart';

import '../../domain/account.dart';
import '../../domain/budget.dart';
import '../../domain/category.dart';
import '../../state/budget_store.dart';
import '../../state/category_store.dart';
import '../../state/pro_controller.dart';
import '../components/action_buttons.dart';
import '../components/app_toast.dart';
import '../components/app_icon.dart';
import '../components/common.dart';
import '../components/confirmation_alert.dart';
import '../components/watch_ad.dart';
import '../components/feature_page.dart';
import '../components/number_keypad.dart';
import '../components/page_slider.dart';
import '../components/select_icon_screen.dart';
import '../components/search_field.dart';
import '../components/secondary_header.dart';
import '../components/text_entry_alert.dart';
import '../transactions/amount_typing.dart';
import '../more/pro/pro_screen.dart';
import 'budget_widgets.dart';

/// What [SetBudgetScreen] hands back after a save or a removal; it pops
/// with null when left without either.
class BudgetEditResult {
  const BudgetEditResult.saved(int this.budgetId);
  const BudgetEditResult.removed() : budgetId = null;

  /// The budget that applies from the edited month. Changing a budget's
  /// categories can replace it with a new one, so this may be a new id.
  final int? budgetId;
  bool get removed => budgetId == null;
}

/// Sets, changes, or removes one budget from [month] onward: the total, or
/// a budget over expense categories — one, or several combined
/// into a custom budget. "Add category" slides over to pick them.
class SetBudgetScreen extends StatefulWidget {
  const SetBudgetScreen({
    super.key,
    required this.budgetStore,
    required this.categoryStore,
    required this.month,
    required this.currency,
    required this.digits,
    required this.budgets,
    this.total = false,
    this.budget,
    this.initialCategoryIds = const {},
  });
  final BudgetStore budgetStore;
  final CategoryStore categoryStore;
  final DateTime month;
  final String currency;
  final int digits;

  /// What's already set for [month]: the total to pre-fill, and which
  /// categories other budgets already cover.
  final BudgetMonth budgets;

  /// True for the total monthly budget, which always covers every expense.
  final bool total;

  /// The category or custom budget being edited; null for a new one.
  final BudgetLine? budget;

  /// The categories a new budget starts with.
  final Set<int> initialCategoryIds;

  @override
  State<SetBudgetScreen> createState() => _SetBudgetScreenState();
}

class _SetBudgetScreenState extends State<SetBudgetScreen> {
  static const _amountPage = 0, _categoryPage = 1;
  static const _headerIconSize = 52.0;

  late final BudgetLine? _existing = widget.total
      ? widget.budgets.allSpending
      : widget.budget;
  late final Set<int> _initialCategories =
      widget.budget?.categoryIds.toSet() ?? widget.initialCategoryIds;
  late Set<int> _categoryIds = {..._initialCategories};
  late String? _name = widget.budget?.name;
  late String? _icon = widget.budget?.icon;
  late String _text = switch (_existing) {
    final line? => AmountTyping.fromMinor(line.limit, widget.digits),
    null => '',
  };

  /// A new budget with nothing chosen yet starts on picking categories.
  late int _page = widget.total || _categoryIds.isNotEmpty
      ? _amountPage
      : _categoryPage;

  /// The category page's ticks, applied to [_categoryIds] on Done.
  late Set<int> _picking = {..._categoryIds};
  bool _saving = false, _leaving = false, _askingToDiscard = false;
  String? _error;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  bool _searching = false;
  String _query = '';

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _cancelSearch() {
    _searchFocus.unfocus();
    setState(() {
      _searching = false;
      _query = '';
      _searchController.clear();
    });
  }

  int get _amount => parseAccountAmount(_text, widget.digits) ?? 0;
  bool get _custom => _categoryIds.length > 1;

  /// Only a custom budget keeps a name; one category is named after it.
  String? get _savedName => _custom ? _name : null;
  bool get _changed =>
      _amount != (_existing?.limit ?? 0) ||
      _categoryIds.length != _initialCategories.length ||
      !_categoryIds.every(_initialCategories.contains) ||
      _savedName != widget.budget?.name ||
      _icon != widget.budget?.icon;
  bool get _canSave =>
      _amount > 0 &&
      _changed &&
      !_saving &&
      (widget.total || _categoryIds.isNotEmpty);

  /// Expense categories and subcategories, in the category list's order.
  List<Category> get _choices => widget.categoryStore.categories
      .where((c) => c.type == CategoryType.expense)
      .toList();

  List<Category> _categoriesOf(Iterable<int> ids) {
    final wanted = ids.toSet();
    return _choices.where((c) => wanted.contains(c.id)).toList();
  }

  /// The other budget already covering [categoryId] this month, if any.
  BudgetLine? _coveredBy(int categoryId) {
    final category = _choices.firstWhere((c) => c.id == categoryId);
    final children = _choices
        .where((c) => c.parentId == categoryId)
        .map((c) => c.id);
    return widget.budgets.budgets
        .where(
          (line) =>
              line.id != widget.budget?.id &&
              line.categoryIds.any(
                (id) =>
                    id == categoryId ||
                    id == category.parentId ||
                    children.contains(id),
              ),
        )
        .firstOrNull;
  }

  void _type(String text) => setState(() {
    _text = text;
    _error = null;
  });

  Future<void> _leave([BudgetEditResult? result]) async {
    setState(() => _leaving = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context, result);
  }

  Future<void> _discard() async {
    if (_saving || _askingToDiscard) return;
    _askingToDiscard = true;
    final discard = await showConfirmationAlert(
      context,
      title: 'Discard changes?',
      message: 'Your unsaved budget will be lost.',
      cancelLabel: 'Keep editing',
      confirmLabel: 'Discard',
    );
    _askingToDiscard = false;
    if (discard && mounted) await _leave();
  }

  void _openCategories() {
    if (_saving) return;
    setState(() {
      _picking = {..._categoryIds};
      _page = _categoryPage;
      _error = null;
    });
  }

  void _closeCategories() {
    _cancelSearch();
    // With nothing chosen the page opened here, so there's nothing behind.
    if (_categoryIds.isEmpty) {
      _leave();
    } else {
      setState(() => _page = _amountPage);
    }
  }

  void _applyCategories() {
    _cancelSearch();
    setState(() {
      _categoryIds = {..._picking};
      _page = _amountPage;
    });
  }

  bool _selected(Category category) =>
      _picking.contains(category.id) || _picking.contains(category.parentId);

  void _toggle(int categoryId) => setState(() {
    final category = _choices.firstWhere((c) => c.id == categoryId);
    if (_picking.remove(categoryId)) return;
    if (_picking.remove(category.parentId)) {
      // Unchecking an included child keeps its siblings selected.
      _picking.addAll(
        _choices
            .where((c) => c.parentId == category.parentId && c.id != categoryId)
            .map((c) => c.id),
      );
    } else {
      _picking.removeAll(
        _choices.where((c) => c.parentId == categoryId).map((c) => c.id),
      );
      _picking.add(categoryId);
    }
  });

  /// A budget always keeps at least one category.
  void _removeCategory(int categoryId) {
    if (_saving || _categoryIds.length < 2) return;
    setState(() {
      _categoryIds = {..._categoryIds}..remove(categoryId);
      _error = null;
    });
  }

  Future<void> _pickIcon() async {
    if (_saving) return;
    final icon = await Navigator.of(context)
        .push(FeatureRoute<String>(SelectIconScreen(selectedKey: _icon)));
    if (icon == null || !mounted) return;
    setState(() => _icon = icon);
  }

  Future<void> _rename() async {
    if (_saving) return;
    final name = await showTextEntryAlert(
      context,
      title: 'Budget name',
      initialValue: _name ?? '',
      hintText: 'e.g. Daily spending',
      maxLength: 40,
      allowEmpty: true,
    );
    if (name == null || !mounted) return;
    setState(() {
      _name = name.isEmpty ? null : name;
      _error = null;
    });
  }

  /// True once the change is saved and the screen has closed.
  Future<bool> _write(
    String message,
    Future<BudgetEditResult> Function() write,
  ) async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final result = await write();
      if (!mounted) return true;
      showAppToast(context, message);
      await _leave(result);
      return true;
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is ArgumentError
              ? e.message.toString()
              : 'Could not save your budget. Please try again.';
        });
      }
      return false;
    }
  }

  /// A new category or custom budget without Pro: the first is free, the next ones up to
  /// [ProController.freeBudgets] each take a short ad, and past that Pro is
  /// needed. True when it may be saved.
  Future<bool> _mayAdd() async {
    // The total monthly budget is one of a kind, so it never counts.
    if (_existing != null ||
        widget.total ||
        ProController.instance.featuresUnlocked) {
      return true;
    }
    final count = widget.budgets.budgets.length;
    if (count == 0) return true;
    void openPro() =>
        Navigator.of(context).push(FeatureRoute<void>(const ProScreen()));
    if (count >= ProController.freeBudgets) {
      if (await showConfirmationAlert(
            context,
            title: '${ProController.freeBudgets} budgets is the free limit',
            message:
                'With Pro you can add as many budgets as you like, with '
                'no ads.',
            confirmLabel: 'See Pro',
            cancelLabel: 'Not now',
            destructive: false,
          ) &&
          mounted) {
        openPro();
      }
      return false;
    }
    final watch = await showConfirmationAlert(
      context,
      title: 'Watch a short ad to add this budget',
      message:
          'Budget ${count + 1} of ${ProController.freeBudgets} on the free '
          'plan. With Pro, add as many as you like, with no ads.',
      confirmLabel: 'Watch ad',
      extraActionLabel: 'Get Pro instead',
      onExtraAction: openPro,
      destructive: false,
    );
    if (!watch || !mounted) return false;
    // Offline, or the user declined: nothing is saved.
    if (!await watchAd(context)) return false;
    return mounted;
  }

  Future<void> _save() async {
    if (!await _mayAdd()) return;
    await _write(
      _existing == null ? 'Budget set' : 'Budget updated',
      () async => BudgetEditResult.saved(
        widget.total
            ? await widget.budgetStore.saveTotal(
                currency: widget.currency,
                digits: widget.digits,
                fromMonth: widget.month,
                amountMinor: _amount,
              )
            : await widget.budgetStore.save(
                budgetId: widget.budget?.id,
                categoryIds: _categoryIds,
                name: _savedName,
                icon: _icon,
                currency: widget.currency,
                digits: widget.digits,
                fromMonth: widget.month,
                amountMinor: _amount,
              ),
      ),
    );
  }

  Future<void> _remove() async {
    if (_saving) return;
    final confirmed = await showDeleteConfirmation(
      context,
      title: 'Remove budget?',
      message:
          'It stops applying from ${DateFormat.yMMMM().format(widget.month)}. Earlier months keep it.',
      confirmLabel: 'Remove',
    );
    if (confirmed && mounted) {
      await _write('Budget removed', () async {
        await widget.budgetStore.remove(_existing!.id!, widget.month);
        return const BudgetEditResult.removed();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final existing = _existing;
    final picking = _page == _categoryPage;
    return PopScope(
      canPop: _leaving || (!picking && !_changed && !_saving),
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Back from picking categories slides back instead of leaving.
        if (picking) {
          if (_searching) {
            _cancelSearch();
          } else {
            _closeCategories();
          }
        } else {
          _discard();
        }
      },
      child: FeaturePage(
        header: picking ? _buildCategoryHeader(context) : null,
        title: picking
            ? 'Choose categories'
            : existing == null
            ? 'Set budget'
            : 'Edit budget',
        actions: existing == null || picking
            ? null
            : [
                IconButton(
                  tooltip: 'Remove budget',
                  onPressed: _saving ? null : _remove,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ],
        child: PageSlider(
          index: _page,
          pages: [_buildAmountPage(context), _buildCategoryPage(context)],
        ),
      ),
    );
  }

  /// What the budget covers at the top, the amount in the middle, and the
  /// keypad low down where a thumb reaches it, just above the buttons.
  Widget _buildAmountPage(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          // Pinned low when there's room; scrolls on a short screen.
          child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
              child: ConstrainedBox(
                constraints: BoxConstraints(minHeight: constraints.maxHeight),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 0),
                      child: widget.total
                          ? _buildTotalCard(context)
                          : _buildBudgetCard(context),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 24,
                        vertical: 20,
                      ),
                      child: Column(
                        children: [
                          Text(
                            'How much per month?',
                            style: text.titleMedium,
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 10),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              AmountTyping.display(
                                _text,
                                currency: widget.currency,
                                decimals: widget.digits,
                              ),
                              style: TextStyle(
                                fontSize: 48,
                                fontWeight: FontWeight.w800,
                                letterSpacing: -1.2,
                                color: _text.isEmpty
                                    ? scheme.onSurfaceVariant.withValues(
                                        alpha: .55,
                                      )
                                    : scheme.onSurface,
                              ),
                            ),
                          ),
                          const SizedBox(height: 10),
                          _MonthPill(month: widget.month),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Text(
                              _error!,
                              textAlign: TextAlign.center,
                              style: TextStyle(color: scheme.error),
                            ),
                          ],
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18),
                      child: NumberKeypad(
                        onDigit: (digit) => _type(
                          AmountTyping.digit(_text, digit, widget.digits),
                        ),
                        onDecimalPoint: () =>
                            _type(AmountTyping.point(_text, widget.digits)),
                        onBackspace: () => _type(AmountTyping.backspace(_text)),
                        onClear: () => _type(''),
                        decimalEnabled:
                            widget.digits > 0 && !_text.contains('.'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        ActionButtonBar(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          secondaryLabel: 'Cancel',
          onSecondary: _saving ? null : () => Navigator.maybePop(context),
          primaryLabel: _saving
              ? 'Saving…'
              : _existing == null
              ? 'Set budget'
              : 'Save changes',
          onPrimary: _canSave ? _save : null,
        ),
      ],
    );
  }

  /// The total always covers every expense, so there's nothing to change.
  Widget _buildTotalCard(BuildContext context) => const MoneyCard(
    padding: EdgeInsets.zero,
    child: _BudgetHeader(
      icon: IconTile(Icons.donut_large_rounded, size: _headerIconSize),
      label: 'Covers every expense',
      title: 'Total spending',
    ),
  );

  /// The budget's icon and title, then each category it covers as a chip
  /// that can be taken out, and a chip to add more.
  Widget _buildBudgetCard(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final chosen = _categoriesOf(_categoryIds);
    final removable = chosen.length > 1 && !_saving;
    return MoneyCard(
      padding: EdgeInsets.zero,
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _BudgetHeader(
              icon: chosen.isEmpty && _icon == null
                  ? const IconTile(
                      Icons.category_outlined,
                      size: _headerIconSize,
                    )
                  : budgetIcon(chosen, icon: _icon, size: _headerIconSize),
              label: _custom ? 'Custom budget' : 'Category budget',
              title: _custom
                  ? _name ?? budgetTitle(null, chosen)
                  : budgetTitle(null, chosen),
              placeholder: _custom && _name == null,
              onIconTap: _saving ? null : _pickIcon,
              onTitleTap: _custom && !_saving ? _rename : null,
            ),
            const Divider(height: 1, indent: 16, endIndent: 16),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    chosen.length == 1
                        ? '1 category'
                        : '${chosen.length} categories',
                    style: text.bodySmall,
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final category in chosen)
                        _CategoryChip(
                          category: category,
                          onRemove: removable
                              ? () => _removeCategory(category.id)
                              : null,
                        ),
                      _AddCategoryChip(onTap: _saving ? null : _openCategories),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryPage(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final all = _choices;
    final choices = <Category>[
      for (final parent in all.where((c) => c.parentId == null))
        if (parent.name.toLowerCase().contains(_query) ||
            all.any(
              (c) =>
                  c.parentId == parent.id &&
                  c.name.toLowerCase().contains(_query),
            )) ...[
          parent,
          ...all.where(
            (c) =>
                c.parentId == parent.id &&
                (parent.name.toLowerCase().contains(_query) ||
                    c.name.toLowerCase().contains(_query)),
          ),
        ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 8, 18, 8),
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
                child: Text(
                  'Pick categories to combine. A main category includes its subcategories.',
                  style: text.bodySmall?.copyWith(height: 1.5),
                ),
              ),
              MoneyCard(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Material(
                  type: MaterialType.transparency,
                  child: Column(
                    children: [
                      if (choices.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(24),
                          child: Text('No categories found'),
                        ),
                      for (final (i, category) in choices.indexed) ...[
                        if (i > 0)
                          const Divider(height: 1, indent: 68, endIndent: 18),
                        _CategoryChoice(
                          category: category,
                          selected: _selected(category),
                          coveredBy: switch (_coveredBy(category.id)) {
                            final line? => budgetTitle(
                              line.name,
                              _categoriesOf(line.categoryIds),
                            ),
                            null => null,
                          },
                          onTap: () => _toggle(category.id),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        ActionButtonBar(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
          secondaryLabel: 'Cancel',
          onSecondary: _closeCategories,
          primaryLabel: 'Done',
          onPrimary: _picking.isEmpty ? null : _applyCategories,
        ),
      ],
    );
  }

  Widget _buildCategoryHeader(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 320);
    return SizedBox(
      height: SecondaryHeader.height,
      child: AnimatedSwitcher(
        duration: duration,
        reverseDuration: duration,
        layoutBuilder: (current, previous) => Stack(
          alignment: Alignment.topCenter,
          children: [
            ...previous.map((child) => Positioned.fill(child: child)),
            ?current,
          ],
        ),
        transitionBuilder: (child, animation) {
          final curved = CurvedAnimation(
            parent: animation,
            curve: Curves.easeInOutCubic,
          );
          if (child.key == const ValueKey('search-header')) {
            return AnimatedBuilder(
              animation: curved,
              child: child,
              builder: (context, child) => ClipRect(
                clipper: _SearchRevealClipper(curved.value),
                child: child,
              ),
            );
          }
          return FadeTransition(opacity: curved, child: child);
        },
        child: _searching
            ? Padding(
                key: const ValueKey('search-header'),
                padding: const EdgeInsets.fromLTRB(18, 4, 12, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: SearchField(
                        controller: _searchController,
                        focusNode: _searchFocus,
                        hintText: 'Search categories',
                        onChanged: (value) =>
                            setState(() => _query = value.trim().toLowerCase()),
                      ),
                    ),
                    const SizedBox(width: 6),
                    TextButton(
                      onPressed: _cancelSearch,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              )
            : SecondaryHeader(
                key: const ValueKey('normal-header'),
                title: 'Choose categories',
                leading: AppBackButton(onPressed: _closeCategories),
                actions: [
                  AppSearchButton(
                    tooltip: 'Search categories',
                    onPressed: () {
                      setState(() => _searching = true);
                      _searchFocus.requestFocus();
                    },
                  ),
                ],
              ),
      ),
    );
  }
}

class _SearchRevealClipper extends CustomClipper<Rect> {
  const _SearchRevealClipper(this.progress);
  final double progress;
  @override
  Rect getClip(Size size) => Rect.fromLTWH(
    size.width * (1 - progress),
    0,
    size.width * progress,
    size.height,
  );
  @override
  bool shouldReclip(_SearchRevealClipper oldClipper) =>
      oldClipper.progress != progress;
}

/// The budget's icon beside its title. A tappable icon wears a small edit
/// badge; a tappable title a pencil.
class _BudgetHeader extends StatelessWidget {
  const _BudgetHeader({
    required this.icon,
    required this.label,
    required this.title,
    this.placeholder = false,
    this.onIconTap,
    this.onTitleTap,
  });
  final Widget icon;
  final String label, title;

  /// True while the title is only suggested, not a name of its own.
  final bool placeholder;
  final VoidCallback? onIconTap, onTitleTap;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final titleBlock = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: text.bodySmall),
        const SizedBox(height: 2),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: text.titleLarge?.copyWith(
            fontSize: 19,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.3,
            height: 1.25,
            color: placeholder ? scheme.onSurfaceVariant : scheme.onSurface,
          ),
        ),
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 8, 12),
      child: Row(
        children: [
          if (onIconTap == null)
            Padding(padding: const EdgeInsets.all(4), child: icon)
          else
            Tooltip(
              message: 'Change icon',
              child: InkWell(
                onTap: onIconTap,
                borderRadius: BorderRadius.circular(20),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      icon,
                      Positioned(
                        right: -3,
                        bottom: -3,
                        child: Container(
                          width: 22,
                          height: 22,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.primary,
                            shape: BoxShape.circle,
                            border: Border.all(color: scheme.surface, width: 2),
                          ),
                          child: const Icon(
                            Icons.edit_rounded,
                            size: 11,
                            color: Colors.white,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: onTitleTap == null
                ? Padding(padding: const EdgeInsets.all(6), child: titleBlock)
                : InkWell(
                    onTap: onTitleTap,
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Row(
                        children: [
                          Expanded(child: titleBlock),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.edit_outlined,
                            size: 18,
                            color: scheme.onSurfaceVariant,
                          ),
                        ],
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// One category the budget covers, with an × when it can be taken out.
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.category, this.onRemove});
  final Category category;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 38,
      padding: EdgeInsetsDirectional.fromSTEB(
        6,
        0,
        onRemove == null ? 12 : 2,
        0,
      ),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          AppIcon(category.icon, size: 26),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              category.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: scheme.onSurface,
              ),
            ),
          ),
          if (onRemove != null)
            IconButton(
              tooltip: 'Remove ${category.name}',
              onPressed: onRemove,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints.tightFor(width: 32, height: 32),
              iconSize: 16,
              icon: Icon(Icons.close_rounded, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}

class _AddCategoryChip extends StatelessWidget {
  const _AddCategoryChip({required this.onTap});
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.primary.withValues(alpha: .1),
    borderRadius: BorderRadius.circular(14),
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 38,
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(10, 0, 14, 0),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.add_rounded,
                size: 18,
                color: Theme.of(context).colorScheme.primary,
              ),
              SizedBox(width: 4),
              Flexible(
                child: Text(
                  'Add category',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// When the budget starts applying; it carries on every month after.
class _MonthPill extends StatelessWidget {
  const _MonthPill({required this.month});
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.onSurface.withValues(alpha: .05),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.calendar_month_rounded,
            size: 14,
            color: scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              'From ${DateFormat.yMMMM().format(month)}, every month',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }
}

/// One category on the picking page, ticked when chosen. A category another
/// budget already covers can't be chosen and says which budget has it.
class _CategoryChoice extends StatelessWidget {
  const _CategoryChoice({
    required this.category,
    required this.selected,
    required this.coveredBy,
    required this.onTap,
  });
  final Category category;
  final bool selected;

  /// The title of the other budget covering this category, if any.
  final String? coveredBy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final available = coveredBy == null;
    return ListTile(
      minTileHeight: 60,
      contentPadding: EdgeInsets.only(
        left: category.parentId == null ? 16 : 44,
        right: 16,
      ),
      leading: Opacity(
        opacity: available ? 1 : .45,
        child: AppIcon(category.icon, size: 36),
      ),
      title: Text(
        category.name,
        style: TextStyle(
          fontSize: 15,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
          color: available ? scheme.onSurface : scheme.onSurfaceVariant,
        ),
      ),
      subtitle: available ? null : Text('In $coveredBy'),
      trailing: available
          ? Icon(
              selected
                  ? Icons.check_circle_rounded
                  : Icons.radio_button_unchecked,
              size: 22,
              color: selected
                  ? Theme.of(context).colorScheme.primary
                  : scheme.onSurfaceVariant.withValues(alpha: .45),
            )
          : null,
      enabled: available,
      selected: selected,
      selectedTileColor: Theme.of(context).colorScheme.primary
          .withValues(alpha: .07),
      onTap: onTap,
    );
  }
}
