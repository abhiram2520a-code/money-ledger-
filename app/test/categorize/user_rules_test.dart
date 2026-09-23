import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/categorize/categorize.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';

void main() {
  final now = DateTime.utc(2026, 9, 20, 12);
  const validPaths = <String>{
    'food_dining/cafe',
    'groceries/kirana',
    'entertainment/streaming',
    'transfers/p2p_sent',
  };

  UserRule rule({
    required String id,
    UserRuleMatch match = UserRuleMatch.merchantExact,
    required String pattern,
    required String categoryPath,
    CategoryKind kind = CategoryKind.expense,
    int priority = 100,
    DateTime? createdAt,
    bool enabled = true,
  }) {
    return UserRule(
      id: id,
      match: match,
      pattern: pattern,
      categoryPath: categoryPath,
      kind: kind,
      createdAt: createdAt ?? now,
      priority: priority,
      enabled: enabled,
    );
  }

  group('UserRuleStore', () {
    test('stores merchant patterns normalised, never raw', () {
      final store = UserRuleStore()..loadAll(const <UserRule>[], validPaths: validPaths);
      store.upsert(rule(
        id: 'r1',
        pattern: 'RAZ*ChaiPointIN29481',
        categoryPath: 'food_dining/cafe',
      ));

      expect(store.rules.single.pattern, 'CHAIPOINTIN');

      // The terminal id changed, the rule still fires. This is the whole
      // point: a rule keyed on the raw string would already be dead.
      final hit = store.resolve(
        merchantNormalized: MerchantNormalizer.key('RAZ*ChaiPointIN30112'),
      );
      expect(hit, isNotNull);
      expect(hit!.categoryPath, 'food_dining/cafe');
    });

    test('re-normalises stored patterns on load', () {
      final store = UserRuleStore()
        ..loadAll(<UserRule>[
          rule(
            id: 'r1',
            pattern: 'raz*chaipoint  ',
            categoryPath: 'food_dining/cafe',
          ),
        ], validPaths: validPaths);
      expect(store.rules.single.pattern, 'CHAIPOINT');
    });

    test('a later correction supersedes the earlier one, and says so', () {
      final store = UserRuleStore()..loadAll(const <UserRule>[], validPaths: validPaths);
      store.upsert(rule(
        id: 'r1',
        pattern: 'CHAIPOINT',
        categoryPath: 'food_dining/cafe',
      ));
      final change = store.upsert(rule(
        id: 'r2',
        pattern: 'CHAIPOINT',
        categoryPath: 'groceries/kirana',
        createdAt: now.add(const Duration(days: 1)),
      ));

      expect(change.superseded, hasLength(1));
      expect(change.superseded.single.id, 'r1');
      expect(change.superseded.single.enabled, isFalse);
      expect(change.summary, contains('was food_dining/cafe'));

      // Exactly one live rule, and it is the new one.
      final live = store.rules.where((r) => r.enabled).toList();
      expect(live, hasLength(1));
      expect(live.single.id, 'r2');
      expect(
        store.resolve(merchantNormalized: 'CHAIPOINT')!.categoryPath,
        'groceries/kirana',
      );

      // The disabled rule is still returned so it is actually persisted -
      // leaving it unwritten is how a fixed correction comes back on restart.
      expect(store.rules.map((r) => r.id), containsAll(<String>['r1', 'r2']));
    });

    test('resolution is deterministic: priority, then newest, then scope', () {
      final store = UserRuleStore()
        ..loadAll(<UserRule>[
          rule(
            id: 'low',
            pattern: 'CHAIPOINT',
            categoryPath: 'food_dining/cafe',
            priority: 100,
          ),
          rule(
            id: 'high',
            match: UserRuleMatch.merchantContains,
            pattern: 'CHAI',
            categoryPath: 'groceries/kirana',
            priority: 200,
          ),
        ], validPaths: validPaths);

      for (var i = 0; i < 20; i++) {
        expect(
          store.resolve(merchantNormalized: 'CHAIPOINT')!.id,
          'high',
          reason: 'the answer must not depend on iteration order',
        );
      }
    });

    test('a disabled rule never fires', () {
      final store = UserRuleStore()
        ..loadAll(<UserRule>[
          rule(
            id: 'r1',
            pattern: 'CHAIPOINT',
            categoryPath: 'food_dining/cafe',
            enabled: false,
          ),
        ], validPaths: validPaths);
      expect(store.resolve(merchantNormalized: 'CHAIPOINT'), isNull);
    });

    test('a rule whose category vanished is surfaced, not dropped', () {
      final store = UserRuleStore()
        ..loadAll(<UserRule>[
          rule(id: 'r1', pattern: 'CHAIPOINT', categoryPath: 'food.cafe'),
        ], validPaths: validPaths);
      expect(store.orphanedRules, hasLength(1));
      // It still wins resolution, so the caller can say "needs attention"
      // rather than silently re-categorising behind the user's back.
      expect(store.resolve(merchantNormalized: 'CHAIPOINT'), isNotNull);
    });

    test('hit counting is explicit, not a side effect of categorising', () {
      final store = UserRuleStore()
        ..loadAll(<UserRule>[
          rule(id: 'r1', pattern: 'CHAIPOINT', categoryPath: 'food_dining/cafe'),
        ], validPaths: validPaths);
      store.resolve(merchantNormalized: 'CHAIPOINT');
      expect(store.rules.single.hitCount, 0);
      store.noteHit('r1', now: now);
      expect(store.rules.single.hitCount, 1);
      expect(store.noteHit('nope', now: now), isNull);
    });
  });

  group('UserRuleStore.fromCorrection', () {
    test('keys an opaque QR payment on the exact VPA', () {
      final result = UserRuleStore.fromCorrection(
        id: 'r1',
        categoryPath: 'food_dining/cafe',
        kind: CategoryKind.expense,
        now: now,
        vpa: 'paytmqr2810050501@paytm',
        merchantName: 'Chai stall',
      );
      expect(result.isOk, isTrue);
      final created = result.valueOrNull!;
      expect(created.match, UserRuleMatch.vpaExact);
      expect(created.pattern, 'paytmqr2810050501@paytm');
    });

    test('keys a named merchant VPA on its prefix, not its sponsor bank', () {
      final created = UserRuleStore.fromCorrection(
        id: 'r1',
        categoryPath: 'food_dining/cafe',
        kind: CategoryKind.expense,
        now: now,
        vpa: 'chaipoint@icici',
      ).valueOrNull!;
      expect(created.match, UserRuleMatch.vpaPrefix);
      expect(created.pattern, 'chaipoint@');
      // Same merchant, new sponsor bank: still matches.
      expect(created.matches(vpa: 'chaipoint@ybl'), isTrue);
    });

    test('falls back to the normalised merchant, then the sender', () {
      final byMerchant = UserRuleStore.fromCorrection(
        id: 'r1',
        categoryPath: 'food_dining/cafe',
        kind: CategoryKind.expense,
        now: now,
        merchantRaw: 'RAZ*ChaiPointIN29481',
      ).valueOrNull!;
      expect(byMerchant.match, UserRuleMatch.merchantExact);
      expect(byMerchant.pattern, 'CHAIPOINTIN');

      final bySender = UserRuleStore.fromCorrection(
        id: 'r2',
        categoryPath: 'food_dining/cafe',
        kind: CategoryKind.expense,
        now: now,
        senderHeader: 'hdfcbk',
      ).valueOrNull!;
      expect(bySender.match, UserRuleMatch.senderExact);
      expect(bySender.pattern, 'HDFCBK');
    });

    test('refuses loudly when there is nothing stable to match on', () {
      final result = UserRuleStore.fromCorrection(
        id: 'r1',
        categoryPath: 'food_dining/cafe',
        kind: CategoryKind.expense,
        now: now,
      );
      expect(result.isErr, isTrue);
      expect(result.errorOrNull!.code, ErrorCodes.invalidArgument);
    });

    test('a more specific scope outranks a broader one by default', () {
      expect(
        UserRuleStore.defaultPriorityFor(UserRuleMatch.vpaExact),
        greaterThan(UserRuleStore.defaultPriorityFor(UserRuleMatch.senderExact)),
      );
      expect(
        UserRuleStore.defaultPriorityFor(UserRuleMatch.merchantExact),
        greaterThan(
            UserRuleStore.defaultPriorityFor(UserRuleMatch.merchantContains)),
      );
    });
  });
}
