import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// The picture behind the Aurora style: one image the user chose, copied
/// into the app's own storage so it stays even if the original moves.
class AuroraWallpaper {
  /// Where the copy goes; tests point it at a temporary folder.
  @visibleForTesting
  static Future<Directory> Function() directory =
      getApplicationSupportDirectory;

  /// Lets the user pick a picture and returns where its copy is saved, or
  /// null when they back out. [pick] stands in for the system picker.
  static Future<String?> choose({Future<String?> Function()? pick}) async {
    final source = await (pick ?? _pick)();
    if (source == null) return null;
    final folder = Directory('${(await directory()).path}/wallpaper');
    await folder.create(recursive: true);
    // A new name each time, so a picture already on screen is never served
    // from the image cache after it was replaced.
    final saved = File(
      '${folder.path}/aurora_${DateTime.now().microsecondsSinceEpoch}'
      '${_extension(source)}',
    );
    await File(source).copy(saved.path);
    return saved.path;
  }

  /// Deletes every saved picture except [keep].
  static Future<void> tidy({String? keep}) async {
    final folder = Directory('${(await directory()).path}/wallpaper');
    if (!await folder.exists()) return;
    await for (final entry in folder.list()) {
      if (entry is File && _same(entry.path, keep) == false) {
        try {
          await entry.delete();
        } catch (_) {}
      }
    }
  }

  static bool _same(String a, String? b) =>
      b != null && a.replaceAll(r'\', '/') == b.replaceAll(r'\', '/');

  static Future<String?> _pick() async {
    final files = await FilePicker.pickFiles(type: FileType.image);
    return files.firstOrNull?.path;
  }

  static String _extension(String path) {
    final dot = path.lastIndexOf('.');
    final ext = dot < 0 ? '' : path.substring(dot).toLowerCase();
    return const {'.jpg', '.jpeg', '.png', '.webp'}.contains(ext)
        ? ext
        : '.jpg';
  }
}
