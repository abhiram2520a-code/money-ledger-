import 'package:flutter/foundation.dart';
import 'package:ledger/models/models.dart';

import 'fingerprints.dart';
import 'ids.dart';

/// How often a series repeats.
///
/// [monthlyDom] is first for a reason: Indian recurring charges are
/// day-of-month anchored, not fixed-interval. A bill on the 8th has gaps of
/// 28, 31, 30, 31 days. Testing the gap alone calls that irregular and loses
/// the series.
enum PeriodKind {
  monthlyDom('monthly_dom'),
  weekly('weekly'),
  fortnightly('fortnightly'),
  monthly('monthly'),
  quarterly('quarterly'),
  halfYearly('half_yearly'),
  yearly('yearly'),
  irregular('irregular');

  const PeriodKind(this.wire);

  final String wire;

  static PeriodKind fromWire(String? wire) {
    for (final PeriodKind v in PeriodKind.values) {
      if (v.wire == wire) return v;
    }
    return PeriodKind.irregular;
  }

  double get approximateDays => switch (this) {
        PeriodKind.weekly => 7,
        PeriodKind.fortnightly => 14,
        PeriodKind.monthlyDom || PeriodKind.monthly => 30.44,
        PeriodKind.quarterly => 91.3,
        PeriodKind.halfYearly => 182.6,
        PeriodKind.yearly => 365.25,
        PeriodKind.irregular => 0,
      };
}

enum SeriesState {
  active('active'),

  /// Expected and not seen yet. Deliberately SILENT: a charge two days late
  /// would otherwise fire a false "your subscription was cancelled" every
  /// month.
  atRisk('at_risk'),

  ended('ended'),
  paused('paused'),
  cancelled('cancelled');

  const SeriesState(this.wire);

  final String wire;

  static SeriesState fromWire(String? wire) {
    for (final SeriesState v in SeriesState.values) {
      if (v.wire == wire) return v;
    }
    return SeriesState.active;
  }
}

/// A price change inside one series, so the user sees "Adobe went ₹1,675 to
/// ₹2,199" instead of two mystery series.
@immutable
class PriceChange {
  const PriceChange({
    required this.at,
    required this.fromPaise,
    required this.toPaise,
  });

  factory PriceChange.fromJson(Map<String, dynamic> json) => PriceChange(
        at: jDate(json['at']),
        fromPaise: jInt(json['fromPaise']),
        toPaise: jInt(json['toPaise']),
      );

  final DateTime at;
  final int fromPaise;
  final int toPaise;

  double get percent => fromPaise == 0 ? 0 : (toPaise - fromPaise) * 100 / fromPaise;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'at': jMillis(at),
        'fromPaise': fromPaise,
        'toPaise': toPaise,
      };
}

/// A repeating charge the app spotted in the user's own history.
@immutable
class RecurringSeries {
  const RecurringSeries({
    required this.id,
    required this.groupKey,
    required this.periodKind,
    required this.amountCenterPaise,
    required this.amountMadPaise,
    required this.occurrences,
    required this.firstSeen,
    required this.lastSeen,
    required this.score,
    required this.createdAt,
    required this.updatedAt,
    this.label = '',
    this.merchantName,
    this.accountId,
    this.categoryPath,
    this.anchorDom,
    this.periodDays,
    this.amountIsVariable = false,
    this.nextExpected,
    this.graceDays = 3,
    this.state = SeriesState.active,
    this.userConfirmed = false,
    this.priceChanges = const <PriceChange>[],
  });

