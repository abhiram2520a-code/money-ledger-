import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/categorize/categorize.dart';

void main() {
  group('MerchantNormalizer', () {
    test('strips acquirer prefixes and terminal ids', () {
      expect(MerchantNormalizer.key('RAZ*SwiggyIN29481'), 'SWIGGYIN');
      expect(MerchantNormalizer.key('UPI/SWIGGYUPI/412345678901'), 'SWIGGYUPI');
      expect(MerchantNormalizer.key('EAZYDINE0000000'), 'EAZYDINE');
      expect(MerchantNormalizer.key('POS/DMART BENGALURU'), 'DMART');
      expect(MerchantNormalizer.key('ACH-D-INDIAN CLEARING CORP'),
          'CLEARING');
    });

    test('never mutilates a merchant that merely starts with a rail name', () {
      // PAYU* is a prefix; PAYUSHA is a name.
      expect(MerchantNormalizer.key('PAYUSHA FOODS'), 'PAYUSHA FOODS');
      expect(MerchantNormalizer.key('SIPCOT INDUSTRIES'), 'SIPCOT INDUSTRIES');
    });

    test('drops trailing geography but keeps the merchant', () {
      expect(MerchantNormalizer.key('THIRD WAVE COFFEE BENGALURU IND'),
          'THIRD WAVE COFFEE');
      expect(MerchantNormalizer.key('AMAZON IN'), 'AMAZON');
    });

    test('collapses the legal entity and the UPI handle to the same key', () {
      expect(
        MerchantNormalizer.key('BUNDL TECHNOLOGIES PRIVATE LIMITED'),
        MerchantNormalizer.key('BUNDL TECHNOLOGIES'),
      );
    });

    test('never returns an empty key for a string that had any letters', () {
      expect(MerchantNormalizer.key('LTD'), 'LTD');
      expect(MerchantNormalizer.key('  '), '');
      expect(MerchantNormalizer.key(null), '');
      expect(MerchantNormalizer.key('1234567'), '1234567');
    });

    test('is idempotent - the defence that keeps user rules alive', () {
      const inputs = <String>[
        'RAZ*SwiggyIN29481',
        'UPI/ZOMATO LTD/998877665544',
        'ACH-D-INDIAN CLEARING CORP',
        'POS 4412 DMART BENGALURU IND',
        'PAYTM-SOMESHOP0000012',
        'BUNDL TECHNOLOGIES PRIVATE LIMITED',
        'Mr. Sharma & Sons (Kirana)',
        '   ',
        'LTD',
      ];
      for (final input in inputs) {
        final once = MerchantNormalizer.key(input);
        final twice = MerchantNormalizer.key(once);
        expect(twice, once, reason: 'normalising "$input" twice changed it');
      }
    });

    test('golden fixture pinned to the normaliser version', () {
      // If you changed the algorithm, you MUST bump
      // MerchantNormalizer.version and update this map in the same commit -
      // every stored user rule is keyed on these outputs.
      expect(MerchantNormalizer.version, 1);

      const golden = <String, String>{
        'SWIGGYUPI': 'SWIGGYUPI',
        'RAZ*SwiggyIN29481': 'SWIGGYIN',
        'BUNDL TECHNOLOGIES': 'BUNDL',
        'Zomato Ltd': 'ZOMATO',
        'UPI-BLINKIT-9988776655': 'BLINKIT',
        'POS/RELIANCE FRESH MUMBAI': 'RELIANCE FRESH',
        'ACH-D-BSE LIMITED SIP': 'BSE SIP',
        'IRCTC-UTS 00012345': 'IRCTC UTS',
        'AMAZON SELLER SERVICES PVT LTD': 'AMAZON SELLER',
      };
      golden.forEach((input, expected) {
        expect(MerchantNormalizer.key(input), expected, reason: 'input: $input');
      });
    });

    test('usable tokens exclude short, numeric and corporate noise', () {
      expect(MerchantNormalizer.isUsableToken('KFC'), isFalse);
      expect(MerchantNormalizer.isUsableToken('12345'), isFalse);
      expect(MerchantNormalizer.isUsableToken('LIMITED'), isFalse);
      expect(MerchantNormalizer.isUsableToken('MUMBAI'), isFalse);
      expect(MerchantNormalizer.isUsableToken('SWIGGY'), isTrue);
    });

    test('strips invisible and bidirectional characters', () {
      const sneaky = 'SWI\u200bGGY\u202eUPI';
      expect(MerchantNormalizer.key(sneaky), 'SWI GGY UPI');
    });
  });
}
