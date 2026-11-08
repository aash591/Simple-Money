import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/statements/pdf_table.dart';
import '../../../data/statements/pdf_text.dart';
import '../../../data/statements/upi_statement.dart';
import '../../../state/sync_controller.dart';
import '../../components/app_toast.dart';
import '../../components/feature_page.dart';
import '../../components/text_entry_alert.dart';
import 'statement_columns_screen.dart';
import 'statement_review_screen.dart';

/// A PDF read as a statement: a UPI app's or a known bank's [statement], or
/// a bank's own layout rebuilt as a [table] from where its words sit.
/// [scanned] when it has no text at all.
typedef PdfStatementRead = ({
  UpiStatement? statement,
  List<List<String>>? table,
  bool scanned,
});

/// Reads a PDF statement — Google Pay, PhonePe, Paytm, or a bank's own
/// (SBI, Union Bank, Kotak) — asking for the password when it's locked.
/// Null when the user gives up on the password; a [FormatException] when
/// it can't be read at all.
Future<PdfStatementRead?> readPdfFile(
  BuildContext context,
  Uint8List bytes, {
  String? fileName,
}) async {
  UpiStatement? statement;
  var scanned = false;
  String? password;
  try {
    while (true) {
      try {
        final text = await extractPdfText(bytes, password: password);
        scanned = text.trim().isEmpty;
        statement = parseUpiStatement(text);
        break;
      } on PdfTextException catch (error) {
        if (error.failure == PdfTextFailure.unreadable || !context.mounted) {
          rethrow;
        }
        password = await showTextEntryAlert(
          context,
          title: error.failure == PdfTextFailure.wrongPassword
              ? 'Wrong password'
              : 'This PDF is locked',
          message: error.failure == PdfTextFailure.wrongPassword
              ? 'Check it and try again.'
              : 'Enter its password to read it. Often it’s your phone '
                    'number or date of birth.',
          subject: fileName,
          hintText: 'Password',
          confirmLabel: 'Open',
          maxLength: 64,
          sensitive: true,
        );
        if (password == null || password.isEmpty) return null;
      }
    }
  } catch (_) {
    throw const FormatException('This PDF could not be read.');
  }
  List<List<String>>? table;
  if (statement == null && !scanned) {
    try {
      table = pdfStatementTable(
        await extractPdfWords(bytes, password: password),
      );
    } catch (_) {
      throw const FormatException('This PDF could not be read.');
    }
  }
  return (statement: statement, table: table, scanned: scanned);
}

/// Why [read] gives nothing to import, and what to try instead; null when
/// it does.
String? pdfProblem(PdfStatementRead read) {
  if (read.table != null) return null;
  final statement = read.statement;
  if (statement != null && statement.rows.isNotEmpty) return null;
  return read.scanned
      ? 'This PDF is a scanned image. Download it again as a text PDF, CSV or Excel.'
      : statement == null
      ? 'No transactions found in this PDF. Try your bank’s CSV or Excel file.'
      : 'No transactions found in this statement.';
}

/// Imports a PDF statement and opens its review. A bank PDF of a layout the
/// app doesn't know opens the column screen, where the user checks what
/// was read and fixes any column that's off.
Future<StatementImportResult?> readPdfStatement(
  BuildContext context,
  SyncController sync,
  Uint8List bytes,
  String fileName,
) async {
  showAppToast(context, 'Reading statement…');
  final read = await readPdfFile(context, bytes, fileName: fileName);
  if (read == null || !context.mounted) return null;
  if (read.table case final table?) {
    return openStatementColumns(
      context,
      sync,
      table,
      fileName,
      UpiStatementSource.bank,
    );
  }
  if (pdfProblem(read) case final problem?) {
    showAppToast(context, problem, icon: Icons.info_outline_rounded);
    return null;
  }
  return Navigator.of(context).push<StatementImportResult>(
    FeatureRoute(StatementReviewScreen(sync: sync, statement: read.statement!)),
  );
}
