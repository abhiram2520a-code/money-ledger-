import 'package:flutter/foundation.dart';
import 'package:ledger/models/models.dart';

import 'fingerprints.dart';
import 'postings.dart';

/// Why two transactions were judged to be the two halves of one movement.
@immutable
class TransferMatch {
  const TransferMatch({
    required this.other,
    required this.confidence,
    required this.reason,
  });

  final Transaction other;

  /// 0.0 - 1.0. Only [autoLinkThreshold] and above is linked without asking.
  final double confidence;

  final String reason;

  static const double autoLinkThreshold = 0.80;

  bool get canAutoLink => confidence >= autoLinkThreshold;

  @override
  String toString() =>
      'TransferMatch(${other.id}, ${confidence.toStringAsFixed(2)}, $reason)';
}

/// Pairs the two SMS of one movement of the user's own money.
///
/// A ₹50,000 HDFC to SBI transfer arrives as two unrelated messages from two
/// senders. Left unpaired, a single-entry app books ₹50,000 of expense and
/// ₹50,000 of income: net worth is accidentally right and every category
/// total is wrong. Paired, the two legs cancel through
/// [LedgerAccounts.inTransit] and the timeline shows one row.
///
/// The same predicate does the credit-card bill payment, where the bank says
/// "₹12,345 debited" and the card issuer says "payment received" - two
/// messages, one movement, zero expense.
abstract final class TransferMatcher {
  /// Self-transfers over UPI and IMPS land within minutes.
  static const Duration fastWindow = Duration(hours: 3);

  /// NEFT, RTGS, NACH and card bill payments can take days to be acknowledged
  /// by the other side.
  static const Duration slowWindow = Duration(hours: 72);

  /// Candidates worth examining at all: the opposite direction, the same
  /// amount, both moving the user's own money.
  static bool isCandidate(Transaction a, Transaction b) {
    if (a.id == b.id) return false;
    if (!a.isNetZero || !b.isNetZero) return false;
    if (a.status == TxnStatus.voided || b.status == TxnStatus.voided) return false;
    if (a.amount.abs.paise != b.amount.abs.paise) return false;
    if (a.direction == b.direction) return false;
    final String? groupA = a.transferGroupId;
    final String? groupB = b.transferGroupId;
    if (groupA != null && groupB != null && groupA != groupB) return false;
    if (groupA != null && groupA == groupB) return false;
    return a.occurredAt.difference(b.occurredAt).abs() <= windowFor(a, b);
  }

  static Duration windowFor(Transaction a, Transaction b) {
    const Set<TxnChannel> fast = <TxnChannel>{TxnChannel.upi, TxnChannel.card};
    final bool bothFast = fast.contains(a.channel) && fast.contains(b.channel);
    final bool cardBill =
        PostingEngine.isCardBillPayment(a) || PostingEngine.isCardBillPayment(b);
    return bothFast && !cardBill ? fastWindow : slowWindow;
  }

