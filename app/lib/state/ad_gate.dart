import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/monetization_config.dart';
import 'pro_controller.dart';

/// The only places an ad may follow. Everyday use (opening the app, adding
/// transactions, browsing) never shows one.
enum AdMoment { budget, statementImport, theme, loan, recurringPayment }

/// Decides whether a finished action earns an interstitial, and keeps one
/// loaded so it can show at once rather than popping up late.
///
/// Each moment is ad-free for its first [MonetizationConfig.freeUses] times;
/// after that ads are spaced by [MonetizationConfig.minGap] and capped at
/// [MonetizationConfig.maxPerDay]. Pro never sees one.
class AdGate {
  AdGate._();
  static final instance = AdGate._();

  static const _lastShownKey = 'ad_last_shown';
  static const _dayKey = 'ad_day';
  static const _dayCountKey = 'ad_day_count';
  // Google expires a loaded interstitial after an hour.
  static const _adLifetime = Duration(minutes: 55);

  InterstitialAd? _ad;
  DateTime? _loadedAt;
  bool _loading = false;
  bool _ready = false;
  bool _showing = false;
  Future<void>? _starting;

  static String _usesKey(AdMoment moment) => 'ad_uses_${moment.name}';

  /// Off in tests, where no ad SDK answers and an unlock would wait on it.
  @visibleForTesting
  static bool enabled = true;

  /// At launch, for people already past their free uses who consented
  /// before: loads an ad quietly so the next moment can show it. Never shows
  /// the consent form, which waits for a moment instead.
  Future<void> prepare() async {
    if (ProController.instance.isPro) return;
    final prefs = await SharedPreferences.getInstance();
    final due = AdMoment.values.any(
      (m) => (prefs.getInt(_usesKey(m)) ?? 0) >= MonetizationConfig.freeUses,
    );
    if (due) await _start(showForm: false);
  }

