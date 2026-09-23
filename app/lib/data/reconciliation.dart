import 'package:flutter/foundation.dart';
import 'package:ledger/models/models.dart';

import 'ids.dart';
import 'postings.dart';

/// What quantity a bank message actually stated.
///
/// Indian bank SMS state five different numbers and call three of them
/// "balance". Getting them into one sign space is most of this engine's work.
enum AssertionKind {
  /// `Avl Bal`, `Available balance`, `Bal Rs.` on an ASSET account.
  availableBalance('available_balance'),

  /// `Ledger bal`, `Total bal`. Preferred when both are present.
  ledgerBalance('ledger_balance'),

  /// `Avl Lmt` on a card. Without the credit limit this is only usable as a
  /// delta - which is enough, because the limit is a constant that cancels.
  availableLimit('available_limit'),

  /// `Total Amt Due`, `Outstanding` on a card.
  outstanding('outstanding'),

  /// `Credit limit`. Not a balance at all; it configures the account.
  totalLimit('total_limit');

  const AssertionKind(this.wire);

  final String wire;

  static AssertionKind fromWire(String? wire) {
    for (final AssertionKind v in AssertionKind.values) {
      if (v.wire == wire) return v;
    }
    return AssertionKind.availableBalance;
  }

  /// Two assertions of different bases must never be compared to each other.
  String get basis => switch (this) {
        AssertionKind.availableBalance => 'available',
        AssertionKind.ledgerBalance => 'ledger',
        AssertionKind.availableLimit => 'limit',
        AssertionKind.outstanding => 'outstanding',
        AssertionKind.totalLimit => 'config',
      };
}

/// A balance the bank stated, stored exactly as it arrived.
///
/// This is the only independent check on the parser that exists, and it is
/// free: every competitor throws it away. Keeping it is what lets the app say
/// "we may have missed something" instead of quietly being wrong.
@immutable
class BalanceAssertion {
  const BalanceAssertion({
    required this.id,
    required this.accountId,
    required this.kind,
    required this.statedPaise,
    required this.ledgerPaise,
    required this.asOf,
    required this.createdAt,
    this.basisUnknown = false,
    this.precedence = 1,
    this.trusted = true,
    this.txnId,
    this.rawMessageId,
  });

  factory BalanceAssertion.fromJson(Map<String, dynamic> json) => BalanceAssertion(
        id: jString(json['id']),
        accountId: jString(json['accountId']),
        kind: AssertionKind.fromWire(jStringOrNull(json['kind'])),
        statedPaise: jInt(json['statedPaise']),
        ledgerPaise: jInt(json['ledgerPaise']),
        asOf: jDate(json['asOf']),
        createdAt: jDate(json['createdAt']),
        basisUnknown: jBool(json['basisUnknown']),
        precedence: jInt(json['precedence'], fallback: 1),
        trusted: jBool(json['trusted'], fallback: true),
        txnId: jStringOrNull(json['txnId']),
        rawMessageId: jStringOrNull(json['rawMessageId']),
      );

  final String id;
  final String accountId;
  final AssertionKind kind;

  /// Exactly what the message said, unsigned.
  final int statedPaise;

  /// [statedPaise] moved into the same sign space as a posting sum.
  final int ledgerPaise;

  final DateTime asOf;
  final DateTime createdAt;

  /// True when the absolute value cannot be trusted but deltas still can -
  /// an available limit with no known credit limit.
  final bool basisUnknown;

  /// `1` when the balance was stated AFTER the transaction at [asOf]; `0` for
  /// a standalone balance enquiry. This is what decides which side of a window
  /// boundary a posting at the same instant falls on.
  final int precedence;

  final bool trusted;
  final String? txnId;
  final String? rawMessageId;

