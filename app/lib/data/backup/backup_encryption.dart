import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

class BackupEncryptionException implements Exception {
  const BackupEncryptionException(this.message);
  final String message;
  @override
  String toString() => message;
}

class BackupPinRequired extends BackupEncryptionException {
  const BackupPinRequired(this.configuration)
    : super('Enter your backup PIN to unlock your encrypted backup.');
  final BackupEncryption configuration;
}

/// Public recovery parameters. These contain no PIN or decryption key.
class BackupEncryption {
  const BackupEncryption._(this.salt, this.check);
  static const iterations = 600000;
  static const _checkText = 'SimpleMoney backup key v1';
  static final _aes = AesGcm.with256bits();
  final String salt;
  final SecretBox check;

  static bool validPin(String pin) => RegExp(r'^[a-zA-Z0-9]{6}$').hasMatch(pin);

  static Future<BackupKey> create(String pin) async {
    _validatePin(pin);
    final random = Random.secure();
    final salt = base64Encode(List.generate(16, (_) => random.nextInt(256)));
    final key = await _derive(pin, salt);
    final check = await _aes.encrypt(
      utf8.encode(_checkText),
      secretKey: key,
      aad: _checkAad(salt),
    );
    return BackupKey(BackupEncryption._(salt, check), key);
  }

  Future<BackupKey> unlock(String pin) async {
    _validatePin(pin);
    final key = await _derive(pin, salt);
    await verify(key);
    return BackupKey(this, key);
  }

  Future<void> verify(SecretKey key) async {
    try {
      final text = await _aes.decrypt(
        check,
        secretKey: key,
        aad: _checkAad(salt),
      );
      if (utf8.decode(text) != _checkText) throw const FormatException();
    } catch (_) {
      throw const BackupEncryptionException(
        'Incorrect PIN, or this backup is damaged. Try again.',
      );
    }
  }

  static void _validatePin(String pin) {
    if (!validPin(pin)) {
      throw const BackupEncryptionException(
        'Use exactly 6 letters or numbers. Letters are case-sensitive.',
      );
    }
  }

  static List<int> _checkAad(String salt) =>
      utf8.encode('simple-money-key-v1:$iterations:$salt');

  // Keep the deliberately expensive password derivation off the UI isolate.
  static Future<SecretKey> _derive(String pin, String salt) async => SecretKey(
    await Isolate.run(() async {
      final key = await Pbkdf2(
        macAlgorithm: Hmac.sha256(),
        iterations: iterations,
        bits: 256,
      ).deriveKeyFromPassword(password: pin, nonce: base64Decode(salt));
      return key.extractBytes();
    }),
  );

  Map<String, Object> toJson() => {
    'version': 1,
    'kdf': 'pbkdf2-sha256',
    'iterations': iterations,
    'salt': salt,
    'check': _boxJson(check),
  };

  factory BackupEncryption.fromJson(Map<String, dynamic> json) {
    try {
      if (json['version'] != 1 ||
          json['kdf'] != 'pbkdf2-sha256' ||
          json['iterations'] != iterations) {
        throw const FormatException();
      }
      final salt = json['salt'] as String;
      if (base64Decode(salt).length != 16) throw const FormatException();
      final check = _readBox(Map<String, dynamic>.from(json['check'] as Map));
      if (check.cipherText.length != utf8.encode(_checkText).length) {
        throw const FormatException();
      }
      return BackupEncryption._(salt, check);
    } catch (_) {
      throw const BackupEncryptionException(
        'This encrypted backup is damaged or needs a newer version of SimpleMoney.',
      );
    }
  }

  String get encoded => jsonEncode(toJson());
  @override
  bool operator ==(Object other) =>
      other is BackupEncryption && encoded == other.encoded;
  @override
  int get hashCode => encoded.hashCode;
}

/// Secret material stays on the phone, in platform secure storage.
class BackupKey {
  const BackupKey(this.configuration, this.secret);
  final BackupEncryption configuration;
  final SecretKey secret;

  Future<Uint8List> encrypt(
    Uint8List bytes,
    String mirrorId,
    int sequence,
  ) async {
    final box = await BackupEncryption._aes.encrypt(
      bytes,
      secretKey: secret,
      aad: _batchAad(configuration, mirrorId, sequence),
    );
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'simple-money-encrypted',
          'version': 1,
          'encryption': configuration.toJson(),
          'box': _boxJson(box),
        }),
      ),
    );
  }
}

typedef BackupKeyLookup = Future<BackupKey?> Function(
  BackupEncryption configuration,
);

/// Returns legacy gzip/JSON unchanged; encrypted data must authenticate first.
Future<Uint8List> decryptBackupBatch(
  Uint8List bytes,
  String mirrorId,
  int sequence,
  BackupKeyLookup? lookup,
) async {
  if (bytes.isEmpty || bytes.first != 123) {
    return bytes; // JSON starts with '{'.
  }
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map || decoded['format'] != 'simple-money-encrypted') {
    return bytes;
  }
  if (decoded['version'] != 1) {
    throw const BackupEncryptionException(
      'Update SimpleMoney to unlock this backup.',
    );
  }
  final configuration = BackupEncryption.fromJson(
    Map<String, dynamic>.from(decoded['encryption'] as Map),
  );
  final key = await lookup?.call(configuration);
  if (key == null) throw BackupPinRequired(configuration);
  if (key.configuration != configuration) {
    throw BackupPinRequired(configuration);
  }
  try {
    final box = _readBox(Map<String, dynamic>.from(decoded['box'] as Map));
    return Uint8List.fromList(
      await BackupEncryption._aes.decrypt(
        box,
        secretKey: key.secret,
        aad: _batchAad(configuration, mirrorId, sequence),
      ),
    );
  } catch (_) {
    throw const BackupEncryptionException(
      'This encrypted backup is damaged or could not be verified. Your phone data has not changed.',
    );
  }
}

BackupEncryption? backupBatchEncryption(Uint8List bytes) {
  if (bytes.isEmpty || bytes.first != 123) return null;
  final decoded = jsonDecode(utf8.decode(bytes));
  if (decoded is! Map || decoded['format'] != 'simple-money-encrypted') {
    return null;
  }
  if (decoded['version'] != 1) {
    throw const BackupEncryptionException(
      'Update SimpleMoney to unlock this backup.',
    );
  }
  return BackupEncryption.fromJson(
    Map<String, dynamic>.from(decoded['encryption'] as Map),
  );
}

List<int> _batchAad(BackupEncryption config, String mirror, int sequence) =>
    utf8.encode(
      jsonEncode([
        'simple-money-encrypted',
        1,
        config.toJson(),
        mirror,
        sequence,
      ]),
    );

Map<String, String> _boxJson(SecretBox box) => {
  'nonce': base64Encode(box.nonce),
  'ciphertext': base64Encode(box.cipherText),
  'mac': base64Encode(box.mac.bytes),
};

SecretBox _readBox(Map<String, dynamic> json) {
  final nonce = base64Decode(json['nonce'] as String);
  final mac = base64Decode(json['mac'] as String);
  if (nonce.length != 12 || mac.length != 16) {
    throw const FormatException('Invalid encrypted backup');
  }
  return SecretBox(
    base64Decode(json['ciphertext'] as String),
    nonce: nonce,
    mac: Mac(mac),
  );
}
