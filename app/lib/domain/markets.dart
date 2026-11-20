/// A stock market, for narrowing a search to where something trades. Not an
/// index: Nifty or the Dow can't be held, but stocks and ETFs on these can.
///
/// A security's market is read off its Yahoo ticker: `TCS.NS` is India, `AAPL`
/// (no suffix) is the US. To add a market, add a line to [markets].
class Market {
  const Market(
    this.id,
    this.label,
    this.currency,
    this.suffixes, {
    this.stocks = const [],
    this.etfs = const [],
  });
  final String id, label;

  /// What most of its securities are priced in.
  final String currency;

  /// Ticker endings that put a security here; '' is a ticker with none.
  final List<String> suffixes;

  /// Well-known names listed here, offered as searches before anything is
  /// typed: a few stocks, and a few funds that trade on it.
  final List<String> stocks, etfs;
}

const markets = [
  Market(
    'in',
    'India',
    'INR',
    ['.NS', '.BO'],
    stocks: ['TCS', 'Reliance', 'Infosys', 'HDFC Bank'],
    etfs: ['NIFTYBEES', 'GOLDBEES', 'BANKBEES', 'JUNIORBEES'],
  ),
  Market(
    'us',
    'US',
    'USD',
    [''],
    stocks: ['Apple', 'Tesla', 'Microsoft', 'Nvidia'],
    etfs: ['SPY', 'QQQ', 'VOO', 'VTI'],
  ),
  Market(
    'uk',
    'UK',
    'GBP',
    ['.L'],
    stocks: ['Shell', 'HSBC', 'AstraZeneca', 'Unilever'],
    etfs: ['VUSA', 'ISF', 'VWRL', 'CSPX'],
  ),
  Market(
    'ca',
    'Canada',
    'CAD',
    ['.TO', '.V'],
    stocks: ['Shopify', 'Royal Bank', 'Enbridge', 'Suncor'],
    etfs: ['XIU', 'VFV', 'XEQT', 'VCN'],
  ),
  Market(
    'au',
    'Australia',
    'AUD',
    ['.AX'],
    stocks: ['BHP', 'Commonwealth Bank', 'CSL', 'Telstra'],
    etfs: ['VAS', 'NDQ', 'IVV', 'A200'],
  ),
  Market(
    'nz',
    'New Zealand',
    'NZD',
    ['.NZ'],
    stocks: ['Fisher & Paykel', 'Auckland Airport', 'Spark', 'Mainfreight'],
    etfs: ['FNZ', 'USF', 'TNZ', 'NZG'],
  ),
  Market(
    'jp',
    'Japan',
    'JPY',
    ['.T'],
    stocks: ['Toyota', 'Sony', 'SoftBank', 'Nintendo'],
    etfs: ['1306', '1321', '1570', '2558'],
  ),
  Market(
    'cn',
    'China',
    'CNY',
    ['.SS', '.SZ'],
    stocks: ['Moutai', 'CATL', 'Ping An', 'BYD'],
    etfs: ['510300', '510050', '159919', '510500'],
  ),
  Market(
    'hk',
    'Hong Kong',
    'HKD',
    ['.HK'],
    stocks: ['Tencent', 'Alibaba', 'HSBC', 'Meituan'],
    etfs: ['2800', '3033', '2828', '3067'],
  ),
  Market(
    'kr',
    'South Korea',
    'KRW',
    ['.KS', '.KQ'],
    stocks: ['Samsung', 'SK Hynix', 'Hyundai', 'Naver'],
    etfs: ['069500', '102110', '360750', '133690'],
  ),
  Market(
    'tw',
    'Taiwan',
    'TWD',
    ['.TW', '.TWO'],
    stocks: ['TSMC', 'Foxconn', 'MediaTek', 'Delta'],
    etfs: ['0050', '0056', '00878', '006208'],
  ),
  Market(
    'sg',
    'Singapore',
    'SGD',
    ['.SI'],
    stocks: ['DBS', 'Singtel', 'OCBC', 'UOB'],
    etfs: ['ES3', 'G3B', 'CLR', 'O87'],
  ),
  Market(
    'my',
    'Malaysia',
    'MYR',
    ['.KL'],
    stocks: ['Maybank', 'Public Bank', 'Tenaga', 'CIMB'],
    etfs: ['0820EA'],
  ),
  Market(
    'th',
    'Thailand',
    'THB',
    ['.BK'],
    stocks: ['PTT', 'CP All', 'Airports of Thailand', 'SCB'],
    etfs: ['TDEX', 'SET50'],
  ),
  Market(
    'id',
    'Indonesia',
    'IDR',
    ['.JK'],
    stocks: ['Bank Central Asia', 'Telkom', 'Bank Mandiri', 'Astra'],
    etfs: ['XIIT', 'R-LQ45X', 'XPLQ', 'XBLQ'],
  ),
  Market(
    'ph',
    'Philippines',
    'PHP',
    ['.PS'],
    stocks: ['SM Investments', 'Ayala', 'BDO', 'PLDT'],
  ),
  Market(
    'de',
    'Germany',
    'EUR',
    ['.DE', '.F'],
    stocks: ['SAP', 'Siemens', 'Allianz', 'BMW'],
    etfs: ['EXS1', 'SXR8', 'VWCE', 'EUNL'],
  ),
  Market(
    'fr',
    'France',
    'EUR',
    ['.PA'],
    stocks: ['LVMH', 'TotalEnergies', 'Airbus', 'Sanofi'],
    etfs: ['CW8', 'PANX', 'EWLD', 'ESE'],
  ),
  Market(
    'it',
    'Italy',
    'EUR',
    ['.MI'],
    stocks: ['Ferrari', 'Enel', 'Intesa Sanpaolo', 'Eni'],
    etfs: ['SWDA', 'VWCE', 'CSSPX', 'ETFMIB'],
  ),
  Market(
    'es',
    'Spain',
    'EUR',
    ['.MC'],
    stocks: ['Inditex', 'Santander', 'Iberdrola', 'BBVA'],
    etfs: ['IBEX'],
  ),
  Market(
    'nl',
    'Netherlands',
    'EUR',
    ['.AS'],
    stocks: ['ASML', 'Heineken', 'Adyen', 'ING'],
    etfs: ['IWDA', 'VWRL', 'VUSA', 'IEMA'],
  ),
  Market(
    'be',
    'Belgium',
    'EUR',
    ['.BR'],
    stocks: ['Anheuser-Busch', 'KBC', 'UCB', 'Solvay'],
  ),
  Market(
    'pt',
    'Portugal',
    'EUR',
    ['.LS'],
    stocks: ['EDP', 'Galp', 'Jeronimo Martins', 'BCP'],
  ),
  Market(
    'ie',
    'Ireland',
    'EUR',
    ['.IR'],
    stocks: ['Ryanair', 'Kerry', 'Bank of Ireland', 'Smurfit'],
  ),
  Market(
    'at',
    'Austria',
    'EUR',
    ['.VI'],
    stocks: ['Erste Group', 'OMV', 'Verbund', 'Voestalpine'],
  ),
  Market(
    'fi',
    'Finland',
    'EUR',
    ['.HE'],
    stocks: ['Nokia', 'Neste', 'Kone', 'Fortum'],
  ),
  Market(
    'ch',
    'Switzerland',
    'CHF',
    ['.SW'],
    stocks: ['Nestle', 'Novartis', 'Roche', 'UBS'],
    etfs: ['CSSMI', 'CHSPI', 'CSNDX', 'CHDVD'],
  ),
  Market(
    'se',
    'Sweden',
    'SEK',
    ['.ST'],
    stocks: ['Volvo', 'Ericsson', 'Investor', 'H&M'],
  ),
  Market(
    'no',
    'Norway',
    'NOK',
    ['.OL'],
    stocks: ['Equinor', 'DNB', 'Telenor', 'Yara'],
  ),
  Market(
    'dk',
    'Denmark',
    'DKK',
    ['.CO'],
    stocks: ['Novo Nordisk', 'Maersk', 'Vestas', 'Carlsberg'],
  ),
  Market(
    'pl',
    'Poland',
    'PLN',
    ['.WA'],
    stocks: ['PKO Bank', 'Orlen', 'CD Projekt', 'KGHM'],
    etfs: ['ETFBW20TR', 'ETFBM40TR', 'ETFBS80TR', 'ETFBDIVPL'],
  ),
  Market(
    'tr',
    'Turkey',
    'TRY',
    ['.IS'],
    stocks: ['Aselsan', 'Garanti', 'Koc', 'Turkcell'],
    etfs: ['ZPX30', 'ZGOLD', 'GLDTR', 'ISGLK'],
  ),
  Market(
    'il',
    'Israel',
    'ILS',
    ['.TA'],
    stocks: ['Teva', 'Nice', 'Bank Leumi', 'Elbit'],
  ),
  Market(
    'sa',
    'Saudi Arabia',
    'SAR',
    ['.SR'],
    stocks: ['Aramco', 'Al Rajhi', 'SABIC', 'STC'],
  ),
  Market(
    'za',
    'South Africa',
    'ZAR',
    ['.JO'],
    stocks: ['Naspers', 'MTN', 'Standard Bank', 'Sasol'],
    etfs: ['STX40', 'STXNDQ', 'SYGWD', 'STXDIV'],
  ),
  Market(
    'br',
    'Brazil',
    'BRL',
    ['.SA'],
    stocks: ['Petrobras', 'Vale', 'Itau', 'Ambev'],
    etfs: ['BOVA11', 'IVVB11', 'SMAL11', 'HASH11'],
  ),
  Market(
    'mx',
    'Mexico',
    'MXN',
    ['.MX'],
    stocks: ['Walmex', 'America Movil', 'Cemex', 'Femsa'],
    etfs: ['NAFTRAC', 'IVVPESO', 'VEA'],
  ),
  Market(
    'ar',
    'Argentina',
    'ARS',
    ['.BA'],
    stocks: ['YPF', 'Galicia', 'Pampa', 'Telecom Argentina'],
  ),
  Market(
    'cl',
    'Chile',
    'CLP',
    ['.SN'],
    stocks: ['Falabella', 'Copec', 'SQM', 'Cencosud'],
  ),
];

/// The market a ticker trades in, or null when its ending isn't known.
Market? marketOfSymbol(String symbol) {
  final upper = symbol.trim().toUpperCase();
  for (final market in markets) {
    for (final suffix in market.suffixes) {
      if (suffix.isNotEmpty && upper.endsWith(suffix)) return market;
    }
  }
  return upper.contains('.') ? null : markets.firstWhere((m) => m.id == 'us');
}

/// Where to start a search for an account in [currency]: the first market
/// priced in it, or null (all markets) when none is.
Market? defaultMarketFor(String currency) =>
    markets.where((m) => m.currency == currency).firstOrNull;
