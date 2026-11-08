import 'package:flutter_test/flutter_test.dart';
import 'package:simple_money/domain/category.dart';
import 'package:simple_money/domain/transaction.dart';
import 'package:simple_money/domain/transaction_icon.dart';

void main() {
  MoneyTransaction transaction(String title, {String? icon}) =>
      MoneyTransaction(
        id: 1,
        type: TransactionType.expense,
        amountMinor: 100,
        accountId: 1,
        date: DateTime(2026),
        title: title,
        icon: icon,
      );
  const transport = Category(
    id: 1,
    name: 'Public Transport',
    type: CategoryType.expense,
    icon: 'bus_two',
  );

  test('resolves recognized titles in existing transactions', () {
    expect(transactionIcon(transaction('Axis Bank'), null), 'brand:axisbank');
    expect(
      transactionIcon(transaction('JioHotstar'), null),
      'brand:jiohotstar',
    );
    expect(transactionIcon(transaction('Zee 5'), null), 'brand:zee5');
    expect(transactionIcon(transaction('CRED'), null), 'brand:cred');
    expect(
      transactionIcon(transaction('Prime Video'), null),
      'brand:primevideo',
    );
    expect(
      transactionIcon(transaction('Amazon Prime Video'), null),
      'brand:primevideo',
    );
    expect(transactionIcon(transaction('Indian Railw'), transport), 'train');
    expect(
      transactionIcon(transaction('Kerala Stat'), transport),
      'brand:ksrtc',
    );
    expect(transactionIcon(transaction('AYATHIL'), null), 'bank_transfer');
  });

  test('preserves explicit artwork and unknown merchant category fallback', () {
    expect(
      transactionIcon(transaction('Axis Bank', icon: 'gift_box'), transport),
      'gift_box',
    );
    expect(transactionIcon(transaction('Unknown'), transport), 'bus_two');
    expect(transactionIcon(transaction('Ola Joseph'), transport), 'bus_two');
  });

  test('matches shopping, streaming and hair service merchant titles', () {
    for (final entry in {
      'MEESHO order 123': 'brand:meesho',
      'Disney Plus subscription': 'brand:disneyplus',
      'Disney+': 'brand:disneyplus',
      'Disney Plus Hotstar': 'brand:jiohotstar',
      'Modern Salon Kochi': 'salon',
      'Royal Saloon': 'salon',
      'Hair Studio': 'salon',
      'Haircare': 'salon',
      'Hair cut': 'haircut',
      'Haircut payment': 'haircut',
      'City Barber': 'haircut',
      'Kerala Vision Broadband recharge': 'brand:keralavision',
      'KERALAVISION': 'brand:keralavision',
      'ACT Fibernet bill': 'brand:actfibernet',
      'Atria Convergence Technologies': 'brand:actfibernet',
      'Excitel payment': 'brand:excitel',
      'Hathway Broadband': 'brand:hathway',
      'Tata Play Fiber recharge': 'brand:tataplayfiber',
      'Tata Sky Broadband': 'brand:tataplayfiber',
      'YOU Broadband India': 'brand:youbroadband',
      'Airtel Xstream Fiber': 'brand:airtel',
      'JioFiber recharge': 'brand:jio',
      'Jio AirFiber': 'brand:jio',
      'BSNL Bharat Fibre': 'brand:bsnl',
    }.entries) {
      expect(
        transactionIcon(transaction(entry.key), transport),
        entry.value,
        reason: entry.key,
      );
      expect(
        transactionIcon(transaction(entry.key, icon: 'gift_box'), transport),
        'gift_box',
      );
    }
    for (final title in [
      'Chair shop',
      'Meeshoha',
      'Disney store',
      'Act now',
      'You Store',
    ]) {
      expect(transactionIcon(transaction(title), transport), 'bus_two');
    }
  });

  test(
    'replaces legacy fuel artwork without changing custom category icons',
    () {
      for (final icon in ['car_battery', 'car']) {
        final category = Category(
          id: 2,
          name: 'Fuel',
          type: CategoryType.expense,
          icon: icon,
        );
        expect(
          transactionIcon(transaction('Chithira Pe'), category),
          icon == 'car_battery' ? 'fuel' : 'car',
        );
      }
    },
  );
}
