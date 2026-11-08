import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The most the attachments of one report may add up to.
const maxReportFileBytes = 30 * 1024 * 1024;

/// How many files one report takes.
const maxReportFiles = 10;

/// Why a report didn't go, in words for the user.
class IssueReportException implements Exception {
  const IssueReportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Sends Help › Send feedback to the developer's Telegram channel, with the
/// bot Report SMS uses (its token and chat come from the build).
class IssueReporter {
  IssueReporter({http.Client? client, String? baseUrl, this.credentials})
    : _client = client ?? http.Client(),
      _baseUrl = baseUrl ?? 'https://api.telegram.org';
  final http.Client _client;
  final String _baseUrl;

  /// For tests; otherwise read from the app's build.
  final Future<({String token, String chat})> Function()? credentials;

  static const _channel = MethodChannel('simple_money/help_improve');

  Future<({String token, String chat})> _credentials() async {
    if (credentials != null) return credentials!();
    final map = await _channel.invokeMapMethod<String, String>('credentials');
    final token = map?['token'] ?? '';
    final chat = map?['chat'] ?? '';
    if (token.isEmpty || chat.isEmpty) throw const _Failed();
    return (token: token, chat: chat);
  }

  /// Stops a send that is under way, for when the user leaves. The reporter
  /// is not used again after this.
  void cancel() => _client.close();

  /// Throws [IssueReportException] when [text] is empty, the file is too big,
  /// or the report couldn't be delivered.
  ///
  /// The files together may not pass 30 MB. [onProgress] gets 0 to 1 as they
  /// are handed to the network, so big attachments can show how far they
  /// have got.
  Future<void> send(
    String text, {
    String contact = '',
    List<PlatformFile> files = const [],
    void Function(double progress)? onProgress,
  }) async {
    final body = text.trim();
    if (body.isEmpty) {
      throw const IssueReportException('Tell us what went wrong first.');
    }
    if (files.length > maxReportFiles) {
      throw const IssueReportException('Attach up to 10 files.');
    }
    final sizes = [for (final file in files) await file.length()];
    final total = sizes.fold(0, (sum, size) => sum + size);
    if (total > maxReportFileBytes) {
      throw const IssueReportException('That file is over 30 MB.');
    }
    try {
      final (:token, :chat) = await _credentials();
      final api = '$_baseUrl/bot$token';
      final version = await _appVersion();
      final install = (await _install()).substring(0, 8);
      final reply = contact.trim();
      final message =
          'Feedback\nApp $version · $install\n\n$body'
          '${reply.isEmpty ? '' : '\n\nContact: $reply'}';
      for (var at = 0; at < message.length; at += 4096) {
        final end = min(at + 4096, message.length);
        await _post(
          http.MultipartRequest('POST', Uri.parse('$api/sendMessage'))
            ..fields['chat_id'] = chat
            ..fields['text'] = message.substring(at, end),
        );
      }
      var handed = 0;
      for (final (i, file) in files.indexed) {
        await _post(
          http.MultipartRequest('POST', Uri.parse('$api/sendDocument'))
            ..fields['chat_id'] = chat
            ..fields['caption'] = files.length == 1
                ? 'Attachment · ${file.name}'
                : 'Attachment ${i + 1} of ${files.length} · ${file.name}'
            ..files.add(
              http.MultipartFile(
                'document',
                file.readAsByteStream().map((chunk) {
                  handed += chunk.length;
                  onProgress?.call(
                    total == 0 ? 1 : (handed / total).clamp(0.0, 1.0),
                  );
                  return chunk;
                }),
                sizes[i],
                filename: file.name,
              ),
            ),
        );
      }
    } on IssueReportException {
      rethrow;
    } catch (_) {
      throw const IssueReportException(
        'Couldn’t send. Check your connection and try again.',
      );
    }
  }

  Future<void> _post(http.MultipartRequest request) async {
    final response = await _client
        .send(request)
        .timeout(const Duration(minutes: 3));
    await response.stream.drain<void>();
    if (response.statusCode == 413) {
      throw const IssueReportException('That file is over 30 MB.');
    }
    if (response.statusCode == 429) {
      throw const IssueReportException('Too many reports. Try again soon.');
    }
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw const _Failed();
    }
  }

  /// The random ID the community fixes use, made once, so a report can be
  /// told apart from another phone's. It says nothing about the user.
  Future<String> _install() async {
    final prefs = await SharedPreferences.getInstance();
    const key = 'community.install';
    if (prefs.getString(key) case final id?) return id;
    final random = Random.secure();
    final id = [
      for (var i = 0; i < 16; i++)
        random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ].join();
    await prefs.setString(key, id);
    return id;
  }

  Future<String> _appVersion() async {
    try {
      final info = await PackageInfo.fromPlatform();
      return '${info.version}+${info.buildNumber}';
    } catch (_) {
      return '';
    }
  }
}

class _Failed implements Exception {
  const _Failed();
}
