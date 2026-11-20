import 'dart:async';

import 'package:flutter/material.dart';

import '../../components/app_back_button.dart';
import '../../components/tab_header.dart';

import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../data/monetization_config.dart';
import '../../../data/play_store.dart';
import '../../../state/ad_gate.dart';
import '../../../state/pro_controller.dart';
import '../../components/action_buttons.dart';
import '../../components/app_toast.dart';
import 'pro_thanks.dart';

class ProScreen extends StatefulWidget {
  const ProScreen({super.key});

  @override
  State<ProScreen> createState() => _ProScreenState();
}

class _ProScreenState extends State<ProScreen>
    with SingleTickerProviderStateMixin {
  final _pro = ProController.instance;

  /// One burst of confetti: on opening as a supporter, the moment a
  /// purchase goes through, and whenever the badge is tapped.
  late final _confetti = AnimationController(
    vsync: this,
    duration: ConfettiBurst.burstDuration,
  );
  late bool _wasPro = _pro.isPro;
  var _selected = ProPlanKind.yearly;
  bool _restoring = false;
  late final _privacyOptions = AdGate.instance.privacyOptionsRequired();

  /// The opening burst for someone who already has Pro; cancelled if they
  /// leave first.
  Timer? _celebrateSoon;

  @override
  void initState() {
    super.initState();
    if (_pro.plans.isEmpty) _pro.loadPlans();
    _pro.addListener(_onProChanged);
    if (_wasPro) {
      // After the page has slid in, so the burst isn't lost in the
      // transition.
      _celebrateSoon = Timer(const Duration(milliseconds: 350), _celebrate);
    }
  }

  @override
  void dispose() {
    _celebrateSoon?.cancel();
    _pro.removeListener(_onProChanged);
    _confetti.dispose();
    super.dispose();
  }

  void _onProChanged() {
    if (_pro.isPro && !_wasPro) {
      HapticFeedback.mediumImpact();
      _celebrate();
    }
    _wasPro = _pro.isPro;
  }

  void _celebrate() {
    if (!mounted) return;
    _confetti.forward(from: 0);
  }

  Future<void> _review() => openPlayStorePage();

  ProPlan? _plan(ProPlanKind kind) =>
      _pro.plans.where((p) => p.kind == kind).firstOrNull;

  /// How much yearly saves over twelve months of monthly, as a whole percent.
  int? get _yearlySaving {
    final yearly = _plan(ProPlanKind.yearly);
    final monthly = _plan(ProPlanKind.monthly);
    if (yearly == null ||
        monthly == null ||
        yearly.product.currencyCode != monthly.product.currencyCode ||
        monthly.rawPrice <= 0) {
      return null;
    }
    final saving = (1 - yearly.rawPrice / (monthly.rawPrice * 12)) * 100;
    return saving >= 5 ? saving.round() : null;
  }

  Future<void> _restore() async {
    setState(() => _restoring = true);
    final owned = await _pro.restore();
    if (!mounted) return;
    setState(() => _restoring = false);
    showAppToast(
      context,
      owned ? 'Pro restored' : 'No Pro purchase found on this Google account',
    );
  }

  Future<void> _manage() async {
    final info = await PackageInfo.fromPlatform();
    await launchUrl(
      Uri.https('play.google.com', '/store/account/subscriptions', {
        'sku': MonetizationConfig.subscriptionId,
        'package': info.packageName,
      }),
      mode: LaunchMode.externalApplication,
    );
  }

  /// The hero's height below the status bar: shorter on a small phone, so
  /// the plans aren't pushed out of sight.
  static double _heroHeightFor(double screen) =>
      (screen * .3).clamp(200.0, 268.0);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final insets = MediaQuery.paddingOf(context);
    final heroHeight = _heroHeightFor(MediaQuery.sizeOf(context).height);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      // Light status bar icons over the coloured hero.
      value: SystemUiOverlayStyle.light.copyWith(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
      ),
      child: Scaffold(
        backgroundColor: scheme.surface,
        body: ListenableBuilder(
          listenable: _pro,
          builder: (context, _) {
            final plans = _ordered;
            final selected = plans.isEmpty
                ? null
                : (_plan(_selected) ?? plans.first);
            final buying =
                !_pro.isPro && selected != null && !_pro.loadingPlans;
            return Stack(
              children: [
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  height: insets.top + heroHeight + 40,
                  child: _Hero(
                    compact: heroHeight < 240,
                    owned: _pro.isPro,
                    lifetime: _pro.ownsLifetime,
                    onBadgeTap: _celebrate,
                    topInset: insets.top,
                    onBack: () => Navigator.maybePop(context),
                  ),
                ),
                Positioned.fill(
                  top: insets.top + heroHeight,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: scheme.surface,
                      borderRadius: const BorderRadius.vertical(
                        top: Radius.circular(32),
                      ),
                    ),
                    child: Column(
                      children: [
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(22, 26, 22, 16),
                            children: _pro.isPro
                                ? _owned(context)
                                : _offer(context, plans, selected),
                          ),
                        ),
                        _bottomBar(
                          context,
                          buying ? selected : null,
                          insets.bottom,
                        ),
                      ],
                    ),
                  ),
                ),
                Positioned.fill(
                  child: ConfettiBurst(
                    controller: _confetti,
                    originY: insets.top + heroHeight,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// What Pro gives: a short name and one plain line each, in its own
  /// colour.
  static const _perks = [
    ThanksPerk(
      Icons.auto_awesome_rounded,
      Color(0xff7c4dff),
      'AI assistant',
      'Ask Claude or ChatGPT about your money',
    ),
    ThanksPerk(
      Icons.pie_chart_rounded,
      Color(0xff0f9d7a),
      'Unlimited budgets',
      'Add as many as you like',
    ),
    ThanksPerk(
      Icons.palette_rounded,
      Color(0xffe0457b),
      'Every look',
      'All styles and colors, your own shade and picture',
    ),
    ThanksPerk(
      Icons.web_asset_off_rounded,
      Color(0xffe8830c),
      'No ads',
      'Never see an ad, anywhere',
    ),
  ];

  List<Widget> _owned(BuildContext context) => [
    ProThanksBody(
      lifetime: _pro.ownsLifetime,
      perks: _perks,
      onReview: _review,
    ),
  ];

  /// The plans in the order they're offered: monthly, yearly, lifetime.
  List<ProPlan> get _ordered => [
    for (final kind in [
      ProPlanKind.monthly,
      ProPlanKind.yearly,
      ProPlanKind.lifetime,
    ])
      ?_plan(kind),
  ];

  /// What twelve months of monthly would cost, in the plan's currency: the
  /// price yearly is struck against.
  String? _fullYear() {
    final monthly = _plan(ProPlanKind.monthly);
    if (_yearlySaving == null || monthly == null) return null;
    return NumberFormat.currency(
      symbol: monthly.product.currencySymbol,
      decimalDigits: 2,
    ).format(monthly.rawPrice * 12);
  }

  /// One plain line under the button: what is charged, and when.
  String _terms(ProPlan plan) {
    if (plan.kind == ProPlanKind.lifetime) {
      return 'One payment of ${plan.price} · Yours for good';
    }
    final period = plan.kind == ProPlanKind.yearly ? 'year' : 'month';
    final trial = plan.trialLabel;
    return trial == null
        ? '${plan.price} per $period · Cancel anytime'
        : '${trial[0].toUpperCase()}${trial.substring(1)}, then '
              '${plan.price} per $period · Cancel anytime';
  }

  List<Widget> _offer(
    BuildContext context,
    List<ProPlan> plans,
    ProPlan? selected,
  ) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final saving = _yearlySaving;
    return [
      Text(
        'Free is complete. Pro is nicer.',
        style: text.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
      const SizedBox(height: 6),
      Text(
        'Tracking your money is free, forever. Pro adds a few extras and '
        'helps keep SimpleMoney going.',
        style: text.bodyMedium?.copyWith(color: scheme.onSurfaceVariant),
      ),
      const SizedBox(height: 18),
      _Compare(aiFree: !_pro.aiRequiresPro),
      const SizedBox(height: 26),
      if (_pro.loadingPlans)
        const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator()),
        )
      else if (plans.isEmpty)
        Row(
          children: [
            Icon(Icons.info_outline_rounded, color: scheme.onSurfaceVariant),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _pro.storeAvailable
                    ? 'Pro isn’t available right now.'
                    : 'Google Play isn’t available on this device.',
                style: text.bodyMedium,
              ),
            ),
            if (_pro.storeAvailable)
              TextButton(
                onPressed: _pro.loadPlans,
                child: const Text('Try again'),
              ),
          ],
        )
      else ...[
        for (final plan in plans)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _PlanRow(
              plan: plan,
              selected: plan.kind == selected!.kind,
              struck: plan.kind == ProPlanKind.yearly ? _fullYear() : null,
              badge: plan.kind == ProPlanKind.yearly && saving != null
                  ? 'Save $saving%'
                  : null,
              onTap: () => setState(() => _selected = plan.kind),
            ),
          ),
      ],
      const SizedBox(height: 6),
      Text(
        'Subscriptions renew automatically. Cancel anytime in Google Play.',
        textAlign: TextAlign.center,
        style: text.bodySmall,
      ),
      FutureBuilder<bool>(
        future: _privacyOptions,
        builder: (context, snapshot) => snapshot.data != true
            ? const SizedBox.shrink()
            : TextButton(
                onPressed: AdGate.instance.showPrivacyOptions,
                child: const Text('Ad privacy choices'),
              ),
      ),
    ];
  }

  /// Pinned at the bottom: the button for [plan], or Manage for a
  /// subscriber, and Restore.
  Widget _bottomBar(BuildContext context, ProPlan? plan, double inset) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.fromLTRB(22, 10, 22, inset + 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_pro.error case final error? when !_pro.isPro)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                error,
                textAlign: TextAlign.center,
                style: text.bodySmall?.copyWith(color: scheme.error),
              ),
            ),
          if (_pro.pending && !_pro.isPro)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Payment processing. Pro turns on once Google Play confirms.',
                textAlign: TextAlign.center,
                style: text.bodySmall,
              ),
            ),
          if (plan != null) ...[
            _GradientButton(
              label: plan.trialLabel != null
                  ? 'Start free trial'
                  : plan.kind == ProPlanKind.lifetime
                  ? 'Get lifetime'
                  : 'Continue',
              loading: _pro.purchasing,
              onPressed: _pro.purchasing || _pro.pending
                  ? null
                  : () => _pro.buy(plan),
            ),
            const SizedBox(height: 8),
            Text(
              _terms(plan),
              textAlign: TextAlign.center,
              style: text.bodySmall?.copyWith(fontWeight: FontWeight.w600),
            ),
          ] else if (_pro.isPro && !_pro.ownsLifetime)
            PillButton(
              label: 'Manage subscription',
              primary: false,
              onPressed: _manage,
            ),
          if (!_pro.isPro)
            Center(
              child: TextButton(
                onPressed: _restoring || !_pro.storeAvailable ? null : _restore,
                child: Text(_restoring ? 'Checking…' : 'Restore purchases'),
              ),
            ),
        ],
      ),
    );
  }
}

