import 'package:flutter/material.dart';

import '../../../domain/app_icons.dart';
import '../../../domain/category.dart';
import '../../../state/category_store.dart';
import '../../components/action_buttons.dart';
import '../../components/settings_icon.dart';
import '../../components/app_toast.dart';
import '../../components/common.dart';
import '../../components/confirmation_alert.dart';
import '../../components/feature_page.dart';
import '../../components/select_icon_screen.dart';
import 'select_parent_category_screen.dart';

class EditCategoryScreen extends StatefulWidget {
  const EditCategoryScreen({
    super.key,
    required this.store,
    required this.type,
    this.category,
    this.initialParentId,
  });
  final CategoryStore store;

  /// The type new categories are created as. Ignored when editing, where
  /// the existing category's type is used instead (type never changes).
  final CategoryType type;
  final Category? category;
  final int? initialParentId;
  @override
  State<EditCategoryScreen> createState() => _EditCategoryScreenState();
}

class _EditCategoryScreenState extends State<EditCategoryScreen> {
  late final _name = TextEditingController(text: widget.category?.name ?? '');
  String? get _initialIcon => widget.category?.icon ?? defaultCategoryIcon;
  late String? _icon = _initialIcon;
  int? get _initialParentId =>
      widget.category?.parentId ?? widget.initialParentId;
  late int? _parentId = _initialParentId;
  bool _saving = false, _leaving = false, _askingToDiscard = false;
  String? _error;
  bool get _editing => widget.category != null;
  CategoryType get _type => widget.category?.type ?? widget.type;
  bool get _dirty =>
      _name.text.trim() != (widget.category?.name ?? '') ||
      _icon != _initialIcon ||
      _parentId != _initialParentId;
  bool get _valid =>
      _name.text.trim().isNotEmpty && _name.text.trim().length <= 40;

  // A category already used as a parent can't itself be nested, or the
  // hierarchy would go two levels deep.
  bool get _isParentOfOthers =>
      widget.category != null &&
      widget.store.categories.any((c) => c.parentId == widget.category!.id);

  List<Category> get _parentChoices => widget.store.categories
      .where(
        (c) =>
            c.type == _type &&
            c.parentId == null &&
            c.id != widget.category?.id,
      )
      .toList();

  Category? _findById(int? id) {
    if (id == null) return null;
    for (final c in widget.store.categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _leave() async {
    setState(() => _leaving = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.pop(context);
  }

  Future<void> _discard() async {
    if (_saving || _askingToDiscard) return;
    _askingToDiscard = true;
    final discard = await showConfirmationAlert(
      context,
      title: 'Discard changes?',
      message: 'Your unsaved category details will be lost.',
      cancelLabel: 'Keep editing',
      confirmLabel: 'Discard',
    );
    _askingToDiscard = false;
    if (discard && mounted) await _leave();
  }

  Future<void> _delete() async {
    if (_saving) return;
    final childCount = widget.store.categories
        .where((c) => c.parentId == widget.category!.id)
        .length;
    final confirmed = await showDeleteConfirmation(
      context,
      title: 'Delete category?',
      message: childCount > 0
          ? 'This will also delete its $childCount ${childCount == 1 ? 'subcategory' : 'subcategories'}.'
          : '“${widget.category!.name}” will be permanently deleted.',
    );
    if (!confirmed || !mounted) return;
    setState(() => _saving = true);
    try {
      await widget.store.delete(widget.category!);
      if (!mounted) return;
      showAppToast(context, 'Category deleted');
      await _leave();
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = 'Could not delete this category. Please try again.';
        });
      }
    }
  }

