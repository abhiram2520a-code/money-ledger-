import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/data/data.dart';
import 'package:ledger/models/models.dart';

import 'ledger_test_support.dart';

/// Reading the ledger back: the rollups every screen is built on, the queue
/// the user is asked about, and the promises the repository makes about
/// streams, accounts and stored message text.
void main() {
  late TestLedger ledger;
  final DateTime may = DateTime(2026, 5, 20, 10);
  final DateTime monthStart = DateTime(2026, 5);
  final DateTime monthEnd = DateTime(2026, 6);

  setUp(() async {
    ledger = TestLedger(now: may);
    await ledger.open();
    await ledger.repository.upsertAccount(bankAccount(may));
  });

  Future<void> seedMonth() async {
    await ledger.post(
      makeTxn(
        id: 't1',
        rupees: 450,
        occurredAt: DateTime(2026, 5, 3, 13),
        merchantName: 'Swiggy',
        accountTail: '0601',
        ref: 'REF000001',
      ),
    );
    await ledger.post(
      makeTxn(
        id: 't2',
        rupees: 1200,
        occurredAt: DateTime(2026, 5, 9, 19),
        categoryPath: 'groceries/quick_commerce',
        merchantName: 'Blinkit',
        accountTail: '0601',
        ref: 'REF000002',
      ),
    );
    await ledger.post(
      makeTxn(
        id: 't3',
        rupees: 300,
        occurredAt: DateTime(2026, 5, 11, 13),
        merchantName: 'Swiggy',
        accountTail: '0601',
        ref: 'REF000003',
      ),
    );
    await ledger.post(
      makeTxn(
        id: 't4',
        rupees: 95000,
        occurredAt: DateTime(2026, 5, 1, 10),
        direction: TxnDirection.credit,
        kind: CategoryKind.income,
        categoryPath: 'income/salary',
        merchantName: 'Employer',
        accountTail: '0601',
        ref: 'SAL000001',
      ),
    );
    await ledger.post(
      makeTxn(
        id: 't5',
        rupees: 2000,
        occurredAt: DateTime(2026, 4, 28, 10),
        merchantName: 'Swiggy',
        accountTail: '0601',
        ref: 'REF000005',
      ),
    );
  }

  group('rollups', () {
    test('the month total counts only what was spent inside it', () async {
      await seedMonth();
      expect(await ledger.spendBetween(monthStart, monthEnd), const Money(195000));
      expect(
        (await ledger.repository.totalIncome(from: monthStart, to: monthEnd))
            .getOrElse(Money.zero),
        const Money(9500000),
      );
    });

    test('adjacent months never double-count a midnight transaction',
        () async {
      await ledger.post(
        makeTxn(
          id: 'midnight',
          rupees: 100,
          occurredAt: DateTime(2026, 5, 1, 0, 0),
          merchantName: 'Chai',
          accountTail: '0601',
          ref: 'MID00001',
        ),
      );
      final Money april = await ledger.spendBetween(DateTime(2026, 4), monthStart);
      final Money mayTotal = await ledger.spendBetween(monthStart, monthEnd);
      expect(april, Money.zero);
      expect(mayTotal, const Money(10000));
    });

    test('spend by category is ordered by what actually costs the most',
        () async {
      await seedMonth();
      final List<SpendBucket> buckets =
          (await ledger.repository.spendByCategory(from: monthStart, to: monthEnd))
              .getOrElse(<SpendBucket>[]);
      expect(buckets.first.key, 'groceries/quick_commerce');
      expect(buckets.first.total, const Money(120000));
      expect(
        buckets.map((SpendBucket b) => b.key),
        isNot(contains('income/salary')),
        reason: 'income is not spending',
      );
    });

    test('spend by merchant adds up the repeats', () async {
      await seedMonth();
      final List<SpendBucket> buckets =
          (await ledger.repository.spendByMerchant(from: monthStart, to: monthEnd))
              .getOrElse(<SpendBucket>[]);
      final SpendBucket swiggy =
          buckets.firstWhere((SpendBucket b) => b.key == 'Swiggy');
      expect(swiggy.total, const Money(75000));
      expect(swiggy.count, 2);
    });

    test('monthly spend is grouped by the local calendar month', () async {
      await seedMonth();
      final List<SpendBucket> months = (await ledger.repository
              .monthlySpend(from: DateTime(2026, 4), to: monthEnd))
          .getOrElse(<SpendBucket>[]);
      expect(months.map((SpendBucket b) => b.key), <String>['2026-04', '2026-05']);
      expect(months.first.total, const Money(200000));
    });

    test('a row the user excluded leaves every total', () async {
      await ledger.post(
        makeTxn(
          id: 'x',
          rupees: 5000,
          occurredAt: DateTime(2026, 5, 4),
          merchantName: 'Deposit refund',
          accountTail: '0601',
          ref: 'EXC00001',
          excluded: true,
        ),
      );
      expect(await ledger.spendBetween(monthStart, monthEnd), Money.zero);
    });
  });

  group('reading and correcting', () {
    test('search looks at the merchant, the note and the reference', () async {
      await seedMonth();
      final List<Transaction> found = (await ledger.repository
              .transactions(const TxnQuery(search: 'swig')))
          .getOrElse(<Transaction>[]);
      expect(found.map((Transaction t) => t.id), containsAll(<String>['t1', 't3']));

      final List<Transaction> byRef = (await ledger.repository
              .transactions(const TxnQuery(search: 'REF000002')))
          .getOrElse(<Transaction>[]);
      expect(byRef.single.id, 't2');
    });

    test('the timeline comes back newest first', () async {
      await seedMonth();
      final List<Transaction> rows =
          (await ledger.repository.transactions(const TxnQuery()))
              .getOrElse(<Transaction>[]);
      expect(rows.first.id, 't3');
      expect(rows.last.id, 't5');
    });

    test('unknown merchants queue up to be asked about, oldest first',
        () async {
      await ledger.post(
        makeTxn(
          id: 'u2',
          rupees: 220,
          occurredAt: DateTime(2026, 5, 12),
          categoryPath: CategoryResult.uncategorizedPath,
          merchantName: 'EAZYDINE0000000',
          accountTail: '0601',
          ref: 'UNK00002',
        ),
      );
      await ledger.post(
        makeTxn(
          id: 'u1',
          rupees: 110,
          occurredAt: DateTime(2026, 5, 4),
          categoryPath: CategoryResult.uncategorizedPath,
          merchantName: 'PZCREDIT0000000',
          accountTail: '0601',
          ref: 'UNK00001',
        ),
      );

      final List<Transaction> queue =
          (await ledger.repository.uncategorized()).getOrElse(<Transaction>[]);
      expect(queue.map((Transaction t) => t.id), <String>['u1', 'u2']);

      final Stream<int> counts = ledger.repository.watchUncategorizedCount();
      expect(await counts.first, 2);
    });

    test('one tap can become a rule for next time', () async {
      await ledger.post(
        makeTxn(
          id: 'u1',
          rupees: 110,
          occurredAt: DateTime(2026, 5, 4),
          categoryPath: CategoryResult.uncategorizedPath,
          merchantName: 'Eazydine',
          accountTail: '0601',
          ref: 'UNK00001',
        ),
      );
      final Result<Transaction> fixed = await ledger.repository.recategorize(
        'u1',
        CategoryResult.manual('food_dining/restaurants', CategoryKind.expense),
        createUserRule: true,
      );
      expect(fixed.isOk, isTrue);
      expect(fixed.valueOrNull?.categoryPath, 'food_dining/restaurants');
      expect(fixed.valueOrNull?.isFieldLocked('categoryPath'), isTrue);
      expect(fixed.valueOrNull?.status, TxnStatus.posted);

      final List<UserRule> rules =
          (await ledger.repository.userRules()).getOrElse(<UserRule>[]);
      expect(rules.single.pattern, 'EAZYDINE');
      expect(rules.single.categoryPath, 'food_dining/restaurants');
    });

    test('a full refund takes the original out of the totals with it',
        () async {
      await ledger.post(
        makeTxn(
          id: 'buy',
          rupees: 1000,
          occurredAt: DateTime(2026, 5, 3),
          categoryPath: 'shopping/ecommerce',
          accountTail: '0601',
          ref: 'BUY00001',
        ),
      );
      await ledger.post(
        makeTxn(
          id: 'back',
          rupees: 1000,
          occurredAt: DateTime(2026, 5, 6),
          direction: TxnDirection.credit,
          categoryPath: 'shopping/ecommerce',
          accountTail: '0601',
          ref: 'BACK0001',
        ),
      );
      await ledger.repository.linkReversal(txnId: 'back', reversesId: 'buy');

      expect(await ledger.spendBetween(monthStart, monthEnd), Money.zero);
      final Transaction? original =
          (await ledger.repository.transactionById('buy')).getOrElse(null);
      expect(original?.status, TxnStatus.reversed);
    });
  });

  group('accounts', () {
    test('an account is found by the tail a message actually prints', () async {
      final Account? byMask =
          (await ledger.repository.accountByTail('XXXXXX0601')).getOrElse(null);
      expect(byMask?.id, 'acc-hdfc');

      final Account? byStars =
          (await ledger.repository.accountByTail('**0601')).getOrElse(null);
      expect(byStars?.id, 'acc-hdfc');
    });

    test('an empty tail matches nothing', () async {
      expect(
        (await ledger.repository.accountByTail('XXXX')).getOrElse(null),
        isNull,
        reason: 'matching on no digits would attach every message to every '
            'account',
      );
      expect((await ledger.repository.accountByTail(null)).getOrElse(null), isNull);
    });

    test('cash in hand exists from the first launch', () async {
      final List<Account> accounts =
          (await ledger.repository.accounts()).getOrElse(<Account>[]);
      expect(
        accounts.map((Account a) => a.id),
        contains(LedgerAccounts.cash),
      );
    });
  });

  group('privacy', () {
    test('message text is purged while the audit trail survives', () async {
      await ledger.repository.saveRawMessage(
        makeMessage(
          id: 'old',
          sender: 'VM-HDFCBK-S',
          body: 'A/C X0601 debited by 150.0 trf to SWIGGY Refno 406512345678',
          receivedAt: DateTime(2025, 10, 1),
        ),
      );
      await ledger.repository.saveRawMessage(
        makeMessage(
          id: 'recent',
          sender: 'VM-HDFCBK-S',
          body: 'A/C X0601 debited by 99.0 trf to CHAI Refno 406599999999',
          receivedAt: DateTime(2026, 5, 18),
        ),
      );

      final int purged = (await ledger.repository.purgeMessageBodies(
        olderThan: LedgerEncryption.purgeAfter(may),
      ))
          .getOrElse(0);
      expect(purged, 1);

      final RawMessage? old =
          (await ledger.repository.rawMessageById('old')).getOrElse(null);
      expect(old, isNotNull, reason: 'the row stays, the words go');
      expect(old?.body, isEmpty);
      expect(old?.bodyHash, isNotEmpty);

      final RawMessage? recent =
          (await ledger.repository.rawMessageById('recent')).getOrElse(null);
      expect(recent?.body, isNotEmpty);
    });

    test('the app never claims encryption it does not implement', () {
      expect(LedgerEncryption.atRestEncryptionEnabled, isFalse);
      expect(
        LedgerEncryption.describeProtection(),
        isNot(contains('encrypted on this device')),
      );
      expect(
        LedgerEncryption.protectionDetails()
            .any((String s) => s.contains('not separately encrypted')),
        isTrue,
      );
      expect(LedgerEncryption.sqlCipherPragmas('abc'), isEmpty);
    });
  });

  group('streams', () {
    test('a watcher gets the current value immediately and again on a change',
        () async {
      final Stream<List<Transaction>> stream =
          ledger.repository.watchTransactions(const TxnQuery());
      final List<List<Transaction>> seen = <List<Transaction>>[];
      final StreamSubscription<List<Transaction>> sub =
          stream.listen(seen.add);

      await Future<void>.delayed(Duration.zero);
      expect(seen.first, isEmpty);

      await ledger.post(
        makeTxn(
          id: 't1',
          rupees: 450,
          occurredAt: DateTime(2026, 5, 3),
          accountTail: '0601',
          ref: 'REF000001',
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(seen.last, hasLength(1));
      await sub.cancel();
    });
  });

  group('failures', () {
    test('a missing row comes back as an error, never as an exception',
        () async {
      final Result<void> missing =
          await ledger.repository.deleteTransaction('nope');
      expect(missing.isErr, isTrue);
      expect(missing.errorOrNull?.code, ErrorCodes.notFound);
    });

    test('an error message never carries message text', () async {
      final Result<Transaction> bad = await ledger.repository.postTransaction(
        makeTxn(
          id: 'bad',
          rupees: 0,
          occurredAt: DateTime(2026, 5, 3),
          merchantName: 'SECRET MERCHANT',
        ),
      );
      expect(bad.isErr, isTrue);
      expect(bad.errorOrNull?.message.contains('SECRET'), isFalse);
    });
  });
}