  BalanceAssertion copyWith({
    String? id,
    int? ledgerPaise,
    bool? basisUnknown,
    bool? trusted,
  }) =>
      BalanceAssertion(
        id: id ?? this.id,
        accountId: accountId,
        kind: kind,
        statedPaise: statedPaise,
        ledgerPaise: ledgerPaise ?? this.ledgerPaise,
        asOf: asOf,
        createdAt: createdAt,
        basisUnknown: basisUnknown ?? this.basisUnknown,
        precedence: precedence,
        trusted: trusted ?? this.trusted,
        txnId: txnId,
        rawMessageId: rawMessageId,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'accountId': accountId,
        'kind': kind.wire,
        'statedPaise': statedPaise,
        'ledgerPaise': ledgerPaise,
        'asOf': jMillis(asOf),
        'createdAt': jMillis(createdAt),
        'basisUnknown': basisUnknown,
        'precedence': precedence,
        'trusted': trusted,
        'txnId': txnId,
        'rawMessageId': rawMessageId,
      };

  @override
  String toString() => 'BalanceAssertion($accountId, ${kind.wire}, $ledgerPaise @ $asOf)';
}

enum ReconVerdict { clean, drift, unverifiable }

enum DriftDirection {
  /// The bank's balance fell more than the postings explain: money left and we
  /// did not see it.
  missingDebit('missing_debit'),

  /// Money arrived that we never saw.
  missingCredit('missing_credit');

  const DriftDirection(this.wire);

  final String wire;

  static DriftDirection fromWire(String? wire) =>
      wire == DriftDirection.missingCredit.wire
          ? DriftDirection.missingCredit
          : DriftDirection.missingDebit;
}

enum DriftState {
  open('open'),
  resolvedTxn('resolved_txn'),
  resolvedPlug('resolved_plug'),
  ignored('ignored'),
  superseded('superseded');

  const DriftState(this.wire);

  final String wire;

  static DriftState fromWire(String? wire) {
    for (final DriftState v in DriftState.values) {
      if (v.wire == wire) return v;
    }
    return DriftState.open;
  }
}

/// One head-to-tail comparison between two balances the bank stated.
@immutable
class ReconWindow {
  const ReconWindow({
    required this.accountId,
    required this.verdict,
    this.start,
    this.end,
    this.headAssertionId,
    this.tailAssertionId,
    this.expectedDeltaPaise = 0,
    this.computedDeltaPaise = 0,
    this.driftPaise = 0,
    this.unverifiableReason,
  });

  final String accountId;
  final ReconVerdict verdict;
  final DateTime? start;
  final DateTime? end;
  final String? headAssertionId;
  final String? tailAssertionId;

  /// What the bank says happened between the two balances.
  final int expectedDeltaPaise;

  /// What our postings say happened.
  final int computedDeltaPaise;

  /// `expected - computed`. Negative means money left that we never recorded.
  final int driftPaise;

  final String? unverifiableReason;

  DriftDirection get direction =>
      driftPaise < 0 ? DriftDirection.missingDebit : DriftDirection.missingCredit;

  Money get drift => Money(driftPaise.abs());

  /// Stable across re-runs, so re-reconciling the same window updates the same
  /// row instead of creating a second card for one gap.
  String get windowKey => LedgerIds.hashParts(<Object?>[
        accountId,
        headAssertionId ?? '',
        tailAssertionId ?? '',
      ]);

  @override
  String toString() => 'ReconWindow($accountId, $verdict, drift=$driftPaise)';
}

/// A ranked guess at what a drift actually was.
@immutable
class DriftHypothesis {
  const DriftHypothesis({
    required this.kind,
    required this.confidence,
    required this.message,
    this.amountPaise,
    this.referenceId,
    this.suggestedCategoryPath,
  });

  factory DriftHypothesis.fromJson(Map<String, dynamic> json) => DriftHypothesis(
        kind: jString(json['kind']),
        confidence: jDouble(json['confidence']),
        message: jString(json['message']),
        amountPaise: jIntOrNull(json['amountPaise']),
        referenceId: jStringOrNull(json['referenceId']),
        suggestedCategoryPath: jStringOrNull(json['suggestedCategoryPath']),
      );

  /// `quarantine_hit`, `known_recurring`, `fee_or_interest`, `round_cash`.
  final String kind;

