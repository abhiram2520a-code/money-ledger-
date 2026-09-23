import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/data/data.dart';
import 'package:ledger/models/models.dart';

import 'ledger_test_support.dart';

/// Recurring charges in India are anchored to a day of the month, not to a
/// fixed interval. A bill on the 8th has gaps of 28, 31, 30, 31 days, and any
/// detector that tests the gap alone throws it away as irregular.
void main() {
  final DateTime may = DateTime(2026, 5, 20, 10);

  List<Transaction> monthlyCharges({
    required int rupees,
    required List<DateTime> dates,
    String merchant = 'Netflix',
    String prefix = 'n',
  }) =>
      <Transaction>[
        for (int i = 0; i < dates.length; i++)
          makeTxn(
            id: '$prefix$i',
            rupees: rupees,
            occurredAt: dates[i],
            categoryPath: 'entertainment/streaming',
            channel: TxnChannel.card,
            merchantName: merchant,
            cardTail: '4455',
            ref: 'SUB$prefix$i$rupees',
          ),
      ];

  group('period detection', () {
    test('a charge on the 8th of every month is monthly, not irregular', () {
      final PeriodDetection period = RecurringDetector.detectPeriod(<DateTime>[
        DateTime(2025, 12, 8),
        DateTime(2026, 1, 8),
        DateTime(2026, 2, 8),
        DateTime(2026, 3, 8),
        DateTime(2026, 4, 8),
        DateTime(2026, 5, 8),
      ]);
      expect(period.kind, PeriodKind.monthlyDom);
      expect(period.anchorDom, 8);
      expect(period.regularity, 1.0);
    });

    test('a charge on the last day of the month survives February', () {
      final PeriodDetection period = RecurringDetector.detectPeriod(<DateTime>[
        DateTime(2026, 1, 31),
        DateTime(2026, 2, 28),
        DateTime(2026, 3, 31),
      ]);
      expect(period.kind, PeriodKind.monthlyDom);
    });

    test('groceries are frequent but not recurring', () {
      final PeriodDetection period = RecurringDetector.detectPeriod(<DateTime>[
        DateTime(2026, 5, 1),
        DateTime(2026, 5, 3),
        DateTime(2026, 5, 9),
        DateTime(2026, 5, 20),
        DateTime(2026, 5, 27),
      ]);
      expect(period.kind, PeriodKind.irregular);
    });

    test('a weekly charge is weekly', () {
      final PeriodDetection period = RecurringDetector.detectPeriod(<DateTime>[
        DateTime(2026, 4, 6),
        DateTime(2026, 4, 13),
        DateTime(2026, 4, 20),
        DateTime(2026, 4, 27),
      ]);
      expect(period.kind, PeriodKind.weekly);
    });

    test('the next charge is clamped to the length of the month', () {
      expect(
        RecurringDetector.nextExpected(
          DateTime(2026, 1, 31),
          PeriodKind.monthlyDom,
          anchorDom: 31,
        ),
        DateTime(2026, 2, 28),
      );
    });
  });

  group('detection over history', () {
    test('six identical monthly charges become one confident series', () {
      final List<RecurringSeries> series = RecurringDetector.detect(
        monthlyCharges(
          rupees: 649,
          dates: <DateTime>[
            DateTime(2025, 12, 8),
            DateTime(2026, 1, 8),
            DateTime(2026, 2, 8),
            DateTime(2026, 3, 8),
            DateTime(2026, 4, 8),
            DateTime(2026, 5, 8),
          ],
        ),
        now: may,
        knownBillerMerchants: const <String>{'NETFLIX'},
      );

      expect(series, hasLength(1));
      final RecurringSeries netflix = series.single;
      expect(netflix.periodKind, PeriodKind.monthlyDom);
      expect(netflix.amountCenterPaise, 64900);
      expect(netflix.occurrences, 6);
      expect(netflix.anchorDom, 8);
      expect(netflix.score, greaterThanOrEqualTo(RecurringDetector.autoCreateThreshold));
      expect(netflix.nextExpected, DateTime(2026, 6, 8));
      expect(netflix.state, SeriesState.active);
      expect(netflix.amountIsVariable, isFalse);
    });

    test('a price rise stays one series and is reported as a rise', () {
      final List<Transaction> history = <Transaction>[
        ...monthlyCharges(
          rupees: 499,
          dates: <DateTime>[
            DateTime(2025, 12, 8),
            DateTime(2026, 1, 8),
            DateTime(2026, 2, 8),
          ],
          prefix: 'old',
        ),
        ...monthlyCharges(
          rupees: 649,
          dates: <DateTime>[
            DateTime(2026, 3, 8),
            DateTime(2026, 4, 8),
            DateTime(2026, 5, 8),
          ],
          prefix: 'new',
        ),
      ];

      final List<RecurringSeries> series = RecurringDetector.detect(
        history,
        now: may,
        knownBillerMerchants: const <String>{'NETFLIX'},
      );

      expect(series, hasLength(1), reason: 'not two mystery subscriptions');
      expect(series.single.occurrences, 6);
      expect(series.single.amountCenterPaise, 64900);
      expect(series.single.priceChanges, hasLength(1));
      expect(series.single.priceChanges.single.fromPaise, 49900);
      expect(series.single.priceChanges.single.toPaise, 64900);
    });

    test('irregular spending never becomes a subscription', () {
      final List<Transaction> groceries = <Transaction>[
        for (int i = 0; i < 5; i++)
          makeTxn(
            id: 'g$i',
            rupees: 500,
            occurredAt: DateTime(2026, 5, <int>[1, 3, 9, 20, 27][i]),
            categoryPath: 'groceries/kirana',
            merchantName: 'Local Kirana',
            accountTail: '0601',
            ref: 'GROC00$i',
          ),
      ];
      expect(RecurringDetector.detect(groceries, now: may), isEmpty);
    });

    test('a monthly self-transfer is not a subscription', () {
      final List<Transaction> transfers = <Transaction>[
        for (int i = 0; i < 4; i++)
          makeTxn(
            id: 't$i',
            rupees: 50000,
            occurredAt: DateTime(2026, i + 2, 5),
            kind: CategoryKind.transfer,
            categoryPath: TransferPaths.selfTransfer,
            accountTail: '0601',
            ref: 'XFER00$i',
          ),
      ];
      expect(
        RecurringDetector.detect(transfers, now: may),
        isEmpty,
        reason: 'transfers are excluded structurally, not by a heuristic',
      );
    });

    test('a series that stopped is reported as ended, not as still active',
        () {
      final List<RecurringSeries> series = RecurringDetector.detect(
        monthlyCharges(
          rupees: 649,
          dates: <DateTime>[
            DateTime(2025, 9, 8),
            DateTime(2025, 10, 8),
            DateTime(2025, 11, 8),
            DateTime(2025, 12, 8),
          ],
        ),
        now: may,
        knownBillerMerchants: const <String>{'NETFLIX'},
      );
      expect(series.single.state, SeriesState.ended);
    });
  });

  test('a mandate creates a confirmed series from a single message', () {
    final RecurringSeries series = RecurringDetector.fromMandate(
      label: 'Netflix',
      amount: const Money(64900),
      firstCharge: DateTime(2026, 6, 8),
      now: may,
      merchantName: 'Netflix',
      accountId: 'acc-hdfc',
      categoryPath: 'entertainment/streaming',
    );
    expect(series.userConfirmed, isTrue);
    expect(series.occurrences, 0);
    expect(series.score, 1.0);
    expect(series.anchorDom, 8);
    expect(
      series.nextExpected,
      DateTime(2026, 6, 8),
      reason: 'mandate text is ground truth; waiting three months is a wound',
    );
  });

  test('the repository stores what it detects and keeps user confirmation',
      () async {
    final TestLedger ledger = TestLedger(now: may);
    await ledger.open();
    await ledger.repository.upsertAccount(cardAccount(may));

    for (final Transaction t in monthlyCharges(
      rupees: 649,
      dates: <DateTime>[
        DateTime(2025, 12, 8),
        DateTime(2026, 1, 8),
        DateTime(2026, 2, 8),
        DateTime(2026, 3, 8),
        DateTime(2026, 4, 8),
        DateTime(2026, 5, 8),
      ],
    )) {
      await ledger.post(t);
    }

    final List<RecurringSeries> detected = (await ledger.repository
            .refreshRecurringSeries(knownBillerMerchants: const <String>{'NETFLIX'}))
        .getOrElse(<RecurringSeries>[]);
    expect(detected, hasLength(1));

    final List<RecurringSeries> stored =
        (await ledger.repository.recurringSeries()).getOrElse(<RecurringSeries>[]);
    expect(stored, hasLength(1));
    expect(stored.single.amountCenterPaise, 64900);

    // The user confirms it, and a later sweep must not undo that.
    await ledger.repository
        .upsertSeries(stored.single.copyWith(userConfirmed: true));
    await ledger.repository
        .refreshRecurringSeries(knownBillerMerchants: const <String>{'NETFLIX'});
    final List<RecurringSeries> again =
        (await ledger.repository.recurringSeries()).getOrElse(<RecurringSeries>[]);
    expect(again.single.userConfirmed, isTrue);
  });
}
