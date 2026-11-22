import 'dart:async';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../../data/repositories/statement_import_repository.dart';
import '../../../data/statements/pending_statement_files.dart';
import '../../../data/statements/statement_table.dart';
import '../../../data/statements/upi_statement.dart';
import '../../../state/sync_controller.dart';
import '../../components/app_toast.dart';
import '../../components/confirmation_alert.dart';
import '../../components/feature_page.dart';
import 'csv_statement_import.dart';
import 'excel_statement_import.dart';
import 'pdf_statement_import.dart';
import 'statement_batch_screen.dart';
import 'statement_review_screen.dart';

bool _reading = false;

/// Picks statements — PDFs, CSV or Excel files — and imports them. One file
/// goes to its format's import, told apart by content rather than by file
/// name; several go to [StatementBatchScreen], which takes them one after
/// another. Says what the import did. One import runs at a time.
///
/// [onReading] hears true once a file is chosen and false when the import
/// is over, for a caller showing that the file is being read.
/// [onOpenAi] opens the AI assistant, for a layout the app can't read yet.
Future<void> importStatement(
  BuildContext context,
  SyncController sync, {
  ValueChanged<bool>? onReading,
  VoidCallback? onOpenAi,
}) async {
  if (_reading) return;
  _reading = true;
  StatementImportResult? result;
  try {
    final files = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf', 'csv', 'xlsx', 'xls'],
    );
    if (files.isEmpty || !context.mounted) return;
    if (files.length > 1) {
      result = await Navigator.of(context).push<StatementImportResult>(
        FeatureRoute(
          StatementBatchScreen(
            sync: sync,
            files: [for (final f in files) (name: f.name, read: f.readAsBytes)],
            onOpenAi: onOpenAi,
          ),
        ),
      );
    } else {
      final file = files.single;
      onReading?.call(true);
      final bytes = await file.readAsBytes();
      if (!context.mounted) return;
      result = await switch (statementKind(bytes)) {
        StatementKind.pdf => readPdfStatement(context, sync, bytes, file.name),
        StatementKind.excel => readExcelStatement(
          context,
          sync,
          bytes,
          file.name,
        ),
        StatementKind.csv => readCsvStatement(context, sync, bytes, file.name),
      };
    }
  } on FormatException catch (error) {
    if (context.mounted) {
      showAppToast(context, error.message, icon: Icons.error_outline_rounded);
    }
  } catch (_) {
    if (context.mounted) {
      showAppToast(
        context,
        'This file could not be read.',
        icon: Icons.error_outline_rounded,
      );
    }
  } finally {
    _reading = false;
    onReading?.call(false);
  }
  if (result != null && context.mounted) {
    final said = describeImport(result);
    if (said.isNotEmpty) {
      showAppToast(context, said, icon: Icons.check_rounded);
    }
  }
}

/// Imports a file kept on the phone while its layout was set up: straight
/// to its review, with no file to pick again. Null when it was left.
Future<StatementImportResult?> importPendingStatement(
  BuildContext context,
  SyncController sync,
  PendingStatementFile file,
  TableMapping mapping,
) async {
  final statement = parseStatementTable(
    file.rows,
    mapping,
    source: file.source,
  ).statement;
  if (statement.rows.isEmpty) {
    showAppToast(
      context,
      'No transactions found in ${file.fileName}.',
      icon: Icons.info_outline_rounded,
    );
    return null;
  }
  final result = await Navigator.of(context).push<StatementImportResult>(
    FeatureRoute(StatementReviewScreen(sync: sync, statement: statement)),
  );
  if (result != null) {
    await PendingStatementFiles().remove(file.signature).catchError((_) {});
    if (context.mounted) {
      final said = describeImport(result);
      if (said.isNotEmpty) {
        showAppToast(context, said, icon: Icons.check_rounded);
      }
    }
  }
  return result;
}

/// The kept file a newly saved layout ([signature]) reads, if there is one.
Future<(PendingStatementFile, TableMapping)?> readyStatementFor(
  SyncController sync,
  String signature,
) async {
  try {
    final saved = await StatementImportRepository(sync.repository.db)
        .knownMappings();
    return (await PendingStatementFiles().ready(saved))
        .where((r) => r.$1.signature == signature)
        .firstOrNull;
  } catch (_) {
    return null;
  }
}

/// Right after an AI's statement layout ([signature]) is approved: offers to
/// import the file it was made for, which waited on the phone meanwhile.
Future<void> offerPendingImport(
  BuildContext context,
  SyncController sync,
  String signature,
) async {
  final ready = await readyStatementFor(sync, signature);
  if (ready == null || !context.mounted) return;
  final (file, mapping) = ready;
  if (!await showConfirmationAlert(
        context,
        title: 'Layout saved',
        message:
            'Import ${file.fileName} now? It’s still on your phone, so there’s '
            'no need to pick it again.',
        confirmLabel: 'Import now',
        cancelLabel: 'Later',
        destructive: false,
      ) ||
      !context.mounted) {
    return;
  }
  await importPendingStatement(context, sync, file, mapping);
}