  final double confidence;

  /// User-facing, and deliberately phrased as the app's fallibility.
  final String message;

  final int? amountPaise;

  /// The raw message or series this hypothesis points at.
  final String? referenceId;

  final String? suggestedCategoryPath;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'kind': kind,
        'confidence': confidence,
        'message': message,
        'amountPaise': amountPaise,
        'referenceId': referenceId,
        'suggestedCategoryPath': suggestedCategoryPath,
      };

  @override
  String toString() => 'DriftHypothesis($kind, ${confidence.toStringAsFixed(2)})';
}

/// A gap the app found in its own books, kept until it is explained.
@immutable
class DriftEvent {
  const DriftEvent({
    required this.id,
    required this.accountId,
    required this.windowKey,
    required this.windowStart,
    required this.windowEnd,
    required this.driftPaise,
    required this.direction,
    required this.createdAt,
    this.state = DriftState.open,
    this.hypotheses = const <DriftHypothesis>[],
    this.resolvedTxnId,
    this.resolvedAt,
  });

  factory DriftEvent.fromJson(Map<String, dynamic> json) => DriftEvent(
        id: jString(json['id']),
        accountId: jString(json['accountId']),
        windowKey: jString(json['windowKey']),
        windowStart: jDate(json['windowStart']),
        windowEnd: jDate(json['windowEnd']),
        driftPaise: jInt(json['driftPaise']),
        direction: DriftDirection.fromWire(jStringOrNull(json['direction'])),
        createdAt: jDate(json['createdAt']),
        state: DriftState.fromWire(jStringOrNull(json['state'])),
        hypotheses: <DriftHypothesis>[
          for (final Map<String, dynamic> h in jMapList(json['hypotheses']))
            DriftHypothesis.fromJson(h),
        ],
        resolvedTxnId: jStringOrNull(json['resolvedTxnId']),
        resolvedAt: jDateOrNull(json['resolvedAt']),
      );

  final String id;
  final String accountId;
  final String windowKey;
  final DateTime windowStart;
  final DateTime windowEnd;
  final int driftPaise;
  final DriftDirection direction;
  final DateTime createdAt;
  final DriftState state;
  final List<DriftHypothesis> hypotheses;
  final String? resolvedTxnId;
  final DateTime? resolvedAt;

  bool get isOpen => state == DriftState.open;

  Money get amount => Money(driftPaise.abs());

  DriftEvent copyWith({
    DriftState? state,
    List<DriftHypothesis>? hypotheses,
    String? resolvedTxnId,
    DateTime? resolvedAt,
  }) =>
      DriftEvent(
        id: id,
        accountId: accountId,
        windowKey: windowKey,
        windowStart: windowStart,
        windowEnd: windowEnd,
        driftPaise: driftPaise,
        direction: direction,
        createdAt: createdAt,
        state: state ?? this.state,
        hypotheses: hypotheses ?? this.hypotheses,
        resolvedTxnId: resolvedTxnId ?? this.resolvedTxnId,
        resolvedAt: resolvedAt ?? this.resolvedAt,
      );

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'accountId': accountId,
        'windowKey': windowKey,
        'windowStart': jMillis(windowStart),
        'windowEnd': jMillis(windowEnd),
        'driftPaise': driftPaise,
        'direction': direction.wire,
        'createdAt': jMillis(createdAt),
        'state': state.wire,
        'hypotheses': <Map<String, dynamic>>[
          for (final DriftHypothesis h in hypotheses) h.toJson(),
        ],
        'resolvedTxnId': resolvedTxnId,
        'resolvedAt': resolvedAt == null ? null : jMillis(resolvedAt!),
      };

  @override
  String toString() => 'DriftEvent($accountId, ${amount.format()}, ${state.wire})';
}

