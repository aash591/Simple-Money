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

/// The format tags of a section file (see sync_sections.dart), of the single
/// file a phone of the previous version keeps, and of the batches older
/// versions uploaded. The last two are only read.
const sectionFileFormat = 'simple-money-section-v3';
const deviceFileFormat = 'simple-money-device-v2';
const legacyBatchFormat = 'simple-money-mirror-v1';

/// A SimpleMoney file in the app folder, as described by its Drive metadata:
/// one section of a phone's data ([section]), the single file of a phone on
/// the previous version ([isDeviceFile]), or one batch of an older version's
/// chain (neither).
class MirrorFile {
  const MirrorFile({
    required this.id,
    required this.mirrorId,
    required this.sequence,
    required this.modified,
    this.isDeviceFile = false,
    this.section,
    this.rows,
    this.newest,
    this.encryption,
    this.encryptionAt,
  });
  final String id, mirrorId;

  /// Which upload of its phone it holds; it only grows, so a file whose
  /// number is higher than the one last merged has changed.
  final int sequence;
  final DateTime modified;
  final bool isDeviceFile;

  /// The section a section file holds, e.g. `transactions/2026-11`.
  final String? section;

  /// How many records a section file holds, for offering a restore without
  /// downloading it.
  final int? rows;

  /// The newest record version a section file holds (SyncBatch.newest).
  final int? newest;

  /// The uploading phone's encryption setting and when it was chosen
  /// (SyncBatch.encryption); null for files of older versions.
  final String? encryption;
  final int? encryptionAt;
}

/// A section file this phone made was deleted from Drive (e.g. by "Delete
/// data from Google Drive" on another phone): it is made again.
class DriveFileMissing implements Exception {
  const DriveFileMissing();
}

abstract interface class MirrorTransport {
  Future<String> newFileId();

  /// Creates [SyncBatch.fileId], or replaces its content when
  /// [SyncBatch.replace], and checks the stored bytes.
  Future<void> upload(SyncBatch batch);

  /// The SimpleMoney files in the app folder; with [modifiedAfter], only
  /// those changed since (Drive's own clock, not the phones').
  Future<List<MirrorFile>> listFiles({DateTime? modifiedAfter});
  Future<Uint8List> download(String fileId);
  Future<void> deleteFile(String fileId);
  void close();
}

/// Drive's change log for the app folder. Unlike a search ([MirrorTransport.listFiles]),
/// it shows a file the moment it's uploaded, so a phone sees another
/// phone's change right away.
abstract interface class ChangeFeed {
  /// Where the log stands now; changes after this are reported later.
  Future<String> startToken();

  /// The SimpleMoney files changed since [token] (deleted ones left out),
  /// and the token to ask with next time.
  Future<(List<MirrorFile>, String)> changesSince(String token);
}

