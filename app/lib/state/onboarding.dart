import 'package:shared_preferences/shared_preferences.dart';

/// The first-open setup. It is the app's first screen until finished, so
/// nothing slides in over Home after it has drawn.
abstract final class Onboarding {
  static const doneKey = 'onboarding_done';

  /// Set by the earlier one-page backup welcome too: installs that saw it
  /// skip the backup step.
  static const backupSeenKey = 'backup_welcome_seen';

  static Future<bool> needed() async =>
      !((await SharedPreferences.getInstance()).getBool(doneKey) ?? false);

  static Future<bool> backupSeen() async =>
      (await SharedPreferences.getInstance()).getBool(backupSeenKey) ?? false;

  static Future<void> finish({required bool sawBackup}) async {
    final prefs = await SharedPreferences.getInstance();
    if (sawBackup) await prefs.setBool(backupSeenKey, true);
    await prefs.setBool(doneKey, true);
  }
}
