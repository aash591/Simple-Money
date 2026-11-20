import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

/// Opens SimpleMoney's page in the Play Store app, or on the web where the
/// Play Store isn't installed.
Future<void> openPlayStorePage() async {
  final info = await PackageInfo.fromPlatform();
  final market = Uri.parse('market://details?id=${info.packageName}');
  if (!await launchUrl(market, mode: LaunchMode.externalApplication)) {
    await launchUrl(
      Uri.https('play.google.com', '/store/apps/details', {
        'id': info.packageName,
      }),
      mode: LaunchMode.externalApplication,
    );
  }
}
