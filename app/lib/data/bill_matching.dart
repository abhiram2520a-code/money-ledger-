import 'package:flutter/foundation.dart';
import 'package:ledger/models/models.dart';

import 'fingerprints.dart';
import 'postings.dart';

/// The link between a bill and the transaction that settled it.
///
/// `amountPaid` on a bill is always RE-DERIVED from these rows and never
/// incremented, which is what makes it idempotent under a re-import and under
/// a re-parse.
@immutable
class BillPayment {
  const BillPayment({
    required this.billId,
    required this.txnId,
    required this.appliedPaise,
    required this.confidence,
    required this.reason,
    required this.createdAt,
    this.byUser = false,
  });

  factory BillPayment.fromJson(Map<String, dynamic> json) => BillPayment(
        billId: jString(json['billId']),
        txnId: jString(json['txnId']),
        appliedPaise: jInt(json['appliedPaise']),
        confidence: jDouble(json['confidence']),
        reason: jString(json['reason']),
        createdAt: jDate(json['createdAt']),
        byUser: jBool(json['byUser']),
      );

  final String billId;
  final String txnId;

  /// How much of this transaction was applied to this bill. A single payment
  /// can be larger than what is left owing.
  final int appliedPaise;

  final double confidence;
  final String reason;
  final DateTime createdAt;
  final bool byUser;

  /// One transaction settles at most one bill, so the transaction id is the
  /// row's identity.
  String get id => txnId;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'billId': billId,
        'txnId': txnId,
        'appliedPaise': appliedPaise,
        'confidence': confidence,
        'reason': reason,
        'createdAt': jMillis(createdAt),
        'byUser': byUser,
      };

  @override
  String toString() => 'BillPayment($billId <- $txnId, $appliedPaise)';
}

/// How a candidate payment relates to the amount that was due.
enum BillMatchTag {
  full,
  partial,
  minimumDue,
  overpay,
}

/// A scored candidate payment for one bill.
@immutable
class BillMatch {
  const BillMatch({
    required this.bill,
    required this.txn,
    required this.score,
    required this.tag,
    required this.appliedPaise,
    required this.reason,
  });

  final Bill bill;
  final Transaction txn;
  final double score;
  final BillMatchTag tag;
  final int appliedPaise;
  final String reason;

  bool get canAutoLink => score >= BillMatcher.autoLinkThreshold;

  bool get worthAsking => score >= BillMatcher.askThreshold && !canAutoLink;

  @override
  String toString() =>
      'BillMatch(${bill.id} <- ${txn.id}, ${score.toStringAsFixed(2)}, $tag)';
}

/// Matches bills to the transactions that paid them.
///
/// The framing rule that prevents the next double-count: **a bill is not a
/// transaction**. A bill creates no postings at all. Only the matched payment
/// posts - and when the bill is a credit-card statement, that payment is a
/// transfer, so the card's spends are still counted exactly once.
abstract final class BillMatcher {
  /// Linked without asking.
  static const double autoLinkThreshold = 0.82;

  /// Worth a one-tap confirmation.
  static const double askThreshold = 0.60;

  /// When two bills score within this of each other for one transaction, the
  /// app asks instead of guessing. Two cards from the same issuer with the
  /// same amount due is not a rare shape.
  static const double contentionMargin = 0.05;

  /// Rounding slack when comparing an amount paid to an amount due.
  static const int tolerancePaise = 100;

  /// Could [txn] possibly be a payment of [bill]?
  ///
  /// A POS swipe or an ATM withdrawal is never a bill payment, however well
  /// the amount happens to line up.
  static bool isCandidate(Bill bill, Transaction txn) {
    if (bill.isPaid && bill.paidTxnId == txn.id) return false;
    if (!txn.status.countsInTotals) return false;
    if (!txn.direction.isDebit && !PostingEngine.isCardBillPayment(txn)) return false;
    if (txn.channel == TxnChannel.atm || txn.channel == TxnChannel.cash) return false;
    if (txn.billId != null && txn.billId != bill.id) return false;
    final DateTime start = windowStart(bill);
    final DateTime end = windowEnd(bill);
    return !txn.occurredAt.isBefore(start) && !txn.occurredAt.isAfter(end);
  }

  static DateTime windowStart(Bill bill) =>
      bill.createdAt.subtract(const Duration(days: 2));

  static DateTime windowEnd(Bill bill) =>
      bill.dueDate.add(const Duration(days: 10));

