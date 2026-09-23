/// The primitives every other part of the parser stands on.
///
/// Most of these look like trivia until you see the message that motivated
/// them: `Rs<NBSP>500` that does not match `Rs\s*\d`, `1,00,000.00` that a
/// western-grouping parser reads as one rupee, and `Ref.6952` that a loose
/// reference regex treats as a unique payment identifier.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/parser/parsing.dart';

void main() {
  group('normalizeBody', () {
    test('collapses the newline-delimited templates into one line', () {
      const raw = 'Sent Rs.100.00\nFrom HDFC Bank A/C *0000\r\nTo CUSTOMER\n'
          'On 17/05/26';
      expect(
        normalizeBody(raw),
        'Sent Rs.100.00 From HDFC Bank A/C *0000 To CUSTOMER On 17/05/26',
      );
    });

    test('strips zero-width characters that break regexes invisibly', () {
      const raw = 'Rs.​100.00 debited‍';
      expect(normalizeBody(raw), 'Rs.100.00 debited');
    });

    test('turns every space-like character into a plain space', () {
      // NBSP and narrow NBSP are what templating engines insert.
      const raw = 'Rs 500 spent at SHOP';
      expect(normalizeBody(raw), 'Rs 500 spent at SHOP');
    });

    test('does not fold case - merchant strings are shown to the user', () {
      expect(normalizeBody('Spent at SampleMerchant'),
          'Spent at SampleMerchant');
    });

    test('dedupBodyKey folds case so a re-delivery still matches', () {
      expect(dedupBodyKey('Rs.100 DEBITED\n'), dedupBodyKey('rs.100 debited'));
    });
  });

  group('SenderId', () {
    test('reads the three forms that reach a handset', () {
      final withSuffix = SenderId.parse('VM-HDFCBK-S')!;
      expect(withSuffix.operatorPrefix, 'VM');
      expect(withSuffix.principal, 'HDFCBK');
      expect(withSuffix.category, 'S');

      final noSuffix = SenderId.parse('AX-SBIUPI')!;
      expect(noSuffix.principal, 'SBIUPI');
      expect(noSuffix.category, isNull);

      final bare = SenderId.parse('ATMSBI')!;
      expect(bare.principal, 'ATMSBI');
      expect(bare.operatorPrefix, isNull);
    });

    test('the telco prefix is noise - the same bank arrives under all of them',
        () {
      final principals = <String>{
        for (final s in <String>['VM-HDFCBK-S', 'AD-HDFCBK-S', 'JM-HDFCBK-S'])
          SenderId.parse(s)!.principal,
      };
      expect(principals, <String>{'HDFCBK'});
    });

    test('mixed-case headers are real traffic', () {
      expect(SenderId.parse('VK-AxisBk-T')!.principal, 'AXISBK');
      expect(SenderId.parse('AX-axioFS-S')!.principal, 'AXIOFS');
    });

    test('numeric addresses are not headers', () {
      for (final sender in <String>[
        '9876543210',
        '+919876543210',
        '575758',
        'AD-123456-P',
      ]) {
        expect(SenderId.parse(sender), isNull, reason: sender);
      }
    });

    test('-P is the one category suffix that is a reject', () {
      expect(SenderId.parse('VM-HDFCBK-P')!.isPromotional, isTrue);
      expect(SenderId.parse('VM-HDFCBK-S')!.isPromotional, isFalse);
      expect(SenderId.parse('VM-SBICRD-T')!.isPromotional, isFalse);
    });

    test('match candidates cover both ways packs spell sender_pattern', () {
      expect(
        SenderId.parse('VM-HDFCBK-S')!.matchCandidates,
        <String>['HDFCBK', 'VM-HDFCBK', 'VM-HDFCBK-S'],
      );
    });

    test('normalizeSenderHeader is the principal entity', () {
      expect(normalizeSenderHeader('JD-AXISBK-S'), 'AXISBK');
      expect(normalizeSenderHeader('9876543210'), isNull);
    });
  });

  group('parseAmount', () {
    const cases = <String, int>{
      'Rs.1,24,500.00': 12450000, // Indian lakh grouping, not 1.24
      '1,00,000.00': 10000000,
      'INR 2000': 200000,
      'Rs 1,234.5': 123450,
      '450': 45000,
      '150.0': 15000, // SBI's single decimal place
      '3800.0': 380000,
      '634.53': 63453, // axio's 'Rs634.53', currency already stripped
      '151.00': 15100, // Union Bank's 'Rs:151.00'
      '99,99,999.99': 999999999,
    };

    cases.forEach((input, paise) {
      test('reads "$input" as $paise paise', () {
        expect(parseAmount(input)?.paise, paise);
      });
    });

    test('a string with no number is null, never zero', () {
      expect(parseAmount('Rs.'), isNull);
      expect(parseAmount(''), isNull);
      expect(parseAmount(null), isNull);
    });

    test('a zero amount is null - it cannot be told from a real one in a total',
        () {
      expect(parseAmount('0.00'), isNull);
    });

    test('always a positive magnitude; the sign lives in the direction', () {
      expect(parseAmount('-500')?.paise, 50000);
    });
  });

  group('amountLooksBalanceBound', () {
    const alert = 'Spent Rs.3000 From HDFC Bank Card x0000 At PZCREDIT0000000 '
        'On 2026-05-02:00:17:56 Bal Rs.142.26 Not You?';

    test('the amount bound to the money verb is not balance-bound', () {
      expect(amountLooksBalanceBound(alert, '3000'), isFalse);
    });

    test('the balance is', () {
      expect(amountLooksBalanceBound(alert, '142.26'), isTrue);
    });

    test('catches every marker the templates use', () {
      const markers = <String>[
        'Avl Bal Rs.100.00',
        'Available balance is Rs 100.00',
        'Avl Limit: INR 100.00',
        'New Bal :INR 100.00',
        'Revised total due Rs 100.00',
        'minimum due Rs 100.00',
        'Avl Lmt: Rs 100.00',
      ];
      for (final body in markers) {
        expect(amountLooksBalanceBound(body, '100.00'), isTrue, reason: body);
      }
    });
  });

  group('tails', () {
    test('every mask dialect reduces to the same digits', () {
      for (final mask in <String>[
        'X1234',
        'XX1234',
        'xx1234',
        '*1234',
        'A/c 1234',
        '...1234',
      ]) {
        expect(tailKey(mask), '1234', reason: mask);
      }
    });

    test('comparison is on the last four digits only', () {
      expect(tailsMatch('XXXXXXXX1234', 'xx1234'), isTrue);
      expect(tailsMatch('000***001234', '1234'), isTrue);
      expect(tailsMatch('XX1234', 'XX5678'), isFalse);
    });

    test('an unknown tail matches nothing - absence is not evidence', () {
      expect(tailsMatch(null, '1234'), isFalse);
      expect(tailsMatch('XX', '1234'), isFalse);
    });
  });

  group('cleanMerchant', () {
    const cases = <String, String?>{
      'EAZYDINE0000000': 'EAZYDINE',
      'PZCREDIT0000000': 'PZCREDIT',
      r'RAZ*SampleFood': 'SampleFood',
      r'PYU*SWIGGY FOOD': 'SWIGGY FOOD',
      'SAMPLEVENDOR, INC        NEW YORK       US':
          'SAMPLEVENDOR, INC NEW YORK US',
      'RAHUL SHARMA Not you? SMS BLOCKUPI Cust ID': 'RAHUL SHARMA',
      'SAMPLE MART.': 'SAMPLE MART',
      '  Pune Metro  ': 'Pune Metro',
      'CAFE 24': 'CAFE 24', // short digit runs are part of the name
      '': null,
      '0000000': null,
      '-': null,
    };

    cases.forEach((input, expected) {
      test('"$input" -> ${expected ?? 'null'}', () {
        expect(cleanMerchant(input), expected);
      });
    });
  });

  group('VPAs', () {
    test('finds the VPA in every counterparty shape', () {
      expect(extractVpa('from VPA customer@bank (UPI 1)'), 'customer@bank');
      expect(extractVpa('Cr. to example@okbank. Ref'), 'example@okbank');
      expect(extractVpa('towards 9999999999@bank.'), '9999999999@bank');
    });

    test('an e-mail address is not a VPA', () {
      expect(extractVpa('write to care@hdfcbank.com for help'), isNull);
    });

    test('opaque handles name nobody and must not become merchants', () {
      expect(isOpaqueVpa('d4da379700914856af8320ffd283c9ad@ibl'), isTrue);
      expect(isOpaqueVpa('paytmqr2810050501011@paytm'), isTrue);
      expect(isOpaqueVpa('9999999999@bank'), isTrue);
      expect(isOpaqueVpa('swiggy@axisbank'), isFalse);

      expect(merchantFromVpa('d4da379700914856af8320ffd283c9ad@ibl'), isNull);
      expect(merchantFromVpa('swiggy@axisbank'), 'swiggy');
    });
  });

  group('references', () {
    test('a 12-digit RRN is the strongest key there is', () {
      expect(findRefInBody('UPI Ref 431234567890.'), '431234567890');
      expect(findRefInBody('RRN:000000000000.'), '000000000000');
      expect(findRefInBody('(UPI Ref No. 000000000000)'), '000000000000');
      expect(findRefInBody('IMPS Ref# 000000000001)'), '000000000001');
      expect(findRefInBody('Ref-000000000001'), '000000000001');
      expect(findRefInBody('Refno 406512345678'), '406512345678');
    });

    test('the Axis rail token is read as a rail token, not as "P2M"', () {
      expect(
        findRefInBody('UPI/P2M/431234567890/RAHUL SHARMA Not you?'),
        '431234567890',
      );
    });

    test('an alphanumeric UTR is accepted', () {
      final utr = findRefInBody('Txn No: HDFCR00000000000000000 On 21-08-2026');
      expect(utr, 'HDFCR00000000000000000');
      expect(isPlausibleRef(utr), isTrue);
    });

    test('the things that look like references but are not', () {
      // A four-digit ATM slip number, not unique across days.
      expect(
        findRefInBody('at ATM TID 6BXxxxm02 Ref.6952 Avlbal Amt:Rs.9234.31'),
        isNull,
      );
      // The cyber-fraud helpline and card-block numbers.
      expect(isPlausibleRef('1930'), isFalse);
      expect(isPlausibleRef('18002586161'), isFalse);
      expect(isPlausibleRef('9876543210'), isFalse);
      expect(isPlausibleRef('123'), isFalse);
    });

    test('leading zeros are preserved - an RRN is fixed-width', () {
      expect(normalizeRef('012345678901'), '012345678901');
    });
  });

  group('dates', () {
    final reference = DateTime(2026, 9, 20, 12);

    void expectDate(
      String token,
      DateTime expected, {
      DatePrecision? precision,
      List<String> ruleFormats = const <String>[],
    }) {
      final parsed =
          parseDateToken(token, reference: reference, formats: ruleFormats);
      expect(parsed, isNotNull, reason: token);
      expect(parsed!.value, expected, reason: token);
      if (precision != null) expect(parsed.precision, precision, reason: token);
    }

    test('every separator dialect in the corpus', () {
      expectDate('05-09-26', DateTime(2026, 9, 5));
      expectDate('05/09/26', DateTime(2026, 9, 5));
      expectDate('16/07/2026', DateTime(2026, 7, 16));
      expectDate('01-May-26', DateTime(2026, 5, 1));
      expectDate('17/MAY/2026', DateTime(2026, 5, 17));
      expectDate('29-JUN-26', DateTime(2026, 6, 29));
      // SBI, with no separators at all.
      expectDate('05Mar24', DateTime(2024, 3, 5));
      // HDFC, joining date and time with a colon.
      expectDate('2026-05-02:22:26:01', DateTime(2026, 5, 2, 22, 26, 1),
          precision: DatePrecision.dateTime);
      // Bank of Baroda, colons as DATE separators.
      expectDate('2026:09:06 09:56:33', DateTime(2026, 9, 6, 9, 56, 33));
      // Axis, comma between date and time.
      expectDate('05-09-26, 10:19:49', DateTime(2026, 9, 5, 10, 19, 49));
      // Long-form English.
      expectDate('February 1, 2026', DateTime(2026, 2, 1));
      expectDate('Apr 12, 2026', DateTime(2026, 4, 12));
    });

    test('a 12-hour clock needs the format from the rule', () {
      expectDate(
        '2026-08-19 02:10:08 PM',
        DateTime(2026, 8, 19, 14, 10, 8),
        ruleFormats: <String>['yyyy-MM-dd hh:mm:ss a'],
      );
    });

    test('a date with no year is resolved against the receipt time', () {
      expectDate('23-05', DateTime(2026, 5, 23),
          precision: DatePrecision.inferredYear);
    });

    test('a year-less date near New Year does not jump forward a year', () {
      final newYear = DateTime(2027, 1, 2, 9);
      final parsed = parseDateToken('31-12', reference: newYear);
      expect(parsed!.value, DateTime(2026, 12, 31));
    });

    test('an impossible date is rejected rather than rolled over', () {
      expect(parseDateToken('31-02-26', reference: reference), isNull);
      expect(parseDateToken('99-99-99', reference: reference), isNull);
    });

    test('precision records how much the message actually said', () {
      expect(parseDateToken('05-09-26', reference: reference)!.precision,
          DatePrecision.date);
      expect(
          parseDateToken('05-09-26 10:19:49', reference: reference)!.precision,
          DatePrecision.dateTime);
    });

    test('findDateInBody only trusts a date behind a preposition', () {
      final found = findDateInBody(
        'Spent Rs.100 at SHOP on 05-09-26. Call 18002586161',
        reference: reference,
      );
      expect(found!.value, DateTime(2026, 9, 5));

      // A bare number run is not a date.
      expect(
        findDateInBody('SMS BLOCK 0000 to 7308080808', reference: reference),
        isNull,
      );
    });
  });

  group('matchableBody', () {
    test('caps the input a regex is run over', () {
      final huge = 'x' * 50000;
      expect(matchableBody(huge).length, maxMatchableBodyChars);
    });
  });
}
