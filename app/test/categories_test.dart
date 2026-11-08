import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/data/db/app_database.dart';
import 'package:simple_money/data/db/default_categories.dart';
import 'package:simple_money/data/repositories/category_repository.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/state/category_store.dart';

void main() {
  test('A fresh install seeds default categories, with subcategories nested one level deep', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = CategoryRepository(db);
    try {
      final categories = await repo.load();
      final expectedCount = defaultCategoryGroups
          .expand((g) => g.categories)
          .fold<int>(0, (n, c) => n + 1 + c.children.length);
      expect(categories, hasLength(expectedCount));

      final foodAndBeverage = categories.firstWhere(
        (c) => c.name == 'Food & Beverage',
      );
      expect(foodAndBeverage.type, CategoryType.expense);
      expect(foodAndBeverage.parentId, isNull);
      final foodChildren = categories
          .where((c) => c.parentId == foodAndBeverage.id)
          .map((c) => c.name);
      expect(
        foodChildren,
        containsAll(['Restaurants', 'Groceries', 'Fruits', 'Cafe']),
      );

      final fruits = categories.firstWhere((c) => c.name == 'Fruits');
      expect(fruits.icon, 'fruits');

      final charity = categories.firstWhere((c) => c.name == 'Charity');
      expect(charity.icon, 'charity');

      final shopping = categories.firstWhere((c) => c.name == 'Shopping');
      final shoppingChildren = categories
          .where((c) => c.parentId == shopping.id)
          .map((c) => c.name);
      expect(
        shoppingChildren,
        containsAll(['Electronics', 'Footwear', 'Accessories']),
      );

      final friendsAndLove = categories.firstWhere(
        (c) => c.name == 'Friends & Love',
      );
      expect(
        categories
            .where((c) => c.parentId == friendsAndLove.id)
            .map((c) => c.name),
        containsAll(['Friends', 'Partner', 'Dates']),
      );

      final insurance = categories.firstWhere((c) => c.name == 'Insurance');
      expect(
        categories.where((c) => c.parentId == insurance.id).map((c) => c.name),
        containsAll([
          'Health Insurance',
          'Vehicle Insurance',
          'Home Insurance',
          'Life Insurance',
        ]),
      );

      final salary = categories.firstWhere((c) => c.name == 'Salary');
      expect(salary.icon, 'salary');
      expect(
        categories.where((c) => c.parentId == salary.id).map((c) => c.name),
        contains('Bonus'),
      );

      final otherExpense = categories.firstWhere(
        (c) => c.name == 'Other Expense',
      );
      expect(categories.where((c) => c.parentId == otherExpense.id), isEmpty);

      // Debt/loan categories are all flat, matching the mockup reference.
      final debtLoan = categories.where((c) => c.type == CategoryType.debtLoan);
      expect(
        debtLoan,
        everyElement(predicate<Category>((c) => c.parentId == null)),
      );
    } finally {
      await db.close();
    }
  });

  test('Expanded icon categories are added idempotently on upgrade', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = CategoryRepository(db);
    try {
      await repo.load();
      await db.customStatement(
        "DELETE FROM categories WHERE lower(trim(name)) IN ('fruits','charity')",
      );
      await db.customStatement(
        "UPDATE categories SET icon='income_one' WHERE name='Salary' AND type='income'",
      );
      await db.customStatement(
        "UPDATE categories SET icon='wallet_one' WHERE name='Personal'",
      );

      await db.seedNewIconCategories();
      await db.seedNewIconCategories();

      final categories = await repo.load();
      expect(categories.where((c) => c.name == 'Fruits'), hasLength(1));
      expect(categories.where((c) => c.name == 'Charity'), hasLength(1));
      expect(categories.firstWhere((c) => c.name == 'Fruits').icon, 'fruits');
      expect(categories.firstWhere((c) => c.name == 'Charity').icon, 'charity');
      expect(categories.firstWhere((c) => c.name == 'Salary').icon, 'salary');
      expect(
        categories.where((c) => c.name == 'Personal'),
        everyElement(predicate<Category>((c) => c.icon == 'person')),
      );
    } finally {
      await db.close();
    }
  });

  test('Deleting a category cascades to its subcategories but leaves other categories intact', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = CategoryRepository(db);
    try {
      final before = await repo.load();
      final foodAndBeverage = before.firstWhere(
        (c) => c.name == 'Food & Beverage',
      );
      final salary = before.firstWhere((c) => c.name == 'Salary');
      final foodChildCount = before
          .where((c) => c.parentId == foodAndBeverage.id)
          .length;

      await repo.delete(foodAndBeverage.id);
      final after = await repo.load();
      expect(after, hasLength(before.length - 1 - foodChildCount));
      expect(after.where((c) => c.id == foodAndBeverage.id), isEmpty);
      expect(after.where((c) => c.parentId == foodAndBeverage.id), isEmpty);
      expect(after.where((c) => c.id == salary.id), hasLength(1));

      final salaryChildCount = after
          .where((c) => c.parentId == salary.id)
          .length;
      // Deleting a parent removes its children and is a no-op elsewhere.
      await repo.delete(salary.id);
      final afterSalary = await repo.load();
      expect(afterSalary, hasLength(after.length - 1 - salaryChildCount));
    } finally {
      await db.close();
    }
  });

  test(
    'Categories, subcategories and edits survive a database close and reopen',
    () async {
      final dir = await Directory.systemTemp.createTemp('simple_money_test_');
      final file = File('${dir.path}/categories.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      try {
        var repo = CategoryRepository(db);
        final seeded = (await repo.load()).length;
        await repo.save(name: 'Food', type: CategoryType.expense);
        await repo.save(name: 'Pets', type: CategoryType.income);
        var categories = await repo.load();
        expect(categories, hasLength(seeded + 2));
        final food = categories.firstWhere((c) => c.name == 'Food');
        await repo.save(
          name: 'Snacks',
          type: CategoryType.expense,
          parentId: food.id,
        );
        categories = await repo.load();
        final snacks = categories.firstWhere((c) => c.name == 'Snacks');
        expect(snacks.parentId, food.id);
        await repo.save(
          existing: snacks,
          name: 'Weekly snacks',
          type: CategoryType.expense,
          parentId: food.id,
        );
        await db.close();
        db = AppDatabase(NativeDatabase(file));
        repo = CategoryRepository(db);
        categories = await repo.load();
        expect(categories, hasLength(seeded + 3));
        expect(categories.map((c) => c.name), contains('Weekly snacks'));
        expect(
          categories.firstWhere((c) => c.name == 'Weekly snacks').parentId,
          categories.firstWhere((c) => c.name == 'Food').id,
        );
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );

  test('A category cannot be nested under itself, a subcategory, or a category of a different type', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = CategoryRepository(db);
    try {
      await repo.save(name: 'Food', type: CategoryType.expense);
      await repo.save(name: 'Wages', type: CategoryType.income);
      var categories = await repo.load();
      final food = categories.firstWhere((c) => c.name == 'Food');
      final wages = categories.firstWhere((c) => c.name == 'Wages');

      await expectLater(
        repo.save(
          existing: food,
          name: 'Food',
          type: CategoryType.expense,
          parentId: food.id,
        ),
        throwsArgumentError,
      );
      await expectLater(
        repo.save(
          name: 'Snacks',
          type: CategoryType.expense,
          parentId: wages.id,
        ),
        throwsArgumentError,
      );

      await repo.save(
        name: 'Groceries',
        type: CategoryType.expense,
        parentId: food.id,
      );
      categories = await repo.load();
      final groceries = categories.firstWhere((c) => c.name == 'Groceries');
      await expectLater(
        repo.save(
          name: 'Sub-sub',
          type: CategoryType.expense,
          parentId: groceries.id,
        ),
        throwsArgumentError,
      );
      await expectLater(
        repo.save(
          existing: food,
          name: 'Food',
          type: CategoryType.expense,
          parentId: wages.id,
        ),
        throwsArgumentError,
      );
      await expectLater(
        repo.save(name: '', type: CategoryType.expense),
        throwsArgumentError,
      );
    } finally {
      await db.close();
    }
  });

  test('Upgrading a pre-categories (v3) database preserves existing accounts and adds an empty categories table', () async {
    final dir = await Directory.systemTemp.createTemp('simple_money_test_');
    final file = File('${dir.path}/categories.sqlite');
    try {
      final legacy = _LegacyDatabase(NativeDatabase(file));
      await legacy.customStatement('''
          CREATE TABLE accounts (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL,
            currency TEXT NOT NULL,
            territory TEXT,
            icon TEXT,
            digits INTEGER NOT NULL,
            balance_minor INTEGER NOT NULL,
            transaction_count INTEGER NOT NULL DEFAULT 0,
            sort_order INTEGER NOT NULL
          )
        ''');
      await legacy.close();

      // An upgrading install must NOT get default categories seeded — only
      // a genuinely fresh install does (see AppDatabase's `onCreate`).
      final db = AppDatabase(NativeDatabase(file));
      final repo = CategoryRepository(db);
      try {
        expect(await repo.load(), isEmpty);
        await repo.save(name: 'Food', type: CategoryType.expense);
        expect(await repo.load(), hasLength(1));
      } finally {
        await db.close();
      }
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('CategoryStore reloads after a save/delete and reports save-in-progress reentrancy', () async {
    final db = AppDatabase(NativeDatabase.memory());
    final repo = CategoryRepository(db);
    final store = CategoryStore(repo);
    try {
      await store.load();
      final seeded = store.categories.length;
      final saveFuture = store.save(
        name: 'Board games',
        type: CategoryType.expense,
      );
      expect(store.saving, isTrue);
      await expectLater(
        store.save(name: 'Rent', type: CategoryType.expense),
        throwsStateError,
      );
      await saveFuture;
      expect(store.categories, hasLength(seeded + 1));
      final added = store.categories.firstWhere((c) => c.name == 'Board games');
      expect(store.saving, isFalse);

      await store.delete(added);
      expect(store.categories, hasLength(seeded));
      expect(store.categories.where((c) => c.name == 'Board games'), isEmpty);
    } finally {
      store.dispose();
      await db.close();
    }
  });
}

/// The schema shipped before the `categories` table existed, used to seed a
/// fixture that exercises [AppDatabase]'s real v3 -> v4 upgrade path.
class _LegacyDatabase extends GeneratedDatabase {
  _LegacyDatabase(super.executor);
  @override
  int get schemaVersion => 3;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy();
}
