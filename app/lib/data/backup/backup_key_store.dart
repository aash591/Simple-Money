import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'backup_encryption.dart';

abstract interface class BackupKeyStore {
  Future<BackupKey?> read(String subject, BackupEncryption configuration);
  Future<void> save(String subject, BackupKey key);
  Future<void> forget(String subject);
}

class SecureBackupKeyStore implements BackupKeyStore {
  const SecureBackupKeyStore();
  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  String _prefix(String subject) =>
      'simple_money_backup_${sha256.convert(utf8.encode(subject))}_';
  String _name(String subject, BackupEncryption config) =>
      '${_prefix(subject)}${sha256.convert(utf8.encode(config.encoded))}';

  @override
  Future<BackupKey?> read(
    String subject,
    BackupEncryption configuration,
  ) async {
    try {
      final stored = await _storage.read(key: _name(subject, configuration));
      if (stored == null) return null;
      final bytes = base64Decode(stored);
      if (bytes.length != 32) return null;
      final secret = SecretKey(bytes);
      await configuration.verify(secret);
      return BackupKey(configuration, secret);
    } catch (_) {
      // Key loss must ask for the PIN, never silently upload plaintext.
      return null;
    }
  }

  @override
  Future<void> save(String subject, BackupKey key) async {
    final name = _name(subject, key.configuration);
    final value = base64Encode(await key.secret.extractBytes());
    await _storage.write(key: name, value: value);
    if (await _storage.read(key: name) != value) {
      throw const BackupEncryptionException(
        'Could not securely save the backup key. Encryption has not been changed.',
      );
    }
  }

  @override
  Future<void> forget(String subject) async {
    for (final key in (await _storage.readAll()).keys) {
      if (key.startsWith(_prefix(subject))) await _storage.delete(key: key);
    }
  }
}
