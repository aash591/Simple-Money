import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Passwords that opened statement PDFs, kept encrypted on this phone so a
/// locked PDF opens without asking again. A bank uses one password for its
/// statements however they arrive (its app, email, WhatsApp) and whatever
/// the file is called, so they aren't tied to a file: each is tried in turn,
/// the one used last first. Never sent anywhere or backed up.
class PdfPasswords {
  const PdfPasswords();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  static const _key = 'simple_money_pdf_passwords';
  static const _kept = 10;

  /// The saved passwords, the one used last first; empty when none or the
  /// store can't be read.
  Future<List<String>> load() async {
    try {
      final saved = await _storage.read(key: _key);
      if (saved == null) return const [];
      return [
        for (final p in jsonDecode(saved) as List)
          if (p is String && p.isNotEmpty) p,
      ];
    } catch (_) {
      return const [];
    }
  }

  /// Keeps [password], which just opened a PDF, as the first to try.
  Future<void> remember(String password) async {
    if (password.isEmpty) return;
    try {
      final next = [
        password,
        for (final p in await load())
          if (p != password) p,
      ].take(_kept).toList();
      await _storage.write(key: _key, value: jsonEncode(next));
    } catch (_) {
      // Only a convenience: the PDF asks again next time.
    }
  }

  /// Forgets every saved password.
  Future<void> forgetAll() async {
    try {
      await _storage.delete(key: _key);
    } catch (_) {}
  }
}