  factory RecurringSeries.fromJson(Map<String, dynamic> json) => RecurringSeries(
        id: jString(json['id']),
        groupKey: jString(json['groupKey']),
        periodKind: PeriodKind.fromWire(jStringOrNull(json['periodKind'])),
        amountCenterPaise: jInt(json['amountCenterPaise']),
        amountMadPaise: jInt(json['amountMadPaise']),
        occurrences: jInt(json['occurrences']),
        firstSeen: jDate(json['firstSeen']),
        lastSeen: jDate(json['lastSeen']),
        score: jDouble(json['score']),
        createdAt: jDate(json['createdAt']),
        updatedAt: jDate(json['updatedAt']),
        label: jString(json['label']),
        merchantName: jStringOrNull(json['merchantName']),
        accountId: jStringOrNull(json['accountId']),
        categoryPath: jStringOrNull(json['categoryPath']),
        anchorDom: jIntOrNull(json['anchorDom']),
        periodDays: jDoubleOrNull(json['periodDays']),
        amountIsVariable: jBool(json['amountIsVariable']),
        nextExpected: jDateOrNull(json['nextExpected']),
        graceDays: jInt(json['graceDays'], fallback: 3),
        state: SeriesState.fromWire(jStringOrNull(json['state'])),
        userConfirmed: jBool(json['userConfirmed']),
        priceChanges: <PriceChange>[
          for (final Map<String, dynamic> p in jMapList(json['priceChanges']))
            PriceChange.fromJson(p),
        ],
      );

  final String id;
  final String groupKey;
  final PeriodKind periodKind;

  /// The MEDIAN amount, not the mean: one annual ₹4,999 charge among eleven
  /// ₹499 monthlies would otherwise move the centre by a fifth.
  final int amountCenterPaise;

  /// Median absolute deviation. Also not standard deviation, for the same
  /// reason.
  final int amountMadPaise;

  final int occurrences;
  final DateTime firstSeen;
  final DateTime lastSeen;
  final double score;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String label;
  final String? merchantName;
  final String? accountId;
  final String? categoryPath;

  /// Day of month the charge is anchored to, for [PeriodKind.monthlyDom].
  final int? anchorDom;

  final double? periodDays;
  final bool amountIsVariable;
  final DateTime? nextExpected;
  final int graceDays;
  final SeriesState state;

  /// Set by a mandate SMS, or by the user confirming the prompt.
  final bool userConfirmed;

  final List<PriceChange> priceChanges;

  Money get amount => Money(amountCenterPaise);

  RecurringSeries copyWith({
    SeriesState? state,
    DateTime? nextExpected,
    DateTime? updatedAt,
    bool? userConfirmed,
  }) =>
      RecurringSeries(
        id: id,
        groupKey: groupKey,
        periodKind: periodKind,
        amountCenterPaise: amountCenterPaise,
        amountMadPaise: amountMadPaise,
        occurrences: occurrences,
        firstSeen: firstSeen,
        lastSeen: lastSeen,
        score: score,
        createdAt: createdAt,
        updatedAt: updatedAt ?? this.updatedAt,
        label: label,
        merchantName: merchantName,
        accountId: accountId,
        categoryPath: categoryPath,
        anchorDom: anchorDom,
        periodDays: periodDays,
        amountIsVariable: amountIsVariable,
        nextExpected: nextExpected ?? this.nextExpected,
        graceDays: graceDays,
        state: state ?? this.state,
        userConfirmed: userConfirmed ?? this.userConfirmed,
        priceChanges: priceChanges,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'groupKey': groupKey,
        'periodKind': periodKind.wire,
        'amountCenterPaise': amountCenterPaise,
        'amountMadPaise': amountMadPaise,
        'occurrences': occurrences,
        'firstSeen': jMillis(firstSeen),
        'lastSeen': jMillis(lastSeen),
        'score': score,
        'createdAt': jMillis(createdAt),
        'updatedAt': jMillis(updatedAt),
        'label': label,
        'merchantName': merchantName,
        'accountId': accountId,
        'categoryPath': categoryPath,
        'anchorDom': anchorDom,
        'periodDays': periodDays,
        'amountIsVariable': amountIsVariable,
        'nextExpected': nextExpected == null ? null : jMillis(nextExpected!),
        'graceDays': graceDays,
        'state': state.wire,
        'userConfirmed': userConfirmed,
        'priceChanges': <Map<String, dynamic>>[
          for (final PriceChange p in priceChanges) p.toJson(),
        ],
      };

  @override
  String toString() =>
      'RecurringSeries($label, ${amount.format()}, ${periodKind.wire}, $occurrences)';
}

/// Finds repeating charges in the user's own history.
///
/// Only expense-bearing transactions are considered, which excludes transfers,
/// card payments and ATM withdrawals structurally: a monthly ₹50,000
/// self-transfer is not a subscription, and no heuristic is needed to say so.
abstract final class RecurringDetector {
  /// Created silently at or above this score.
  static const double autoCreateThreshold = 0.70;

