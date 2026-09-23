import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/data/data.dart';
import 'package:ledger/models/models.dart';

import 'ledger_test_support.dart';

/// "Avl Bal Rs X" is the only independent check on the parser that exists.
///
/// These tests are what make the claim "we will tell you when we missed
/// something" true rather than aspirational.
void main() {
  late TestLedger ledger;
  final DateTime may = DateTime(2026, 5, 20, 10);

  setUp(() async {
    ledger = TestLedger(now: may);
    await ledger.open();
    await ledger.repository.upsertAccount(bankAccount(may));
  });

  Future<void> statedBalance(int rupees, DateTime at, {int precedence = 1}) async {
    final Result<BalanceAssertion> result =
        await ledger.repository.recordBalanceAssertion(
      accountId: 'acc-hdfc',
      kind: AssertionKind.availableBalance,
      stated: Money(rupees * 100),
      asOf: at,
      precedence: precedence,
    );
    expect(result.isOk, isTrue, reason: result.errorOrNull?.message);
  }

  test('a window whose postings explain the balance change is clean', () async {
    await statedBalance(50000, DateTime(2026, 5, 10, 9), precedence: 0);
    await ledger.post(
      makeTxn(
        id: 'lunch',
        rupees: 450,
        occurredAt: DateTime(2026, 5, 10, 13),
        merchantName: 'Swiggy',
        accountTail: '0601',
      ),
    );
    await statedBalance(49550, DateTime(2026, 5, 10, 18), precedence: 0);

    final List<ReconWindow> windows =
        (await ledger.repository.reconcileAccount('acc-hdfc'))
            .getOrElse(<ReconWindow>[]);

    expect(windows, hasLength(1));
    expect(windows.single.verdict, ReconVerdict.clean);
    expect(windows.single.driftPaise, 0);
    expect(
      (await ledger.repository.driftEvents()).getOrElse(<DriftEvent>[]),
      isEmpty,
    );
  });

  test('a transaction we never saw shows up as a gap, with its direction',
      () async {
    await statedBalance(50000, DateTime(2026, 5, 10, 9), precedence: 0);
    await ledger.post(
      makeTxn(
        id: 'lunch',
        rupees: 450,
        occurredAt: DateTime(2026, 5, 10, 13),
        merchantName: 'Swiggy',
        accountTail: '0601',
      ),
    );
    // The bank says the balance fell by 1,690 - we can only account for 450.
    await statedBalance(48310, DateTime(2026, 5, 10, 18), precedence: 0);

    final List<ReconWindow> windows =
        (await ledger.repository.reconcileAccount('acc-hdfc'))
            .getOrElse(<ReconWindow>[]);

    expect(windows.single.verdict, ReconVerdict.drift);
    expect(windows.single.drift, const Money(124000));
    expect(windows.single.direction, DriftDirection.missingDebit);

    final List<DriftEvent> events =
        (await ledger.repository.driftEvents()).getOrElse(<DriftEvent>[]);
    expect(events, hasLength(1));
    expect(events.single.amount, const Money(124000));
    expect(events.single.isOpen, isTrue);
  });

  test('a two-and-a-half rupee difference is a gap, not noise', () async {
    // The tolerance is one rupee, and it is there for rounding in the app's
    // own percentage splits - not to paper over small missing charges.
    await statedBalance(50000, DateTime(2026, 5, 10, 9), precedence: 0);
    await ledger.repository.recordBalanceAssertion(
      accountId: 'acc-hdfc',
      kind: AssertionKind.availableBalance,
      stated: const Money(4999750),
      asOf: DateTime(2026, 5, 10, 18),
      precedence: 0,
    );

    final List<ReconWindow> windows =
        (await ledger.repository.reconcileAccount('acc-hdfc'))
            .getOrElse(<ReconWindow>[]);
    expect(windows.single.verdict, ReconVerdict.drift);
    expect(windows.single.drift, const Money(250));
  });

  test('an account whose bank never states a balance is left alone', () async {
    await ledger.repository.upsertAccount(
      Account(
        id: 'acc-axis',
        type: AccountType.savings,
        displayName: 'Axis 7788',
        createdAt: may,
        updatedAt: may,
        tail: '7788',
      ),
    );
    final List<ReconWindow> windows =
        (await ledger.repository.reconcileAccount('acc-axis'))
            .getOrElse(<ReconWindow>[]);

    expect(windows.single.verdict, ReconVerdict.unverifiable);
    expect(windows.single.unverifiableReason, isNotNull);
    expect(
      (await ledger.repository.driftEvents()).getOrElse(<DriftEvent>[]),
      isEmpty,
      reason: 'zero false alarms beats coverage here',
    );
  });

  test('a message we could not read is offered as the explanation', () async {
    await statedBalance(50000, DateTime(2026, 5, 10, 9), precedence: 0);
    await ledger.repository.quarantineMessage(
      rawMessageId: 'raw-unreadable',
      reason: 'no rule matched',
      amount: const Money(124000),
      receivedAt: DateTime(2026, 5, 10, 14, 30),
    );
    await statedBalance(48760, DateTime(2026, 5, 10, 18), precedence: 0);

    await ledger.repository.reconcileAccount('acc-hdfc');
    final List<DriftEvent> events =
        (await ledger.repository.driftEvents()).getOrElse(<DriftEvent>[]);

    expect(events.single.hypotheses, isNotEmpty);
    final DriftHypothesis top = events.single.hypotheses.first;
    expect(top.kind, 'quarantine_hit');
    expect(top.referenceId, 'raw-unreadable');
    expect(top.confidence, greaterThan(0.9));
  });

  test('a bank charge with GST on it is recognised by its size', () {
    const ReconWindow window = ReconWindow(
      accountId: 'acc-hdfc',
      verdict: ReconVerdict.drift,
      driftPaise: -2360,
      expectedDeltaPaise: -2360,
    );
    final List<DriftHypothesis> guesses =
        ReconciliationEngine.hypotheses(window);
    expect(
      guesses.any((DriftHypothesis h) =>
          h.suggestedCategoryPath == 'fees_charges/bank_charges'),
      isTrue,
    );
  });

  test('a card reconciles on deltas even with no known credit limit', () {
    // Avl Lmt is limit - outstanding. The limit is a constant, so it cancels.
    final DateTime t0 = DateTime(2026, 5, 1, 9);
    final DateTime t1 = DateTime(2026, 5, 3, 9);
    final BalanceAssertion head = ReconciliationEngine.normalize(
      id: 'a0',
      accountId: 'card',
      kind: AssertionKind.availableLimit,
      statedPaise: 15000000,
      asOf: t0,
      now: t0,
      precedence: 0,
    )!;
    final BalanceAssertion tail = ReconciliationEngine.normalize(
      id: 'a1',
      accountId: 'card',
      kind: AssertionKind.availableLimit,
      statedPaise: 13971000,
      asOf: t1,
      now: t1,
      precedence: 0,
    )!;
    expect(head.basisUnknown, isTrue, reason: 'the absolute value is unusable');

    final List<ReconWindow> windows = ReconciliationEngine.reconcile(
      accountId: 'card',
      assertions: <BalanceAssertion>[head, tail],
      postings: <Posting>[
        Posting(
          id: 'p1',
          txnId: 't1',
          accountId: 'card',
          accountClass: AccountClass.liability,
          amountPaise: -1029000,
          occurredAt: DateTime(2026, 5, 2, 22),
          bookingDate: '2026-05-02',
        ),
      ],
    );
    expect(windows.single.verdict, ReconVerdict.clean);
  });

  test('available balance and ledger balance are never compared', () {
    final DateTime t0 = DateTime(2026, 5, 1, 9);
    final List<BalanceAssertion> mixed = <BalanceAssertion>[
      ReconciliationEngine.normalize(
        id: 'a0',
        accountId: 'acc',
        kind: AssertionKind.availableBalance,
        statedPaise: 5000000,
        asOf: t0,
        now: t0,
      )!,
      ReconciliationEngine.normalize(
        id: 'a1',
        accountId: 'acc',
        kind: AssertionKind.ledgerBalance,
        // A hold of Rs 2,000 makes this legitimately different.
        statedPaise: 5200000,
        asOf: t0.add(const Duration(hours: 2)),
        now: t0,
      )!,
    ];
    final List<ReconWindow> windows = ReconciliationEngine.reconcile(
      accountId: 'acc',
      assertions: mixed,
      postings: const <Posting>[],
    );
    expect(
      windows.single.verdict,
      ReconVerdict.unverifiable,
      reason: 'mixing bases would manufacture a drift the size of the holds',
    );
  });

  test('the plug goes to equity and can never reach a category', () async {
    await statedBalance(50000, DateTime(2026, 5, 10, 9), precedence: 0);
    await statedBalance(48760, DateTime(2026, 5, 10, 18), precedence: 0);
    await ledger.repository.reconcileAccount('acc-hdfc');

    final DriftEvent event =
        (await ledger.repository.driftEvents()).getOrElse(<DriftEvent>[]).single;
    final Result<Transaction> plugged =
        await ledger.repository.plugDriftEvent(event.id);
    expect(plugged.isOk, isTrue);

    // The gap is visible in equity...
    final List<Posting> all = await ledger.allPostings();
    expect(
      PostingEngine.balanceOf(LedgerAccounts.unreconciled, all),
      const Money(124000),
    );
    // ...and nowhere near a spend total.
    expect(PostingEngine.spendFromPostings(all), Money.zero);
    expect(
      await ledger.spendBetween(DateTime(2026, 5), DateTime(2026, 6)),
      Money.zero,
    );

    final List<DriftEvent> stillOpen =
        (await ledger.repository.driftEvents()).getOrElse(<DriftEvent>[]);
    expect(stillOpen, isEmpty);
  });

  test('reconciling twice does not create a second card for one gap',
      () async {
    await statedBalance(50000, DateTime(2026, 5, 10, 9), precedence: 0);
    await statedBalance(48760, DateTime(2026, 5, 10, 18), precedence: 0);

    await ledger.repository.reconcileAccount('acc-hdfc');
    await ledger.repository.reconcileAccount('acc-hdfc');

    expect(
      (await ledger.repository.driftEvents()).getOrElse(<DriftEvent>[]),
      hasLength(1),
    );
  });

  test('the computed balance is what gets compared against the bank',
      () async {
    await ledger.post(
      makeTxn(
        id: 'a',
        rupees: 450,
        occurredAt: DateTime(2026, 5, 10, 13),
        accountTail: '0601',
      ),
    );
    await ledger.post(
      makeTxn(
        id: 'b',
        rupees: 1200,
        occurredAt: DateTime(2026, 5, 11, 13),
        direction: TxnDirection.credit,
        kind: CategoryKind.income,
        categoryPath: 'income/salary',
        accountTail: '0601',
      ),
    );
    final Money balance =
        (await ledger.repository.computedBalance('acc-hdfc')).getOrElse(Money.zero);
    expect(balance, const Money(75000));
  });
}
