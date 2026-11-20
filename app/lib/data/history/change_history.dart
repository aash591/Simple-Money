import 'dart:convert';

import 'package:drift/drift.dart';

import '../backup/sync_schema.dart';
import '../db/app_database.dart';

enum ChangeAction {
  added,
  edited,
  deleted;

  static ChangeAction parse(String name) =>
      values.firstWhere((a) => a.name == name, orElse: () => edited);
}

/// One add, edit or delete of a record, made on this phone or merged in
/// from another one (see `record_history` and [createHistoryTriggers]).
class RecordChange {
  const RecordChange({
    required this.id,
    required this.at,
    required this.table,
    required this.recordKey,
    required this.action,
    this.before,
    this.after,
    this.device,
    this.undone = false,
  });
  final int id;
  final DateTime at;
  final String table;
  final String recordKey;
  final ChangeAction action;

  /// The record before and after the change; null where it didn't exist.
  final Map<String, Object?>? before, after;

  /// The other phone that made it; null for this phone.
  final String? device;
  final bool undone;

  /// The record as the log shows it: as it became, or as it was when deleted.
  Map<String, Object?> get record => after ?? before ?? const {};

  /// For an edit, the columns whose value changed.
  Set<String> get changedColumns {
    final before = this.before, after = this.after;
    if (before == null || after == null) return const {};
    return {
      for (final key in {...before.keys, ...after.keys})
        if (!sameValue(before[key], after[key])) key,
    };
  }

  static bool sameValue(Object? a, Object? b) =>
      a == b || (a is num && b is num && a.toDouble() == b.toDouble());
}

/// Every add, edit and delete of a transaction, here or on another phone,
/// for More › History; each can be undone.
class ChangeHistoryRepository {
  ChangeHistoryRepository(this.db);
  final AppDatabase db;

  /// How many changes are kept; older ones are dropped.
  static const keep = 5000;

  /// The newest changes first; [olderThan] continues a list from that ID.
  Future<List<RecordChange>> load({int limit = 200, int? olderThan}) async {
    final rows = await db
        .customSelect(
          'SELECT * FROM record_history '
          '${olderThan == null ? '' : 'WHERE id < ?'} '
          'ORDER BY id DESC LIMIT ?',
          variables: [
            if (olderThan != null) Variable(olderThan),
            Variable(limit),
          ],
        )
        .get();
    Map<String, Object?>? decode(String? json) {
      if (json == null) return null;
      try {
        return Map<String, Object?>.from(jsonDecode(json) as Map);
      } catch (_) {
        return null;
      }
    }

    return [
      for (final row in rows)
        RecordChange(
          id: row.read<int>('id'),
          at: DateTime.fromMillisecondsSinceEpoch(row.read<int>('at')),
          table: row.read<String>('table_name'),
          recordKey: row.read<String>('record_key'),
          action: ChangeAction.parse(row.read<String>('action')),
          before: decode(row.readNullable<String>('before_json')),
          after: decode(row.readNullable<String>('after_json')),
          device: row.readNullable<String>('device'),
          undone: row.read<int>('undone') == 1,
        ),
    ];
  }

  /// Drops all but the newest [keep] changes.
  Future<void> prune() => db.customStatement(
    '''DELETE FROM record_history WHERE id <=
      (SELECT id FROM record_history ORDER BY id DESC LIMIT 1 OFFSET ?)''',
    [keep],
  );

  /// Puts the record of change [id] back as it was before it: an addition
  /// is deleted, a deletion comes back, an edit is reverted. Saved as an
  /// edit made on this phone, so it syncs to the other phones and shows in
  /// the log itself. Account balances move with the transaction.
  ///
  /// Throws a [StateError] when the record changed again since: the newer
  /// change has to be undone first.
  Future<void> undo(int id) => db.transaction(() async {
    final entry = await db
        .customSelect(
          'SELECT * FROM record_history WHERE id = ?',
          variables: [Variable(id)],
        )
        .getSingleOrNull();
    if (entry == null) throw StateError('This change is no longer in the log.');
    if (entry.read<int>('undone') == 1) {
      throw StateError('This was already undone.');
    }
    final table = entry.read<String>('table_name');
    final keyColumns = syncTables[table];
    if (keyColumns == null || !historyTables.contains(table)) {
      throw StateError('This can’t be undone.');
    }
    final key = jsonDecode(entry.read<String>('record_key')) as List;
    Map<String, Object?>? decode(String column) {
      final json = entry.readNullable<String>(column);
      return json == null
          ? null
          : Map<String, Object?>.from(jsonDecode(json) as Map);
    }

    final before = decode('before_json'), after = decode('after_json');
    final where = keyColumns.map((c) => '$c = ?').join(' AND ');
    final current =
        (await db
                .customSelect(
                  'SELECT * FROM $table WHERE $where',
                  variables: [for (final v in key) Variable(v)],
                )
                .getSingleOrNull())
            ?.data;
    final unchanged = current == null || after == null
        ? current == null && after == null
        : after.entries.every(
            (e) =>
                !current.containsKey(e.key) ||
                RecordChange.sameValue(current[e.key], e.value),
          );
    if (!unchanged) {
      throw StateError(
        'This transaction changed again since. Undo the newer change first.',
      );
    }

    // Each affected account's base (balance less what its transactions
    // add), so the balance moves with the transaction put back.
    final accounts = <int>{
      for (final row in [current, before])
        for (final column in ['account_id', 'to_account_id'])
          if (row?[column] case final int id) id,
    };
    final bases = <int, int>{};
    for (final account in accounts) {
      final row = await db
          .customSelect(
            'SELECT balance_minor FROM accounts WHERE id = ?',
            variables: [Variable(account)],
          )
          .getSingleOrNull();
      if (row == null) continue;
      bases[account] =
          row.read<int>('balance_minor') - (await _effect(account)).$1;
    }

    if (before == null) {
      await db.customStatement('DELETE FROM $table WHERE $where', key);
    } else {
      final columns = {
        for (final c in await db.customSelect('PRAGMA table_info($table)').get())
          c.read<String>('name'),
      };
      final values = <String, Object?>{
        for (final MapEntry(:key, :value) in before.entries)
          if (columns.contains(key)) key: value,
      };
      final updates = values.keys
          .where((c) => !keyColumns.contains(c))
          .map((c) => '$c = excluded.$c');
      await db.customStatement(
        'INSERT INTO $table (${values.keys.join(', ')}) '
        'VALUES (${List.filled(values.length, '?').join(', ')}) '
        'ON CONFLICT(${keyColumns.join(', ')}) DO '
        '${updates.isEmpty ? 'NOTHING' : 'UPDATE SET ${updates.join(', ')}'}',
        values.values.toList(),
      );
    }
    for (final MapEntry(key: account, value: base) in bases.entries) {
      final (effect, count) = await _effect(account);
      await db.customStatement(
        'UPDATE accounts SET balance_minor = ?, transaction_count = ? '
        'WHERE id = ?',
        [base + effect, count, account],
      );
    }
    await db.customStatement(
      'UPDATE record_history SET undone = 1 WHERE id = ?',
      [id],
    );
  });

  Future<(int, int)> _effect(int accountId) async {
    final row = await db
        .customSelect(accountEffectSql, variables: [Variable(accountId)])
        .getSingle();
    return (row.read<int>('effect'), row.read<int>('count'));
  }
}
