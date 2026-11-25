import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:simple_money/data/prices/price_sources.dart';

/// Yahoo's chart reply for [price] on 20 Nov 2026.
String _chart(num price) => jsonEncode({
  'chart': {
    'result': [
      {
        'meta': {'currency': 'X', 'gmtoffset': 0},
        'timestamp': [1795132800],
        'indicators': {
          'quote': [
            {
              'close': [price],
            },
          ],
        },
      },
    ],
  },
});

/// Answers only the pairs in [prices]; any other is "not found".
http.Client _yahoo(Map<String, num> prices) => MockClient((request) async {
  final symbol = request.url.pathSegments.last;
  final price = prices[symbol];
  return price == null
      ? http.Response('{"chart":{"result":null}}', 404)
      : http.Response(_chart(price), 200);
});

void main() {
  test('a pair Yahoo lists is used directly', () async {
    final quote = await ForexSource.rate(
      _yahoo({'USDINR=X': 92.67}),
      'usd',
      'INR',
    );
    expect(quote?.priceE4, 926700);
    expect(quote?.currency, 'INR');
  });

  test('a pair Yahoo lacks is worked out through the dollar', () async {
    // 1 SAR = 92.67 / 3.7515 INR.
    final quote = await ForexSource.rate(
      _yahoo({'USDINR=X': 92.67, 'USDSAR=X': 3.7515}),
      'SAR',
      'INR',
    );
    expect(quote?.priceE4, (92.67 / 3.7515 * 10000).round());
    expect(quote?.currency, 'INR');
  });

  test('into dollars, the dollar side counts as one', () async {
    final quote = await ForexSource.rate(
      _yahoo({'USDAFN=X': 66.15}),
      'AFN',
      'USD',
    );
    expect(quote?.priceE4, (1 / 66.15 * 10000).round());
  });

  test('the list works out a row from two shared dollar rates', () async {
    final client = _yahoo({'USDINR=X': 92.67, 'USDSAR=X': 3.7515});
    final sar = await ForexSource.perDollar(client, 'SAR');
    final inr = await ForexSource.perDollar(client, 'INR');
    final usd = await ForexSource.perDollar(client, 'USD');
    expect(
      ForexSource.cross(sar!, inr!, 'INR')?.priceE4,
      (92.67 / 3.7515 * 10000).round(),
    );
    // The dollar itself needs no lookup.
    expect(ForexSource.cross(usd!, inr, 'INR')?.priceE4, 926700);
  });

  test(
    'the same currency, or one Yahoo has no rate for, gives nothing',
    () async {
      final client = _yahoo({'USDINR=X': 92.67});
      expect(await ForexSource.rate(client, 'INR', 'INR'), isNull);
      expect(await ForexSource.rate(client, 'XYZ', 'INR'), isNull);
    },
  );

  group('the one-request table', () {
    const body =
        '{"result":"success","base_code":"INR","rates":{"INR":1,"USD":0.010766,"SAR":0.040371,"COP":35.951632,"BAD":0,"TXT":"x"}}';

    test('turns per-rupee figures into a rupee price for one unit', () {
      final table = ForexTable.parse(body, 'INR')!;
      expect(table.rateOf('usd')?.priceE4, (10000 / 0.010766).round());
      expect(table.rateOf('SAR')?.currency, 'INR');
      // Not a currency the service has, or a figure that isn't a number.
      expect(table.rateOf('XYZ'), isNull);
      expect(table.rateOf('BAD'), isNull);
      expect(table.rateOf('TXT'), isNull);
    });

    test('a failure reply is no table', () {
      expect(ForexTable.parse('{"result":"error"}', 'INR'), isNull);
      expect(ForexTable.parse('not json', 'INR'), isNull);
    });

    test('is asked for once, then kept', () async {
      var asked = 0;
      final client = MockClient((request) async {
        asked++;
        return http.Response(body.replaceAll('INR', 'EUR'), 200);
      });
      final first = await ForexTable.load(client, 'EUR');
      final second = await ForexTable.load(client, 'EUR');
      expect(first, isNotNull);
      expect(identical(first, second), isTrue);
      expect(asked, 1);
    });
  });
}
