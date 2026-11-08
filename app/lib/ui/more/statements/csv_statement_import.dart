import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/statements/statement_table.dart';
import '../../../data/statements/upi_statement.dart';
import '../../../state/sync_controller.dart';
import 'statement_columns_screen.dart';
import 'statement_review_screen.dart';

/// Imports a bank's or app's CSV export: reads it in whatever encoding and
/// separator it was saved with, then opens its columns.
Future<StatementImportResult?> readCsvStatement(
  BuildContext context,
  SyncController sync,
  Uint8List bytes,
  String fileName,
) => openStatementColumns(
  context,
  sync,
  readCsvTable(bytes),
  fileName,
  UpiStatementSource.csv,
);
