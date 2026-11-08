import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:in_app_purchase/in_app_purchase.dart';
import 'package:in_app_purchase_android/billing_client_wrappers.dart';
import 'package:in_app_purchase_android/in_app_purchase_android.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/monetization_config.dart';

enum ProPlanKind { yearly, monthly, lifetime }

/// One way to buy Pro, priced by Google Play.
class ProPlan {
  const ProPlan(this.kind, this.product, {this.trial});
  final ProPlanKind kind;

  /// The base plan (or the one-time product), whose price is shown.
  final GooglePlayProductDetails product;

  /// A free-trial offer on the base plan, when Play says this user may use it.
  final GooglePlayProductDetails? trial;

  String get price => product.price;
  double get rawPrice => product.rawPrice;

  /// "7-day free trial", from the offer's ISO 8601 period such as P7D.
  String? get trialLabel {
    final offer = trial
        ?.productDetails
        .subscriptionOfferDetails?[trial!.subscriptionIndex!];
    final period = offer?.pricingPhases.first.billingPeriod;
    final match = RegExp(r'^P(\d+)([DWM])$').firstMatch(period ?? '');
    if (match == null) return null;
    final unit = switch (match[2]) {
      'D' => 'day',
      'W' => 'week',
      _ => 'month',
    };
    return '${match[1]}-$unit free trial';
  }
}

/// Whether this install owns Pro, and the plans to buy it with.
///
/// Play is the source of truth; the last answer is cached so Pro holds while
/// offline. There is no server, so the check runs on the device.
class ProController extends ChangeNotifier {
  ProController._();
  static final instance = ProController._();

  static const _lifetimeKey = 'pro_lifetime';
  static const _subscribedKey = 'pro_subscribed';

  // A getter: the instance connects to Play on creation, which must wait for
  // [start] rather than the first [isPro] check.
  InAppPurchase get _iap => InAppPurchase.instance;
  StreamSubscription<List<PurchaseDetails>>? _purchases;

  bool ownsLifetime = false;
  bool subscribed = false;
  bool get isPro => ownsLifetime || subscribed;

  /// Whether the free plan's limits (budgets, accent colours) are open: for
  /// Pro, and for everyone while [enforceLimits] is off. [isPro] stays the
  /// truth about what was bought (it also turns ads off).
  bool get featuresUnlocked => isPro || !enforceLimits;

  /// Whether the AI assistant's questions and fixes are open: for Pro, and
  /// for everyone while [aiNeedsPro] is off.
  bool get aiUnlocked => isPro || !aiNeedsPro;

  /// [MonetizationConfig.enforceProLimits] and
  /// [MonetizationConfig.aiNeedsPro]; tests change them to check each case.
  @visibleForTesting
  static bool enforceLimits = MonetizationConfig.enforceProLimits;
  @visibleForTesting
  static bool aiNeedsPro = MonetizationConfig.aiNeedsPro;

  /// Budgets a free user may keep; each after the first takes a short ad.
  static const freeBudgets = 7;

  bool storeAvailable = false;
  bool loadingPlans = false;
  bool purchasing = false;

  /// Paid with a method that settles later, such as some UPI payments.
  bool pending = false;
  String? error;
  List<ProPlan> plans = const [];

  Future<void> start() async {
    if (_purchases != null) return;
    final prefs = await SharedPreferences.getInstance();
    ownsLifetime = prefs.getBool(_lifetimeKey) ?? false;
    subscribed = prefs.getBool(_subscribedKey) ?? false;
    notifyListeners();
    _purchases = _iap.purchaseStream.listen(_onPurchases, onError: (_) {});
    try {
      storeAvailable = await _iap.isAvailable();
    } catch (_) {
      storeAvailable = false;
    }
    notifyListeners();
    if (storeAvailable) await Future.wait([refresh(), loadPlans()]);
  }

