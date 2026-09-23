/// One payment, many messages - and two payments that look like one.
///
/// The asymmetry here is different from the trust gate's. Over-collapsing
/// UNDER-counts silently: two genuine Rs 1,200 Swiggy payments four minutes
/// apart become one and nothing says so. Under-collapsing OVER-counts, which
/// is at least visible as a duplicate row the user can delete. The reference
/// number is what makes the choice deterministic instead of a time-window
/// guess, so most of these tests are about what happens when it is present,
/// absent, or present and DIFFERENT.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/parser/parsing.dart';

import 'fixtures/rule_fixtures.dart';

final DateTime t0 = DateTime(2026, 9, 12, 13, 30);

DedupCandidate event(
  String id, {
  required int paise,
  required TxnDirection direction,
  DateTime? at,
  String? ref,
  String? accountTail,
  String? cardTail,
  String? merchant,
  String issuer = 'HDFCBK',
  bool isPsp = false,
  bool isCard = false,
  String? bodyKey,
  DatePrecision precision = DatePrecision.dateTime,
}) {
  final when = at ?? t0;
  return DedupCandidate(
    id: id,
    amount: Money(paise),
    direction: direction,
    occurredAt: when,
    receivedAt: when,
    bodyKey: bodyKey ?? 'body-$id',
    ref: ref,
    accountTail: accountTail,
    cardTail: cardTail,
    merchantKey: DedupCandidate.merchantKeyOf(merchant),
    issuer: issuer,
    isPsp: isPsp,
    isCardInstrument: isCard || cardTail != null,
    datePrecision: precision,
  );
}