  /// Scores one candidate. Returns `null` when the amount rules it out.
  static BillMatch? score(Bill bill, Transaction txn, {int alreadyPaidPaise = 0}) {
    if (!isCandidate(bill, txn)) return null;

    final _AmountScore? amount = _scoreAmount(bill, txn);
    if (amount == null) return null;

    final _Scored biller = _scoreBiller(bill, txn);
    final double date = _scoreDate(bill, txn);
    final double rail = _scoreRail(txn);
    final double account = _scoreAccount(bill, txn);

    double total = 0.45 * amount.value +
        0.25 * biller.value +
        0.15 * date +
        0.10 * rail +
        0.05 * account;

    // A bill whose amount was never stated cannot be auto-linked: there is
    // nothing to check the payment against.
    if (bill.amountDue == null && total >= autoLinkThreshold) {
      total = autoLinkThreshold - 0.01;
    }

    final int due = bill.amountDue?.abs.paise ?? txn.amount.abs.paise;
    final int remaining = (due - alreadyPaidPaise).clamp(0, due).toInt();
    final int applied = txn.amount.abs.paise < remaining
        ? txn.amount.abs.paise
        : (remaining == 0 ? txn.amount.abs.paise : remaining);

    return BillMatch(
      bill: bill,
      txn: txn,
      score: total.clamp(0, 1).toDouble(),
      tag: amount.tag,
      appliedPaise: applied,
      reason: '${amount.reason}; ${biller.reason}',
    );
  }

  /// The best candidate for [bill], honouring contention.
  ///
  /// When the top two are within [contentionMargin] the winner is still
  /// returned, but with its score pulled below [autoLinkThreshold] so the UI
  /// asks. Silently picking one of two equally good cards is how a user's card
  /// payment lands on the wrong statement.
  static BillMatch? best(
    Bill bill,
    Iterable<Transaction> candidates, {
    int alreadyPaidPaise = 0,
  }) {
    final List<BillMatch> scored = <BillMatch>[
      for (final Transaction t in candidates)
        if (score(bill, t, alreadyPaidPaise: alreadyPaidPaise) case final BillMatch m)
          m,
    ]..sort((BillMatch a, BillMatch b) => b.score.compareTo(a.score));
    if (scored.isEmpty) return null;
    final BillMatch top = scored.first;
    if (scored.length > 1 && (top.score - scored[1].score) < contentionMargin) {
      return BillMatch(
        bill: top.bill,
        txn: top.txn,
        score: autoLinkThreshold - 0.01,
        tag: top.tag,
        appliedPaise: top.appliedPaise,
        reason: '${top.reason}; another payment fits just as well',
      );
    }
    return top;
  }

  static _AmountScore? _scoreAmount(Bill bill, Transaction txn) {
    final Money? due = bill.amountDue;
    final int paid = txn.amount.abs.paise;
    if (due == null) {
      return const _AmountScore(0.5, 'amount not stated on the bill', BillMatchTag.full);
    }
    final int duePaise = due.abs.paise;
    if (duePaise <= 0) return null;
    if (paid == duePaise) {
      return const _AmountScore(1, 'exact amount', BillMatchTag.full);
    }
    if ((paid - duePaise).abs() <= tolerancePaise) {
      return const _AmountScore(0.95, 'amount matches to the rupee', BillMatchTag.full);
    }
    final Money? minimum = bill.minimumDue;
    if (minimum != null && paid == minimum.abs.paise) {
      return const _AmountScore(0.85, 'minimum due', BillMatchTag.minimumDue);
    }
    if ((paid - duePaise).abs() * 200 <= duePaise) {
      return const _AmountScore(0.8, 'amount within half a percent', BillMatchTag.full);
    }
    if (paid < duePaise && paid * 10 >= duePaise) {
      return const _AmountScore(0.55, 'part of the amount due', BillMatchTag.partial);
    }
    if (paid > duePaise && paid * 100 <= duePaise * 110) {
      return const _AmountScore(0.7, 'slightly more than due', BillMatchTag.overpay);
    }
    return null;
  }

  static _Scored _scoreBiller(Bill bill, Transaction txn) {
    final String? billAccount = bill.accountId;
    if (billAccount != null && billAccount == txn.accountId) {
      return const _Scored(1, 'paid from the account this bill belongs to');
    }
    final String? billCard = Account.normalizeTail(bill.cardTail);
    final String? txnCard = Account.normalizeTail(txn.cardTail);
    if (billCard != null && billCard == txnCard) {
      return const _Scored(1, 'same card');
    }
    final String billMerchant = Fingerprints.normalizeMerchant(bill.merchantName);
    final String txnMerchant =
        Fingerprints.normalizeMerchant(txn.merchantName ?? txn.merchantRaw);
    if (billMerchant.isNotEmpty && billMerchant == txnMerchant) {
      return const _Scored(1, 'same biller');
    }
    final String? billTail = Account.normalizeTail(bill.accountTail);
    final String? txnTail = Account.normalizeTail(txn.accountTail);
    if (billTail != null && billTail == txnTail) {
      return const _Scored(0.95, 'same account number');
    }
    if (billMerchant.isNotEmpty && txnMerchant.isNotEmpty) {
      final double j = _jaccard(billMerchant, txnMerchant);
      if (j >= 0.6) {
        return const _Scored(0.8, 'biller name is a close match');
      }
    }
    final String? vpa = txn.vpa?.toLowerCase();
    final String? issuer = bill.issuer?.toLowerCase();
    if (vpa != null && issuer != null && issuer.isNotEmpty && vpa.contains(issuer)) {
      return const _Scored(0.85, 'paid to the biller handle');
    }
    return const _Scored(0.2, 'biller not confirmed');
  }

