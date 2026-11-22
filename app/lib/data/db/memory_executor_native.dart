import 'package:drift/drift.dart';
import 'package:drift/native.dart';

/// A throwaway in-memory database, used for the home layout preview.
QueryExecutor memoryExecutor() => NativeDatabase.memory();