  /// Scores [a] against [b]. Returns `null` when they are not the two halves
  /// of one movement.
  ///
  /// The reference number is the strongest evidence there is: an RRN or a UTR
  /// identifies the movement itself, not the message. Tail cross-matching is
  /// next - the message that debits HDFC names the SBI account it sent to.
  static TransferMatch? score(Transaction a, Transaction b) {
    if (!isCandidate(a, b)) return null;

    final String? refA = _ref(a);
    final String? refB = _ref(b);
    if (refA != null && refA == refB) {
      return TransferMatch(
        other: b,
        confidence: 1,
        reason: 'Same reference $refA on both messages',
      );
    }

    // The debit message names the destination, and the credit message names
    // the source. Either direction of that cross-reference is conclusive
    // enough to link without asking.
    final String? tailA = Account.normalizeTail(a.accountTail ?? a.cardTail);
    final String? tailB = Account.normalizeTail(b.accountTail ?? b.cardTail);
    final String? cardA = Account.normalizeTail(a.cardTail);
    final String? cardB = Account.normalizeTail(b.cardTail);
    if (tailA != null && tailA == cardB && cardB != null) {
      return TransferMatch(
        other: b,
        confidence: 0.95,
        reason: 'One message names the account the other moved money to',
      );
    }
    if (tailB != null && tailB == cardA && cardA != null) {
      return TransferMatch(
        other: b,
        confidence: 0.95,
        reason: 'One message names the account the other moved money from',
      );
    }

    // A card bill payment seen from both sides: the bank debit and the
    // issuer's acknowledgement.
    final bool cardBill =
        PostingEngine.isCardBillPayment(a) || PostingEngine.isCardBillPayment(b);
    if (cardBill && (cardA != null || cardB != null) && cardA == cardB) {
      return TransferMatch(
        other: b,
        confidence: 0.9,
        reason: 'Both messages are about card ${cardA ?? cardB}',
      );
    }

    final String merchantA = Fingerprints.normalizeMerchant(a.merchantRaw ?? a.merchantName);
    final String merchantB = Fingerprints.normalizeMerchant(b.merchantRaw ?? b.merchantName);
    if (merchantA.isNotEmpty && merchantA == merchantB) {
      return TransferMatch(
        other: b,
        confidence: 0.75,
        reason: 'Same counterparty on both messages',
      );
    }

    // Same amount, opposite directions, inside the window, and nothing
    // contradicts it. Worth asking the user about; never worth doing silently.
    return TransferMatch(
      other: b,
      confidence: cardBill ? 0.7 : 0.6,
      reason: 'Same amount moved the other way within '
          '${windowFor(a, b).inHours}h',
    );
  }

  /// The best partner for [txn] among [pool], or `null`.
  static TransferMatch? findPartner(Transaction txn, Iterable<Transaction> pool) {
    TransferMatch? best;
    for (final Transaction other in pool) {
      final TransferMatch? match = score(txn, other);
      if (match == null) continue;
      if (best == null || match.confidence > best.confidence) best = match;
    }
    return best;
  }

  /// Money that left an account and was never seen arriving anywhere.
  ///
  /// The in-transit account should always be empty. A balance older than
  /// [staleAfter] is the app noticing, by itself, that it missed a message -
  /// which is the whole reason the transfer legs post through an account
  /// instead of cancelling on the spot.
  static List<Posting> unpairedLegs(
    Iterable<Posting> postings, {
    required DateTime now,
    Duration staleAfter = const Duration(hours: 24),
  }) {
    final Map<String, List<Posting>> byTxn = <String, List<Posting>>{};
    for (final Posting p in postings) {
      if (p.accountId != LedgerAccounts.inTransit) continue;
      if (now.difference(p.occurredAt) < staleAfter) continue;
      byTxn.putIfAbsent(p.txnId, () => <Posting>[]).add(p);
    }
    // Only the legs that do not cancel against another in-transit leg of the
    // same amount are genuinely unpaired.
    final List<Posting> flat = <Posting>[
      for (final List<Posting> legs in byTxn.values) ...legs,
    ];
    final List<Posting> unpaired = <Posting>[];
    final List<Posting> remaining = List<Posting>.of(flat);
    while (remaining.isNotEmpty) {
      final Posting head = remaining.removeAt(0);
      final int opposite = remaining.indexWhere(
        (Posting p) => p.amountPaise == -head.amountPaise,
      );
      if (opposite >= 0) {
        remaining.removeAt(opposite);
      } else {
        unpaired.add(head);
      }
    }
    return unpaired;
  }

  static String? _ref(Transaction txn) {
    final String? ref = txn.ref;
    if (ref == null) return null;
    final String cleaned = ref.replaceAll(RegExp(r'[^0-9A-Za-z]'), '').toUpperCase();
    return cleaned.length >= 6 ? cleaned : null;
  }
}