void main() {
  late DedupIndex index;

  setUp(() => index = DedupIndex());

  group('layer 0 - the same body twice', () {
    test('a dual-SIM duplicate collapses even though the prefixes differ', () {
      // The telco prefix differs (VM- vs AD-) but the principal entity and the
      // body are identical, which is exactly what dual delivery looks like.
      const body = 'Sent Rs.100.00 From HDFC Bank A/C *0000 To CUSTOMER NAME '
          'On 17/05/26 Ref 000000000000';
      final first = event('sim1',
          paise: 10000,
          direction: TxnDirection.debit,
          ref: '000000000000',
          accountTail: '0000',
          bodyKey: dedupBodyKey(body));
      final second = event('sim2',
          paise: 10000,
          direction: TxnDirection.debit,
          ref: '000000000000',
          accountTail: '0000',
          at: t0.add(const Duration(seconds: 3)),
          bodyKey: dedupBodyKey('$body\n'));

      expect(index.add(first).relation, DedupRelation.unique);
      final result = index.add(second);
      expect(result.relation, DedupRelation.duplicateDelivery);
      expect(result.matchId, 'sim1');
      expect(result.collapses, isTrue);
    });

    test('the same body from a different entity is a different event', () {
      const body = 'Rs.100.00 debited';
      index.add(event('bank',
          paise: 10000,
          direction: TxnDirection.debit,
          issuer: 'HDFCBK',
          bodyKey: dedupBodyKey(body)));
      final other = index.add(event('psp',
          paise: 10000,
          direction: TxnDirection.debit,
          issuer: 'PHONPE',
          at: t0.add(const Duration(hours: 5)),
          bodyKey: dedupBodyKey(body)));
      expect(other.relation, isNot(DedupRelation.duplicateDelivery));
    });

    test('a re-delivery a week later is not a re-delivery', () {
      const body = 'Rs.100.00 debited from a/c XX1234';
      index.add(event('a',
          paise: 10000,
          direction: TxnDirection.debit,
          accountTail: '1234',
          bodyKey: dedupBodyKey(body)));
      final later = index.add(event('b',
          paise: 10000,
          direction: TxnDirection.debit,
          accountTail: '1234',
          at: t0.add(const Duration(days: 7)),
          bodyKey: dedupBodyKey(body)));
      expect(later.relation, isNot(DedupRelation.duplicateDelivery));
    });
  });

  group('layer 1 - the reference number', () {
    test('the bank and the UPI app reporting one payment collapse', () {
      index.add(event('bank',
          paise: 120000,
          direction: TxnDirection.debit,
          ref: '431234567890',
          accountTail: '1234',
          merchant: 'SWIGGY'));
      final psp = index.add(event('psp',
          paise: 120000,
          direction: TxnDirection.debit,
          ref: '431234567890',
          merchant: 'Swiggy Limited',
          issuer: 'PHONPE',
          isPsp: true,
          at: t0.add(const Duration(seconds: 40))));

      expect(psp.relation, DedupRelation.sameEvent);
      expect(psp.matchId, 'bank');
      expect(psp.reason, 'l1:ref');
    });

    test('a settlement confirmation hours later still collapses - the UTR '
        'match is not time-bounded', () {
      index.add(event('neft.debit',
          paise: 250000,
          direction: TxnDirection.debit,
          ref: 'HDFCH00000000000000',
          accountTail: '1234'));
      final confirmation = index.add(event('neft.confirm',
          paise: 250000,
          direction: TxnDirection.credit,
          ref: 'HDFCH00000000000000',
          at: t0.add(const Duration(hours: 9))));

      expect(confirmation.relation, DedupRelation.followUp);
      expect(confirmation.collapses, isTrue);
    });

    test('one reference on two of the user OWN accounts is a transfer, not a '
        'duplicate - collapsing it deletes a leg', () {
      index.add(event('leg.debit',
          paise: 500000,
          direction: TxnDirection.debit,
          ref: '431234567890',
          accountTail: '1234'));
      final credit = index.add(event('leg.credit',
          paise: 500000,
          direction: TxnDirection.credit,
          ref: '431234567890',
          accountTail: '5678',
          at: t0.add(const Duration(seconds: 2))));

      expect(credit.relation, DedupRelation.transferLeg);
      expect(credit.collapses, isFalse);
      expect(credit.links, isTrue);
    });
  });

  group('two payments that look like one', () {
    test('failed-then-retried UPI: different references means two events', () {
      // The failed attempt never reaches dedup - the trust gate rejects it.
      // What arrives is two genuine debits four minutes apart.
      index.add(event('try1',
          paise: 120000,
          direction: TxnDirection.debit,
          ref: '431234567890',
          accountTail: '1234',
          merchant: 'SWIGGY'));
      final retry = index.add(event('try2',
          paise: 120000,
          direction: TxnDirection.debit,
          ref: '431299999999',
          accountTail: '1234',
          merchant: 'SWIGGY',
          at: t0.add(const Duration(minutes: 4))));

      expect(retry.relation, DedupRelation.unique,
          reason: 'two references that disagree are two events, full stop');
    });

    test('two identical small payments minutes apart stay two', () {
      index.add(event('tea1',
          paise: 5000,
          direction: TxnDirection.debit,
          ref: '431200000001',
          accountTail: '1234',
          merchant: 'CHAI POINT'));
      final second = index.add(event('tea2',
          paise: 5000,
          direction: TxnDirection.debit,
          ref: '431200000002',
          accountTail: '1234',
          merchant: 'CHAI POINT',
          at: t0.add(const Duration(minutes: 2))));
      expect(second.relation, DedupRelation.unique);
    });

    test('with NO reference on either side they are indistinguishable, and '
        'the index says so by collapsing', () {
      // Documented cost of a template that ships no reference (SBI Card,
      // OneCard, HDFC "Amt Deducted!"). The alternative - booking both - is
      // the more common real-world error, so the index collapses and the
      // reason names the layer that decided.
      index.add(event('noref1',
          paise: 5000,
          direction: TxnDirection.debit,
          accountTail: '1234',
          merchant: 'CHAI POINT'));
      final second = index.add(event('noref2',
          paise: 5000,
          direction: TxnDirection.debit,
          accountTail: '1234',
          merchant: 'CHAI POINT',
          at: t0.add(const Duration(seconds: 30))));
      expect(second.relation, DedupRelation.sameEvent);
      expect(second.reason, 'l2:amount_tail_time');
    });

    test('different instruments never collapse on amount alone', () {
      index.add(event('cardA',
          paise: 5000, direction: TxnDirection.debit, cardTail: '1111'));
      final other = index.add(event('cardB',
          paise: 5000,
          direction: TxnDirection.debit,
          cardTail: '2222',
          at: t0.add(const Duration(seconds: 10))));
      expect(other.relation, DedupRelation.unique);
    });

    test('outside the window they stay separate', () {
      index.add(event('early',
          paise: 5000, direction: TxnDirection.debit, accountTail: '1234'));
      final late = index.add(event('late',
          paise: 5000,
          direction: TxnDirection.debit,
          accountTail: '1234',
          at: t0.add(const Duration(minutes: 30))));
      expect(late.relation, DedupRelation.unique);
    });

    test('the window widens when one side has no in-body timestamp', () {
      final tight = DedupIndex(
        fuzzyWindow: const Duration(seconds: 10),
        approximateFuzzyWindow: const Duration(minutes: 15),
      );
      tight.add(event('bank',
          paise: 830100,
          direction: TxnDirection.debit,
          accountTail: '0601',
          precision: DatePrecision.receivedFallback));
      final psp = tight.add(event('psp',
          paise: 830100,
          direction: TxnDirection.debit,
          accountTail: '0601',
          issuer: 'PHONPE',
          isPsp: true,
          at: t0.add(const Duration(minutes: 6)),
          precision: DatePrecision.dateTime));
      expect(psp.relation, DedupRelation.sameEvent);
    });
  });

  group('refunds and reversals', () {
    test('a refund links back to the spend on the same card', () {
      index.add(event('spend',
          paise: 24900,
          direction: TxnDirection.debit,
          cardTail: '4455',
          merchant: 'SWIGGY'));
      final refund = index.add(event('refund',
          paise: 24900,
          direction: TxnDirection.credit,
          cardTail: '4455',
          merchant: 'SWIGGY',
          at: t0.add(const Duration(days: 5))));

      expect(refund.relation, DedupRelation.reversalOf);
      expect(refund.matchId, 'spend');
      expect(refund.links, isTrue,
          reason: 'a refund is a real entry that corrects another, not income');
    });

    test('an authorisation reversal the same minute is still a reversal', () {
      index.add(event('auth',
          paise: 200, direction: TxnDirection.debit, cardTail: '0000'));
      final reversal = index.add(event('reversal',
          paise: 200,
          direction: TxnDirection.credit,
          cardTail: '0000',
          at: t0.add(const Duration(seconds: 45))));
      expect(reversal.relation, DedupRelation.reversalOf);
    });

    test('a credit that predates the spend is not its reversal', () {
      index.add(event('spend',
          paise: 24900,
          direction: TxnDirection.debit,
          cardTail: '4455',
          at: t0.add(const Duration(days: 2))));
      final earlier = index.add(event('salary',
          paise: 24900, direction: TxnDirection.credit, cardTail: '4455'));
      expect(earlier.relation, isNot(DedupRelation.reversalOf));
    });

    test('a refund beyond the window is not linked', () {
      final short = DedupIndex(reversalWindow: const Duration(days: 3));
      short.add(event('spend',
          paise: 24900, direction: TxnDirection.debit, cardTail: '4455'));
      final refund = short.add(event('refund',
          paise: 24900,
          direction: TxnDirection.credit,
          cardTail: '4455',
          at: t0.add(const Duration(days: 10))));
      expect(refund.relation, DedupRelation.unique);
    });
  });

  group('the user own money moving', () {
    test('a credit-card bill payment is two legs, counted as neither spend '
        'nor income', () {
      // The bank debit carries an account mask; the card issuer's "payment
      // received" carries no mask at all, which is why the pairing cannot
      // rely on tails alone.
      index.add(event('bank.debit',
          paise: 1843200,
          direction: TxnDirection.debit,
          accountTail: '1234',
          merchant: 'HDFC CARD'));
      final cardSide = index.add(event('card.credit',
          paise: 1843200,
          direction: TxnDirection.credit,
          isCard: true,
          issuer: 'SBICRD',
          at: t0.add(const Duration(hours: 3))));

      expect(cardSide.relation, DedupRelation.transferLeg);
      expect(cardSide.reason, 'transfer:card_bill');
      expect(cardSide.collapses, isFalse);
    });

    test('a self-transfer between two of the user accounts pairs up', () {
      index.add(event('out',
          paise: 5000000, direction: TxnDirection.debit, accountTail: '0002'));
      final inbound = index.add(event('in',
          paise: 5000000,
          direction: TxnDirection.credit,
          accountTail: '0001',
          at: t0.add(const Duration(seconds: 1))));

      expect(inbound.relation, DedupRelation.transferLeg);
      expect(inbound.reason, 'transfer:own_accounts');
    });

    test('an unrelated equal-amount credit with a named counterparty is NOT a '
        'transfer leg', () {
      index.add(event('rent',
          paise: 5000000,
          direction: TxnDirection.debit,
          accountTail: '0002',
          merchant: 'LANDLORD'));
      final salary = index.add(event('salary',
          paise: 5000000,
          direction: TxnDirection.credit,
          accountTail: '0002',
          merchant: 'ACME PAYROLL',
          at: t0.add(const Duration(hours: 20))));
      expect(salary.relation, DedupRelation.unique);
    });
  });

  group('housekeeping', () {
    test('records outside the retention window are pruned', () {
      final short = DedupIndex(retention: const Duration(days: 2));
      short.add(event('old',
          paise: 1000, direction: TxnDirection.debit, accountTail: '1234'));
      short.add(event('new',
          paise: 2000,
          direction: TxnDirection.debit,
          accountTail: '1234',
          at: t0.add(const Duration(days: 10))));
      expect(short.entries.map((e) => e.id), <String>['new']);
    });

    test('a collapsed duplicate is still remembered, so a third delivery is '
        'caught too', () {
      const body = 'Rs.100.00 debited from a/c XX1234';
      final key = dedupBodyKey(body);
      index.add(event('one',
          paise: 10000,
          direction: TxnDirection.debit,
          accountTail: '1234',
          bodyKey: key));
      index.add(event('two',
          paise: 10000,
          direction: TxnDirection.debit,
          accountTail: '1234',
          at: t0.add(const Duration(seconds: 1)),
          bodyKey: key));
      final third = index.add(event('three',
          paise: 10000,
          direction: TxnDirection.debit,
          accountTail: '1234',
          at: t0.add(const Duration(seconds: 2)),
          bodyKey: key));
      expect(third.relation, DedupRelation.duplicateDelivery);
      expect(index.size, 3);
    });

    test('the most recent match wins, deterministically', () {
      index.add(event('older',
          paise: 5000, direction: TxnDirection.debit, accountTail: '1234'));
      index.add(event('newer',
          paise: 5000,
          direction: TxnDirection.debit,
          accountTail: '1234',
          at: t0.add(const Duration(seconds: 5))));
      final third = index.add(event('third',
          paise: 5000,
          direction: TxnDirection.debit,
          accountTail: '1234',
          at: t0.add(const Duration(seconds: 10))));
      expect(third.matchId, 'newer');
    });

    test('classify does not mutate the index', () {
      final candidate = event('probe',
          paise: 5000, direction: TxnDirection.debit, accountTail: '1234');
      index.classify(candidate);
      index.classify(candidate);
      expect(index.size, 0);
    });
  });

  group('merchant keys', () {
    test('a VPA and a bare name collapse to the same key', () {
      expect(DedupCandidate.merchantKeyOf('swiggy@axisbank'),
          DedupCandidate.merchantKeyOf('SWIGGY'));
      expect(DedupCandidate.merchantKeyOf('Chai Point'), 'chaipoint');
    });

    test('a key too short to mean anything is null', () {
      expect(DedupCandidate.merchantKeyOf('AB'), isNull);
      expect(DedupCandidate.merchantKeyOf(null), isNull);
    });
  });

  group('fromParsed', () {
    test('carries the fields dedup needs straight off a parse', () {
      final parser = RuleBasedSmsParser()..loadSync(fixtureRuleSet());
      final raw = message(
        'VM-HDFCBK-S',
        'Spent Rs.10290 On HDFC Bank Card 0000 At EAZYDINE0000000 On '
            '2026-05-02:22:26:01.Not You?',
        receivedAt: DateTime(2026, 5, 2, 22, 27),
        id: 'raw-1',
      );
      final outcome = parser.parse(raw, now: DateTime(2026, 9, 20));
      expect(outcome.status, ParseStatus.parsed);

      final candidate = DedupCandidate.fromParsed(outcome.message!, raw);
      expect(candidate.id, 'raw-1');
      expect(candidate.amount.paise, 1029000);
      expect(candidate.direction, TxnDirection.debit);
      expect(candidate.cardTail, '0000');
      expect(candidate.isCardInstrument, isTrue);
      expect(candidate.issuer, 'HDFCBK');
      expect(candidate.merchantKey, 'eazydine');
      expect(candidate.bodyKey, dedupBodyKey(raw.body));
    });

    test('two deliveries of one parse collapse end to end', () {
      final parser = RuleBasedSmsParser()..loadSync(fixtureRuleSet());
      const body = 'Sent Rs.100.00 From HDFC Bank A/C *0000 To CUSTOMER NAME '
          'On 17/05/26 Ref 000000000000';
      final at = DateTime(2026, 5, 17, 9, 30);

      final sim1 = message('VM-HDFCBK-S', body, receivedAt: at, id: 'sim-1');
      final sim2 = message('AD-HDFCBK-S', body,
          receivedAt: at.add(const Duration(seconds: 2)), id: 'sim-2');

      final a = parser.parse(sim1, now: at).message!;
      final b = parser.parse(sim2, now: at).message!;

      expect(index.add(DedupCandidate.fromParsed(a, sim1)).relation,
          DedupRelation.unique);
      expect(index.add(DedupCandidate.fromParsed(b, sim2)).relation,
          DedupRelation.duplicateDelivery);
    });
  });
}