  /// Call once [moment] has finished and its success is on screen.
  Future<void> after(AdMoment moment) async {
    if (ProController.instance.isPro || _showing) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final uses = (prefs.getInt(_usesKey(moment)) ?? 0) + 1;
      await prefs.setInt(_usesKey(moment), uses);
      if (uses <= MonetizationConfig.freeUses) {
        // The last free one gets an ad ready for next time.
        if (uses == MonetizationConfig.freeUses) {
          await _start(showForm: true);
        }
        return;
      }
      final ad = _fresh();
      if (ad == null || !_allowed(prefs)) {
        await _start(showForm: true);
        return;
      }
      // Let the success toast land before the ad covers it.
      await Future<void>.delayed(const Duration(milliseconds: 600));
      if (ProController.instance.isPro || _showing) return;
      await _show(ad, prefs);
    } catch (_) {
      // An ad is never worth breaking the action that came before it.
    }
  }

  /// Shows an ad now, for something the user unlocks by watching one (a new
  /// budget, an accent colour). Resolves once the ad is closed, or at once
  /// when none can show (Pro, offline, no consent, nothing to fill it), so
  /// the action never waits on an ad that won't come.
  ///
  /// [onShowing] runs just before the ad opens, so a loading indicator can
  /// close first.
  Future<void> watch({VoidCallback? onShowing}) async {
    if (!enabled || ProController.instance.isPro || _showing) return;
    try {
      await _start(showForm: true).timeout(const Duration(seconds: 8));
      var ad = _fresh();
      // One may still be loading: give it a few seconds.
      for (var i = 0; ad == null && _loading && i < 16; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        ad = _fresh();
      }
      if (ad == null || ProController.instance.isPro) return;
      onShowing?.call();
      final closed = Completer<void>();
      await _show(
        ad,
        await SharedPreferences.getInstance(),
        onClosed: closed.complete,
      );
      await closed.future.timeout(const Duration(minutes: 3), onTimeout: () {});
    } catch (_) {
      // The unlock goes ahead without its ad.
    }
  }

  /// True when [watch] may have to wait for an ad to load first.
  bool get mayWait =>
      enabled && !ProController.instance.isPro && !_showing && _fresh() == null;

  /// True when an ad is needed, none is ready, and the phone has no network:
  /// the ad can't load, so the caller should ask for the internet instead of
  /// letting the action through for free.
  Future<bool> get blockedOffline async =>
      mayWait &&
      (await Connectivity().checkConnectivity()).every(
        (network) => network == ConnectivityResult.none,
      );

  /// GDPR regions must offer a way to change ad consent later.
  Future<bool> privacyOptionsRequired() async {
    if (!_ready) return false;
    return await ConsentInformation.instance
            .getPrivacyOptionsRequirementStatus() ==
        PrivacyOptionsRequirementStatus.required;
  }

  Future<void> showPrivacyOptions() =>
      ConsentForm.showPrivacyOptionsForm((_) {});

  InterstitialAd? _fresh() {
    final loadedAt = _loadedAt;
    if (_ad != null &&
        loadedAt != null &&
        DateTime.now().difference(loadedAt) > _adLifetime) {
      _ad!.dispose();
      _ad = null;
    }
    return _ad;
  }

  bool _allowed(SharedPreferences prefs) {
    final now = DateTime.now();
    final last = prefs.getInt(_lastShownKey);
    if (last != null &&
        now.difference(DateTime.fromMillisecondsSinceEpoch(last)) <
            MonetizationConfig.minGap) {
      return false;
    }
    final shownToday = prefs.getString(_dayKey) == _today(now)
        ? prefs.getInt(_dayCountKey) ?? 0
        : 0;
    return shownToday < MonetizationConfig.maxPerDay;
  }

  static String _today(DateTime now) => '${now.year}-${now.month}-${now.day}';

  Future<void> _show(
    InterstitialAd ad,
    SharedPreferences prefs, {
    void Function()? onClosed,
  }) async {
    _ad = null;
    _showing = true;
    void done(Ad ad) {
      ad.dispose();
      _showing = false;
      onClosed?.call();
      if (!ProController.instance.isPro) _load();
    }

    ad.fullScreenContentCallback = FullScreenContentCallback(
      onAdDismissedFullScreenContent: done,
      onAdFailedToShowFullScreenContent: (ad, _) => done(ad),
    );
    final now = DateTime.now();
    final today = _today(now);
    final shownToday = prefs.getString(_dayKey) == today
        ? prefs.getInt(_dayCountKey) ?? 0
        : 0;
    await prefs.setInt(_lastShownKey, now.millisecondsSinceEpoch);
    await prefs.setString(_dayKey, today);
    await prefs.setInt(_dayCountKey, shownToday + 1);
    await ad.show();
  }

  Future<void> _start({required bool showForm}) =>
      _starting ??= _initialize(showForm).whenComplete(() => _starting = null);

  Future<void> _initialize(bool showForm) async {
    if (!_ready) {
      if (!await _consent(showForm)) return;
      await MobileAds.instance.initialize();
      _ready = true;
    }
    _load();
  }

  /// Google's consent form, shown only where the law needs it (EEA, UK).
  Future<bool> _consent(bool showForm) async {
    final updated = Completer<void>();
    ConsentInformation.instance.requestConsentInfoUpdate(
      ConsentRequestParameters(),
      updated.complete,
      (_) => updated.complete(),
    );
    await updated.future;
    if (showForm) {
      final dismissed = Completer<void>();
      await ConsentForm.loadAndShowConsentFormIfRequired(
        (_) => dismissed.complete(),
      );
      await dismissed.future;
    }
    return ConsentInformation.instance.canRequestAds();
  }

  void _load() {
    if (_fresh() != null || _loading) return;
    _loading = true;
    InterstitialAd.load(
      adUnitId: MonetizationConfig.interstitialId,
      request: const AdRequest(),
      adLoadCallback: InterstitialAdLoadCallback(
        onAdLoaded: (ad) {
          _loading = false;
          _ad = ad;
          _loadedAt = DateTime.now();
        },
        onAdFailedToLoad: (_) => _loading = false,
      ),
    );
  }
}
