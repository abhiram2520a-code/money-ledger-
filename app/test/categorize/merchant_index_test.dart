import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/categorize/categorize.dart';
import 'package:ledger/models/models.dart';

import 'rules_fixture.dart';

void main() {
  final ruleSet = loadRealRuleSet();
  final index = MerchantIndex.build(ruleSet.merchants);

  group('MerchantIndex against the real merchants.json', () {
    test('indexes every shipped merchant', () {
      expect(index.size, ruleSet.merchants.length);
      expect(index.size, greaterThan(50));
    });

    test('exact alias lookup', () {
      final match =
          index.lookupExact(MerchantNormalizer.normalize('SWIGGYUPI'));
      expect(match, isNotNull);
      expect(match!.entry.name, 'Swiggy');
      expect(match.entry.categoryPath, 'food_dining/food_delivery');
      expect(match.matchedOn, 'SWIGGYUPI');
      expect(match.score, 1.0);
    });

    test('exact lookup reaches the legal entity name on the card rail', () {
      final match = index.lookupExact(
        MerchantNormalizer.normalize('BUNDL TECHNOLOGIES PRIVATE LIMITED'),
      );
      expect(match, isNotNull);
      expect(match!.entry.name, 'Swiggy');
    });

    test('full VPA prefixes match, bare PSP handles never do', () {
      final hit = index.lookupVpa('swiggy@axisbank');
      expect(hit, isNotNull);
      expect(hit!.entry.name, 'Swiggy');

      // The handle is on the RIGHT of the @, so it can never be a prefix.
      for (final handle in VpaHeuristics.pspHandles) {
        expect(index.lookupVpa(handle), isNull, reason: handle);
        expect(index.lookupVpa('somebody$handle'), isNull,
            reason: 'somebody$handle');
      }
    });

    test('token containment needs half the token, so OLA is not CHOLA', () {
      final chola =
          index.lookupTokens(MerchantNormalizer.normalize('CHOLAMANDALAM'));
      expect(chola, isNull);

      final swiggy =
          index.lookupTokens(MerchantNormalizer.normalize('SWIGGYIN'));
      expect(swiggy, isNotNull);
      expect(swiggy!.entry.name, 'Swiggy');
    });

    test('a bare 3-letter token cannot drive a match', () {
      expect(index.lookupTokens(MerchantNormalizer.normalize('OLA')), isNull);
      expect(index.lookupTokens(MerchantNormalizer.normalize('999999')), isNull);
    });

    test('gateways are recognised as non-identifying', () {
      for (final name in <String>['Razorpay', 'PayU', 'BillDesk', 'Cashfree']) {
        final match = index.lookupExact(MerchantNormalizer.normalize(name));
        expect(match, isNotNull, reason: name);
        expect(index.isGateway(match!.entry), isTrue, reason: name);
      }
      // Recognised even when the dictionary has never heard of them.
      expect(index.isGatewayKey(MerchantNormalizer.key('JUSPAY')), isTrue);
      expect(index.isGatewayKey(MerchantNormalizer.key('SWIGGY')), isFalse);
    });

    test('no two shipped merchants collide on a normalised key', () {
      expect(index.ambiguousKeys, isEmpty,
          reason: 'ambiguous keys would make the winner depend on file order');
    });

    test('stays cheap at dictionary scale', () {
      final padded = <MerchantEntry>[
        ...ruleSet.merchants,
        for (var i = 0; i < 1000; i++)
          MerchantEntry(
            name: 'Synthetic Merchant $i',
            categoryPath: 'shopping/ecommerce',
            aliases: <String>['SYNTHETIC MERCHANT $i', 'SYNMERCH$i'],
          ),
      ];
      final big = MerchantIndex.build(padded);
      expect(big.size, greaterThan(1000));

      final probes = <NormalizedMerchant>[
        MerchantNormalizer.normalize('SWIGGYUPI'),
        MerchantNormalizer.normalize('SYNTHETIC MERCHANT 640'),
        MerchantNormalizer.normalize('TOTALLY UNKNOWN KIRANA STORE'),
        MerchantNormalizer.normalize('RAZ*SomeShop12345'),
      ];

      final watch = Stopwatch()..start();
      for (var i = 0; i < 2000; i++) {
        final probe = probes[i % probes.length];
        big.lookupExact(probe) ?? big.lookupTokens(probe);
      }
      watch.stop();
      expect(watch.elapsedMilliseconds, lessThan(2000),
          reason: '2000 lookups took ${watch.elapsedMilliseconds}ms - the '
              'index has probably degraded into a scan');
    });
  });
}
