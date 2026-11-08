import 'package:flutter/services.dart';

class PickedContact {
  const PickedContact(this.name, this.phone);
  final String name;
  final String? phone;
}

/// The system contact picker and share sheet (see PeopleBridge.kt). Picking
/// hands over only the chosen contact, so no contacts permission is needed.
class PeoplePlatform {
  const PeoplePlatform();
  static const channel = MethodChannel('simple_money/people');

  /// Null when nothing was picked.
  Future<PickedContact?> pickContact() async {
    final row = await channel.invokeMapMethod<String, Object?>('pickContact');
    final name = (row?['name'] as String?)?.trim();
    if (name == null || name.isEmpty) return null;
    final phone = (row!['phone'] as String?)?.trim();
    return PickedContact(
      name.length > 40 ? name.substring(0, 40).trim() : name,
      phone == null || phone.isEmpty ? null : phone,
    );
  }

  Future<void> shareText(String text) =>
      channel.invokeMethod<void>('shareText', {'text': text});
}
