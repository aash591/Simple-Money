import 'dart:convert';

/// A sync event in More › History (record changes are kept by the
/// change history, see ChangeHistoryRepository).
enum SyncActivityKind {
  /// This phone's changes reached Drive.
  sent,

  /// Another phone's changes were merged here.
  received,

  /// The ledger was replaced by a backup from Drive.
  restored,

  /// The ledger was replaced by an imported file.
  imported,

  /// Everything on this phone was deleted.
  erased,

  /// Sync was turned on for a Google account.
  connected,

  /// Sync was turned off, or the account signed out.
  paused,

  /// Sync failed; it retries by itself.
  error;

  static SyncActivityKind parse(String name) =>
      values.firstWhere((k) => k.name == name, orElse: () => error);
}

/// One record that arrived from another phone, as the log shows it.
class SyncActivityItem {
  const SyncActivityItem({
    required this.action,
    required this.kind,
    this.label,
    this.amountMinor,
    this.currency,
    this.digits,
  });

  /// added, edited or deleted.
  final String action;

  /// What it is: expense, income, transfer, account, category, …
  final String kind;
  final String? label;
  final int? amountMinor;
  final String? currency;
  final int? digits;

  Map<String, Object?> toJson() => {
    'action': action,
    'kind': kind,
    'label': ?label,
    'amount': ?amountMinor,
    'currency': ?currency,
    'digits': ?digits,
  };

  static SyncActivityItem? fromJson(Object? json) {
    if (json is! Map) return null;
    final action = json['action'], kind = json['kind'];
    if (action is! String || kind is! String) return null;
    return SyncActivityItem(
      action: action,
      kind: kind,
      label: json['label'] is String ? json['label'] as String : null,
      amountMinor: json['amount'] is int ? json['amount'] as int : null,
      currency: json['currency'] is String ? json['currency'] as String : null,
      digits: json['digits'] is int ? json['digits'] as int : null,
    );
  }
}

class SyncActivity {
  const SyncActivity({
    required this.id,
    required this.at,
    required this.kind,
    this.device,
    this.count = 0,
    this.items = const [],
    this.message,
  });

  final int id;
  final DateTime at;
  final SyncActivityKind kind;

  /// The other phone, for [SyncActivityKind.received].
  final String? device;

  /// Changes sent or received; for an error, how many times it happened.
  final int count;

  /// What arrived, newest first (at most a few dozen).
  final List<SyncActivityItem> items;
  final String? message;

  static List<SyncActivityItem> decodeItems(String json) {
    try {
      return [
        for (final item in jsonDecode(json) as List)
          ?SyncActivityItem.fromJson(item),
      ];
    } catch (_) {
      return const [];
    }
  }
}