/// Turns "Avl Bal Rs X" into automatic error detection.
///
/// The idea in one line: between two balances the bank stated, the change in
/// the balance must equal the sum of the postings we recorded. When it does
/// not, we missed something - and we can say exactly how much and when.
///
/// The engine is delta-first on purpose. For a credit card the ledger balance
/// is `available limit - credit limit`, and the credit limit is a constant, so
/// the difference of two available limits equals the difference of two ledger
/// balances even when the limit itself is unknown.
abstract final class ReconciliationEngine {
  /// One rupee. Indian bank SMS are exact to the paisa; this absorbs nothing
  /// but rounding in the app's own percentage splits.
  ///
  /// Widening it is how this feature becomes useless: a fifty-paisa drift is a
  /// real missing entry, not noise.
  static const int tolerancePaise = 100;

  /// Moves a stated number into posting sign space.
  ///
  /// Returns `null` for [AssertionKind.totalLimit], which is configuration
  /// rather than a balance.
  static BalanceAssertion? normalize({
    required String id,
    required String accountId,
    required AssertionKind kind,
    required int statedPaise,
    required DateTime asOf,
    required DateTime now,
    int? creditLimitPaise,
    int precedence = 1,
    bool trusted = true,
    String? txnId,
    String? rawMessageId,
  }) {
    if (kind == AssertionKind.totalLimit) return null;

    int ledger = statedPaise;
    bool basisUnknown = false;
    if (kind == AssertionKind.outstanding) {
      // Money owed is a negative ledger balance on a liability.
      ledger = -statedPaise;
    } else if (kind == AssertionKind.availableLimit) {
      if (creditLimitPaise != null && creditLimitPaise > 0) {
        ledger = statedPaise - creditLimitPaise;
      } else {
        // The limit is a constant, so it cancels in every delta. Absolute
        // values from this assertion are not usable; deltas still are.
        basisUnknown = true;
      }
    }
    return BalanceAssertion(
      id: id,
      accountId: accountId,
      kind: kind,
      statedPaise: statedPaise,
      ledgerPaise: ledger,
      asOf: asOf,
      createdAt: now,
      basisUnknown: basisUnknown,
      precedence: precedence,
      trusted: trusted,
      txnId: txnId,
      rawMessageId: rawMessageId,
    );
  }

  /// Every window between consecutive trusted assertions on one account.
  ///
  /// Returns a single [ReconVerdict.unverifiable] window when the bank does
  /// not put balances in its messages at all. That is a real and common case -
  /// and suppressing every drift affordance for such an account is worth more
  /// than the coverage, because a false alarm costs the user's trust.
  static List<ReconWindow> reconcile({
    required String accountId,
    required List<BalanceAssertion> assertions,
    required List<Posting> postings,
    int tolerance = tolerancePaise,
  }) {
    final List<BalanceAssertion> usable = <BalanceAssertion>[
      for (final BalanceAssertion a in assertions)
        if (a.trusted && a.accountId == accountId) a,
    ]..sort((BalanceAssertion a, BalanceAssertion b) {
        final int t = a.asOf.compareTo(b.asOf);
        return t != 0 ? t : a.precedence.compareTo(b.precedence);
      });

    final List<BalanceAssertion> sameBasis = _largestBasisRun(usable);
    if (sameBasis.length < 2) {
      return <ReconWindow>[
        ReconWindow(
          accountId: accountId,
          verdict: ReconVerdict.unverifiable,
          unverifiableReason: usable.isEmpty
              ? 'This bank does not put your balance in its messages.'
              : 'Only one balance so far - nothing to compare it against yet.',
        ),
      ];
    }

    final List<Posting> ours = <Posting>[
      for (final Posting p in postings)
        if (p.accountId == accountId) p,
    ];

    final List<ReconWindow> out = <ReconWindow>[];
    for (int i = 0; i + 1 < sameBasis.length; i++) {
      final BalanceAssertion head = sameBasis[i];
      final BalanceAssertion tail = sameBasis[i + 1];
      final int expected = tail.ledgerPaise - head.ledgerPaise;
      final int computed = sumBetween(ours, head, tail);
      final int drift = expected - computed;
      out.add(
        ReconWindow(
          accountId: accountId,
          verdict: drift.abs() <= tolerance ? ReconVerdict.clean : ReconVerdict.drift,
          start: head.asOf,
          end: tail.asOf,
          headAssertionId: head.id,
          tailAssertionId: tail.id,
          expectedDeltaPaise: expected,
          computedDeltaPaise: computed,
          driftPaise: drift,
        ),
      );
    }
    return out;
  }

