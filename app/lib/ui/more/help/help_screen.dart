import 'package:flutter/material.dart';

import 'package:url_launcher/url_launcher.dart';

import '../../../data/app_links.dart';
import '../../components/app_toast.dart';
import '../../components/feature_page.dart';
import '../../components/menu_list.dart';
import 'about/about_screen.dart';
import 'report_issue_screen.dart';

final _faqUrl = Uri.parse('https://simplemoney.aashglobal.in/');

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key, this.communityUrl = AppLinks.community});

  /// Where Join community goes; empty hides the row.
  final String communityUrl;

  Future<void> _open(BuildContext context, Uri url, String failure) async {
    final opened = await launchUrl(
      url,
      mode: LaunchMode.externalApplication,
    ).catchError((_) => false);
    if (!opened && context.mounted) showAppToast(context, failure);
  }

  Future<void> _openFaq(BuildContext context) =>
      _open(context, _faqUrl, 'Could not open the browser');

  Future<void> _openCommunity(BuildContext context) => _open(
    context,
    Uri.parse(communityUrl),
    'Could not open the community link',
  );

  @override
  Widget build(BuildContext context) => FeaturePage(
    title: 'Help',
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 8, 18, 40),
          children: [
            MenuGroup(
              children: [
                MenuRow(
                  icon: Icons.help_rounded,
                  title: 'FAQ',
                  subtitle: 'Answers to common questions',
                  external: true,
                  onTap: () => _openFaq(context),
                ),
                if (communityUrl.isNotEmpty)
                  MenuRow(
                    icon: Icons.groups_rounded,
                    title: 'Join community',
                    subtitle: 'Chat with other users, ask and share tips',
                    external: true,
                    onTap: () => _openCommunity(context),
                  ),
                MenuRow(
                  icon: Icons.rate_review_outlined,
                  title: 'Send feedback',
                  subtitle: 'Report a problem or request a feature',
                  onTap: () =>
                      Navigator.of(context)
                          .push(FeatureRoute<void>(const ReportIssueScreen())),
                ),
              ],
            ),
            const SizedBox(height: 24),
            MenuGroup(
              children: [
                MenuRow(
                  icon: Icons.info_rounded,
                  title: 'About SimpleMoney',
                  onTap: () =>
                      Navigator.of(context)
                          .push(FeatureRoute<void>(const AboutScreen())),
                ),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
