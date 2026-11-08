import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/statements/statement_table.dart';
import '../../../data/statements/upi_statement.dart';
import '../../../state/sync_controller.dart';
import 'statement_columns_screen.dart';
import 'statement_review_screen.dart';

/// Imports a bank's or app's Excel export: reads the workbook's first sheet,
/// then opens its columns.
Future<StatementImportResult?> readExcelStatement(
  BuildContext context,
  SyncController sync,
  Uint8List bytes,
  String fileName,
) => openStatementColumns(
  context,
  sync,
  readExcelTable(bytes),
  fileName,
  UpiStatementSource.excel,
);
