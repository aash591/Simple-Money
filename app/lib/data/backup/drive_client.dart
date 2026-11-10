import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'sync_repository.dart';
import 'backup_encryption.dart';

class DriveSyncException implements Exception {
  const DriveSyncException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// One uploaded batch, as described by its Drive metadata.
class MirrorFile {
  const MirrorFile({
    required this.id,
    required this.mirrorId,
    required this.sequence,
    required this.modified,
  });
  final String id, mirrorId;
  final int sequence;
  final DateTime modified;
}

abstract interface class MirrorTransport {
  Future<String> newFileId();
  Future<void> upload(SyncBatch batch);
  Future<List<MirrorFile>> listFiles();
  Future<Uint8List> download(String fileId);
  Future<void> deleteFile(String fileId);
  void close();
}

/// File IDs are allocated before upload and persisted with the exact bytes.
/// Retrying a successful request whose response was lost returns 409; verify
/// the existing file checksum before acknowledging the batch locally.
class DriveClient implements MirrorTransport {
  DriveClient(this.token, {http.Client? client})
    : _client = client ?? http.Client();
  final String token;
  final http.Client _client;
  Map<String, String> get _headers => {'Authorization': 'Bearer $token'};

  Future<Map<String, dynamic>> account() async => _json(
    await _client
        .get(
          Uri.https('www.googleapis.com', '/oauth2/v3/userinfo'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 30)),
  );

  @override
  Future<String> newFileId() async {
    final data = _json(
      await _client
          .get(
            Uri.https('www.googleapis.com', '/drive/v3/files/generateIds', {
              'count': '1',
              'space': 'appDataFolder',
              'type': 'files',
            }),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 30)),
    );
    return (data['ids'] as List).single as String;
  }

  @override
  Future<void> upload(SyncBatch batch) async {
    final boundary = 'simplemoney_${batch.fileId}';
    final encrypted = backupBatchEncryption(batch.payload) != null;
    final mime = encrypted ? 'application/octet-stream' : 'application/gzip';
    final suffix = encrypted ? 'json.enc' : 'json.gz';
    final metadata = jsonEncode({
      'id': batch.fileId,
      'name':
          'simple-money-${batch.mirrorId}-${batch.sequence.toString().padLeft(12, '0')}.$suffix',
      'parents': ['appDataFolder'],
      'mimeType': mime,
      'appProperties': {
        'format': 'simple-money-mirror-v1',
        'mirrorId': batch.mirrorId,
        'sequence': '${batch.sequence}',
      },
    });
    final body = <int>[
      ...utf8.encode(
        '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n'
        '--$boundary\r\nContent-Type: $mime\r\n\r\n',
      ),
      ...batch.payload,
      ...utf8.encode('\r\n--$boundary--\r\n'),
    ];
    var response = await _client
        .post(
          Uri.https('www.googleapis.com', '/upload/drive/v3/files', {
            'uploadType': 'multipart',
            'fields': 'id,md5Checksum,size',
          }),
          headers: {
            ..._headers,
            'Content-Type': 'multipart/related; boundary=$boundary',
          },
          body: body,
        )
        .timeout(const Duration(seconds: 45));
    if (response.statusCode == 409) {
      response = await _client
          .get(
            Uri.https('www.googleapis.com', '/drive/v3/files/${batch.fileId}', {
              'fields': 'id,md5Checksum,size',
            }),
            headers: _headers,
          )
          .timeout(const Duration(seconds: 30));
    }
    final stored = _json(response);
    if (stored['id'] != batch.fileId ||
        stored['md5Checksum'] != batch.checksum ||
        stored['size'].toString() != '${batch.payload.length}') {
      throw const DriveSyncException(
        'Drive could not verify the upload. Your changes remain queued.',
      );
    }
  }

  @override
  Future<List<MirrorFile>> listFiles() async {
    final files = <MirrorFile>[];
    String? pageToken;
    do {
      final data = _json(
        await _client
            .get(
              Uri.https('www.googleapis.com', '/drive/v3/files', {
                'spaces': 'appDataFolder',
                'q':
                    "appProperties has { key='format' and "
                    "value='simple-money-mirror-v1' } and trashed = false",
                'fields': 'nextPageToken,files(id,modifiedTime,appProperties)',
                'pageSize': '1000',
                'pageToken': ?pageToken,
              }),
              headers: _headers,
            )
            .timeout(const Duration(seconds: 30)),
      );
      for (final file in data['files'] as List? ?? const []) {
        final properties = file['appProperties'] as Map? ?? const {};
        final mirrorId = properties['mirrorId'];
        final sequence = int.tryParse('${properties['sequence']}');
        final modified = DateTime.tryParse('${file['modifiedTime']}');
        if (mirrorId is String && sequence != null && modified != null) {
          files.add(
            MirrorFile(
              id: file['id'] as String,
              mirrorId: mirrorId,
              sequence: sequence,
              modified: modified,
            ),
          );
        }
      }
      pageToken = data['nextPageToken'] as String?;
    } while (pageToken != null);
    return files;
  }

  @override
  Future<Uint8List> download(String fileId) async {
    final response = await _client
        .get(
          Uri.https('www.googleapis.com', '/drive/v3/files/$fileId', {
            'alt': 'media',
          }),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 45));
    // Not JSON on success; _json only raises the matching sync error.
    if (response.statusCode >= 300) _json(response);
    return response.bodyBytes;
  }

  @override
  Future<void> deleteFile(String fileId) async {
    final response = await _client
        .delete(
          Uri.https('www.googleapis.com', '/drive/v3/files/$fileId'),
          headers: _headers,
        )
        .timeout(const Duration(seconds: 30));
    // Already gone counts as deleted.
    if (response.statusCode == 404) return;
    if (response.statusCode >= 300) _json(response);
  }

  Map<String, dynamic> _json(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    if (response.statusCode == 401) {
      throw const DriveSyncException(
        'Reconnect your Google account to resume sync.',
      );
    }
    if (response.body.contains('storageQuotaExceeded')) {
      throw const DriveSyncException(
        'Google Drive is full. Free some space to resume sync.',
      );
    }
    if (response.statusCode == 429 ||
        response.body.contains('rateLimitExceeded') ||
        response.body.contains('userRateLimitExceeded')) {
      throw const DriveSyncException(
        'Google Drive is busy. Sync will retry automatically.',
      );
    }
    if (response.statusCode == 403) {
      throw const DriveSyncException(
        'Google Drive access is unavailable. Check app setup or reconnect your account.',
      );
    }
    throw const DriveSyncException(
      'Could not reach Google Drive. Sync will retry automatically.',
    );
  }

  @override
  void close() => _client.close();
}
