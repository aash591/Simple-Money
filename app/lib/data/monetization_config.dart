import 'package:flutter/foundation.dart';

/// Build-time settings from `--dart-define-from-file=.env` (see
/// `.env.example`). Prices are deliberately absent: Google Play owns them.
abstract final class MonetizationConfig {
  static const subscriptionId = String.fromEnvironment(
    'PRO_SUBSCRIPTION_ID',
    defaultValue: 'pro',
  );
  static const monthlyPlan = String.fromEnvironment(
    'PRO_MONTHLY_PLAN',
    defaultValue: 'monthly',
  );
  static const yearlyPlan = String.fromEnvironment(
    'PRO_YEARLY_PLAN',
    defaultValue: 'annual',
  );
  static const lifetimeId = String.fromEnvironment(
    'PRO_LIFETIME_ID',
    defaultValue: 'pro_lifetime',
  );

  static const _interstitialId = String.fromEnvironment(
    'ADMOB_INTERSTITIAL_ID',
  );
  static const _testInterstitialId = 'ca-app-pub-3940256099942544/1033173712';

  /// Google's test unit outside release builds, and whenever no real one was
  /// given, so development never serves (or clicks) live ads.
  static String get interstitialId => kReleaseMode && _interstitialId.isNotEmpty
      ? _interstitialId
      : _testInterstitialId;

  /// Whether the free plan's limits hold: seven budgets, and the first row
  /// of accent colours. On unless PRO_LIMITS=false in `.env`.
  static const enforceProLimits = bool.fromEnvironment(
    'PRO_LIMITS',
    defaultValue: true,
  );

  /// Whether the AI assistant's questions and fixes need Pro. Off until the
  /// app is live on Google Play and Pro can be bought, so the assistant is
  /// open to everyone; set AI_NEEDS_PRO=true in `.env` to hold it back.
  static const aiNeedsPro = bool.fromEnvironment('AI_NEEDS_PRO');

  /// Treats a debug build as if Pro were bought, so every Pro feature can be
  /// tried without buying. On unless DEBUG_PRO=false is given, and ignored
  /// in profile and release builds.
  static const debugPro = bool.fromEnvironment('DEBUG_PRO', defaultValue: true);

  static const freeUses = int.fromEnvironment('AD_FREE_USES', defaultValue: 0);
  static const minGap = Duration(
    minutes: int.fromEnvironment('AD_MIN_GAP_MINUTES', defaultValue: 0),
  );
  static const maxPerDay = int.fromEnvironment(
    'AD_MAX_PER_DAY',
    defaultValue: 1000000,
  );
}
