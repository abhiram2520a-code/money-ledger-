import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/data/data.dart';
import 'package:ledger/models/models.dart';

import 'ledger_test_support.dart';

/// A bill is a promise about the future; only the payment is money moving.
///
/// Booking the bill AND the payment is how EMIs and card statements get
/// counted twice, so a bill creates no postings at all - these tests hold that
/// line while still matching payments to the bills they settled.
void main() {
  late TestLedger ledger;
  final DateTime may = DateTime(2026, 5, 20, 10);

  Bill cardStatement({
    String name = 'HDFC Card 4455',
    String cardTail = '4455',
    int dueRupees = 24530,
    int? minimumRupees = 1230,
  }) =>
      Bill(
        id: '',
        name: name,
        dueDate: DateTime(2026, 5, 18),
        createdAt: DateTime(2026, 5, 2),
        updatedAt: DateTime(2026, 5, 2),
        amountDue: Money(dueRupees * 100),
        minimumDue: minimumRupees == null ? null : Money(minimumRupees * 100),
        cardTail: cardTail,
        merchantName: name,
        issuer: 'HDFC',
        kind: CategoryKind.transfer,
        categoryPath: TransferPaths.creditCardPayment,
        isRecurring: true,
      );

  Transaction payment({
    required String id,
    required int rupees,
    String cardTail = '4455',
    DateTime? when,
  }) =>
      makeTxn(
        id: id,
        rupees: rupees,
        occurredAt: when ?? DateTime(2026, 5, 15, 11),
        kind: CategoryKind.transfer,
        categoryPath: TransferPaths.creditCardPayment,
        channel: TxnChannel.netbanking,
        accountTail: '0601',
        cardTail: cardTail,
      );

  setUp(() async {
    ledger = TestLedger(now: may);
    await ledger.open();
    await ledger.repository.upsertAccount(bankAccount(may));
    await ledger.repository.upsertAccount(cardAccount(may));
  });

  test('a full payment links itself and settles the bill', () async {
    final Bill bill =
        (await ledger.repository.upsertBill(cardStatement())).getOrElse(
      cardStatement(),
    );
    expect(bill.id, isNotEmpty);

    await ledger.post(payment(id: 'pay', rupees: 24530));

    final List<Bill> bills = (await ledger.repository.bills()).getOrElse(<Bill>[]);
    expect(bills.single.status, BillStatus.paid);
    expect(bills.single.paidTxnId, 'pay');

    final Transaction? txn =
        (await ledger.repository.transactionById('pay')).getOrElse(null);
    expect(txn?.billId, bill.id);

    // And it is still not spending.
    expect(
      await ledger.spendBetween(DateTime(2026, 5), DateTime(2026, 6)),
      Money.zero,
    );
  });

  test('the same reminder arriving five times is still one bill', () async {
    for (int i = 0; i < 5; i++) {
      await ledger.repository.upsertBill(cardStatement());
    }
    expect(await ledger.store.count(LedgerCollections.bills), 1);
  });

  test('a restated amount updates the bill instead of adding one', () async {
    await ledger.repository.upsertBill(cardStatement());
    await ledger.repository.upsertBill(cardStatement(dueRupees: 12185));

    final List<Bill> bills = (await ledger.repository.bills()).getOrElse(<Bill>[]);
    expect(bills, hasLength(1));
    expect(bills.single.amountDue, const Money(1218500));
  });

  test('a partial payment leaves the bill owing the rest', () async {
    final Bill bill =
        (await ledger.repository.upsertBill(cardStatement())).getOrElse(
      cardStatement(),
    );
    final Transaction paid = await ledger.post(payment(id: 'part', rupees: 12000));

    // A part payment is never linked silently - it is offered.
    expect(paid.billId, isNull);
    final BillMatch? match = BillMatcher.score(bill, paid);
    expect(match, isNotNull);
    expect(match!.tag, BillMatchTag.partial);
    expect(match.canAutoLink, isFalse);
    expect(match.worthAsking, isTrue);

    // The user confirms it.
    final Result<void> linked = await ledger.repository.markBillPaid(
      billId: bill.id,
      txnId: 'part',
    );
    expect(linked.isOk, isTrue);

    final List<Bill> bills = (await ledger.repository.bills()).getOrElse(<Bill>[]);
    expect(bills.single.status, isNot(BillStatus.paid));
    expect(
      (await ledger.repository.billRemaining(bill.id)).getOrElse(Money.zero),
      const Money(1253000),
    );

    // The remainder arrives later and finishes the job.
    await ledger.post(payment(id: 'rest', rupees: 12530, when: DateTime(2026, 5, 17)));
    await ledger.repository.markBillPaid(billId: bill.id, txnId: 'rest');
    final List<Bill> settled =
        (await ledger.repository.bills()).getOrElse(<Bill>[]);
    expect(settled.single.status, BillStatus.paid);
    expect(
      (await ledger.repository.billRemaining(bill.id)).getOrElse(Money.zero),
      Money.zero,
    );
  });

  test('paying only the minimum is recognised as exactly that', () async {
    final Bill bill =
        (await ledger.repository.upsertBill(cardStatement())).getOrElse(
      cardStatement(),
    );
    await ledger.post(payment(id: 'min', rupees: 1230));

    final List<Bill> bills = (await ledger.repository.bills()).getOrElse(<Bill>[]);
    expect(
      bills.single.status,
      isNot(BillStatus.paid),
      reason: 'the minimum is not the bill',
    );
    expect(
      BillLifecycle.isMinimumOnly(bill, paidPaise: 123000),
      isTrue,
      reason: 'this is where the app can save the user real interest',
    );
  });

  test('an ATM withdrawal of the exact amount is never a bill payment',
      () async {
    await ledger.repository.upsertBill(cardStatement());
    await ledger.post(
      makeTxn(
        id: 'atm',
        rupees: 24530,
        occurredAt: DateTime(2026, 5, 15, 11),
        kind: CategoryKind.transfer,
        categoryPath: TransferPaths.atmWithdrawal,
        channel: TxnChannel.atm,
        accountTail: '0601',
      ),
    );
    final List<Bill> bills = (await ledger.repository.bills()).getOrElse(<Bill>[]);
    expect(bills.single.status, isNot(BillStatus.paid));
  });

  test('two cards with the same amount due are asked about, not guessed',
      () async {
    await ledger.repository.upsertAccount(
      Account(
        id: 'acc-hdfc-card-2',
        type: AccountType.creditCard,
        displayName: 'HDFC Card 9900',
        createdAt: may,
        updatedAt: may,
        tail: '9900',
      ),
    );
    await ledger.repository.upsertBill(cardStatement());
    await ledger.repository
        .upsertBill(cardStatement(name: 'HDFC Card 9900', cardTail: '9900'));

    // A payment that names no card at all - the real "no payee" template.
    await ledger.post(
      makeTxn(
        id: 'pay',
        rupees: 24530,
        occurredAt: DateTime(2026, 5, 15, 11),
        kind: CategoryKind.transfer,
        categoryPath: TransferPaths.creditCardPayment,
        channel: TxnChannel.netbanking,
        accountTail: '0601',
      ),
    );

    final List<Bill> bills = (await ledger.repository.bills()).getOrElse(<Bill>[]);
    expect(
      bills.where((Bill b) => b.status == BillStatus.paid),
      isEmpty,
      reason: 'putting it on the wrong statement is worse than asking',
    );
  });

  test('two equally good payments for one bill are not auto-linked', () {
    final Bill bill = cardStatement();
    final BillMatch? best = BillMatcher.best(
      bill,
      <Transaction>[
        payment(id: 'a', rupees: 24530),
        payment(id: 'b', rupees: 24530, when: DateTime(2026, 5, 15, 12)),
      ],
    );
    expect(best, isNotNull);
    expect(
      best!.canAutoLink,
      isFalse,
      reason: 'when two candidates fit equally well, ask',
    );
    expect(best.reason, contains('another payment fits just as well'));
  });

  test('a bill creates no postings; only its payment does', () async {
    await ledger.repository.upsertBill(cardStatement());
    expect(await ledger.allPostings(), isEmpty);

    await ledger.post(payment(id: 'pay', rupees: 24530));
    final List<Posting> postings = await ledger.allPostings();
    expect(postings, hasLength(2));
    expect(
      postings.where((Posting p) => p.accountClass == AccountClass.expense),
      isEmpty,
    );
  });

  group('lifecycle', () {
    test('an unpaid bill moves upcoming to due to overdue', () {
      final Bill bill = cardStatement();
      expect(
        BillLifecycle.statusFor(bill, paidPaise: 0, now: DateTime(2026, 5, 2)),
        BillStatus.upcoming,
      );
      expect(
        BillLifecycle.statusFor(bill, paidPaise: 0, now: DateTime(2026, 5, 17)),
        BillStatus.due,
      );
      expect(
        BillLifecycle.statusFor(bill, paidPaise: 0, now: DateTime(2026, 5, 19)),
        BillStatus.overdue,
      );
    });

    test('a bill the user dismissed stays dismissed', () {
      final Bill skipped = cardStatement().copyWith(status: BillStatus.skipped);
      expect(
        BillLifecycle.statusFor(skipped, paidPaise: 0, now: DateTime(2026, 5, 25)),
        BillStatus.skipped,
      );
    });

    test('an autopay that never fired is spotted the day after it was due',
        () {
      final Bill bill = cardStatement();
      expect(
        BillLifecycle.looksLikeFailedAutopay(
          bill,
          paidPaise: 0,
          now: DateTime(2026, 5, 20),
          autopay: true,
        ),
        isTrue,
      );
      expect(
        BillLifecycle.looksLikeFailedAutopay(
          bill,
          paidPaise: 2453000,
          now: DateTime(2026, 5, 20),
          autopay: true,
        ),
        isFalse,
      );
    });
  });
}
