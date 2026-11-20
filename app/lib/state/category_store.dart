import 'package:flutter/foundation.dart' hide Category;

import '../data/repositories/category_repository.dart';
import '../domain/category.dart';

class CategoryStore extends ChangeNotifier {
  CategoryStore(this.repository);
  final CategoryRepository repository;
  List<Category> _categories = [];
  List<Category> get categories => List.unmodifiable(_categories);
  bool loading = true;
  bool saving = false;
  String? loadError;

  /// Fills the store with [categories] without touching the database, for
  /// screens that show example data. Nothing is saved.
  void usePreview(List<Category> categories) {
    _categories = categories;
    loading = false;
    notifyListeners();
  }

  /// Only the first load shows as loading. Reloads (returning to the app,
  /// changes from another phone) keep the current list on screen and swap
  /// in the new one at once, so lists don't flicker; a reload that finishes
  /// after a newer one is dropped, and one that fails keeps the list shown.
  bool _loaded = false;
  int _generation = 0;

  Future<void> load() async {
    final generation = ++_generation;
    if (!_loaded) {
      loading = true;
      loadError = null;
      notifyListeners();
    }
    try {
      final categories = await repository.load();
      if (generation != _generation) return;
      _categories = categories;
      _loaded = true;
      loadError = null;
    } catch (_) {
      if (generation != _generation) return;
      if (!_loaded) {
        loadError = 'Your categories could not be loaded. Please try again.';
      }
    }
    loading = false;
    notifyListeners();
  }

  Future<void> save({
    Category? existing,
    required String name,
    required CategoryType type,
    String? icon,
    int? parentId,
  }) async {
    if (saving) throw StateError('A category update is already being saved.');
    saving = true;
    notifyListeners();
    try {
      await repository.save(
        existing: existing,
        name: name,
        type: type,
        icon: icon,
        parentId: parentId,
      );
      _categories = await repository.load();
    } finally {
      saving = false;
      notifyListeners();
    }
  }

  Future<void> delete(Category category) async {
    if (saving) throw StateError('A category update is already being saved.');
    saving = true;
    notifyListeners();
    try {
      await repository.delete(category.id);
      _categories = await repository.load();
    } finally {
      saving = false;
      notifyListeners();
    }
  }
}