/// The top of the page: a rich gradient reaching under the status bar, with
/// the crown, the name and its promise.
class _Hero extends StatelessWidget {
  const _Hero({
    required this.compact,
    required this.owned,
    required this.lifetime,
    required this.topInset,
    required this.onBack,
    required this.onBadgeTap,
  });
  final bool owned, lifetime, compact;
  final double topInset;
  final VoidCallback onBack, onBadgeTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final deep = Color.lerp(scheme.primary, Colors.black, .45)!;
    final violet = Color.lerp(scheme.primary, const Color(0xff8b5cf6), .7)!;
    Widget glow(double size, Color color) => Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [color.withValues(alpha: .55), color.withValues(alpha: 0)],
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [deep, scheme.primary, violet],
        ),
      ),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          Positioned(top: -60, right: -40, child: glow(240, Colors.white)),
          Positioned(bottom: -30, left: -70, child: glow(220, violet)),
          if (owned) const Positioned.fill(child: SparkleField()),
          Padding(
            padding: EdgeInsets.only(top: topInset),
            child: Column(
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(
                      TabHeader.sideMargin - GlassCircleButton.edgeInset,
                      4,
                      0,
                      4,
                    ),
                    child: AppBackButton(onPressed: onBack),
                  ),
                ),
                if (owned)
                  // The halo adds height; pull it up so the title stays put.
                  Transform.translate(
                    offset: const Offset(0, -6),
                    child: SupporterBadge(
                      size: compact ? 50 : 64,
                      lifetime: lifetime,
                      onTap: onBadgeTap,
                    ),
                  )
                else
                  Container(
                    width: compact ? 56 : 76,
                    height: compact ? 56 : 76,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: .18),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: .45),
                        width: 1.5,
                      ),
                    ),
                    child: Icon(
                      Icons.workspace_premium_rounded,
                      size: compact ? 30 : 40,
                      color: Colors.white,
                    ),
                  ),
                SizedBox(height: compact ? 10 : 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'SimpleMoney',
                          style: text.headlineMedium?.copyWith(
                            color: Colors.white,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -.5,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(
                            'PRO',
                            style: text.titleMedium?.copyWith(
                              color: scheme.primary,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    owned
                        ? 'Thank you for keeping SimpleMoney growing'
                        : 'Get more from SimpleMoney',
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: text.bodyLarge?.copyWith(
                      color: Colors.white.withValues(alpha: .9),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Free and Pro side by side. Every row is ticked or filled in for Free,
/// so it reads as complete on its own; the Pro column is lit in the accent,
/// so it reads as the nicer one.
class _Compare extends StatelessWidget {
  const _Compare({required this.aiFree});
  final bool aiFree;

  static const _column = 84.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final text = theme.textTheme;
    final dark = theme.brightness == Brightness.dark;
    final rows = <(String, Object, Object)>[
      ('Track spending, accounts, loans and debts', true, true),
      ('Backups to Google Drive', true, true),
      ('Budgets', 'Up to ${ProController.freeBudgets}', 'Unlimited'),
      ('Looks', 'Simple, 4 colors', 'Every look'),
      ('AI assistant', aiFree ? 'Free for now' : false, true),
      ('Ads', 'A few, short', 'None'),
    ];
    Widget cell(Object value, {required bool pro}) {
      final color = pro ? scheme.primary : scheme.onSurfaceVariant;
      return Center(
        child: switch (value) {
          true => Icon(Icons.check_rounded, size: 20, color: color),
          false => Icon(
            Icons.remove_rounded,
            size: 18,
            color: scheme.onSurfaceVariant.withValues(alpha: .5),
          ),
          _ => Text(
            '$value',
            textAlign: TextAlign.center,
            style: text.bodySmall?.copyWith(
              color: pro ? scheme.primary : scheme.onSurfaceVariant,
              fontWeight: pro ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        },
      );
    }

    Widget proBand({
      required Widget child,
      bool top = false,
      bool end = false,
    }) => Container(
      width: _column,
      decoration: BoxDecoration(
        color: scheme.primary.withValues(alpha: dark ? .14 : .08),
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(top ? 16 : 0),
          bottom: Radius.circular(end ? 16 : 0),
        ),
      ),
      child: child,
    );

    return Column(
      children: [
        IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Spacer(),
              SizedBox(
                width: _column,
                child: Center(
                  child: Text(
                    'Free',
                    style: text.labelLarge?.copyWith(
                      color: scheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              proBand(
                top: true,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Center(
                    child: Text(
                      'Pro',
                      style: text.labelLarge?.copyWith(
                        color: scheme.primary,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        for (var i = 0; i < rows.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      border: i == 0
                          ? null
                          : Border(
                              top: BorderSide(
                                color: scheme.outlineVariant.withValues(
                                  alpha: .5,
                                ),
                              ),
                            ),
                    ),
                    alignment: Alignment.centerLeft,
                    child: Text(rows[i].$1, style: text.bodyMedium),
                  ),
                ),
                SizedBox(width: _column, child: cell(rows[i].$2, pro: false)),
                proBand(
                  end: i == rows.length - 1,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: cell(rows[i].$3, pro: true),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// One plan: its name and price, the chosen one outlined and tinted.
class _PlanRow extends StatelessWidget {
  const _PlanRow({
    required this.plan,
    required this.selected,
    required this.onTap,
    this.struck,
    this.badge,
  });
  final ProPlan plan;
  final bool selected;
  final VoidCallback onTap;

  /// The price this one is struck against, when it saves money.
  final String? struck;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    final name = switch (plan.kind) {
      ProPlanKind.yearly => 'Yearly',
      ProPlanKind.monthly => 'Monthly',
      ProPlanKind.lifetime => 'Lifetime',
    };
    final note = switch (plan.kind) {
      ProPlanKind.lifetime => 'Pay once, keep it for good',
      _ => plan.trialLabel,
    };
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: selected
                  ? scheme.primary.withValues(alpha: dark ? .16 : .07)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? scheme.primary : scheme.outlineVariant,
                width: selected ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  selected
                      ? Icons.check_circle_rounded
                      : Icons.radio_button_unchecked_rounded,
                  color: selected ? scheme.primary : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            name,
                            style: text.titleMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (badge case final badge?)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.green.withValues(alpha: .16),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                badge,
                                style: text.labelSmall?.copyWith(
                                  color: dark
                                      ? Colors.greenAccent
                                      : Colors.green.shade800,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (note != null) ...[
                        const SizedBox(height: 2),
                        Text(note, style: text.bodySmall),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (struck != null)
                      Text(
                        struck!,
                        style: text.bodySmall?.copyWith(
                          decoration: TextDecoration.lineThrough,
                        ),
                      ),
                    Text(
                      plan.price,
                      style: text.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The buy button: the hero's gradient, so the page ends where it began.
class _GradientButton extends StatelessWidget {
  const _GradientButton({
    required this.label,
    required this.onPressed,
    this.loading = false,
  });
  final String label;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final violet = Color.lerp(scheme.primary, const Color(0xff8b5cf6), .7)!;
    final enabled = onPressed != null && !loading;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: Opacity(
        opacity: onPressed == null && !loading ? .5 : 1,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(28),
            gradient: LinearGradient(colors: [scheme.primary, violet]),
            boxShadow: [
              BoxShadow(
                color: scheme.primary.withValues(alpha: .35),
                blurRadius: 18,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              borderRadius: BorderRadius.circular(28),
              onTap: enabled ? onPressed : null,
              child: SizedBox(
                height: 56,
                child: Center(
                  child: loading
                      ? const SizedBox.square(
                          dimension: 22,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.white,
                          ),
                        )
                      : ExcludeSemantics(
                          child: Text(
                            label,
                            style: Theme.of(context).textTheme.titleMedium
                                ?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w800,
                                ),
                          ),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
