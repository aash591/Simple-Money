import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../../data/statements/pdf_passwords.dart';
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
  String? password,
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
  // A locked PDF first tries the passwords that opened others: a bank uses
  // one for all its statements, whatever the file is called.
  const passwords = PdfPasswords();
  final saved = await passwords.load();
  var tried = 0;
  String? typed;
  final keep = ValueNotifier(true);
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
        if (typed == null && tried < saved.length) {
          password = saved[tried++];
          continue;
        }
        final wrong = typed != null;
        password = typed = await showTextEntryAlert(
          context,
          title: wrong ? 'Wrong password' : 'This PDF is locked',
          message: wrong
              ? 'Check it and try again.'
              : 'Enter its password to read it. Often it’s your phone '
                    'number or date of birth.',
          subject: fileName,
          hintText: 'Password',
          confirmLabel: 'Open',
          maxLength: 64,
          sensitive: true,
          checkLabel: 'Remember for next time',
          checked: keep,
        );
        if (password == null || password.isEmpty) return null;
      }
    }
  } catch (_) {
    throw const FormatException('This PDF could not be read.');
  }
  // A password typed here is kept only if the user left the box ticked.
  if (password != null && (typed == null || keep.value)) {
    await passwords.remember(password);
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
  return (
    statement: statement,
    table: table,
    scanned: scanned,
    password: password,
  );
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
      pagePictures: () => renderPdfPages(bytes, password: read.password),
    );
  }
  if (pdfProblem(read) case final problem?) {
    showAppToast(context, problem, icon: Icons.info_outline_rounded);
    return null;
  }
  return Navigator.of(context).push<StatementImportResult>(
    FeatureRoute(
      StatementReviewScreen(
        sync: sync,
        statement: read.statement!,
        // The app read this PDF itself. If that went wrong, the user can
        // open its columns instead, where their AI can help too.
        onLooksWrong: (reviewContext) async {
          final table = pdfStatementTable(
            await extractPdfWords(bytes, password: read.password),
          );
          if (!reviewContext.mounted) return null;
          if (table == null || table.length < 2) {
            showAppToast(
              reviewContext,
              'Columns can’t be set for this PDF.',
              icon: Icons.info_outline_rounded,
            );
            return null;
          }
          return openStatementColumns(
            reviewContext,
            sync,
            table,
            fileName,
            UpiStatementSource.bank,
            pagePictures: () => renderPdfPages(bytes, password: read.password),
          );
        },
      ),
    ),
  );
}
