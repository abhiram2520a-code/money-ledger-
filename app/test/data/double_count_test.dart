import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/data/data.dart';
import 'package:ledger/models/models.dart';

import 'ledger_test_support.dart';

/// The tests this whole data layer exists to pass.
///
/// Every one of them is a real shape from Indian bank SMS, and every one of
/// them is a number a single-entry app reports as double what the user spent.
void main() {
  late TestLedger ledger;
  final DateTime may = DateTime(2026, 5, 20, 10);
  final DateTime monthStart = DateTime(2026, 5);
  final DateTime monthEnd = DateTime(2026, 6);

  setUp(() async {
    ledger = TestLedger(now: may);
    await ledger.open();
    await ledger.repository.upsertAccount(bankAccount(may));
    await ledger.repository.upsertAccount(cardAccount(may));
  });

  group('credit card spend and its bill payment', () {
    test('produce ONE expense, not two', () async {
      // 2 May: the user swipes the HDFC card for Rs 10,290.
      await ledger.post(
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

      // 18 May: the bill for that card is paid from the HDFC savings account.
      // The message names the bank account, not the merchant - the real
      // template carries no payee at all.
      await ledger.post(
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

      final Money spend = await ledger.spendBetween(monthStart, monthEnd);
      expect(
        spend,
        const Money(1029000),
        reason: 'the card spend is counted once; paying the bill is not spending',
      );
    });

    test('the bill payment has no expense posting at all', () async {
      await ledger.post(
        makeTxn(
          id: 'card-bill',
          rupees: 12345,
          occurredAt: DateTime(2026, 5, 18, 9, 5),
          kind: CategoryKind.transfer,
          categoryPath: TransferPaths.creditCardPayment,
          channel: TxnChannel.netbanking,
          accountTail: '0601',
          cardTail: '4455',
        ),
      );

      final List<Posting> postings =
          (await ledger.repository.postingsFor('card-bill')).getOrElse(<Posting>[]);

      expect(postings, hasLength(2));
      expect(
        postings.where((Posting p) => p.accountClass == AccountClass.expense),
        isEmpty,
        reason: 'this is the structural proof - there is nothing to suppress',
      );
      // The card liability shrinks, the bank asset falls, and the two cancel.
      expect(postings.fold<int>(0, (int a, Posting p) => a + p.amountPaise), 0);
    });

    test('the card balance and the bank balance both move, net worth does not',
        () async {
      await ledger.post(
        makeTxn(
          id: 'card-spend',
          rupees: 5000,
          occurredAt: DateTime(2026, 5, 2),
          categoryPath: 'shopping/ecommerce',
          channel: TxnChannel.card,
          cardTail: '4455',
        ),
      );
      await ledger.post(
        makeTxn(
          id: 'card-bill',
          rupees: 5000,
          occurredAt: DateTime(2026, 5, 18),
          kind: CategoryKind.transfer,
          categoryPath: TransferPaths.creditCardPayment,
          channel: TxnChannel.netbanking,
          accountTail: '0601',
          cardTail: '4455',
        ),
      );

      final List<Posting> all = await ledger.allPostings();
      // The card was run up by 5,000 and paid off by 5,000.
      expect(PostingEngine.balanceOf('acc-hdfc-card', all), Money.zero);
      // The bank paid for it.
      expect(PostingEngine.balanceOf('acc-hdfc', all), const Money(-500000));
      // And exactly one expense was recorded.
      expect(PostingEngine.spendFromPostings(all), const Money(500000));
    });
  });

  test('an ATM withdrawal is not spending until the cash is spent', () async {
    await ledger.post(
      makeTxn(
        id: 'atm',
        rupees: 2000,
        occurredAt: DateTime(2026, 5, 4, 19),
        kind: CategoryKind.transfer,
        categoryPath: TransferPaths.atmWithdrawal,
        channel: TxnChannel.atm,
        accountTail: '0601',
      ),
    );

    expect(await ledger.spendBetween(monthStart, monthEnd), Money.zero);

    final List<Posting> all = await ledger.allPostings();
    expect(
      PostingEngine.balanceOf(LedgerAccounts.cash, all),
      const Money(200000),
      reason: 'the money is in the user’s pocket, not gone',
    );

    // The user then logs what the cash went on. NOW it is spending.
    await ledger.post(
      makeTxn(
        id: 'cash-spend',
        rupees: 600,
        occurredAt: DateTime(2026, 5, 5, 13),
        categoryPath: 'groceries/kirana',
        channel: TxnChannel.cash,
        accountId: LedgerAccounts.cash,
      ),
    );
    expect(await ledger.spendBetween(monthStart, monthEnd), const Money(60000));
    expect(
      PostingEngine.balanceOf(LedgerAccounts.cash, await ledger.allPostings()),
      const Money(140000),
      reason: 'Rs 1,400 of withdrawn cash is still unaccounted for',
    );
  });

  test('a self-transfer between the user’s own accounts is never spend',
      () async {
    // Two independent messages, from two senders, for one movement.
    await ledger.post(
      makeTxn(
        id: 'leg-out',
        rupees: 50000,
        occurredAt: DateTime(2026, 5, 12, 14, 41),
        kind: CategoryKind.transfer,
        categoryPath: TransferPaths.selfTransfer,
        accountTail: '0601',
        ref: 'UPI000000000001',
      ),
    );
    await ledger.post(
      makeTxn(
        id: 'leg-in',
        rupees: 50000,
        occurredAt: DateTime(2026, 5, 12, 14, 43),
        direction: TxnDirection.credit,
        kind: CategoryKind.transfer,
        categoryPath: TransferPaths.selfTransfer,
        accountTail: '1234',
        ref: 'UPI000000000001',
      ),
    );

    expect(await ledger.spendBetween(monthStart, monthEnd), Money.zero);

    final Result<Transaction?> outResult =
        await ledger.repository.transactionById('leg-out');
    final Transaction out = outResult.getOrElse(null)!;
    expect(
      out.transferGroupId,
      isNotNull,
      reason: 'the same reference on both messages is conclusive',
    );

    // In-transit nets to zero once both legs are in, which is the app proving
    // to itself that it saw the whole movement.
    final List<Posting> all = await ledger.allPostings();
    expect(PostingEngine.balanceOf(LedgerAccounts.inTransit, all), Money.zero);
    expect(
      TransferMatcher.unpairedLegs(all, now: DateTime(2026, 5, 20)),
      isEmpty,
    );
  });

  test('a one-sided transfer is surfaced instead of being counted', () async {
    await ledger.post(
      makeTxn(
        id: 'leg-out-only',
        rupees: 5000,
        occurredAt: DateTime(2026, 5, 12, 14, 41),
        kind: CategoryKind.transfer,
        categoryPath: TransferPaths.selfTransfer,
        accountTail: '0601',
      ),
    );

    expect(await ledger.spendBetween(monthStart, monthEnd), Money.zero);
    final List<Posting> unpaired = TransferMatcher.unpairedLegs(
      await ledger.allPostings(),
      now: DateTime(2026, 5, 20),
    );
    expect(unpaired, hasLength(1));
    expect(unpaired.single.amountPaise, 500000);
  });

  test('a SIP is an investment, not an expense', () async {
    await ledger.post(
      makeTxn(
        id: 'sip',
        rupees: 25000,
        occurredAt: DateTime(2026, 5, 5),
        kind: CategoryKind.investment,
        categoryPath: 'investments/mutual_fund_sip',
        channel: TxnChannel.nach,
        merchantName: 'Groww',
        accountTail: '0601',
      ),
    );
    expect(await ledger.spendBetween(monthStart, monthEnd), Money.zero);

    final List<Posting> postings =
        (await ledger.repository.postingsFor('sip')).getOrElse(<Posting>[]);
    expect(
      postings.where((Posting p) => p.accountClass == AccountClass.expense),
      isEmpty,
    );
    expect(
      postings.where((Posting p) => p.amountPaise > 0).single.accountId,
      LedgerAccounts.forInvestment('investments/mutual_fund_sip'),
    );
  });

  test('a wallet top-up moves money, it does not spend it', () async {
    await ledger.post(
      makeTxn(
        id: 'topup',
        rupees: 1000,
        occurredAt: DateTime(2026, 5, 6),
        kind: CategoryKind.transfer,
        categoryPath: TransferPaths.walletTopup,
        merchantName: 'Paytm',
        accountTail: '0601',
      ),
    );
    expect(await ledger.spendBetween(monthStart, monthEnd), Money.zero);
  });

  test('a refund reduces the category it came from, it is not income',
      () async {
    await ledger.post(
      makeTxn(
        id: 'buy',
        rupees: 1000,
        occurredAt: DateTime(2026, 5, 3),
        categoryPath: 'shopping/ecommerce',
        cardTail: '4455',
      ),
    );
    await ledger.post(
      makeTxn(
        id: 'refund',
        rupees: 250,
        occurredAt: DateTime(2026, 5, 9),
        direction: TxnDirection.credit,
        categoryPath: 'shopping/ecommerce',
        cardTail: '4455',
      ),
    );

    final List<Posting> all = await ledger.allPostings();
    expect(
      PostingEngine.spendFromPostings(all),
      const Money(75000),
      reason: 'a partial refund reduces Shopping rather than creating income',
    );
    // The transaction-level spend total agrees: the refund is a credit, so it
    // is not counted as spend, and the original stands at its full amount.
    expect(await ledger.spendBetween(monthStart, monthEnd), const Money(100000));
  });

  test('every transaction posts a balanced set of legs', () async {
    await ledger.post(
      makeTxn(
        id: 'a',
        rupees: 150,
        occurredAt: DateTime(2026, 5, 5),
        merchantName: 'Swiggy',
        accountTail: '0601',
      ),
    );
    await ledger.post(
      makeTxn(
        id: 'b',
        rupees: 4200,
        occurredAt: DateTime(2026, 5, 6),
        direction: TxnDirection.credit,
        kind: CategoryKind.income,
        categoryPath: 'income/salary',
        accountTail: '0601',
      ),
    );

    final Map<String, int> byTxn = <String, int>{};
    for (final Posting p in await ledger.allPostings()) {
      byTxn[p.txnId] = (byTxn[p.txnId] ?? 0) + p.amountPaise;
    }
    expect(byTxn.values.every((int sum) => sum == 0), isTrue);
    expect(byTxn.keys, containsAll(<String>['a', 'b']));
  });

  test('a voided transaction leaves both the totals and the postings',
      () async {
    await ledger.post(
      makeTxn(
        id: 'oops',
        rupees: 999,
        occurredAt: DateTime(2026, 5, 7),
        accountTail: '0601',
      ),
    );
    expect(await ledger.spendBetween(monthStart, monthEnd), const Money(99900));

    await ledger.repository.deleteTransaction('oops');
    expect(await ledger.spendBetween(monthStart, monthEnd), Money.zero);
    expect(await ledger.allPostings(), isEmpty);

    // ...but the row itself survives, so the audit trail does too.
    final Transaction? stored =
        (await ledger.repository.transactionById('oops')).getOrElse(null);
    expect(stored?.status, TxnStatus.voided);
  });
}
