/// The negative grammar.
///
/// Two failure modes are being held apart here and they are not symmetric.
/// Booking an OTP or a promo invents money the user never spent, and the user
/// notices immediately and stops trusting the app. Rejecting a genuine alert
/// loses money silently. So the guards that could plausibly fire on a real
/// alert - promo, balance, obligation - are all conditional on the body NOT
/// showing a completed money movement bound to an account or card mask, and
/// the tests below spend most of their effort on that side.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/parser/parsing.dart';

import 'fixtures/rule_fixtures.dart';

TrustGate gateWithShippedRejects() {
  final compiled = RuleCompiler.compile(fixtureRuleSet());
  return TrustGate.fromRules(compiled.valueOrNull!);
}

TrustVerdict screen(TrustGate gate, String sender, String body) => gate.screen(
      senderHeader: SenderId.parse(sender)?.principal,
      senderRaw: sender,
      body: normalizeBody(body),
    );

void main() {
  late TrustGate gate;

  setUp(() => gate = gateWithShippedRejects());

  group('sender', () {
    test('a 10-digit number is untrusted however convincing the body is', () {
      final verdict = screen(
        gate,
        '9876543210',
        'Rs 25,000.00 has been credited to your A/c XX1234. UPI Ref '
            '000000000000.',
      );
      expect(verdict.kind, TrustVerdictKind.untrustedSender);
    });

    test('an unnormalisable header is untrusted', () {
      final verdict = gate.screen(
        senderHeader: null,
        senderRaw: 'VM-HDFCBK-S',
        body: 'Rs.100 debited from a/c XX1234',
      );
      expect(verdict.kind, TrustVerdictKind.untrustedSender);
      expect(verdict.reason, 'sender:not_normalised');
    });

    test('a promotional category suffix is a reject on its own', () {
      final verdict = screen(
        gate,
        'VM-HDFCBK-P',
        'Rs.100 debited from your a/c XX1234 on 01-01-26',
      );
      expect(verdict.kind, TrustVerdictKind.rejected);
      expect(verdict.classifiedAs, TxnType.promo);
      expect(verdict.reason, 'sender:category_p');
    });

    test('the telco prefix never changes the decision', () {
      for (final sender in <String>['VM-HDFCBK-S', 'AD-HDFCBK-S', 'JM-HDFCBK-S']) {
        expect(
          screen(gate, sender, 'Rs.100 debited from a/c XX1234 on 01-01-26')
              .kind,
          TrustVerdictKind.candidate,
          reason: sender,
        );
      }
    });
  });

  group('OTP', () {
    test('an OTP carrying an amount, a merchant and a card tail is rejected',
        () {
      final verdict = screen(
        gate,
        'VM-HDFCBK-T',
        'OTP 483920 for txn of Rs 4,999 at AMAZON on card XX4455. '
            'Do not share this OTP with anyone.',
      );
      expect(verdict.kind, TrustVerdictKind.rejected);
      expect(verdict.classifiedAs, TxnType.otp);
    });

    test('every spelling of the word', () {
      const bodies = <String>[
        'Your One Time Password is 123456',
        'Use verification code 998877 to log in',
        '445566 is your login code for NetBanking',
        'Never share your OTP or PIN with anyone',
      ];
      for (final body in bodies) {
        expect(screen(gate, 'VM-HDFCBK-T', body).classifiedAs, TxnType.otp,
            reason: body);
      }
    });

    test('the SMS Retriever prefix is an OTP tell on its own', () {
      final verdict = screen(
        gate,
        'JK-NOBRKR-S',
        '<#> 557026 is the code for Phone Verification on NoBroker A7jPtLVJWz3',
      );
      expect(verdict.classifiedAs, TxnType.otp);
    });

    test('a genuine alert that merely contains the letters otp is not an OTP',
        () {
      // 'Optum' and similar merchant names must not trip the word-bounded
      // pattern.
      final verdict = screen(
        gate,
        'VM-HDFCBK-S',
        'Rs.100.00 spent on HDFC Bank Card 0000 at OPTUM HEALTH on 01-01-26',
      );
      expect(verdict.kind, TrustVerdictKind.candidate);
    });
  });

  group('failed and declined', () {
    test('a failed txn differs from a real debit by one word', () {
      final verdict = screen(
        gate,
        'AX-CANBNK-S',
        'Dear Customer, txn of Rs.637.70 thru A/C XX1234 on 18-8-26 at '
            '14:16:16 to ACME STORE failed due to INSUFFICIENT FUNDS',
      );
      expect(verdict.kind, TrustVerdictKind.rejected);
      expect(verdict.reason, 'guard:failed');
    });

    test('the ATM non-dispense disclaimer is NOT a failure', () {
      final verdict = screen(
        gate,
        'AX-BOBSMS-S',
        'Rs.8000.00 withdrawn from A/c ...1055 at ATM TID 6BXxxxm02. In case '
            'your a/c is debited but cash is not dispensed from the ATM, the '
            'transaction will be automatically reversed',
      );
      expect(verdict.kind, TrustVerdictKind.candidate);
    });
  });

  group('promotional', () {
    test('a conditional offer with an amount is rejected', () {
      const promos = <String>[
        'Get up to Rs 1,500 cashback! Spend Rs 5,000 and get assured rewards.',
        'You are pre-approved for a personal loan of Rs 5,00,000 at 10.5% p.a.',
        'Cashback up to Rs 500 on your next UPI payment. T&C apply.',
      ];
      for (final body in promos) {
        final verdict = screen(gate, 'VM-HDFCBK-S', body);
        expect(verdict.kind, TrustVerdictKind.rejected, reason: body);
      }
    });

    test('a real alert carrying a marketing tail survives', () {
      // ICICI appends an EMI-conversion CTA to genuine spend alerts.
      final icici = screen(
        gate,
        'AD-ICICIT-S',
        'Rs 100.00 spent on ICICI Bank Card XX0000 on 16-May-26 at SAMPLE '
            'MERCHANT. Avl Lmt: Rs 200.00. To convert this txn to EMI give a '
            'missed call on 9924667667.',
      );
      expect(icici.kind, TrustVerdictKind.candidate);

      // OneCard opens real spend alerts with a rotating marketing hook.
      final oneCard = screen(
        gate,
        'TX-SBMONE-S',
        "Tank's full! Rs. 210.00 spent at Veer Petroleum, Surat on your SBM "
            'One Credit Card xxXX6438. Reward points added.',
      );
      expect(oneCard.kind, TrustVerdictKind.candidate);

      // Suryoday sends transaction alerts under a -T header with an EMI CTA.
      final suryoday = screen(
        gate,
        'VM-SSFBNK-T',
        'Rs 99.00 spent on Stable Money Suryoday SFB CC xx1234 on 30-08-2026 '
            'at 21:34:28. Convert to EMI? visit: '
            'https://cc.suryoday.bank.in/emi-web',
      );
      expect(suryoday.kind, TrustVerdictKind.candidate);
    });
  });

  group('balance', () {
    test('a balance-only message is rejected', () {
      final verdict = screen(
        gate,
        'VM-HDFCBK-S',
        'Available balance in your A/c XX1234 is Rs 9,500.00 as on 12-09-26.',
      );
      expect(verdict.kind, TrustVerdictKind.rejected);
      expect(verdict.classifiedAs, TxnType.balanceInfo);
    });

    test('"contains a balance" is never grounds for rejection on its own', () {
      // Most real alerts carry a balance too. Only "contains ONLY a balance"
      // is a reject.
      final verdict = screen(
        gate,
        'JD-KOTAKD-S',
        'Rs.1234.56 spent via Kotak Debit Card XX0000 at SAMPLE MERCHANT on '
            '16/07/2026. Avl bal Rs.9999.99',
      );
      expect(verdict.kind, TrustVerdictKind.candidate);
    });
  });

  group('hasSettledMoneyMovement', () {
    test('needs a past-tense verb AND an instrument', () {
      expect(
        TrustGate.hasSettledMoneyMovement(
            'Rs 5,000 debited from A/c XX1234 on 01-01-26'),
        isTrue,
      );
      // A verb with no instrument: an advert.
      expect(
        TrustGate.hasSettledMoneyMovement('Spend Rs 5,000 and get Rs 500 back'),
        isFalse,
      );
      // An instrument with no completed verb: a statement.
      expect(
        TrustGate.hasSettledMoneyMovement(
            'Statement for your Card 0000 is generated. Total Due: 1234.56'),
        isFalse,
      );
    });

    test('recognises the abbreviations some banks use instead of words', () {
      expect(
        TrustGate.hasSettledMoneyMovement(
            'Rs.230.00 Dr. from A/C XXXXXX1234 and Cr. to example@okbank'),
        isTrue,
      );
    });
  });

  group('classifyObligation', () {
    test('a statement is a bill reminder', () {
      expect(
        TrustGate.classifyObligation(
          'Statement for your Equitas Credit Card 0000 is generated. Total '
          'Due: 12345.67 Min Due: 1234.56 Due by: 09/06/26.',
        ),
        TxnType.billReminder,
      );
    });

    test('an RBI pre-debit notice is money that has not moved', () {
      expect(
        TrustGate.classifyObligation(
          'KINDLY MAINTAIN SUFFICIENT BALANCE FOR AUTO DEBIT OF PREMIUM OF '
          'RS.20/- FOR PMSBY BETWEEN 25/05/2026 AND 01/06/2026',
        ),
        TxnType.preDebitNotice,
      );
      expect(
        TrustGate.classifyObligation(
          'UPI AutoPay vpa@ibl for Jar Gold Debited Rs.30.00 scheduled on '
          '19/04/2026',
        ),
        TxnType.preDebitNotice,
      );
      expect(
        TrustGate.classifyObligation(
          'Your SIP of Rs 5,000 will be debited on 05/10/2026',
        ),
        TxnType.preDebitNotice,
      );
    });

    test('an ASBA block is a lien, not a debit', () {
      expect(
        TrustGate.classifyObligation(
          'Your ASBA application for SAMPLEIPO is received and Application '
          'value of Rs 14999 is blocked in your registered Bank account on '
          '14/08/2026.',
        ),
        TxnType.preDebitNotice,
      );
    });

    test('a settled movement is never demoted, decoy due amounts and all', () {
      // ICICI's refund alert contains BOTH 'Revised total due' and
      // 'minimum due'. It is still a real credit.
      expect(
        TrustGate.classifyObligation(
          'SAMPLE MERCHANT AI refund of Rs 2.00 credited to ICICI Bank Credit '
          'Card XX0000 on 06-SEP-26. Revised total due Rs 99,999.00, minimum '
          'due Rs 4,999.00',
        ),
        isNull,
      );
    });
  });

  group('pack-supplied reject patterns', () {
    test('fire, and the reason names the pattern', () {
      final verdict = screen(
        gate,
        'VM-HDFCBK-S',
        'Your offer is valid till 31-12-2026.',
      );
      expect(verdict.kind, TrustVerdictKind.rejected);
      expect(verdict.reason, startsWith('reject:'));
    });

    test('an empty pack leaves only the built-in guards', () {
      const bare = TrustGate();
      expect(
        screen(bare, 'VM-HDFCBK-S', 'Your OTP is 123456').classifiedAs,
        TxnType.otp,
      );
    });

    test('the guards can be switched off for isolation', () {
      const noGuards = TrustGate(builtInGuards: false);
      expect(
        screen(noGuards, 'VM-HDFCBK-S', 'Available balance is Rs 100').kind,
        TrustVerdictKind.candidate,
      );
    });
  });

  test('an empty body is rejected before anything else looks at it', () {
    expect(screen(gate, 'VM-HDFCBK-S', '   ').reason, 'body:empty');
  });
}