  /// Below this, say nothing at all.
  static const double promptThreshold = 0.50;

  /// How far back to look.
  static const int historyDays = 400;

  /// Groups [transactions] and returns the series worth keeping.
  static List<RecurringSeries> detect(
    List<Transaction> transactions, {
    required DateTime now,
    Set<String> knownBillerMerchants = const <String>{},
  }) {
    final Map<String, List<Transaction>> groups = <String, List<Transaction>>{};
    final DateTime cutoff = now.subtract(const Duration(days: historyDays));
    for (final Transaction t in transactions) {
      if (!t.countsAsSpend && t.kind != CategoryKind.investment) continue;
      if (t.occurredAt.isBefore(cutoff)) continue;
      groups.putIfAbsent(groupKeyFor(t), () => <Transaction>[]).add(t);
    }

    final List<RecurringSeries> out = <RecurringSeries>[];
    for (final MapEntry<String, List<Transaction>> entry in groups.entries) {
      final List<Transaction> rows = entry.value
        ..sort((Transaction a, Transaction b) => a.occurredAt.compareTo(b.occurredAt));
      final List<RecurringSeries> built = <RecurringSeries>[];
      for (final List<Transaction> cluster in clusterByAmount(rows)) {
        final RecurringSeries? series = _seriesFrom(
          entry.key,
          cluster,
          now: now,
          knownBillerMerchants: knownBillerMerchants,
        );
        if (series != null && series.score >= promptThreshold) built.add(series);
      }
      out.addAll(_reconcileGroup(entry.key, built));
    }
    out.sort((RecurringSeries a, RecurringSeries b) => b.score.compareTo(a.score));
    return out;
  }

  /// Folds a price increase back into one series.
  ///
  /// Amount clustering splits eleven charges at Rs 499 and six at Rs 649 into
  /// two clusters. If the second cluster starts only after the first one ends
  /// and both repeat the same way, that is not two subscriptions - it is one
  /// subscription that got more expensive, which is exactly what the user
  /// wants to be told.
  ///
  /// Clusters that genuinely overlap keep their own ids, because two charges
  /// of different sizes running at the same time really are two things.
  static List<RecurringSeries> _reconcileGroup(
    String groupKey,
    List<RecurringSeries> series,
  ) {
    if (series.length <= 1) return series;
    final List<RecurringSeries> sorted = List<RecurringSeries>.of(series)
      ..sort((RecurringSeries a, RecurringSeries b) =>
          a.firstSeen.compareTo(b.firstSeen));

    bool sequential = true;
    for (int i = 1; i < sorted.length; i++) {
      if (sorted[i].periodKind != sorted[0].periodKind ||
          !sorted[i].firstSeen.isAfter(sorted[i - 1].lastSeen)) {
        sequential = false;
        break;
      }
    }
    if (!sequential) {
      return <RecurringSeries>[
        for (int i = 0; i < sorted.length; i++)
          _rebuild(sorted[i], id: '$groupKey:$i'),
      ];
    }

    final RecurringSeries latest = sorted.last;
    int occurrences = 0;
    double score = 0;
    for (final RecurringSeries s in sorted) {
      occurrences += s.occurrences;
      if (s.score > score) score = s.score;
    }
    return <RecurringSeries>[
      _rebuild(
        latest,
        id: groupKey,
        occurrences: occurrences,
        firstSeen: sorted.first.firstSeen,
        score: score,
        priceChanges: <PriceChange>[
          for (int i = 1; i < sorted.length; i++)
            PriceChange(
              at: sorted[i].firstSeen,
              fromPaise: sorted[i - 1].amountCenterPaise,
              toPaise: sorted[i].amountCenterPaise,
            ),
        ],
      ),
    ];
  }

