import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/data/data.dart';
import 'package:ledger/models/models.dart';

import 'ledger_test_support.dart';

/// Re-running the inbox backfill must not change a single number.
///
/// This is the failure the user notices fastest and trusts least: open the
/// app, tap "scan my messages" twice, and watch the month's spending double.
void main() {
  late TestLedger ledger;
  final DateTime may = DateTime(2026, 5, 20, 10);

  const String swiggySms =
      'Dear UPI user A/C X0601 debited by 150.0 on 05May26 trf to SWIGGY '
      'Refno 406512345678';

  setUp(() async {
    ledger = TestLedger(now: may);
    await ledger.open();
    await ledger.repository.upsertAccount(bankAccount(may));
  });

  group('raw messages', () {
    test('the live copy and the backfill copy are one message', () async {
      final Result<IngestReceipt> live = await ledger.repository.saveRawMessage(
        makeMessage(
          id: 'live-1',
          sender: 'VM-HDFCBK-S',
          body: swiggySms,
          receivedAt: DateTime(2026, 5, 5, 13, 30, 2),
        ),
      );
      expect(live.valueOrNull?.isDuplicate, isFalse);

      // The same SMS, read back out of the inbox 40 seconds later with a
      // provider id and a different delivery prefix.
      final Result<IngestReceipt> backfill =
          await ledger.repository.saveRawMessage(
        makeMessage(
          id: 'backfill-1',
          sender: 'AD-HDFCBK-S',
          body: swiggySms,
          receivedAt: DateTime(2026, 5, 5, 13, 30, 42),
          source: IngestSource.smsBackfill,
          providerId: 99123,
        ),
      );
      expect(backfill.valueOrNull?.isDuplicate, isTrue);
      expect(backfill.valueOrNull?.id, 'live-1');
      expect(backfill.valueOrNull?.mergedIntoId, 'live-1');

      // The provider id was folded into the row we already had, so the next
      // backfill recognises it without relying on the time window.
      final RawMessage? stored =
          (await ledger.repository.rawMessageById('live-1')).getOrElse(null);
      expect(stored?.providerId, 99123);
    });

    test('two genuine payments a minute apart are two messages', () async {
      await ledger.repository.saveRawMessage(
        makeMessage(
          id: 'm1',
          sender: 'VM-HDFCBK-S',
          body: 'A/C X0601 debited by 10.0 on 05May26 trf to CHAI Refno 1',
          receivedAt: DateTime(2026, 5, 5, 13, 30),
        ),
      );
      final Result<IngestReceipt> second =
          await ledger.repository.saveRawMessage(
        makeMessage(
          id: 'm2',
          sender: 'VM-HDFCBK-S',
          body: 'A/C X0601 debited by 10.0 on 05May26 trf to CHAI Refno 2',
          receivedAt: DateTime(2026, 5, 5, 13, 30, 40),
        ),
      );
      expect(
        second.valueOrNull?.isDuplicate,
        isFalse,
        reason: 'different reference numbers mean two real payments',
      );
    });

    test('a message delivered outside the window is not folded in', () async {
      await ledger.repository.saveRawMessage(
        makeMessage(
          id: 'm1',
          sender: 'VM-HDFCBK-S',
          body: swiggySms,
          receivedAt: DateTime(2026, 5, 5, 13, 30),
        ),
      );
      final Result<IngestReceipt> muchLater =
          await ledger.repository.saveRawMessage(
        makeMessage(
          id: 'm2',
          sender: 'VM-HDFCBK-S',
          body: swiggySms,
          receivedAt: DateTime(2026, 5, 5, 19, 0),
        ),
      );
      expect(muchLater.valueOrNull?.isDuplicate, isFalse);
    });

    test('a whole batch can be re-imported with no new rows', () async {
      final List<RawMessage> batch = <RawMessage>[
        for (int i = 0; i < 25; i++)
          makeMessage(
            id: 'm$i',
            sender: 'VM-HDFCBK-S',
            body: 'A/C X0601 debited by ${100 + i}.0 trf to SHOP Refno 40650$i',
            receivedAt: DateTime(2026, 5, 5, 9).add(Duration(minutes: i * 7)),
            source: IngestSource.smsBackfill,
            providerId: 1000 + i,
          ),
      ];

      final List<IngestReceipt> first =
          (await ledger.repository.saveRawMessages(batch)).getOrElse(<IngestReceipt>[]);
      expect(first.where((IngestReceipt r) => r.isDuplicate), isEmpty);

      final List<IngestReceipt> again =
          (await ledger.repository.saveRawMessages(batch)).getOrElse(<IngestReceipt>[]);
      expect(again.length, 25);
      expect(again.every((IngestReceipt r) => r.isDuplicate), isTrue);

      final int stored = await ledger.store.count(LedgerCollections.rawMessages);
      expect(stored, 25);
    });
  });

  group('transactions', () {
    test('posting the same parse twice stores one row and one amount',
        () async {
      final Transaction parsed = makeTxn(
        id: 'txn-1',
        rupees: 150,
        occurredAt: DateTime(2026, 5, 5, 13, 30),
        merchantName: 'Swiggy',
        accountTail: '0601',
        ref: '406512345678',
      );

      await ledger.post(parsed);
      // The second pass generates a fresh id, exactly as a re-parse would.
      await ledger.post(parsed.copyWith(id: 'txn-2'));

      final int rows = await ledger.store.count(LedgerCollections.transactions);
      expect(rows, 1, reason: 'the reference number identifies the money event');
      expect(
        await ledger.spendBetween(DateTime(2026, 5), DateTime(2026, 6)),
        const Money(15000),
      );

      // And exactly one balanced pair of postings, not two.
      expect(await ledger.allPostings(), hasLength(2));
    });

    test('a re-parse of the same message updates its own row', () async {
      await ledger.repository.saveRawMessage(
        makeMessage(
          id: 'raw-1',
          sender: 'VM-HDFCBK-S',
          body: swiggySms,
          receivedAt: DateTime(2026, 5, 5, 13, 30),
        ),
      );
      await ledger.post(
        makeTxn(
          id: 'txn-1',
          rupees: 150,
          occurredAt: DateTime(2026, 5, 5, 13, 30),
          accountTail: '0601',
          rawMessageId: 'raw-1',
          categoryPath: CategoryResult.uncategorizedPath,
        ),
      );

      // A newer rules pack recognises the merchant. Same message, better
      // answer, still one transaction.
      await ledger.post(
        makeTxn(
          id: 'txn-rebuilt',
          rupees: 150,
          occurredAt: DateTime(2026, 5, 5, 13, 30),
          accountTail: '0601',
          rawMessageId: 'raw-1',
          merchantName: 'Swiggy',
          categoryPath: 'food_dining/food_delivery',
        ),
      );

      expect(await ledger.store.count(LedgerCollections.transactions), 1);
      final Transaction? stored =
          (await ledger.repository.transactionById('txn-1')).getOrElse(null);
      expect(stored?.categoryPath, 'food_dining/food_delivery');
      expect(stored?.merchantName, 'Swiggy');
    });

    test('a re-parse never overwrites a category the user chose', () async {
      await ledger.post(
        makeTxn(
          id: 'txn-1',
          rupees: 480,
          occurredAt: DateTime(2026, 5, 6, 20),
          accountTail: '0601',
          merchantName: 'Blinkit',
          rawMessageId: 'raw-9',
          categoryPath: 'groceries/quick_commerce',
        ),
      );
      await ledger.repository.recategorize(
        'txn-1',
        CategoryResult.manual('personal_family/gifts', CategoryKind.expense),
      );

      await ledger.post(
        makeTxn(
          id: 'txn-again',
          rupees: 480,
          occurredAt: DateTime(2026, 5, 6, 20),
          accountTail: '0601',
          merchantName: 'Blinkit',
          rawMessageId: 'raw-9',
          categoryPath: 'groceries/quick_commerce',
        ),
      );

      final Transaction? stored =
          (await ledger.repository.transactionById('txn-1')).getOrElse(null);
      expect(stored?.categoryPath, 'personal_family/gifts');
      expect(stored?.categorySource, CategorySource.manual);
    });

    test('a transaction with no reference still de-duplicates on its fields',
        () async {
      final Transaction cash = makeTxn(
        id: 'a',
        rupees: 90,
        occurredAt: DateTime(2026, 5, 7, 8, 15),
        merchantName: 'Chai Point',
        accountTail: '0601',
      );
      await ledger.post(cash);
      await ledger.post(cash.copyWith(id: 'b'));
      expect(await ledger.store.count(LedgerCollections.transactions), 1);
    });

    test('the same amount on two different days is two transactions',
        () async {
      await ledger.post(
        makeTxn(
          id: 'a',
          rupees: 90,
          occurredAt: DateTime(2026, 5, 7, 8, 15),
          merchantName: 'Chai Point',
          accountTail: '0601',
        ),
      );
      await ledger.post(
        makeTxn(
          id: 'b',
          rupees: 90,
          occurredAt: DateTime(2026, 5, 8, 8, 15),
          merchantName: 'Chai Point',
          accountTail: '0601',
        ),
      );
      expect(
        await ledger.store.count(LedgerCollections.transactions),
        2,
        reason: 'a missing transaction is noticed sooner than a duplicate',
      );
    });

    test('a negative or zero amount is refused', () async {
      final Result<Transaction> zero = await ledger.repository.postTransaction(
        makeTxn(
          id: 'zero',
          rupees: 0,
          occurredAt: DateTime(2026, 5, 7),
          accountTail: '0601',
        ),
      );
      expect(zero.isErr, isTrue);
      expect(zero.errorOrNull?.code, ErrorCodes.invalidArgument);
    });

    test('an unknown category path is refused when a taxonomy is supplied',
        () async {
      final LedgerRepositoryImpl strict = LedgerRepositoryImpl(
        store: MemoryLedgerStore(),
        clock: () => may,
        knownCategoryPaths: const <String>{'food_dining/food_delivery'},
      );
      await strict.init();

      final Result<Transaction> bad = await strict.postTransaction(
        makeTxn(
          id: 'x',
          rupees: 10,
          occurredAt: DateTime(2026, 5, 7),
          categoryPath: 'not_a_real/category',
        ),
      );
      expect(bad.isErr, isTrue);
      expect(bad.errorOrNull?.code, ErrorCodes.invalidArgument);
      await strict.close();
    });
  });

  group('export and restore', () {
    test('a backup restores every transaction and carries no message text',
        () async {
      await ledger.repository.saveRawMessage(
        makeMessage(
          id: 'raw-1',
          sender: 'VM-HDFCBK-S',
          body: swiggySms,
          receivedAt: DateTime(2026, 5, 5, 13, 30),
        ),
      );
      await ledger.post(
        makeTxn(
          id: 'txn-1',
          rupees: 150,
          occurredAt: DateTime(2026, 5, 5, 13, 30),
          merchantName: 'Swiggy',
          accountTail: '0601',
          rawMessageId: 'raw-1',
        ),
      );

      final Map<String, dynamic> backup =
          (await ledger.repository.exportAll()).getOrElse(<String, dynamic>{});
      expect(backup['containsMessageBodies'], isFalse);
      expect(backup.toString().contains('SWIGGY'), isFalse,
          reason: 'a backup file may end up in a cloud folder');

      final TestLedger restored = TestLedger(now: may);
      await restored.open();
      final Result<void> result = await restored.repository.importAll(backup);
      expect(result.isOk, isTrue);

      expect(
        await restored.spendBetween(DateTime(2026, 5), DateTime(2026, 6)),
        const Money(15000),
      );
      final Transaction? txn =
          (await restored.repository.transactionById('txn-1')).getOrElse(null);
      expect(txn?.merchantName, 'Swiggy');
      // The message metadata survives; the words do not.
      final RawMessage? raw =
          (await restored.repository.rawMessageById('raw-1')).getOrElse(null);
      expect(raw, isNotNull);
      expect(raw?.body, isEmpty);
      expect(raw?.bodyHash, isNotEmpty);
    });

    test('a file we did not write leaves the ledger untouched', () async {
      await ledger.post(
        makeTxn(
          id: 'txn-1',
          rupees: 150,
          occurredAt: DateTime(2026, 5, 5),
          accountTail: '0601',
        ),
      );

      final Result<void> bad = await ledger.repository.importAll(
        <String, dynamic>{'format': 'some-other-app', 'collections': <String, dynamic>{}},
      );
      expect(bad.isErr, isTrue);
      expect(bad.errorOrNull?.code, ErrorCodes.invalidArgument);
      expect(await ledger.store.count(LedgerCollections.transactions), 1);
    });
  });
}
