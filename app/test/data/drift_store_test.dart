import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/data/data.dart';
import 'package:ledger/data/drift_store.dart';
import 'package:ledger/models/models.dart';

import 'ledger_test_support.dart';

/// The SQL store, exercised against a real SQLite database.
///
/// Every other test in this directory runs against [MemoryLedgerStore], which
/// is what makes them fast and portable. This file is the one that proves the
/// two stores agree - that the generated DDL is valid, that the indexed
/// columns and the `WHERE` clauses line up, and that a row written as JSON
/// comes back as the same model.
///
/// `NativeDatabase.memory()` needs a SQLite binary on whatever machine is
/// running the tests. On a phone that binary ships inside the APK
/// (`sqlite3_flutter_libs`); on a bare desktop CI box it may be absent, so the
/// whole group skips rather than failing a build for a missing system library.
void main() {
  final DateTime may = DateTime(2026, 5, 20, 10);

  bool sqliteAvailable = true;
  try {
    NativeDatabase.memory().close();
  } catch (_) {
    sqliteAvailable = false;
  }

  group(
    'DriftLedgerStore',
    () {
      late DriftLedgerStore store;
      late LedgerRepositoryImpl repository;

      setUp(() async {
        store = DriftLedgerStore(LedgerDriftDatabase(NativeDatabase.memory()));
        repository = LedgerRepositoryImpl(store: store, clock: () => may);
        final Result<void> opened = await repository.init();
        expect(opened.isOk, isTrue, reason: opened.errorOrNull?.message);
      });

      tearDown(() async {
        await repository.close();
      });

      test('creates every table and index declared in the schema', () async {
        // Opening twice must be a no-op, not a failure: every statement is
        // `IF NOT EXISTS` precisely so a reopen cannot touch existing rows.
        await store.open();
        for (final CollectionDef c in LedgerSchema.collections) {
          expect(await store.count(c.name), isNonNegative);
        }
      });

      test('a transaction round-trips through SQL unchanged', () async {
        await repository.upsertAccount(bankAccount(may));
        final Transaction posted = (await repository.postTransaction(
          makeTxn(
            id: 't1',
            rupees: 450,
            paise: 50,
            occurredAt: DateTime(2026, 5, 3, 13),
            merchantName: 'Swiggy',
            accountTail: '0601',
            ref: 'REF000001',
            note: 'lunch with the team',
          ),
        ))
            .getOrElse(
          makeTxn(id: 'x', rupees: 0, occurredAt: may),
        );

        final Transaction? read =
            (await repository.transactionById('t1')).getOrElse(null);
        expect(read, posted);
        expect(read?.amount, const Money(45050));
        expect(read?.note, 'lunch with the team');
      });

      test('the double-count rule holds on real SQL too', () async {
        await repository.upsertAccount(bankAccount(may));
        await repository.upsertAccount(cardAccount(may));

        await repository.postTransaction(
          makeTxn(
            id: 'card-spend',
            rupees: 10290,
            occurredAt: DateTime(2026, 5, 2, 22, 26),
            categoryPath: 'food_dining/restaurants',
            channel: TxnChannel.card,
            merchantName: 'Eazydine',
            cardTail: '4455',
            ref: 'AUTH00551277',
          ),
        );
        await repository.postTransaction(
          makeTxn(
            id: 'card-bill',
            rupees: 10290,
            occurredAt: DateTime(2026, 5, 18, 9, 5),
            kind: CategoryKind.transfer,
            categoryPath: TransferPaths.creditCardPayment,
            channel: TxnChannel.netbanking,
            accountTail: '0601',
            cardTail: '4455',
            ref: 'UTR908877665544',
          ),
        );

        final Money spend = (await repository.totalSpend(
          from: DateTime(2026, 5),
          to: DateTime(2026, 6),
        ))
            .getOrElse(Money.zero);
        expect(spend, const Money(1029000));
      });

      test('re-importing a batch inserts nothing the second time', () async {
        final List<RawMessage> batch = <RawMessage>[
          for (int i = 0; i < 10; i++)
            makeMessage(
              id: 'm$i',
              sender: 'VM-HDFCBK-S',
              body: 'A/C X0601 debited by ${100 + i}.0 trf to SHOP Ref 4065$i',
              receivedAt: DateTime(2026, 5, 5, 9).add(Duration(minutes: i * 7)),
              providerId: 500 + i,
            ),
        ];
        await repository.saveRawMessages(batch);
        await repository.saveRawMessages(batch);
        expect(await store.count(LedgerCollections.rawMessages), 10);
      });

      test('every filter a query can build is valid SQL', () async {
        await repository.upsertAccount(bankAccount(may));
        await repository.postTransaction(
          makeTxn(
            id: 't1',
            rupees: 450,
            occurredAt: DateTime(2026, 5, 3, 13),
            merchantName: 'Swiggy',
            accountTail: '0601',
            ref: 'REF000001',
          ),
        );

        final Result<List<Transaction>> everything =
            await repository.transactions(
          TxnQuery(
            from: DateTime(2026, 5),
            to: DateTime(2026, 6),
            categoryPaths: const <String>{'food_dining/food_delivery'},
            kinds: const <CategoryKind>{CategoryKind.expense},
            statuses: const <TxnStatus>{TxnStatus.posted},
            accountIds: const <String>{'acc-hdfc'},
            channels: const <TxnChannel>{TxnChannel.upi},
            direction: TxnDirection.debit,
            merchantName: 'Swiggy',
            search: 'swig',
            limit: 10,
            offset: 0,
          ),
        );
        expect(everything.isOk, isTrue, reason: everything.errorOrNull?.message);
        expect(everything.getOrElse(<Transaction>[]).single.id, 't1');

        // An empty IN () would be a syntax error, so it must be rewritten.
        final Result<List<Transaction>> none = await repository.transactions(
          const TxnQuery(accountIds: <String>{'nobody'}),
        );
        expect(none.getOrElse(<Transaction>[]), isEmpty);
      });

      test('a wipe empties every table and keeps the app usable', () async {
        await repository.upsertAccount(bankAccount(may));
        await repository.postTransaction(
          makeTxn(
            id: 't1',
            rupees: 450,
            occurredAt: DateTime(2026, 5, 3),
            accountTail: '0601',
            ref: 'REF000001',
          ),
        );
        expect((await repository.wipe()).isOk, isTrue);
        expect(await store.count(LedgerCollections.transactions), 0);
        expect(await store.count(LedgerCollections.postings), 0);
        // Cash in hand is seeded again, so the app still works after an erase.
        final List<Account> accounts =
            (await repository.accounts()).getOrElse(<Account>[]);
        expect(accounts.map((Account a) => a.id), contains(LedgerAccounts.cash));
      });

      test('a failed write leaves the database exactly as it was', () async {
        await repository.upsertAccount(bankAccount(may));
        final Result<Transaction> bad = await repository.postTransaction(
          makeTxn(id: 'bad', rupees: 0, occurredAt: DateTime(2026, 5, 3)),
        );
        expect(bad.isErr, isTrue);
        expect(await store.count(LedgerCollections.transactions), 0);
      });
    },
    skip: sqliteAvailable
        ? null
        : 'No SQLite binary on this machine; the ledger logic is covered by '
            'the in-memory store tests.',
  );
}
