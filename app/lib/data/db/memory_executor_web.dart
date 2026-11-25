import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';
import 'package:sqlite3/wasm.dart';

/// A throwaway in-memory database, used for the home layout preview.
QueryExecutor memoryExecutor() => LazyDatabase(() async {
  final sqlite3 = await WasmSqlite3.loadFromUrl(Uri.parse('sqlite3.wasm'));
  return WasmDatabase.inMemory(sqlite3);
});