  Future<void> _pickParent() async {
    FocusScope.of(context).unfocus();
    final picked = await Navigator.of(context).push(
      FeatureRoute<Object?>(
        SelectParentCategoryScreen(
          choices: _parentChoices,
          selectedId: _parentId,
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _parentId = picked == noParentSentinel ? null : picked as int;
      _error = null;
    });
  }

  Future<void> _save() async {
    if (!_valid || _saving) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.save(
        existing: widget.category,
        name: _name.text.trim(),
        type: _type,
        icon: _icon,
        parentId: _parentId,
      );
      if (!mounted) return;
      showAppToast(context, _editing ? 'Category updated' : 'Category added');
      await _leave();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = e is ArgumentError
              ? e.message.toString()
              : 'Couldn’t save. Your changes are still here. Try again.';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final selectedParent = _findById(_parentId);
    return PopScope(
      canPop: _leaving || (!_dirty && !_saving),
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _discard();
      },
      child: FeaturePage(
        title: _editing ? 'Category settings' : 'Add category',
        actions: _editing
            ? [
                IconButton(
                  tooltip: 'Delete category',
                  onPressed: _saving ? null : _delete,
                  icon: const Icon(Icons.delete_outline_rounded),
                ),
              ]
            : null,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 32),
                keyboardDismissBehavior:
                    ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  MoneyCard(
                    padding: EdgeInsets.zero,
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 16, 18, 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Material(
                                color: Colors.transparent,
                                child: InkWell(
                                  customBorder: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(
                                      34 * .4,
                                    ),
                                  ),
                                  onTap: _saving
                                      ? null
                                      : () async {
                                          FocusScope.of(context).unfocus();
                                          final icon =
                                              await Navigator.of(context).push(
                                                FeatureRoute<String>(
                                                  SelectIconScreen(
                                                    selectedKey: _icon,
                                                  ),
                                                ),
                                              );
                                          if (icon != null && mounted) {
                                            setState(() => _icon = icon);
                                          }
                                        },
                                  child: SettingsIcon(_icon, size: 34),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: TextField(
                                  key: const Key('category-name'),
                                  controller: _name,
                                  enabled: !_saving,
                                  maxLength: 40,
                                  textCapitalization: TextCapitalization.words,
                                  textInputAction: TextInputAction.done,
                                  onChanged: (_) =>
                                      setState(() => _error = null),
                                  decoration: const InputDecoration(
                                    labelText: 'Category name',
                                    hintText: 'e.g. Food or Salary',
                                    filled: false,
                                    contentPadding: EdgeInsets.zero,
                                    counterText: '',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 18),
                          child: Divider(height: 24),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
                          child: Row(
                            children: [
                              const IconTile(
                                Icons.label_outline_rounded,
                                size: 34,
                              ),
                              const SizedBox(width: 12),
                              const Expanded(child: Text('Type')),
                              Text(
                                _type.label,
                                style: text.titleMedium?.copyWith(fontSize: 14),
                              ),
                            ],
                          ),
                        ),
                        if (!_isParentOfOthers) ...[
                          const Padding(
                            padding: EdgeInsets.symmetric(horizontal: 18),
                            child: Divider(height: 1),
                          ),
                          Material(
                            color: Colors.transparent,
                            child: InkWell(
                              borderRadius: const BorderRadius.vertical(
                                bottom: Radius.circular(24),
                              ),
                              onTap: _saving ? null : _pickParent,
                              child: Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  18,
                                  14,
                                  18,
                                  20,
                                ),
                                child: Row(
                                  children: [
                                    selectedParent == null
                                        ? const IconTile(
                                            Icons.horizontal_rule_rounded,
                                            size: 34,
                                          )
                                        : SettingsIcon(
                                            selectedParent.icon,
                                            size: 34,
                                          ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Parent category',
                                            style: text.bodySmall,
                                          ),
                                          const SizedBox(height: 3),
                                          Text(
                                            selectedParent?.name ??
                                                'Select category',
                                            style: text.titleMedium?.copyWith(
                                              fontSize: 15,
                                              color: selectedParent == null
                                                  ? scheme.onSurfaceVariant
                                                  : null,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Icon(
                                      Icons.chevron_right_rounded,
                                      size: 20,
                                      color: scheme.onSurfaceVariant,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_isParentOfOthers)
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Container(
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.primary
                              .withValues(alpha: .07),
                          borderRadius: BorderRadius.circular(18),
                        ),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              Icons.info_outline_rounded,
                              size: 19,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                'It has subcategories, so it can’t go under another category.',
                                style: text.bodySmall?.copyWith(
                                  height: 1.6,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 18),
                      child: Text(
                        _error!,
                        style: TextStyle(color: scheme.error),
                      ),
                    ),
                ],
              ),
            ),
            ActionButtonBar(
              padding: const EdgeInsets.fromLTRB(18, 12, 18, 16),
              secondaryLabel: 'Cancel',
              onSecondary: _saving ? null : () => Navigator.maybePop(context),
              primaryLabel: _saving
                  ? 'Saving…'
                  : _editing
                  ? 'Save changes'
                  : 'Add category',
              onPrimary: _valid && _dirty && !_saving ? _save : null,
            ),
          ],
        ),
      ),
    );
  }
}
