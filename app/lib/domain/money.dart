const _shortMonthNames = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

/// "Today", "Yesterday", or e.g. "5 Mar 2026" — used wherever a transaction
/// date is shown as a short summary rather than in a calendar.
String formatShortDate(DateTime date) {
  final today = DateTime.now();
  final day = DateTime(date.year, date.month, date.day);
  final todayOnly = DateTime(today.year, today.month, today.day);
  if (day == todayOnly) return 'Today';
  if (day == todayOnly.subtract(const Duration(days: 1))) return 'Yesterday';
  return '${day.day} ${_shortMonthNames[day.month - 1]} ${day.year}';
}