  /// Re-reads what Play says this account owns. An expired or refunded
  /// subscription drops out here.
  Future<void> refresh() async {
    if (!storeAvailable) return;
    try {
      final response = await _iap
          .getPlatformAddition<InAppPurchaseAndroidPlatformAddition>()
          .queryPastPurchases();
      if (response.error != null) return;
      final owned = [
        for (final purchase in response.pastPurchases)
          if (purchase.billingClientPurchase.purchaseState ==
              PurchaseStateWrapper.purchased)
            purchase,
      ];
      for (final purchase in owned) {
        // Play refunds purchases left unacknowledged for three days.
        if (purchase.pendingCompletePurchase) {
          await _iap.completePurchase(purchase);
        }
      }
      await _save(
        lifetime: owned.any(
          (p) => p.productID == MonetizationConfig.lifetimeId,
        ),
        subscription: owned.any(
          (p) => p.productID == MonetizationConfig.subscriptionId,
        ),
      );
    } catch (_) {
      // Offline or Play unavailable: keep the cached answer.
    }
  }

  Future<void> loadPlans() async {
    if (!storeAvailable || loadingPlans) return;
    loadingPlans = true;
    notifyListeners();
    try {
      final response = await _iap.queryProductDetails({
        MonetizationConfig.subscriptionId,
        MonetizationConfig.lifetimeId,
      });
      final products = response.productDetails
          .whereType<GooglePlayProductDetails>()
          .toList();
      plans = [for (final kind in ProPlanKind.values) ?_plan(kind, products)];
    } catch (_) {
      plans = const [];
    } finally {
      loadingPlans = false;
      notifyListeners();
    }
  }

  static ProPlan? _plan(
    ProPlanKind kind,
    List<GooglePlayProductDetails> products,
  ) {
    if (kind == ProPlanKind.lifetime) {
      final product = products
          .where((p) => p.id == MonetizationConfig.lifetimeId)
          .firstOrNull;
      return product == null ? null : ProPlan(kind, product);
    }
    final basePlan = kind == ProPlanKind.monthly
        ? MonetizationConfig.monthlyPlan
        : MonetizationConfig.yearlyPlan;
    GooglePlayProductDetails? base, trial;
    for (final product in products) {
      final index = product.subscriptionIndex;
      if (product.id != MonetizationConfig.subscriptionId || index == null) {
        continue;
      }
      final offer = product.productDetails.subscriptionOfferDetails![index];
      if (offer.basePlanId != basePlan) continue;
      if (offer.offerId == null) {
        base = product;
      } else if (offer.pricingPhases.first.priceAmountMicros == 0) {
        trial = product;
      }
    }
    return base == null ? null : ProPlan(kind, base, trial: trial);
  }

  Future<void> buy(ProPlan plan) async {
    if (purchasing) return;
    final details = plan.trial ?? plan.product;
    purchasing = true;
    error = null;
    notifyListeners();
    try {
      final started = await _iap.buyNonConsumable(
        purchaseParam: GooglePlayPurchaseParam(
          productDetails: details,
          offerToken: details.offerToken,
        ),
      );
      if (!started) throw StateError('Purchase did not start.');
    } catch (_) {
      purchasing = false;
      error = 'Could not start the purchase. Please try again.';
      notifyListeners();
      // Most often the account already owns it.
      unawaited(refresh());
    }
  }

  /// For "Restore purchases": true when this account owns Pro.
  Future<bool> restore() async {
    await refresh();
    return isPro;
  }

  Future<void> _onPurchases(List<PurchaseDetails> updates) async {
    for (final purchase in updates) {
      final lifetime = purchase.productID == MonetizationConfig.lifetimeId;
      final ours =
          lifetime || purchase.productID == MonetizationConfig.subscriptionId;
      if (ours) {
        switch (purchase.status) {
          case PurchaseStatus.pending:
            pending = true;
          case PurchaseStatus.purchased || PurchaseStatus.restored:
            purchasing = pending = false;
            await _save(
              lifetime: lifetime || ownsLifetime,
              subscription: !lifetime || subscribed,
            );
          case PurchaseStatus.error:
            purchasing = pending = false;
            error = 'The purchase did not go through. Please try again.';
          case PurchaseStatus.canceled:
            purchasing = pending = false;
        }
      }
      if (purchase.pendingCompletePurchase) {
        await _iap.completePurchase(purchase);
      }
    }
    notifyListeners();
  }

  Future<void> _save({
    required bool lifetime,
    required bool subscription,
  }) async {
    if (lifetime == ownsLifetime && subscription == subscribed) return;
    ownsLifetime = lifetime;
    subscribed = subscription;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_lifetimeKey, lifetime);
    await prefs.setBool(_subscribedKey, subscription);
  }

  @override
  void dispose() {
    _purchases?.cancel();
    super.dispose();
  }
}