  static RecurringSeries _rebuild(
    RecurringSeries base, {
    String? id,
    int? occurrences,
    DateTime? firstSeen,
    double? score,
    List<PriceChange>? priceChanges,
  }) =>
      RecurringSeries(
        id: id ?? base.id,
        groupKey: base.groupKey,
        periodKind: base.periodKind,
        amountCenterPaise: base.amountCenterPaise,
        amountMadPaise: base.amountMadPaise,
        occurrences: occurrences ?? base.occurrences,
        firstSeen: firstSeen ?? base.firstSeen,
        lastSeen: base.lastSeen,
        score: score ?? base.score,
        createdAt: base.createdAt,
        updatedAt: base.updatedAt,
        label: base.label,
        merchantName: base.merchantName,
        accountId: base.accountId,
        categoryPath: base.categoryPath,
        anchorDom: base.anchorDom,
        periodDays: base.periodDays,
        amountIsVariable: base.amountIsVariable,
        nextExpected: base.nextExpected,
        graceDays: base.graceDays,
        state: base.state,
        userConfirmed: base.userConfirmed,
        priceChanges: priceChanges ?? base.priceChanges,
      );

  /// The account is part of the key on purpose. The same Netflix charge moving
  /// from a card to a bank account is a change the user should see, not a
  /// silent continuation.
  static String groupKeyFor(Transaction txn) {
    final String merchant = Fingerprints.normalizeMerchant(
      txn.merchantName ?? txn.merchantRaw ?? txn.vpa,
    );
    return LedgerIds.hashParts(<Object?>[
      merchant.isEmpty ? 'path:${txn.categoryPath}' : merchant,
      txn.accountId ?? Account.normalizeTail(txn.accountTail ?? txn.cardTail) ?? '',
      txn.categoryPath,
    ]);
  }

  /// One-dimensional gap clustering.
  ///
  /// Gap-based rather than k-means because k is unknown, and because k-means
  /// would split a genuine price increase into two unrelated series. Clusters
  /// smaller than three occurrences are dropped by the caller, not here.
  static List<List<Transaction>> clusterByAmount(List<Transaction> rows) {
    if (rows.isEmpty) return const <List<Transaction>>[];
    final List<Transaction> sorted = List<Transaction>.of(rows)
      ..sort((Transaction a, Transaction b) =>
          a.amount.abs.paise.compareTo(b.amount.abs.paise));
    final List<List<Transaction>> clusters = <List<Transaction>>[];
    List<Transaction> current = <Transaction>[sorted.first];
    for (int i = 1; i < sorted.length; i++) {
      final int prev = sorted[i - 1].amount.abs.paise;
      final int here = sorted[i].amount.abs.paise;
      final double allowed = prev * 0.08 < 200 ? 200 : prev * 0.08;
      if (here - prev > allowed) {
        clusters.add(current);
        current = <Transaction>[sorted[i]];
      } else {
        current.add(sorted[i]);
      }
    }
    clusters.add(current);
    final List<List<Transaction>> kept = <List<Transaction>>[];
    for (final List<Transaction> c in clusters) {
      if (c.length < 3) continue;
      c.sort((Transaction a, Transaction b) => a.occurredAt.compareTo(b.occurredAt));
      kept.add(c);
    }
    return kept;
  }

  /// Day-of-month first, then fixed interval. Returns
  /// [PeriodKind.irregular] when neither fits - groceries, for example, which
  /// are frequent but not recurring.
  static PeriodDetection detectPeriod(List<DateTime> dates) {
    if (dates.length < 3) {
      return const PeriodDetection(PeriodKind.irregular, 0);
    }
    final List<DateTime> sorted = List<DateTime>.of(dates)
      ..sort((DateTime a, DateTime b) => a.compareTo(b));
    final List<int> gaps = <int>[
      for (int i = 1; i < sorted.length; i++)
        sorted[i].difference(sorted[i - 1]).inDays,
    ];
    final double medianGap = _median(gaps.map((int g) => g.toDouble()).toList());

    // Test 1: day-of-month anchored.
    final List<int> doms = <int>[
      for (final DateTime d in sorted) d.toLocal().day,
    ];
    final int spread = _rotationalSpread(doms);
    if (spread <= 3 && medianGap >= 26 && medianGap <= 35) {
      return PeriodDetection(
        PeriodKind.monthlyDom,
        (1 - spread / 6).clamp(0, 1).toDouble(),
        anchorDom: _median(doms.map((int d) => d.toDouble()).toList()).round(),
        periodDays: 30.44,
      );
    }

    // Test 2: fixed interval.
    if (medianGap <= 0) return const PeriodDetection(PeriodKind.irregular, 0);
    final double mad = _mad(gaps.map((int g) => g.toDouble()).toList());
    final double regularity = (1 - (mad / medianGap).clamp(0, 1)).toDouble();
    if (regularity < 0.82) return const PeriodDetection(PeriodKind.irregular, 0);
    final PeriodKind kind = _kindForDays(medianGap);
    if (kind == PeriodKind.irregular) {
      return const PeriodDetection(PeriodKind.irregular, 0);
    }
    return PeriodDetection(kind, regularity, periodDays: medianGap);
  }