/// File IDs are allocated and saved before a file is created. Retrying a
/// create whose response was lost returns 409: the file exists, so its
/// content is replaced instead. Every upload is checked against Drive's MD5
/// before it counts.
class DriveClient implements MirrorTransport, ChangeFeed {
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
    var response = await _send(batch, replace: batch.replace);
    if (!batch.replace && response.statusCode == 409) {
      // Made by an earlier try whose response was lost.
      response = await _send(batch, replace: true);
    }
    if (response.statusCode == 404) throw const DriveFileMissing();
    final stored = _json(response);
    if (stored['id'] != batch.fileId ||
        stored['md5Checksum'] != batch.checksum ||
        stored['size'].toString() != '${batch.payload.length}') {
      throw const DriveSyncException(
        'Drive could not verify the upload. Your changes remain queued.',
      );
    }
  }

  Future<http.Response> _send(SyncBatch batch, {required bool replace}) async {
    final boundary = 'simplemoney_${batch.fileId}';
    final encrypted = backupBatchEncryption(batch.payload) != null;
    final mime = encrypted ? 'application/octet-stream' : 'application/gzip';
    final properties = {
      'format': sectionFileFormat,
      'mirrorId': batch.mirrorId,
      'sequence': '${batch.sequence}',
      'section': batch.section,
      'rows': '${batch.rows}',
      'newest': '${batch.newest}',
      'enc': batch.encryption,
      'encAt': '${batch.encryptionAt}',
    };
    final metadata = jsonEncode(
      replace
          ? {'mimeType': mime, 'appProperties': properties}
          : {
              'id': batch.fileId,
              'name':
                  'simple-money-${batch.mirrorId}-'
                  '${batch.section.replaceAll('/', '-')}'
                  '.${encrypted ? 'json.enc' : 'json.gz'}',
              'parents': ['appDataFolder'],
              'mimeType': mime,
              'appProperties': properties,
            },
    );
    final body = <int>[
      ...utf8.encode(
        '--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n$metadata\r\n'
        '--$boundary\r\nContent-Type: $mime\r\n\r\n',
      ),
      ...batch.payload,
      ...utf8.encode('\r\n--$boundary--\r\n'),
    ];
    final request =
        http.Request(
            replace ? 'PATCH' : 'POST',
            Uri.https(
              'www.googleapis.com',
              replace
                  ? '/upload/drive/v3/files/${batch.fileId}'
                  : '/upload/drive/v3/files',
              {'uploadType': 'multipart', 'fields': 'id,md5Checksum,size'},
            ),
          )
          ..headers.addAll({
            ..._headers,
            'Content-Type': 'multipart/related; boundary=$boundary',
          })
          ..bodyBytes = body;
    return http.Response.fromStream(
      await _client.send(request).timeout(const Duration(seconds: 90)),
    ).timeout(const Duration(seconds: 90));
  }

  @override
  Future<List<MirrorFile>> listFiles({DateTime? modifiedAfter}) async {
    final files = <MirrorFile>[];
    String? pageToken;
    final formats = [sectionFileFormat, deviceFileFormat, legacyBatchFormat]
        .map((f) => "appProperties has { key='format' and value='$f' }")
        .join(' or ');
    final since = modifiedAfter == null
        ? ''
        : " and modifiedTime > '${modifiedAfter.toUtc().toIso8601String()}'";
    do {
      final data = _json(
        await _client
            .get(
              Uri.https('www.googleapis.com', '/drive/v3/files', {
                'spaces': 'appDataFolder',
                'q': '($formats) and trashed = false$since',
                'fields': 'nextPageToken,files(id,modifiedTime,appProperties)',
                'pageSize': '1000',
                'pageToken': ?pageToken,
              }),
              headers: _headers,
            )
            .timeout(const Duration(seconds: 30)),
      );
      for (final file in data['files'] as List? ?? const []) {
        if (_fileOf(file) case final parsed?) files.add(parsed);
      }
      pageToken = data['nextPageToken'] as String?;
    } while (pageToken != null);
    return files;
  }

  /// A SimpleMoney file from Drive's metadata, or null for anything else.
  static MirrorFile? _fileOf(Object? file) {
    if (file is! Map || file['trashed'] == true) return null;
    final properties = file['appProperties'] as Map? ?? const {};
    final format = properties['format'];
    if (format != sectionFileFormat &&
        format != deviceFileFormat &&
        format != legacyBatchFormat) {
      return null;
    }
    final mirrorId = properties['mirrorId'];
    final sequence = int.tryParse('${properties['sequence']}');
    final modified = DateTime.tryParse('${file['modifiedTime']}');
    if (mirrorId is! String || sequence == null || modified == null) {
      return null;
    }
    return MirrorFile(
      id: file['id'] as String,
      mirrorId: mirrorId,
      sequence: sequence,
      modified: modified,
      isDeviceFile: format == deviceFileFormat,
      section: format == sectionFileFormat
          ? properties['section'] as String?
          : null,
      rows: int.tryParse('${properties['rows']}'),
      newest: int.tryParse('${properties['newest']}'),
      encryption: properties['enc'] as String?,
      encryptionAt: int.tryParse('${properties['encAt']}'),
    );
  }

  @override
  Future<String> startToken() async =>
      _json(
            await _client
                .get(
                  Uri.https(
                    'www.googleapis.com',
                    '/drive/v3/changes/startPageToken',
                  ),
                  headers: _headers,
                )
                .timeout(const Duration(seconds: 30)),
          )['startPageToken']
          as String;

  @override
  Future<(List<MirrorFile>, String)> changesSince(String token) async {
    final files = <MirrorFile>[];
    var pageToken = token;
    while (true) {
      final data = _json(
        await _client
            .get(
              Uri.https('www.googleapis.com', '/drive/v3/changes', {
                'pageToken': pageToken,
                'spaces': 'appDataFolder',
                'pageSize': '1000',
                'fields':
                    'nextPageToken,newStartPageToken,'
                    'changes(removed,file(id,modifiedTime,trashed,appProperties))',
              }),
              headers: _headers,
            )
            .timeout(const Duration(seconds: 30)),
      );
      for (final change in data['changes'] as List? ?? const []) {
        if (change is! Map || change['removed'] == true) continue;
        if (_fileOf(change['file']) case final parsed?) files.add(parsed);
      }
      if (data['newStartPageToken'] case final String next) {
        return (files, next);
      }
      final next = data['nextPageToken'];
      if (next is! String) return (files, pageToken);
      pageToken = next;
    }
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