Future<void> _forgetPending(List<List<String>> rows) async {
  final header = rows.elementAtOrNull(guessHeaderRow(rows));
  if (header == null) return;
  await PendingStatementFiles()
      .remove(tableSignature(header))
      .catchError((_) {});
}

/// What an import did, in a few words: "Added 32 · 180 already here".
String describeImport(StatementImportResult result) {
  String plural(int n, String noun) => '$n $noun${n == 1 ? '' : 's'}';
  return [
    if (result.added > 0) 'Added ${plural(result.added, 'transaction')}',
    if (result.linked > 0)
      '${plural(result.linked, 'transfer')} between your accounts',
    if (result.already > 0) '${result.already} already here',
  ].join(' · ');
}

enum StatementKind { pdf, excel, csv }

StatementKind statementKind(Uint8List bytes) {
  bool startsWith(List<int> magic) =>
      bytes.length >= magic.length &&
      Iterable.generate(magic.length).every((i) => bytes[i] == magic[i]);
  if (startsWith('%PDF'.codeUnits)) return StatementKind.pdf;
  // An .xlsx is a zip; an old .xls an OLE file, which the Excel import
  // refuses with a way out.
  if (startsWith(const [0x50, 0x4B, 0x03, 0x04]) ||
      startsWith(const [0xD0, 0xCF, 0x11, 0xE0])) {
    return StatementKind.excel;
  }
  return StatementKind.csv;
}

/// A picked statement once read: ready to review, a layout to set up once,
/// or why it can't be imported.
sealed class StatementFile {
  const StatementFile(this.name);
  final String name;
}

/// Read and understood.
final class ReadStatement extends StatementFile {
  const ReadStatement(super.name, this.statement);
  final UpiStatement statement;
}

/// A table whose layout the app hasn't seen: its columns are set up once,
/// by the user or their AI assistant, and remembered.
final class NewLayoutStatement extends StatementFile {
  const NewLayoutStatement(super.name, this.rows, this.source);
  final List<List<String>> rows;
  final UpiStatementSource source;
}

/// Can't be imported; [message] says why and what to try.
final class UnreadStatement extends StatementFile {
  const UnreadStatement(super.name, this.message);
  final String message;
}

/// Reads [bytes] as a statement without opening anything: a locked PDF
/// asks for its password; a table uses the columns saved for its layout.
Future<StatementFile> readStatementFile(
  BuildContext context,
  SyncController sync,
  String name,
  Uint8List bytes,
) async {
  try {
    switch (statementKind(bytes)) {
      case StatementKind.pdf:
        if (!context.mounted) return UnreadStatement(name, 'Not read.');
        final read = await readPdfFile(context, bytes, fileName: name);
        if (read == null) {
          return UnreadStatement(name, 'Locked. Tap to enter its password.');
        }
        if (read.table case final table?) {
          return await _tableFile(sync, name, table, UpiStatementSource.bank);
        }
        if (pdfProblem(read) case final problem?) {
          return UnreadStatement(name, problem);
        }
        return ReadStatement(name, read.statement!);
      case StatementKind.excel:
        return await _tableFile(
          sync,
          name,
          readExcelTable(bytes),
          UpiStatementSource.excel,
        );
      case StatementKind.csv:
        return await _tableFile(
          sync,
          name,
          readCsvTable(bytes),
          UpiStatementSource.csv,
        );
    }
  } on FormatException catch (error) {
    return UnreadStatement(name, error.message);
  } catch (_) {
    return UnreadStatement(name, 'This file could not be read.');
  }
}

Future<StatementFile> _tableFile(
  SyncController sync,
  String name,
  List<List<String>> rows,
  UpiStatementSource source,
) async {
  if (rows.every((r) => r.every((c) => c.trim().isEmpty))) {
    return UnreadStatement(name, 'This file is empty.');
  }
  final mapping = await StatementImportRepository(sync.repository.db)
      .mappingFor(rows);
  if (mapping == null) {
    await rememberNewLayout(name, rows, source);
    return NewLayoutStatement(name, rows, source);
  }
  // Picked again by hand: no longer waiting for a one-tap import.
  unawaited(_forgetPending(rows));
  final statement = parseStatementTable(
    rows,
    mapping,
    source: source,
  ).statement;
  return statement.rows.isEmpty
      ? UnreadStatement(name, 'No transactions found in this file.')
      : ReadStatement(name, statement);
}