  static double _scoreDate(Bill bill, Transaction txn) {
    final DateTime start = windowStart(bill);
    final DateTime due = bill.dueDate;
    final DateTime when = txn.occurredAt;
    if (!when.isBefore(start) && !when.isAfter(due)) {
      final int span = due.difference(start).inMinutes.abs();
      if (span == 0) return 1;
      final int centre = start.millisecondsSinceEpoch +
          (due.millisecondsSinceEpoch - start.millisecondsSinceEpoch) ~/ 2;
      final double off =
          (when.millisecondsSinceEpoch - centre).abs() / (span * 60000 / 2);
      return 0.70 + 0.30 * (1 - off.clamp(0, 1));
    }
    final int daysLate = when.difference(due).inDays.abs();
    return (1 - daysLate / 10).clamp(0, 1).toDouble();
  }

  static double _scoreRail(Transaction txn) => switch (txn.channel) {
        TxnChannel.upi ||
        TxnChannel.netbanking ||
        TxnChannel.nach ||
        TxnChannel.impsNeft =>
          1,
        TxnChannel.card => 0.3,
        TxnChannel.unknown => 0.5,
        TxnChannel.atm || TxnChannel.cash => 0,
      };

  static double _scoreAccount(Bill bill, Transaction txn) {
    final String? billAccount = bill.accountId;
    if (billAccount == null || txn.accountId == null) return 0.5;
    return billAccount == txn.accountId ? 1 : 0.5;
  }

  static double _jaccard(String a, String b) {
    final Set<String> sa = a.split(' ').where((String s) => s.isNotEmpty).toSet();
    final Set<String> sb = b.split(' ').where((String s) => s.isNotEmpty).toSet();
    if (sa.isEmpty || sb.isEmpty) return 0;
    final int inter = sa.intersection(sb).length;
    final int union = sa.union(sb).length;
    return union == 0 ? 0 : inter / union;
  }
}

/// The bill state machine.
///
/// Every transition is a pure function of `(amount paid, due date, today,
/// user action)`, so the state is always re-derivable. That is why bills need
/// no repair job after a re-import: recomputing from the payment rows gives
/// the same answer as the first time.
abstract final class BillLifecycle {
  /// The status [bill] should have, given how much has been applied to it.
  static BillStatus statusFor(
    Bill bill, {
    required int paidPaise,
    required DateTime now,
  }) {
    if (bill.status == BillStatus.skipped) return BillStatus.skipped;
    final Money? due = bill.amountDue;
    if (due != null && due.abs.paise > 0) {
      if (paidPaise >= due.abs.paise - BillMatcher.tolerancePaise) {
        return BillStatus.paid;
      }
    } else if (paidPaise > 0) {
      // No stated amount: any matched payment settles it.
      return BillStatus.paid;
    }
    // Partially paid bills keep their due/overdue urgency; the remaining
    // amount is what the UI shows. Recomputed from the due date rather than
    // from the stored status, so a re-import cannot leave a bill stuck.
    final int days = bill.daysUntilDue(now);
    if (days < 0) return BillStatus.overdue;
    if (days <= bill.notifyDaysBefore) return BillStatus.due;
    return BillStatus.upcoming;
  }

  /// How much is still owed.
  static Money remaining(Bill bill, {required int paidPaise}) {
    final Money? due = bill.amountDue;
    if (due == null) return Money.zero;
    final int left = due.abs.paise - paidPaise;
    return Money(left < 0 ? 0 : left);
  }

  /// True when the user paid only the card's minimum. Worth saying out loud:
  /// it is one of the few places an expense app can save someone real money.
  static bool isMinimumOnly(Bill bill, {required int paidPaise}) {
    final Money? minimum = bill.minimumDue;
    final Money? due = bill.amountDue;
    if (minimum == null || due == null) return false;
    if (due.abs.paise <= minimum.abs.paise) return false;
    return (paidPaise - minimum.abs.paise).abs() <= BillMatcher.tolerancePaise;
  }

  /// A bill that is past due with nothing matched, where the app expected an
  /// autopay to fire. Catches the silent failures where the bank sends
  /// nothing at all.
  static bool looksLikeFailedAutopay(
    Bill bill, {
    required int paidPaise,
    required DateTime now,
    required bool autopay,
  }) {
    if (!autopay || paidPaise > 0) return false;
    return now.isAfter(bill.dueDate.add(const Duration(days: 1)));
  }
}

@immutable
class _Scored {
  const _Scored(this.value, this.reason);

  final double value;
  final String reason;
}

@immutable
class _AmountScore extends _Scored {
  const _AmountScore(super.value, super.reason, this.tag);

  final BillMatchTag tag;
}