  /// Sum of postings strictly inside the half-open window `(head, tail]`.
  ///
  /// Precedence settles the only ambiguity: a posting and a balance stated at
  /// the same instant. `precedence == 1` means "stated after that posting", so
  /// the posting belongs on the head's side of a head boundary and inside the
  /// window at a tail boundary.
  static int sumBetween(
    List<Posting> postings,
    BalanceAssertion head,
    BalanceAssertion tail,
  ) {
    int total = 0;
    for (final Posting p in postings) {
      final int t = p.occurredAt.millisecondsSinceEpoch;
      final int h = head.asOf.millisecondsSinceEpoch;
      final int e = tail.asOf.millisecondsSinceEpoch;
      final bool afterHead = t > h || (t == h && head.precedence == 0);
      final bool beforeTail = t < e || (t == e && tail.precedence == 1);
      if (afterHead && beforeTail) total += p.amountPaise;
    }
    return total;
  }

  /// The opening entry that turns a delta-verified account into a displayable
  /// balance. Anchor at the OLDEST assertion and verify forward, so a twelve
  /// month backfill checks its own history instead of assuming it.
  static int openingAdjustmentPaise({
    required BalanceAssertion anchor,
    required List<Posting> postings,
  }) {
    int before = 0;
    for (final Posting p in postings) {
      if (p.accountId != anchor.accountId) continue;
      if (p.occurredAt.millisecondsSinceEpoch <= anchor.asOf.millisecondsSinceEpoch) {
        before += p.amountPaise;
      }
    }
    return anchor.ledgerPaise - before;
  }

  /// Ranked explanations for a drift, best first.
  ///
  /// The highest-value one by far is [quarantined]: a message we received,
  /// could not read, and whose amount exactly explains the gap. That turns the
  /// parser's long tail from an invisible problem into a one-tap fix.
  static List<DriftHypothesis> hypotheses(
    ReconWindow window, {
    List<QuarantinedAmount> quarantined = const <QuarantinedAmount>[],
    List<ExpectedCharge> expected = const <ExpectedCharge>[],
    bool accountIsSavings = true,
  }) {
    if (window.verdict != ReconVerdict.drift) return const <DriftHypothesis>[];
    final int gap = window.driftPaise.abs();
    final List<DriftHypothesis> out = <DriftHypothesis>[];

    for (final QuarantinedAmount q in quarantined) {
      if (q.amountPaise != gap) continue;
      if (!_inWindow(q.receivedAt, window)) continue;
      out.add(
        DriftHypothesis(
          kind: 'quarantine_hit',
          confidence: 0.95,
          message: 'We got a message from your bank we could not read. '
              'Was this a ${Money(gap).format()} payment?',
          amountPaise: gap,
          referenceId: q.rawMessageId,
        ),
      );
    }

    for (final ExpectedCharge e in expected) {
      if (!_inWindow(e.expectedAt, window)) continue;
      final int slack = e.tolerancePaise;
      if ((e.amountPaise - gap).abs() > slack) continue;
      out.add(
        DriftHypothesis(
          kind: 'known_recurring',
          confidence: 0.85,
          message: 'Looks like your ${Money(e.amountPaise).format()} '
              '${e.label} - did it go through?',
          amountPaise: e.amountPaise,
          referenceId: e.seriesId,
          suggestedCategoryPath: e.categoryPath,
        ),
      );
    }

    if (window.direction == DriftDirection.missingDebit && _isGstFee(gap)) {
      out.add(
        DriftHypothesis(
          kind: 'fee_or_interest',
          confidence: 0.75,
          message: 'That is the size of a bank charge with GST on it.',
          amountPaise: gap,
          suggestedCategoryPath: 'fees_charges/bank_charges',
        ),
      );
    }

    if (window.direction == DriftDirection.missingCredit && accountIsSavings) {
      out.add(
        DriftHypothesis(
          kind: 'fee_or_interest',
          confidence: 0.5,
          message: 'Banks rarely message about savings interest. '
              'This may be interest credited to the account.',
          amountPaise: gap,
          suggestedCategoryPath: 'income/interest',
        ),
      );
    }

    if (window.direction == DriftDirection.missingDebit &&
        gap >= 50000 &&
        gap % 10000 == 0) {
      out.add(
        DriftHypothesis(
          kind: 'round_cash',
          confidence: 0.5,
          message: 'A round amount like this is usually cash from an ATM.',
          amountPaise: gap,
          suggestedCategoryPath: TransferPaths.atmWithdrawal,
        ),
      );
    }

    out.sort((DriftHypothesis a, DriftHypothesis b) =>
        b.confidence.compareTo(a.confidence));
    return out;
  }

