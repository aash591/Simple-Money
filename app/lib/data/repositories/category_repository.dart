import '../../domain/app_icons.dart';

import 'package:universal_bank_sms_parser/universal_bank_sms_parser.dart';
import 'package:drift/drift.dart';

import '../../domain/category.dart';
import '../db/app_database.dart';

const draftFoodCategories = {-1001: 'Swiggy', -1002: 'Zomato'};

class CategoryRepository {
  CategoryRepository(this.database);
  final AppDatabase database;

  Future<List<Category>> load({bool includeDrafts = false}) async {
    final categories =
        (await database
                .customSelect(
                  'SELECT * FROM categories ORDER BY sort_order, id',
                )
                .get())
            .map(
              (r) => Category(
                id: r.read<int>('id'),
                name: r.read<String>('name'),
                type: CategoryTypeStorage.fromStorage(r.read<String>('type')),
                icon: r.readNullable<String>('icon'),
                parentId: r.readNullable<int>('parent_id'),
              ),
            )
            .toList();
    if (!includeDrafts) return categories;
    final parent = categories
        .where(
          (c) =>
              c.type == CategoryType.expense &&
              c.parentId == null &&
              ['food', 'food & beverage'].contains(c.name.toLowerCase()),
        )
        .firstOrNull;
    if (parent == null) return categories;
    final rows = await database
        .customSelect(
          "SELECT body FROM sms_imports WHERE status='pending' AND json_extract(candidate,'\$.direction')='debit'",
        )
        .get();
    final names = rows
        .map((r) => foodDeliveryMerchant(r.readNullable<String>('body') ?? ''))
        .toSet();
    for (final entry in draftFoodCategories.entries) {
      if (names.contains(entry.value) &&
          !categories.any(
            (c) =>
                c.parentId == parent.id &&
                c.name.toLowerCase() == entry.value.toLowerCase(),
          )) {
        categories.add(
          Category(
            id: entry.key,
            name: entry.value,
            type: CategoryType.expense,
            parentId: parent.id,
            icon: brandIconKey(entry.value.toLowerCase()),
          ),
        );
      }
    }
    return categories;
  }

  Future<void> save({
    Category? existing,
    required String name,
    required CategoryType type,
    String? icon,
    int? parentId,
  }) async {
    final cleanName = name.trim();
    if (cleanName.isEmpty || cleanName.length > 40) {
      throw ArgumentError('Enter a name of 1–40 characters.');
    }
    if (parentId != null) {
      if (existing != null && parentId == existing.id) {
        throw ArgumentError('A category cannot be its own parent.');
      }
      final parent = await database
          .customSelect(
            'SELECT type, parent_id FROM categories WHERE id = ?',
            variables: [Variable(parentId)],
          )
          .getSingleOrNull();
      final parentType = existing == null ? type : existing.type;
      if (parent == null ||
          parent.read<String>('type') != parentType.storageValue ||
          parent.readNullable<int>('parent_id') != null) {
        throw ArgumentError(
          'Choose a top-level category of the same type as the parent.',
        );
      }
      if (existing != null) {
        final children = await database
            .customSelect(
              'SELECT COUNT(*) AS n FROM categories WHERE parent_id = ?',
              variables: [Variable(existing.id)],
            )
            .getSingle();
        if (children.read<int>('n') > 0) {
          throw ArgumentError(
            'This category has subcategories, so it can’t be nested under another one.',
          );
        }
      }
    }
    if (existing == null) {
      await database.customInsert(
        '''INSERT INTO categories
        (id, name, type, icon, parent_id, sort_order)
        VALUES (${newRowId('categories')}, ?, ?, ?, ?, (SELECT COALESCE(MAX(sort_order), -1) + 1 FROM categories))''',
        variables: [
          Variable(cleanName),
          Variable(type.storageValue),
          Variable(icon),
          Variable(parentId),
        ],
      );
    } else {
      await database.customUpdate(
        'UPDATE categories SET name = ?, icon = ?, parent_id = ? WHERE id = ?',
        variables: [
          Variable(cleanName),
          Variable(icon),
          Variable(parentId),
          Variable(existing.id),
        ],
      );
    }
  }

  /// Deletes [id] and, since nesting is only one level deep, every category
  /// that names it as a parent — along with their budgets.
  Future<void> delete(int id) => database.transaction(() async {
    await database.customUpdate(
      '''DELETE FROM budget_categories WHERE category_id IN
      (SELECT id FROM categories WHERE id = ? OR parent_id = ?)''',
      variables: [Variable(id), Variable(id)],
    );
    // A category or custom budget left covering nothing goes with them.
    const emptyBudgets = '''SELECT id FROM budgets WHERE kind = 'categories'
      AND id NOT IN (SELECT budget_id FROM budget_categories)''';
    await database.customUpdate(
      'DELETE FROM budget_amounts WHERE budget_id IN ($emptyBudgets)',
    );
    await database.customUpdate(
      'DELETE FROM budgets WHERE id IN ($emptyBudgets)',
    );
    await database.customUpdate(
      '''UPDATE recurring_payments SET category_id = NULL WHERE category_id IN
      (SELECT id FROM categories WHERE id = ? OR parent_id = ?)''',
      variables: [Variable(id), Variable(id)],
    );
    await database.customUpdate(
      'DELETE FROM categories WHERE id = ? OR parent_id = ?',
      variables: [Variable(id), Variable(id)],
    );
  });
}
