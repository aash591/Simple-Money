import 'dart:async';

import 'package:flutter/material.dart';

import '../../../data/agent/agent_suggestion_repository.dart';
import '../../../data/community/community_fixes.dart';
import '../../../data/user_sms_rules.dart';
import '../../components/app_toast.dart';
import '../../components/confirmation_alert.dart';

/// What of an approved suggestion can be shared: an SMS format without the
/// messages it was tested on, or a statement layout. Null for anything else.
(CommunityKind, Map<String, Object?>)? shareableFix(AgentSuggestion s) {
  final p = s.payload;
  return switch (s.kind) {
    AgentSuggestionKind.parserRule => (
      CommunityKind.smsRule,
      {
        'bankName': p['bankName'],
        'senders': p['senders'],
        'format': p['format'],
        // The category the rule files a message under, for the dashboard.
        if (_ruleCategory(s) case final category?)
          'resolved': {'category': category},
      },
    ),
    AgentSuggestionKind.statementLayout => (
      CommunityKind.statementLayout,
      {'signature': p['signature'], 'mapping': p['mapping']},
    ),
    _ => null,
  };
}

/// The category a rule's messages file under: the one the parser found, or
/// else the one the user picked when saving its sample. The catch-all
/// "Personal" says nothing.
String? _ruleCategory(AgentSuggestion s) {
  String? real(String? name) {
    final clean = name?.trim();
    return clean == null || clean.isEmpty || clean.toLowerCase() == 'personal'
        ? null
        : clean;
  }

  for (final line in s.detail) {
    if (line.startsWith('Category: ')) {
      if (real(line.substring(10)) case final name?) return name;
    }
  }
  return real(s.payload['savedCategory'] as String?);
}

/// A rule the user taught by hand, offered for sharing the way an AI-taught
/// one is. Only the format goes, unless [withMessage]: then the message it
/// was taught from is sent too, and the note says so. True when it was
/// shared.
Future<bool> offerToShareRule(
  BuildContext context,
  CommunitySync community,
  UserSmsRule rule, {
  String? category,
  bool withMessage = false,
}) async {
  final fix = <String, Object?>{
    'bankName': rule.bankName,
    'senders': rule.senders,
    'format': rule.format,
    if (category != null &&
        category.trim().isNotEmpty &&
        category.trim().toLowerCase() != 'personal')
      'resolved': {'category': category.trim()},
  };
  final share = await showConfirmationAlert(
    context,
    title: 'Share this fix?',
    message: withMessage
        ? 'Share it so others with ${rule.bankName} get it too. The format '
              'goes with this message and its sender, so it can be checked. '
              'No personal info is shared.'
        : 'Share it so others with ${rule.bankName} get it too. Only the '
              'format is shared, never your messages.',
    confirmLabel: 'Share',
    cancelLabel: 'Not now',
    destructive: false,
    autofocusCancel: false,
  );
  await CommunitySync.noteRules([fix], sent: share);
  if (!share) return false;
  unawaited(community.share([(CommunityKind.smsRule, fix)]));
  if (context.mounted) {
    showAppToast(
      context,
      'Thanks! You’re helping others.',
      icon: Icons.favorite_rounded,
    );
  }
  return true;
}

/// Right after fixes are approved: a well-done note that offers to share the
/// same fixes, so others with the same bank or statement get them without
/// asking an AI. Asked each time; nothing is shared unless the user taps
/// Share.
Future<void> offerToShareFixes(
  BuildContext context,
  CommunitySync community,
  Iterable<AgentSuggestion> approved,
) async {
  final shareable = [
    for (final s in approved)
      if (shareableFix(s) case final fix?) (s, fix),
  ];
  if (shareable.isEmpty || !context.mounted) return;
  final sms = [
    for (final (s, _) in shareable)
      if (s.kind == AgentSuggestionKind.parserRule) s,
  ];
  final banks = {
    for (final s in sms)
      if (s.payload['bankName'] case final String bank) bank,
  };
  final String message;
  if (shareable.length > 1) {
    message =
        '${shareable.length} fixes added. Share them so others get them too. '
        'Only formats and column names are shared, never your messages or data.';
  } else if (sms.isNotEmpty) {
    final bank = banks.firstOrNull ?? 'this bank';
    message =
        'Your $bank SMS will now be added. Share this fix so others with '
        '$bank get it too. Only the format is shared, never your messages.';
  } else {
    message =
        'This statement can now be read. Share this fix so others with the '
        'same statement get it too. Only the column names are shared, never '
        'your data.';
  }
  final share = await showConfirmationAlert(
    context,
    title: shareable.length > 1 ? 'Nice, all fixed!' : 'Nice, it’s fixed!',
    message: message,
    confirmLabel: 'Share',
    cancelLabel: 'Not now',
    destructive: false,
    autofocusCancel: false,
  );
  // Remembered either way, so a rule isn't sent later on its own: not after
  // "Not now", nor a second time after Share.
  await CommunitySync.noteRules([
    for (final (kind, payload) in [for (final (_, fix) in shareable) fix])
      if (kind == CommunityKind.smsRule) payload,
  ], sent: share);
  if (!share) return;
  unawaited(community.share([for (final (_, fix) in shareable) fix]));
  if (context.mounted) {
    showAppToast(
      context,
      'Thanks! You’re helping others.',
      icon: Icons.favorite_rounded,
    );
  }
}
