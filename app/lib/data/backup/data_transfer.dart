import 'dart:convert';
import 'dart:typed_data';

import 'package:intl/intl.dart';

import '../db/app_database.dart';
import 'sync_restore.dart';
import 'sync_schema.dart';

const _exportFormat = 'simple-money-export';

/// Every synced table as readable JSON, importable with [parseLedgerExport].
Future<Uint8List> exportLedger(AppDatabase db) async {
  final tables = <String, List<Map<String, Object?>>>{};
  for (final MapEntry(key: table, value: keys) in syncTables.entries) {
    tables[table] = [
      for (final row
          in await db
              .customSelect('SELECT * FROM $table ORDER BY ${keys.join(', ')}')
              .get())
        row.data,
    ];
  }
  return Uint8List.fromList(
    utf8.encode(
      const JsonEncoder.withIndent(' ').convert({
        'format': _exportFormat,
        'formatVersion': 1,
        'schemaVersion': db.schemaVersion,
        'exportedAt': DateTime.now().toUtc().toIso8601String(),
        'tables': tables,
      }),
    ),
  );
}

/// Reads a file written by [exportLedger]. Unknown tables are dropped here and
/// unknown columns on import, since both end up in SQL.
SyncBackup parseLedgerExport(Uint8List bytes) {
  const invalid = FormatException('This isn’t a SimpleMoney export file.');
  final Object? json;
  try {
    json = jsonDecode(utf8.decode(bytes));
  } catch (_) {
    throw invalid;
  }
  if (json is! Map || json['format'] != _exportFormat) throw invalid;
  final source = json['tables'];
  if (source is! Map) throw invalid;
  final schemaVersion = json['schemaVersion'];
  return SyncBackup(
    mirrorId: 'import',
    updatedAt:
        DateTime.tryParse('${json['exportedAt']}')?.toLocal() ?? DateTime.now(),
    schemaVersion: schemaVersion is int ? schemaVersion : 0,
    tables: {
      for (final MapEntry(:key, :value) in source.entries)
        if (key is String && syncTables.containsKey(key) && value is List)
          key: [
            for (final row in value)
              if (row is Map) Map<String, Object?>.from(row),
          ],
    },
  );
}

/// Transactions for spreadsheets: one row each, amounts in major units.
Future<Uint8List> exportTransactionsCsv(AppDatabase db) async {
  final rows = await db.customSelect('''
    SELECT t.date, t.type, t.amount_minor, a.currency, a.digits,
      a.name AS account, ta.name AS to_account, c.name AS category,
      p.name AS parent_category, t.title, t.note
    FROM transactions t
    LEFT JOIN accounts a ON a.id = t.account_id
    LEFT JOIN accounts ta ON ta.id = t.to_account_id
    LEFT JOIN categories c ON c.id = t.category_id
    LEFT JOIN categories p ON p.id = c.parent_id
    ORDER BY t.date DESC, t.id DESC''').get();
  final format = DateFormat('yyyy-MM-dd HH:mm');
  final buffer = StringBuffer('﻿')
    ..write(
      'Date,Type,Amount,Currency,Account,To account,Category,Title,Note\r\n',
    );
  for (final row in rows) {
    final parent = row.readNullable<String>('parent_category');
    final category = row.readNullable<String>('category');
    buffer
      ..writeAll([
        format.format(
          DateTime.fromMillisecondsSinceEpoch(row.read<int>('date')),
        ),
        row.read<String>('type'),
        _amount(
          row.read<int>('amount_minor'),
          row.readNullable<int>('digits') ?? 2,
        ),
        _cell(row.readNullable<String>('currency')),
        _cell(row.readNullable<String>('account')),
        _cell(row.readNullable<String>('to_account')),
        _cell(
          parent == null || category == null ? category : '$parent / $category',
        ),
        _cell(row.readNullable<String>('title')),
        _cell(row.readNullable<String>('note')),
      ], ',')
      ..write('\r\n');
  }
  return Uint8List.fromList(utf8.encode(buffer.toString()));
}

String _amount(int minor, int digits) {
  if (digits == 0) return '$minor';
  final text = minor.abs().toString().padLeft(digits + 1, '0');
  final split = text.length - digits;
  return '${minor < 0 ? '-' : ''}${text.substring(0, split)}.${text.substring(split)}';
}

/// Quotes when needed, and defuses text a spreadsheet would run as a formula.
String _cell(String? value) {
  if (value == null || value.isEmpty) return '';
  var text = value;
  if ('=+-@'.contains(text[0])) text = "'$text";
  if (!text.contains(RegExp(r'[",\r\n]'))) return text;
  return '"${text.replaceAll('"', '""')}"';
}