  /// When the next charge is due, and how much slack to allow before saying
  /// anything.
  static DateTime nextExpected(
    DateTime lastSeen,
    PeriodKind kind, {
    int? anchorDom,
    double? periodDays,
  }) {
    if (kind == PeriodKind.monthlyDom) {
      final DateTime local = lastSeen.toLocal();
      final int dom = anchorDom ?? local.day;
      final int month = local.month == 12 ? 1 : local.month + 1;
      final int year = local.month == 12 ? local.year + 1 : local.year;
      final int lastDay = DateTime(year, month + 1, 0).day;
      return DateTime(year, month, dom > lastDay ? lastDay : dom);
    }
    final double days = periodDays ?? kind.approximateDays;
    if (days <= 0) return lastSeen;
    return lastSeen.add(Duration(days: days.round()));
  }

  /// A mandate SMS is ground truth about the future. Making the user wait
  /// three months for pattern inference would be a self-inflicted wound, so a
  /// UPI Autopay or NACH pre-debit notice creates a confirmed series at the
  /// very first message.
  static RecurringSeries fromMandate({
    required String label,
    required Money amount,
    required DateTime firstCharge,
    required DateTime now,
    String? merchantName,
    String? accountId,
    String? categoryPath,
  }) {
    final String key = LedgerIds.hashParts(<Object?>[
      'mandate',
      Fingerprints.normalizeMerchant(merchantName ?? label),
      accountId ?? '',
    ]);
    return RecurringSeries(
      id: key,
      groupKey: key,
      periodKind: PeriodKind.monthlyDom,
      amountCenterPaise: amount.abs.paise,
      amountMadPaise: 0,
      occurrences: 0,
      firstSeen: firstCharge,
      lastSeen: firstCharge,
      score: 1,
      createdAt: now,
      updatedAt: now,
      label: label,
      merchantName: merchantName,
      accountId: accountId,
      categoryPath: categoryPath,
      anchorDom: firstCharge.toLocal().day,
      periodDays: 30.44,
      nextExpected: firstCharge,
      userConfirmed: true,
    );
  }

  /// State from the calendar alone, so it is always re-derivable.
  static SeriesState stateAt(RecurringSeries series, DateTime now) {
    if (series.state == SeriesState.paused ||
        series.state == SeriesState.cancelled) {
      return series.state;
    }
    final DateTime? next = series.nextExpected;
    if (next == null) return SeriesState.active;
    final DateTime grace = next.add(Duration(days: series.graceDays));
    if (!now.isAfter(grace)) return SeriesState.active;
    final double period = series.periodDays ?? series.periodKind.approximateDays;
    if (period > 0 && now.difference(next).inDays > period + series.graceDays) {
      return SeriesState.ended;
    }
    return SeriesState.atRisk;
  }

