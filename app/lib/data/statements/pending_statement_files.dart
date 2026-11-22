import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../agent/statement_samples.dart';
import 'statement_table.dart';
import 'upi_statement.dart';

/// A statement file whose layout the app couldn't read, kept whole on the
/// phone so it can be imported in one tap once the layout is set up.
class PendingStatementFile {
  const PendingStatementFile({
    required this.signature,
    required this.fileName,
    required this.source,
    required this.rows,
    required this.savedAt,
  });

  /// [tableSignature] of its header, as the AI's layout suggestion names it.
  final String signature;
  final String fileName;
  final UpiStatementSource source;
  final List<List<String>> rows;
  final DateTime savedAt;

  Map<String, Object?> toJson() => {
    'signature': signature,
    'fileName': fileName,
    'source': source.name,
    'savedAt': savedAt.toIso8601String(),
    'rows': rows,
  };

  static PendingStatementFile? fromJson(Object? json) {
    if (json is! Map) return null;
    try {
      return PendingStatementFile(
        signature: json['signature'] as String,
        fileName: json['fileName'] as String,
        source: UpiStatementSource.values.byName(json['source'] as String),
        savedAt: DateTime.parse(json['savedAt'] as String),
        rows: [
          for (final row in json['rows'] as List) (row as List).cast<String>(),
        ],
      );
    } catch (_) {
      return null;
    }
  }
}

/// Device-only: statement files waiting for their layout. Never sent
/// anywhere (the AI sees only [StatementSampleRepository]'s few rows). The
/// newest few are kept for a month, and one goes once it's imported.
class PendingStatementFiles {
  PendingStatementFiles({Future<Directory> Function()? directory})
    : _directory = directory ?? defaultDirectory;

  /// Where the files go; tests point it at a temporary folder.
  @visibleForTesting
  static Future<Directory> Function() defaultDirectory =
      getApplicationSupportDirectory;

  final Future<Directory> Function() _directory;
  static const _kept = 5;
  static const _maxAge = Duration(days: 30);

  Future<Directory> _folder() async {
    final folder = Directory('${(await _directory()).path}/pending_statements');
    await folder.create(recursive: true);
    return folder;
  }

  File _file(Directory folder, String signature) => File(
    '${folder.path}/${signature.hashCode.toUnsigned(32).toRadixString(36)}.json',
  );

  /// Keeps [rows] read from [fileName]; the same layout again replaces it.
  Future<void> save(
    String fileName,
    List<List<String>> rows,
    UpiStatementSource source,
  ) async {
    final header = rows.elementAtOrNull(guessHeaderRow(rows));
    if (header == null) return;
    final signature = tableSignature(header);
    if (signature.isEmpty) return;
    final folder = await _folder();
    await _file(folder, signature).writeAsString(
      jsonEncode(
        PendingStatementFile(
          signature: signature,
          fileName: fileName,
          source: source,
          rows: rows,
          savedAt: DateTime.now(),
        ).toJson(),
      ),
    );
    final all = await load();
    for (final old in all.skip(_kept)) {
      await remove(old.signature);
    }
  }

  /// Newest first; old or unreadable files are cleared away.
  Future<List<PendingStatementFile>> load() async {
    final folder = await _folder();
    final files = <PendingStatementFile>[];
    await for (final entry in folder.list()) {
      // Pictures go with their file, and on their own once a month old.
      if (entry is File && entry.path.endsWith('.jpg')) {
        if (DateTime.now().difference(await entry.lastModified()) > _maxAge) {
          await entry.delete();
        }
        continue;
      }
      if (entry is! File || !entry.path.endsWith('.json')) continue;
      final file = await () async {
        try {
          return PendingStatementFile.fromJson(
            jsonDecode(await entry.readAsString()),
          );
        } catch (_) {
          return null;
        }
      }();
      if (file == null || DateTime.now().difference(file.savedAt) > _maxAge) {
        await entry.delete();
        continue;
      }
      files.add(file);
    }
    return files..sort((a, b) => b.savedAt.compareTo(a.savedAt));
  }

  /// The waiting files whose layout is now saved, ready to import.
  Future<List<(PendingStatementFile, TableMapping)>> ready(
    Map<String, Object?> savedMappings,
  ) async => [
    for (final file in await load())
      if (findSavedMapping(file.rows, savedMappings) case final mapping?)
        (file, mapping),
  ];

  Future<void> remove(String signature) async {
    final folder = await _folder();
    final file = _file(folder, signature);
    if (await file.exists()) await file.delete();
    await _removePictures(folder, signature);
  }

  // ── Page pictures: only once the user allows their AI to see them. ──

  File _picture(Directory folder, String signature, int page) => File(
    '${folder.path}/${signature.hashCode.toUnsigned(32).toRadixString(36)}'
    '.p$page.jpg',
  );

  static const _maxPictures = 2;

  /// Keeps [pictures] of the file with [signature]'s first pages.
  Future<void> savePictures(String signature, List<Uint8List> pictures) async {
    final folder = await _folder();
    await _removePictures(folder, signature);
    for (final (i, picture) in pictures.take(_maxPictures).indexed) {
      await _picture(folder, signature, i + 1).writeAsBytes(picture);
    }
  }

  /// The pictures kept for [signature], first page first; empty when the
  /// user didn't allow them.
  Future<List<Uint8List>> pictures(String signature) async {
    final folder = await _folder();
    return [
      for (var page = 1; page <= _maxPictures; page++)
        if (_picture(folder, signature, page) case final file
            when await file.exists())
          await file.readAsBytes(),
    ];
  }

  Future<void> _removePictures(Directory folder, String signature) async {
    for (var page = 1; page <= _maxPictures; page++) {
      final file = _picture(folder, signature, page);
      if (await file.exists()) await file.delete();
    }
  }
}

/// A layout the app couldn't read: a connected AI can fill it in from a few
/// of its rows (list_statements_to_map), and the whole file waits on the
/// phone so it imports in one tap once the layout is approved.
Future<void> rememberNewLayout(
  String fileName,
  List<List<String>> rows,
  UpiStatementSource source,
) async {
  await StatementSampleRepository().add(fileName, rows, guessHeaderRow(rows));
  // Written meanwhile, so reading the file doesn't wait on it. Only a
  // shortcut: without it the file is picked again.
  unawaited(
    PendingStatementFiles().save(fileName, rows, source).catchError((_) {}),
  );
}
