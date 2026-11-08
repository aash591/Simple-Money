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

  Future<void> load() async {
    loading = true;
    loadError = null;
    notifyListeners();
    try {
      _categories = await repository.load();
    } catch (_) {
      loadError = 'Your categories could not be loaded. Please try again.';
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
