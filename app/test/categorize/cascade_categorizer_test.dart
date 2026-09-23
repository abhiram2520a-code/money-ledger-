import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/categorize/categorize.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';

import 'rules_fixture.dart';

void main() {
  final ruleSet = loadRealRuleSet();
  final now = DateTime.utc(2026, 9, 20, 12);

  Future<CascadeCategorizer> categorizer({
    List<UserRule> userRules = const <UserRule>[],
    bool Function(String? cardTail)? isCardTracked,
  }) async {
    final c = CascadeCategorizer(isCardTracked: isCardTracked);
    final loaded = await c.load(ruleSet, userRules: userRules);
    expect(loaded.isOk, isTrue, reason: loaded.errorOrNull?.message);
    return c;
  }

  UserRule userRule({
    required String id,
    UserRuleMatch match = UserRuleMatch.merchantExact,
    required String pattern,
    required String categoryPath,
    CategoryKind kind = CategoryKind.expense,
    DateTime? createdAt,
    String? merchantName,
  }) {
    return UserRule(
      id: id,
      match: match,
      pattern: pattern,
      categoryPath: categoryPath,
      kind: kind,
      createdAt: createdAt ?? now,
      merchantName: merchantName,
      priority: UserRuleStore.defaultPriorityFor(match),
    );
  }

  group('load', () {
    test('refuses an empty taxonomy instead of sending everything to the '
        'Uncategorized queue', () async {
      final c = CascadeCategorizer();
      final result = await c.load(RuleSet.empty);
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.code, ErrorCodes.corruptRules);
      expect(c.isReady, isFalse);
      // Still total: categorising before a successful load asks the user.
      final out = c.categorize(parsedMessage(merchantRaw: 'SWIGGY'));
      expect(out.isUncategorized, isTrue);
    });

    test('is ready after loading the shipped pack', () async {
      final c = await categorizer();
      expect(c.isReady, isTrue);
      expect(c.index.size, ruleSet.merchants.length);
    });
  });

  group('stage 1 - the dictionary', () {
    test('exact alias, with an explanation naming what matched', () async {
      final c = await categorizer();
      final out = c.categorize(parsedMessage(merchantRaw: 'SWIGGYUPI'));
      expect(out.categoryPath, 'food_dining/food_delivery');
      expect(out.kind, CategoryKind.expense);
      expect(out.source, CategorySource.dictionary);
      expect(out.confidence, CategoryResult.dictionaryConfidence);
      expect(out.merchantName, 'Swiggy');
      expect(out.matchedOn, 'SWIGGYUPI');
      expect(out.explanation, contains('SWIGGYUPI'));
      expect(out.canAutoApply, isTrue);
    });

    test('reaches the legal entity name that appears on the card rail',
        () async {
      final c = await categorizer();
      final out = c.categorize(
        parsedMessage(
          merchantRaw: 'BUNDL TECHNOLOGIES PVT LTD BENGALURU',
          channel: TxnChannel.card,
          cardTail: '4412',
        ),
      );
      expect(out.merchantName, 'Swiggy');
      expect(out.categoryPath, 'food_dining/food_delivery');
    });

    test('token match is weaker and says so', () async {
      final c = await categorizer();
      final out = c.categorize(parsedMessage(merchantRaw: 'RAZ*SwiggyIN29481'));
      expect(out.merchantName, 'Swiggy');
      expect(out.source, CategorySource.dictionary);
      expect(out.confidence, CategoryResult.tokenConfidence);
      expect(out.explanation, contains('Swiggy'));
    });
  });

  group('payment gateways', () {
    test('every shipped gateway resolves to Uncategorized, never a category',
        () async {
      final c = await categorizer();
      const raws = <String>[
        'RAZORPAY SOFTWARE PVT LTD',
        'PAYU PAYMENTS',
        'BILLDESK',
        'CASHFREE',
      ];
      for (final raw in raws) {
        final out = c.categorize(parsedMessage(merchantRaw: raw));
        expect(out.isUncategorized, isTrue, reason: raw);
        expect(out.categoryPath, CategoryResult.uncategorizedPath, reason: raw);
        expect(out.explanation.toLowerCase(), contains('gateway'), reason: raw);
      }
    });

    test('but the real merchant behind a gateway prefix still resolves',
        () async {
      final c = await categorizer();
      final out = c.categorize(parsedMessage(merchantRaw: 'RAZ*ZOMATO'));
      expect(out.categoryPath, 'food_dining/food_delivery');
    });
  });

  group('stage 3 - UPI addresses', () {
    test('a full merchant VPA prefix resolves', () async {
      final c = await categorizer();
      final out = c.categorize(parsedMessage(vpa: 'swiggy@axisbank'));
      expect(out.categoryPath, 'food_dining/food_delivery');
      expect(out.source, CategorySource.vpa);
      expect(out.matchedOn, 'swiggy@');
    });

    test('a PSP handle NEVER decides a category', () async {
      final c = await categorizer();
      for (final handle in VpaHeuristics.pspHandles) {
        final out = c.categorize(parsedMessage(vpa: 'unknownpayee$handle'));
        expect(out.isUncategorized, isTrue, reason: 'unknownpayee$handle');
        expect(out.source, CategorySource.unknown, reason: handle);
      }
    });

    test('two different shops on the same PSP do not become the same category',
        () async {
      final c = await categorizer();
      final a = c.categorize(parsedMessage(vpa: 'q9876543210@ybl'));
      final b = c.categorize(parsedMessage(vpa: 'q1234509876@ybl'));
      expect(a.isUncategorized, isTrue);
      expect(b.isUncategorized, isTrue);
    });

    test('a QR merchant code is not identifiable, even when the dictionary '
        'carries the acquirer prefix', () async {
      final c = await categorizer();
      final out = c.categorize(parsedMessage(vpa: 'paytmqr2810050501@paytm'));
      expect(out.isUncategorized, isTrue);
      expect(out.explanation, contains('QR'));
      // Critically NOT transfers/wallet_topup: a QR payment is a purchase,
      // and filing it as a transfer would drop it out of the spend total.
      expect(out.categoryPath, isNot('transfers/wallet_topup'));
    });

    test('a payment to a person asks rather than guessing', () async {
      final c = await categorizer();
      final out = c.categorize(parsedMessage(vpa: '9876543210@ybl'));
      expect(out.isUncategorized, isTrue);
      expect(out.explanation, contains('person'));
    });
  });

  group('stage 4 - the payment rail', () {
    test('an ATM withdrawal is a transfer to cash, never a purchase', () async {
      final c = await categorizer();
      final out = c.categorize(
        parsedMessage(channel: TxnChannel.atm, merchantRaw: 'ATM WDL HDFC'),
      );
      expect(out.categoryPath, 'transfers/atm_withdrawal');
      expect(out.kind, CategoryKind.transfer);
      expect(out.kind.countsAsSpend, isFalse);
      expect(out.source, CategorySource.channel);
      expect(out.confidence,
          greaterThanOrEqualTo(ChannelSignals.minConfidenceToExcludeFromSpend));
    });

    test('a SIP auto-debit is an investment, not spending', () async {
      final c = await categorizer();
      final out = c.categorize(
        parsedMessage(
          channel: TxnChannel.nach,
          merchantRaw: 'ACH-D-INDIAN CLEARING CORP',
          paise: 1000000,
        ),
      );
      expect(out.categoryPath, 'investments/mutual_fund_sip');
      expect(out.kind, CategoryKind.investment);
      expect(out.kind.countsAsSpend, isFalse);
    });

    test('a credit card bill payment is not counted a second time', () async {
      final c = await categorizer();
      final out = c.categorize(
        parsedMessage(
          channel: TxnChannel.netbanking,
          merchantRaw: 'PAYMENT TOWARDS CREDIT CARD',
          accountTail: '0601',
          paise: 3800000,
        ),
      );
      expect(out.categoryPath, 'transfers/credit_card_payment');
      expect(out.kind.countsAsSpend, isFalse);
    });

    test('a bill for a card we never see IS counted, because nothing else '
        'records that spend', () async {
      final c = await categorizer(isCardTracked: (_) => false);
      final out = c.categorize(
        parsedMessage(
          channel: TxnChannel.netbanking,
          merchantRaw: 'PAYMENT TOWARDS CREDIT CARD',
          paise: 3800000,
        ),
      );
      expect(out.kind.countsAsSpend, isTrue);
    });

    test('an EMI is expense, and below the auto-apply bar because the loan is '
        'a guess', () async {
      final c = await categorizer();
      final out = c.categorize(
        parsedMessage(channel: TxnChannel.nach, merchantRaw: 'ACH-D-EMI 4412'),
      );
      expect(out.kind, CategoryKind.expense);
      expect(out.canAutoApply, isFalse);
    });
  });

  group('never wrongly excluded from spend', () {
    test('a weak name match may not move money out of the spend total',
        () async {
      final c = await categorizer();
      // PAYTM is transfers/wallet_topup. A fuzzy hit on it must NOT silently
      // turn a purchase into a transfer.
      final out = c.categorize(parsedMessage(merchantRaw: 'PAYTMFOODSTALL'));
      expect(out.categoryPath, isNot('transfers/wallet_topup'));
      expect(out.isUncategorized, isTrue);
    });

    test('an unidentified debit still counts toward the spend total', () async {
      final c = await categorizer();
      final out = c.categorize(parsedMessage(vpa: 'q9876543210@ybl'));
      expect(out.isUncategorized, isTrue);
      expect(out.kind.countsAsSpend, isTrue,
          reason: 'under-counting is the error the user cannot see');
    });

    test('every transfer and investment path in the taxonomy is net-zero',
        () async {
      final c = await categorizer();
      for (final path in ruleSet.categoryPaths) {
        final kind = c.kindOf(path);
        expect(kind, isNotNull, reason: path);
        if (path.startsWith('transfers/')) {
          expect(kind, CategoryKind.transfer, reason: path);
          expect(kind!.countsAsSpend, isFalse, reason: path);
        }
        if (path.startsWith('investments/')) {
          expect(kind, CategoryKind.investment, reason: path);
          expect(kind!.countsAsSpend, isFalse, reason: path);
        }
      }
      expect(c.kindOf('not_a_category/at_all'), isNull);
    });
  });

  group('user rules', () {
    test('override the shipped dictionary', () async {
      final c = await categorizer(userRules: <UserRule>[
        userRule(
          id: 'r1',
          pattern: 'SWIGGY',
          categoryPath: 'personal_family/gifts',
          merchantName: 'Swiggy gift cards',
        ),
      ]);
      final out = c.categorize(parsedMessage(merchantRaw: 'SWIGGY'));
      expect(out.categoryPath, 'personal_family/gifts');
      expect(out.source, CategorySource.userRule);
      expect(out.confidence, CascadeCategorizer.userRuleConfidence);
      expect(out.explanation, contains('You categorised'));
      expect(out.explanation, contains('Swiggy gift cards'));
    });

    test('a correction sticks across a terminal id change AND a restart',
        () async {
      final first = await categorizer();
      final message = parsedMessage(merchantRaw: 'RAZ*ChaiPointIN29481');
      expect(first.categorize(message).isUncategorized, isTrue);

      final created = first.ruleFromCorrection(
        id: 'rule_1',
        categoryPath: 'food_dining/cafe',
        now: now,
        message: message,
        merchantName: 'Chai Point',
      );
      expect(created.isOk, isTrue, reason: created.errorOrNull?.message);
      final saved = await first.upsertUserRule(created.valueOrNull!);
      expect(saved.isOk, isTrue);

      // Same shop, new terminal id next week.
      final later = parsedMessage(merchantRaw: 'RAZ*ChaiPointIN30112');
      expect(first.categorize(later).categoryPath, 'food_dining/cafe');

      // Restart: a fresh engine loaded from what the repository persisted.
      final restarted = await categorizer(userRules: first.userRules);
      final out = restarted.categorize(later);
      expect(out.categoryPath, 'food_dining/cafe');
      expect(out.source, CategorySource.userRule);
    });

    test('a correction on a QR code teaches the app that exact payee',
        () async {
      final c = await categorizer();
      final message = parsedMessage(vpa: 'q9876543210@ybl', paise: 2000);
      expect(c.categorize(message).isUncategorized, isTrue);

      final rule = c
          .ruleFromCorrection(
            id: 'rule_qr',
            categoryPath: 'food_dining/cafe',
            now: now,
            message: message,
            merchantName: 'Chai stall',
          )
          .valueOrNull!;
      expect((await c.upsertUserRule(rule)).isOk, isTrue);

      expect(c.categorize(message).categoryPath, 'food_dining/cafe');
      // A different QR code is still unknown - we learned one payee, not all.
      expect(
        c.categorize(parsedMessage(vpa: 'q1111111111@ybl')).isUncategorized,
        isTrue,
      );
    });

    test('the newer correction wins and the older one is disabled, so the '
        'rules list never contradicts itself', () async {
      final c = await categorizer();
      await c.upsertUserRule(userRule(
        id: 'r1',
        pattern: 'CHAIPOINT',
        categoryPath: 'food_dining/cafe',
      ));
      await c.upsertUserRule(userRule(
        id: 'r2',
        pattern: 'CHAIPOINT',
        categoryPath: 'groceries/kirana',
        createdAt: now.add(const Duration(days: 2)),
      ));

      expect(
        c.categorize(parsedMessage(merchantRaw: 'CHAIPOINT')).categoryPath,
        'groceries/kirana',
      );
      expect(c.lastRuleChange!.superseded.single.id, 'r1');
      expect(c.userRules.where((r) => r.enabled).map((r) => r.id), <String>['r2']);
    });

    test('a rule for a category that does not exist is refused, loudly',
        () async {
      final c = await categorizer();
      final result = await c.upsertUserRule(userRule(
        id: 'r1',
        pattern: 'CHAIPOINT',
        categoryPath: 'food.cafe',
      ));
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.code, ErrorCodes.invalidArgument);
    });

    test('an orphaned rule is reported, never silently overruled', () async {
      final c = await categorizer(userRules: <UserRule>[
        userRule(id: 'r1', pattern: 'SWIGGY', categoryPath: 'food.delivery'),
      ]);
      expect(c.orphanedUserRules, hasLength(1));
      final out = c.categorize(parsedMessage(merchantRaw: 'SWIGGY'));
      expect(out.isUncategorized, isTrue);
      expect(out.explanation, contains('no longer exists'));
    });

    test('removing a rule restores the dictionary answer', () async {
      final c = await categorizer(userRules: <UserRule>[
        userRule(
          id: 'r1',
          pattern: 'SWIGGY',
          categoryPath: 'personal_family/gifts',
        ),
      ]);
      expect(c.categorize(parsedMessage(merchantRaw: 'SWIGGY')).categoryPath,
          'personal_family/gifts');
      await c.removeUserRule('r1');
      expect(c.categorize(parsedMessage(merchantRaw: 'SWIGGY')).categoryPath,
          'food_dining/food_delivery');
      // Removing an unknown id is not an error.
      expect((await c.removeUserRule('nope')).isOk, isTrue);
    });
  });

  group('cascade order', () {
    test('user rule beats forced category beats dictionary beats rail',
        () async {
      final message = parsedMessage(
        merchantRaw: 'SWIGGY',
        forcedCategoryPath: 'transfers/atm_withdrawal',
        channel: TxnChannel.atm,
      );

      final withRule = await categorizer(userRules: <UserRule>[
        userRule(
          id: 'r1',
          pattern: 'SWIGGY',
          categoryPath: 'personal_family/gifts',
        ),
      ]);
      expect(withRule.categorize(message).source, CategorySource.userRule);

      final withoutRule = await categorizer();
      final forced = withoutRule.categorize(message);
      expect(forced.source, CategorySource.parserRule);
      expect(forced.categoryPath, 'transfers/atm_withdrawal');

      final dictionaryOnly = withoutRule.categorize(
        parsedMessage(merchantRaw: 'SWIGGY', channel: TxnChannel.atm),
      );
      expect(dictionaryOnly.source, CategorySource.dictionary);
      expect(dictionaryOnly.categoryPath, 'food_dining/food_delivery');
    });

    test('a forced category outside the taxonomy is ignored, not returned',
        () async {
      final c = await categorizer();
      final out = c.categorize(parsedMessage(
        merchantRaw: 'SWIGGY',
        forcedCategoryPath: 'not_a_category/nope',
      ));
      expect(out.categoryPath, 'food_dining/food_delivery');
    });
  });

  group('contract obligations', () {
    test('never returns a path outside the taxonomy', () async {
      final c = await categorizer();
      final paths = ruleSet.categoryPaths.toSet()
        ..add(CategoryResult.uncategorizedPath);
      final probes = <ParsedMessage>[
        parsedMessage(merchantRaw: 'SWIGGYUPI'),
        parsedMessage(merchantRaw: 'RAZORPAY'),
        parsedMessage(merchantRaw: 'TOTALLY UNKNOWN SHOP'),
        parsedMessage(vpa: 'q9876543210@ybl'),
        parsedMessage(vpa: 'someone.name@okaxis'),
        parsedMessage(channel: TxnChannel.atm, merchantRaw: 'ATM WDL'),
        parsedMessage(channel: TxnChannel.nach, merchantRaw: 'ACH-D-BSE SIP'),
        parsedMessage(merchantRaw: null, vpa: null),
        parsedMessage(merchantRaw: '', vpa: ''),
        parsedMessage(merchantRaw: '@@@@', vpa: '@ybl'),
        parsedMessage(direction: TxnDirection.credit, merchantRaw: 'SALARY'),
      ];
      for (final probe in probes) {
        final out = c.categorize(probe);
        expect(paths, contains(out.categoryPath), reason: probe.toString());
        expect(out.explanation, isNotEmpty, reason: probe.toString());
        expect(out.confidence, inInclusiveRange(0.0, 1.0));
      }
    });

    test('normalizeMerchant is the same function user rules are keyed on',
        () async {
      final c = await categorizer();
      expect(c.normalizeMerchant('RAZ*SwiggyIN29481'),
          MerchantNormalizer.key('RAZ*SwiggyIN29481'));
      expect(c.normalizeMerchant(null), '');
    });

    test('merchantFor exposes the entry behind a decision', () async {
      final c = await categorizer();
      expect(c.merchantFor('SWIGGYUPI')!.name, 'Swiggy');
      expect(c.merchantFor('NOT A MERCHANT'), isNull);
    });

    test('categorising is total - no input makes it throw', () async {
      final c = await categorizer();
      for (final raw in <String?>[
        null,
        '',
        '   ',
        '@@@',
        'a' * 500,
        '\u202eEVIL',
      ]) {
        expect(
          () => c.categorize(parsedMessage(merchantRaw: raw, vpa: raw)),
          returnsNormally,
        );
      }
    });
  });
}