  static RecurringSeries? _seriesFrom(
    String groupKey,
    List<Transaction> cluster, {
    required DateTime now,
    required Set<String> knownBillerMerchants,
  }) {
    if (cluster.length < 3) return null;
    final List<int> amounts = <int>[
      for (final Transaction t in cluster) t.amount.abs.paise,
    ];
    final double centre = _median(amounts.map((int a) => a.toDouble()).toList());
    final double mad = _mad(amounts.map((int a) => a.toDouble()).toList());
    final double cv = centre == 0 ? 1 : mad / centre;

    final PeriodDetection period = detectPeriod(
      <DateTime>[for (final Transaction t in cluster) t.occurredAt],
    );
    if (period.kind == PeriodKind.irregular) return null;

    final Transaction last = cluster.last;
    final String merchant = last.merchantName ?? last.merchantRaw ?? '';
    final double merchantPrior = knownBillerMerchants
            .contains(Fingerprints.normalizeMerchant(merchant))
        ? 1.0
        : (last.channel == TxnChannel.nach ? 0.6 : 0.3);
    final double amountStability = (1 - (cv / 0.30).clamp(0, 1)).toDouble();
    final double occurrenceScore =
        ((cluster.length - 2) / 4).clamp(0, 1).toDouble();
    final DateTime next = nextExpected(
      last.occurredAt,
      period.kind,
      anchorDom: period.anchorDom,
      periodDays: period.periodDays,
    );
    final int graceDays = _graceFor(period);
    final double recency = now.isAfter(next.add(Duration(days: graceDays)))
        ? 0.3
        : 1.0;

    final double score = 0.30 * period.regularity +
        0.20 * amountStability +
        0.15 * occurrenceScore +
        0.25 * merchantPrior +
        0.10 * recency;

    final RecurringSeries series = RecurringSeries(
      id: groupKey,
      groupKey: groupKey,
      periodKind: period.kind,
      amountCenterPaise: centre.round(),
      amountMadPaise: mad.round(),
      occurrences: cluster.length,
      firstSeen: cluster.first.occurredAt,
      lastSeen: last.occurredAt,
      score: score.clamp(0, 1).toDouble(),
      createdAt: now,
      updatedAt: now,
      label: merchant.isEmpty ? last.categoryPath : merchant,
      merchantName: last.merchantName,
      accountId: last.accountId,
      categoryPath: last.categoryPath,
      anchorDom: period.anchorDom,
      periodDays: period.periodDays,
      amountIsVariable: cv > 0.15,
      nextExpected: next,
      graceDays: graceDays,
    );
    return series.copyWith(state: stateAt(series, now));
  }

  static int _graceFor(PeriodDetection period) {
    final double days = period.periodDays ?? period.kind.approximateDays;
    final int computed = (days * 0.15).round();
    return computed < 3 ? 3 : computed;
  }

  static PeriodKind _kindForDays(double days) {
    if (days >= 6 && days <= 8) return PeriodKind.weekly;
    if (days >= 13 && days <= 16) return PeriodKind.fortnightly;
    if (days >= 26 && days <= 35) return PeriodKind.monthly;
    if (days >= 85 && days <= 95) return PeriodKind.quarterly;
    if (days >= 175 && days <= 190) return PeriodKind.halfYearly;
    if (days >= 355 && days <= 375) return PeriodKind.yearly;
    return PeriodKind.irregular;
  }

  /// The smallest range the days-of-month occupy once the month boundary is
  /// allowed to rotate, so the 30th, 31st and 1st read as three days apart
  /// rather than thirty.
  static int _rotationalSpread(List<int> doms) {
    int best = 31;
    for (int r = 0; r < 31; r++) {
      int lo = 31;
      int hi = 0;
      for (final int d in doms) {
        final int v = (d - 1 + r) % 31;
        if (v < lo) lo = v;
        if (v > hi) hi = v;
      }
      final int spread = hi - lo;
      if (spread < best) best = spread;
    }
    return best;
  }

  static double _median(List<double> values) {
    if (values.isEmpty) return 0;
    final List<double> sorted = List<double>.of(values)..sort();
    final int mid = sorted.length ~/ 2;
    if (sorted.length.isOdd) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2;
  }

  static double _mad(List<double> values) {
    if (values.isEmpty) return 0;
    final double centre = _median(values);
    return _median(<double>[
      for (final double v in values) (v - centre).abs(),
    ]);
  }
}

/// The outcome of period detection.
@immutable
class PeriodDetection {
  const PeriodDetection(
    this.kind,
    this.regularity, {
    this.anchorDom,
    this.periodDays,
  });

  final PeriodKind kind;

  /// 0.0 - 1.0. How evenly spaced the charges are.
  final double regularity;

  final int? anchorDom;
  final double? periodDays;

  @override
  String toString() =>
      'PeriodDetection(${kind.wire}, ${regularity.toStringAsFixed(2)})';
}