  /// Builds the stored event for a drift window.
  static DriftEvent eventFor(
    ReconWindow window, {
    required DateTime now,
    List<DriftHypothesis> hypotheses = const <DriftHypothesis>[],
  }) {
    final DateTime start = window.start ?? now;
    final DateTime end = window.end ?? now;
    return DriftEvent(
      id: window.windowKey,
      accountId: window.accountId,
      windowKey: window.windowKey,
      windowStart: start,
      windowEnd: end,
      driftPaise: window.driftPaise,
      direction: window.direction,
      createdAt: now,
      hypotheses: hypotheses,
    );
  }

  /// The longest run of consecutive assertions that share a basis.
  ///
  /// Mixing an available balance with a ledger balance would manufacture a
  /// drift the size of the account's holds, every single time.
  static List<BalanceAssertion> _largestBasisRun(List<BalanceAssertion> sorted) {
    if (sorted.isEmpty) return const <BalanceAssertion>[];
    final Map<String, List<BalanceAssertion>> byBasis =
        <String, List<BalanceAssertion>>{};
    for (final BalanceAssertion a in sorted) {
      byBasis.putIfAbsent(a.kind.basis, () => <BalanceAssertion>[]).add(a);
    }
    List<BalanceAssertion> best = const <BalanceAssertion>[];
    for (final List<BalanceAssertion> run in byBasis.values) {
      if (run.length > best.length) best = run;
    }
    return best;
  }

  static bool _inWindow(DateTime when, ReconWindow window) {
    final DateTime? start = window.start;
    final DateTime? end = window.end;
    if (start == null || end == null) return false;
    return !when.isBefore(start) && !when.isAfter(end);
  }

  /// Indian bank fees are quoted ex-GST and charged with 18% on top, so the
  /// amount that actually hits the account is one of a small, recognisable
  /// set: ₹23.60, ₹29.50, ₹59, ₹118, ₹177, ₹236, ₹295, ₹590, ₹708.
  static bool _isGstFee(int paise) {
    const List<int> bases = <int>[2000, 2500, 5000, 10000, 15000, 20000, 25000, 50000, 60000];
    for (final int base in bases) {
      if ((base * 118) ~/ 100 == paise) return true;
    }
    return false;
  }
}

/// A message the parser could not read, reduced to the one fact that matters
/// for reconciliation: how much money it was about.
@immutable
class QuarantinedAmount {
  const QuarantinedAmount({
    required this.rawMessageId,
    required this.amountPaise,
    required this.receivedAt,
  });

  final String rawMessageId;
  final int amountPaise;
  final DateTime receivedAt;
}

/// A charge the app already expects - a recurring series or an autopay bill.
@immutable
class ExpectedCharge {
  const ExpectedCharge({
    required this.seriesId,
    required this.label,
    required this.amountPaise,
    required this.expectedAt,
    this.tolerancePaise = 0,
    this.categoryPath,
  });

  final String seriesId;
  final String label;
  final int amountPaise;
  final DateTime expectedAt;
  final int tolerancePaise;
  final String? categoryPath;
}
