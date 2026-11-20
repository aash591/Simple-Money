import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/domain/app_icons.dart';
import 'package:simple_money/domain/bank_institution_icon.dart';
import 'package:simple_money/data/repositories/sms_import_repository.dart';
import 'package:simple_money/ui/sms/sms_suggestions.dart';
import 'package:simple_money/domain/brand_icons.dart';
import 'package:simple_money/domain/brand_dark_icons.dart';
import 'package:simple_money/domain/service_icon.dart';
import 'package:simple_money/ui/components/app_icon.dart';
import 'package:simple_money/ui/components/select_icon_screen.dart';
import 'package:simple_money/ui/components/settings_icon.dart';

void main() {
  test('every broker logo is bundled, found by name, and in its country', () {
    const brokers = {
      'Groww': 'groww',
      'Upstox': 'upstox',
      'Angel One': 'angelone',
      'ICICI Direct': 'icicidirect',
      'HDFC Securities': 'hdfcsecurities',
      'Kotak Securities': 'kotakneo',
      'Dhan': 'dhan',
      'Paytm Money': 'paytmmoney',
      'Fidelity': 'fidelity',
      'E*TRADE': 'etrade',
      'Vanguard': 'vanguard',
      'Interactive Brokers': 'interactivebrokers',
      'Webull': 'webull',
      'Merrill Edge': 'merrilledge',
      'SoFi': 'sofi',
      'Trading 212': 'trading212',
      'AJ Bell': 'ajbell',
      'eToro': 'etoro',
      'Trade Republic': 'traderepublic',
      'DEGIRO': 'degiro',
      'Questrade': 'questrade',
      'Wealthsimple': 'wealthsimple',
      'CommSec': 'commsec',
      'Stake': 'stake',
      'Tiger Brokers': 'tigerbrokers',
      'XP Investimentos': 'xp',
    };
    for (final MapEntry(key: typed, value: key) in brokers.entries) {
      expect(matchingInstitutionIcon(typed), brandIconKey(key), reason: typed);
      final brand = brandIcons.firstWhere((b) => b.key == key);
      expect(brand.isBank && brand.bankCountry != null, isTrue, reason: key);
      expect(
        File(brandIconAssetPath(key, Brightness.light)).existsSync(),
        isTrue,
        reason: '$key asset',
      );
    }
    expect(matchingInstitutionIcon('Zerodha'), brandIconKey('zerodha'));
    expect(matchingInstitutionIcon('Robinhood Gold'), brandIconKey('robinhood'));
    expect(darkBrandIconKeys, contains('xp'));
    expect(
      File(brandIconAssetPath('xp', Brightness.dark)).existsSync(),
      isTrue,
    );
  });

  testWidgets('brand WebPs render directly without a runtime tint', (
    tester,
  ) async {
    for (final brightness in [Brightness.light, Brightness.dark]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: Scaffold(body: AppIcon(brandIconKey('telegram'), size: 48)),
        ),
      );
      final image = tester.widget<Image>(find.byType(Image));
      expect(image.color, isNull);
      expect(image.colorBlendMode, isNull);
      expect(
        (image.image as AssetImage).assetName,
        brandIconAssetPath('telegram', brightness),
      );
    }
  });

  testWidgets('dark settings icon uses its companion WebP directly', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(brightness: Brightness.dark),
        home: Scaffold(body: SettingsIcon(brandIconKey('github'), size: 48)),
      ),
    );
    final image = tester.widget<Image>(find.byType(Image));
    expect(image.color, isNull);
    expect(
      (image.image as AssetImage).assetName,
      brandIconAssetPath('github', Brightness.dark),
    );
  });

  test('dark companions exist and use the same icon key', () {
    for (final key in darkBrandIconKeys) {
      expect(
        File(brandIconAssetPath(key, Brightness.dark)).existsSync(),
        true,
        reason: key,
      );
      expect(
        File(brandIconAssetPath(key, Brightness.light)).existsSync(),
        true,
        reason: key,
      );
    }
    expect(
      brandIconAssetPath('openai', Brightness.dark),
      'assets/icon_packs/logos/brands/openai_dark.webp',
    );
    expect(
      brandIconAssetPath('sbicard', Brightness.dark),
      'assets/icon_packs/logos/brands/sbicard_dark.webp',
    );
    for (final key in ['equitas', 'btn', 'viindia']) {
      expect(
        brandIconAssetPath(key, Brightness.dark),
        brandIconAssetPath(key, Brightness.light),
      );
    }
    expect(
      brandIconAssetPath('goldmansachs', Brightness.dark),
      'assets/icon_packs/logos/banks/united_states/'
      'goldmansachs_dark.webp',
    );
  });

  test('bank catalog assigns every bank to a country', () {
    final banks = brandIcons.where((brand) => brand.isBank).toList();

    expect(banks, isNotEmpty);
    expect(
      banks,
      everyElement(predicate<BrandIcon>((bank) => bank.bankCountry != null)),
    );
    for (final bank in banks) {
      final path = brandIconAssetPath(bank.key, Brightness.light);
      expect(
        path,
        startsWith('assets/icon_packs/logos/banks/'),
        reason: bank.key,
      );
      expect(File(path).existsSync(), true, reason: bank.key);
    }
    expect(
      banks
          .where((bank) => bank.bankCountry == 'India')
          .map((bank) => bank.title),
      containsAll([
        'HDFC Bank',
        'Federal Bank',
        'Bandhan Bank',
        'Bank of India',
        'IndusInd Bank',
        'Bank of Maharashtra',
        'Karur Vysya Bank',
        'Tamilnad Mercantile Bank',
        'South Indian Bank',
        'Karnataka Bank',
        'City Union Bank',
        'IDBI Bank',
        'CSB Bank',
        'Central Bank of India',
        'ESAF Small Finance Bank',
        'Punjab & Sind Bank',
        'Bajaj Finance',
      ]),
    );
    expect(
      banks
          .where((bank) => bank.bankCountry == 'Indonesia')
          .map((bank) => bank.title),
      containsAll(['BRI', 'BCA', 'BNI', 'BTN', 'Mandiri']),
    );
  });

  test('non-bank brand assets use the nested brands directory', () {
    for (final brand in brandIcons.where((brand) => !brand.isBank)) {
      final path = brandIconAssetPath(brand.key, Brightness.light);
      expect(
        path,
        startsWith('assets/icon_packs/logos/brands/'),
        reason: brand.key,
      );
      expect(File(path).existsSync(), true, reason: brand.key);
    }
  });

  test('Bajaj Finance merchant aliases resolve to its brand icon', () {
    expect(serviceIcon('Bajaj Finance'), brandIconKey('bajajfinance'));
    expect(
      serviceIcon('BAJAJ FINSERV EMI PAYMENT'),
      brandIconKey('bajajfinance'),
    );
  });

  test('ESAF Small Finance Bank resolves to its bundled bank icon', () {
    expect(
      bankInstitutionIcon('ESAF Small Finance Bank'),
      brandIconKey('esafbank'),
    );
    expect(
      File(brandIconAssetPath('esafbank', Brightness.light)).lengthSync(),
      greaterThan(1000),
    );
  });

  test('major US, UK, Indonesian, and African bank icons are bundled', () {
    const regionalKeys = <String, List<String>>{
      'United States': [
        'wellsfargo',
        'usbank',
        'capitalone',
        'pncbank',
        'truist',
        'tdbank',
        'fifththird',
        'bmo',
        'firstcitizens',
        'citizensbank',
        'mtbank',
        'keybank',
        'allybank',
        'hsbcusa',
        'regionsbank',
        'santanderus',
        'goldmansachs',
        'bnymellon',
        'morganstanley',
        'statestreet',
        'northerntrust',
      ],
      'United Kingdom': [
        'barclays',
        'hsbcuk',
        'lloydsbank',
        'natwest',
        'santanderuk',
        'standardchartereduk',
        'bankofscotland',
        'tsbuk',
        'virginmoneyuk',
        'cooperativebankuk',
        'nationwideuk',
        'halifaxuk',
        'metrobankuk',
      ],
      'Indonesia': [
        'banksyariahindonesia',
        'cimbniaga',
        'ocbcindonesia',
        'permatabank',
        'danamon',
      ],
      'Africa': [
        'standardbanksa',
        'fnbsa',
        'absa',
        'nedbank',
        'investec',
        'capitec',
        'banquemisr',
        'qnbegypt',
        'arabafricanbank',
        'attijariwafa',
        'bcpgroup',
        'bankofafrica',
        'creditagricolemaroc',
        'cihbank',
        'sahambank',
        'uba',
        'firstbanknigeria',
        'cpaalgeria',
        'bdlalgeria',
        'ecobank',
        'mcbmauritius',
        'kcbkenya',
        'bgfibank',
      ],
    };
    for (final region in regionalKeys.entries) {
      for (final key in region.value) {
        final brand = resolveBrandIcon(brandIconKey(key));
        expect(brand?.isBank, true, reason: '$key (${region.key})');
        expect(brand?.bankCountry, isNotNull, reason: key);
        expect(
          File(brandIconAssetPath(key, Brightness.light)).lengthSync(),
          greaterThan(1000),
          reason: key,
        );
      }
    }
  });

  test('regional bank aliases resolve to their institution marks', () {
    const aliases = <String, String>{
      'FirstRand': 'fnbsa',
      'First National Bank': 'fnbsa',
      'Standard Bank South Africa': 'standardbanksa',
      'BNY': 'bnymellon',
      'BSI': 'banksyariahindonesia',
      'AAIB': 'arabafricanbank',
      'BCP': 'bcpgroup',
      'CPA': 'cpaalgeria',
      'BDL': 'bdlalgeria',
      'MCB': 'mcbmauritius',
    };
    for (final alias in aliases.entries) {
      expect(
        bankInstitutionIcon(alias.key),
        brandIconKey(alias.value),
        reason: alias.key,
      );
    }
  });

  test('reviewed worldwide bank logos resolve and have bundled assets', () {
    const institutions = <String, String>{
      'CIB Egypt': 'cibegypt',
      'National Bank of Egypt': 'nationalbankofegypt',
      'Mellat Bank': 'mellatbank',
      'Orange Money': 'orangemoney',
      'Al Rajhi Bank': 'alrajhibank',
      'Bangkok Bank': 'bangkokbank',
      'First Abu Dhabi Bank': 'firstabudhabibank',
      'Navy Federal Credit Union': 'navyfederal',
      'GTBank': 'gtbank',
      'Zenith Bank': 'zenithbank',
    };
    for (final entry in institutions.entries) {
      expect(bankInstitutionIcon(entry.key), brandIconKey(entry.value));
      expect(
        File(brandIconAssetPath(entry.value, Brightness.light)).lengthSync(),
        greaterThan(1000),
        reason: entry.key,
      );
    }
  });

  test('Indian card brands resolve from SMS and have bundled assets', () {
    PendingSmsImport sms(String bank, {bool card = true}) => PendingSmsImport(
      id: 'test',
      sender: 'TEST',
      body: '',
      receivedAt: DateTime(2026),
      data: {'bankName': bank, 'isCreditCard': card},
    );
    expect(smsBankIcon(sms('OneCard')), brandIconKey('onecard'));
    expect(smsBankIcon(sms('State Bank India')), brandIconKey('sbicard'));
    expect(
      smsBankIcon(sms('State Bank India', card: false)),
      brandIconKey('sbi'),
    );
    expect(smsBankIcon(sms('BOBCARD')), brandIconKey('bobcard'));
    expect(resolveBrandIcon(brandIconKey('onecard'))?.isPayment, true);
    expect(resolveBrandIcon(brandIconKey('sbicard'))?.isPayment, true);
  });

  test('common services and metro operators have selectable bundled marks', () {
    const keys = [
      'ola',
      'rapido',
      'nammayatri',
      'kseb',
      'kwa',
      'ksrtc',
      'irctc',
      'redbus',
      'bsnl',
      'viindia',
      'asianetbroadband',
      'kochimetro',
      'delhimetro',
      'nammametro',
      'chennaimetro',
      'hyderabadmetro',
      'mumbaimetro',
      'keralavision',
      'actfibernet',
      'excitel',
      'hathway',
      'tataplayfiber',
      'youbroadband',
    ];
    for (final key in keys) {
      expect(resolveBrandIcon(brandIconKey(key)), isNotNull, reason: key);
      expect(
        File(brandIconAssetPath(key, Brightness.light)).lengthSync(),
        greaterThan(1000),
        reason: key,
      );
    }
  });

  testWidgets('bank picker displays separate country sections', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SelectIconScreen()));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Banks'));
    await tester.pumpAndSettle();

    final scrollable = find.descendant(
      of: find.byKey(const PageStorageKey<String>('icon-tab-banks')),
      matching: find.byType(Scrollable),
    );
    expect(find.text('Algeria'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Indonesia'),
      500,
      scrollable: scrollable,
    );
    expect(find.text('Indonesia'), findsOneWidget);
    expect(find.text('Banks around the world'), findsNothing);
  });

  testWidgets('brokers are their own section under Services, not in Banks', (
    tester,
  ) async {
    final brokers = brandIcons.where((b) => b.isBroker).toList();
    expect(brokers.length, greaterThanOrEqualTo(28));
    expect(
      brokers.map((b) => b.key),
      containsAll(['zerodha', 'robinhood', 'charlesschwab', 'groww', 'xp']),
    );

    await tester.pumpWidget(const MaterialApp(home: SelectIconScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Services'));
    await tester.pumpAndSettle();
    final services = find.descendant(
      of: find.byKey(const PageStorageKey<String>('icon-tab-brands')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey('icon-section-Brokers')),
      600,
      scrollable: services,
    );
    expect(find.byKey(const ValueKey('icon-section-Brokers')), findsOneWidget);

    // Banks keep their own countries, with no broker-only country listed.
    await tester.tap(find.text('Banks'));
    await tester.pumpAndSettle();
    final banks = find.descendant(
      of: find.byKey(const PageStorageKey<String>('icon-tab-banks')),
      matching: find.byType(Scrollable),
    );
    await tester.scrollUntilVisible(
      find.text('United States'),
      800,
      scrollable: banks,
    );
    for (final country in ['Singapore', 'Israel', 'Canada', 'Australia']) {
      expect(find.text(country), findsNothing, reason: country);
    }
  });

  testWidgets('a broker icon reopens the picker on Services', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: SelectIconScreen(selectedKey: brandIconKey('zerodha')),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Services & subscriptions'), findsOneWidget);
  });

  testWidgets('picker opens on the tab holding the current icon', (
    tester,
  ) async {
    // A unique key per case so each pump builds a fresh State, the way
    // pushing the picker as a new route does; the starting tab is chosen
    // once on open and deliberately doesn't chase later selection changes.
    Future<void> pumpWith(String? selectedKey) async {
      await tester.pumpWidget(
        MaterialApp(
          home: SelectIconScreen(
            key: ValueKey(selectedKey),
            selectedKey: selectedKey,
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    // A bank icon opens on Banks, without the user hunting for it.
    await pumpWith(brandIconKey('hdfcbank'));
    expect(find.byType(Scrollable), findsWidgets);
    expect(find.text('Services & subscriptions'), findsNothing);

    // A service mark opens on Services.
    await pumpWith(brandIconKey('netflix'));
    expect(find.text('Services & subscriptions'), findsOneWidget);
    expect(find.text('Services'), findsOneWidget);

    // Category artwork (and no selection at all) opens on the icon set.
    await pumpWith('groceries');
    expect(find.text('Services & subscriptions'), findsNothing);
    expect(find.text('Algeria'), findsNothing);
  });

  testWidgets('long pressing a brand icon shows its name', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SelectIconScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Services'));
    await tester.pumpAndSettle();

    await tester.longPress(find.bySemanticsLabel('Ola'));
    await tester.pump();
    expect(find.text('Ola'), findsOneWidget);
  });
}
