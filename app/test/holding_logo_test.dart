import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/domain/holding.dart';
import 'package:simple_money/ui/more/portfolio/holding_logo.dart';

Holding holding(
  HoldingKind kind, {
  String? symbol,
  String? exchange,
  String? meta,
}) => Holding(
  id: 1,
  accountId: 1,
  kind: kind,
  name: 'x',
  symbol: symbol,
  exchange: exchange,
  meta: meta,
);

void main() {
  test('a listed stock or ETF finds its logo by ticker', () {
    expect(
      holdingLogoUrl(
        holding(HoldingKind.stock, symbol: 'TCS', exchange: 'NSE'),
      ),
      'https://financialmodelingprep.com/image-stock/TCS.NS.png',
    );
    expect(
      holdingLogoUrl(holding(HoldingKind.etf, symbol: 'VOO')),
      'https://financialmodelingprep.com/image-stock/VOO.png',
    );
  });

  test(
    'a saved coin logo wins; funds by scheme code and no ticker have none',
    () {
      expect(
        holdingLogoUrl(
          holding(
            HoldingKind.crypto,
            symbol: 'bitcoin',
            meta: '{"image":"https://coin-images.coingecko.com/a/large/b.png"}',
          ),
        ),
        'https://coin-images.coingecko.com/a/large/b.png',
      );
      expect(
        holdingLogoUrl(holding(HoldingKind.fund, symbol: '122639')),
        isNull,
      );
      expect(holdingLogoUrl(holding(HoldingKind.stock)), isNull);
      expect(
        holdingLogoUrl(holding(HoldingKind.crypto, symbol: 'bitcoin')),
        isNull,
      );
    },
  );
}
