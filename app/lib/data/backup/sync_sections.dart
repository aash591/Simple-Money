import 'sync_schema.dart';

/// How a phone's data is split into files on Drive ("sections"), so an
/// upload only replaces the few small files whose records changed.
///
/// - Every table not listed in [sectionedTables] is one file, named after
///   the table, holding all its records and their deletions.
/// - The big, growing tables are split by the UTC month a record was made
///   (`transactions/2026-11`), never by a date the user can edit, so a
///   record stays in one file for good. Records made today go in a day file
///   (`transactions/2026-11-19`) that the frequent uploads replace; the
///   next day it is folded into its month.
/// - Their deletions go in a file per month the deletion happened
///   (`transactions/deleted/2026-11`), as the deleted record's own month
///   isn't known once it's gone. Deletions are kept for good.
///
/// A record can be found in more than one of a phone's files for a while
/// (a deleted row still in its month, yesterday's day file not yet
/// removed); readers merge each record by version, so the newest wins.
const sectionedTables = {
  'transactions': 'created_at',
  'sms_history': 'received_at',
};

String _two(int n) => n.toString().padLeft(2, '0');

/// `2026-11` for [ms] (Unix milliseconds), in UTC.
String monthOf(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  return '${t.year.toString().padLeft(4, '0')}-${_two(t.month)}';
}

/// `2026-11-19` for [ms] (Unix milliseconds), in UTC.
String dayOf(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true);
  return '${monthOf(ms)}-${_two(t.day)}';
}

/// The section holding [table]'s record [row] (null: deleted, at version
/// [hlc]) as of [now].
String sectionOf(
  String table,
  Map<String, Object?>? row,
  int hlc,
  DateTime now,
) {
  final column = sectionedTables[table];
  if (column == null) return table;
  if (row == null) return '$table/deleted/${monthOf(hlc >> 16)}';
  final made = row[column] is int ? row[column] as int : 0;
  final day = dayOf(made);
  return day == dayOf(now.millisecondsSinceEpoch)
      ? '$table/$day'
      : '$table/${monthOf(made)}';
}

/// The table a section's records belong to.
String sectionTable(String section) => section.split('/').first;

/// For a day section (`transactions/2026-11-19`), its day; otherwise null.
String? sectionDay(String section) {
  final parts = section.split('/');
  return parts.length == 2 && parts[1].length == 10 ? parts[1] : null;
}

/// A day section's month section: where its records go once the day is over.
String monthSectionOfDay(String section) =>
    section.substring(0, section.length - 3);

/// Whether [section] names a section this version can read: a synced table,
/// alone or with a period.
bool isKnownSection(String section) {
  final parts = section.split('/');
  if (!syncTables.containsKey(parts.first)) return false;
  if (parts.length == 1) return !sectionedTables.containsKey(parts.first);
  return sectionedTables.containsKey(parts.first) &&
      (parts.length == 2 || (parts.length == 3 && parts[1] == 'deleted'));
}

/// Small tables first, then the periods oldest first: a phone merging them in
/// this order has accounts and categories before the transactions using them.
int compareSections(String a, String b) {
  final aSplit = a.contains('/'), bSplit = b.contains('/');
  if (aSplit != bSplit) return aSplit ? 1 : -1;
  return a.compareTo(b);
}
