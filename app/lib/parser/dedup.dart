/// Collapsing many messages about one payment into one record - and, just as
/// importantly, refusing to collapse two payments that merely look alike.
///
/// One economic event routinely produces several SMS: the bank's alert, the
/// UPI app's alert, a settlement confirmation hours later, and an accidental
/// re-delivery on the second SIM. Booking all four quadruples the month.
/// Meanwhile two genuine Rs 50 payments to the same tea shop, a minute apart,
/// must stay two.
///
/// The field that decides this is the bank reference - the NPCI RRN (exactly
/// twelve digits), the NEFT/RTGS UTR, the IMPS reference. It is identical on
/// the payer's message, the payee's message and the PSP's message, and it is
/// the only stable identity of a money EVENT as opposed to a MESSAGE. When two
/// records carry references and the references differ, they are two events -
/// full stop. That single rule is what makes a failed-then-retried UPI payment
/// come out right, and no amount of time-window tuning substitutes for it.
///
/// Everything here is advisory. The deduplicator says what it found and why;
/// the ledger decides what to write. Nothing is deleted, because a dedupe
/// decision is only reversible if the original records survive.
library;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'normalize.dart';

/// How a candidate relates to a record already in the ledger.
enum DedupRelation {
  /// Nothing matched. Book it.
  unique('unique'),

  /// The same body from the same entity arrived twice - dual SIM, or an
  /// operator retry. Drop it.
  duplicateDelivery('duplicate_delivery'),

  /// A different message about the same money event: the bank's alert and the
  /// UPI app's alert. Merge the fields, keep one record.
  sameEvent('same_event'),

  /// A later confirmation of an event already booked ("your beneficiary has
  /// received..."). Merge; never a second entry.
  followUp('follow_up'),

  /// A refund or an authorisation reversal of an earlier spend. Book it, but
  /// linked, so the category total is corrected rather than the month being
  /// credited with phantom income.
  reversalOf('reversal_of'),

  /// The other half of the user's own transfer: a card-bill payment, a
  /// self-transfer, a wallet load. Book both legs, link them, count neither as
  /// spend or income.
  transferLeg('transfer_leg');

  const DedupRelation(this.wire);

  final String wire;

  /// True when the candidate must NOT become its own ledger entry.
  bool get collapses =>
      this == DedupRelation.duplicateDelivery ||
      this == DedupRelation.sameEvent ||
      this == DedupRelation.followUp;

  /// True when the candidate is a real, separate entry that points at another.
  bool get links =>
      this == DedupRelation.reversalOf || this == DedupRelation.transferLeg;
}

/// One money event, reduced to the fields dedup actually reasons about.
///
/// Deliberately not a [Transaction]: dedup runs before the ledger exists and
/// must be testable without one.
@immutable
class DedupCandidate {
  const DedupCandidate({
    required this.id,
    required this.amount,
    required this.direction,
    required this.occurredAt,
    required this.receivedAt,
    required this.bodyKey,
    this.ref,
    this.accountTail,
    this.cardTail,
    this.merchantKey,
    this.issuer,
    this.isPsp = false,
    this.isCardInstrument = false,
    this.datePrecision = DatePrecision.receivedFallback,
  });

  /// Builds a candidate from a parse result and the message it came from.
  ///
  /// [isPsp] marks a payment app rather than a bank (PhonePe, PayZapp, slice,
  /// FamPay). When a bank and a PSP report the same event the bank record is
  /// canonical, because it carries the account mask and the balance.
  factory DedupCandidate.fromParsed(
    ParsedMessage parsed,
    RawMessage raw, {
    String? id,
    bool isPsp = false,
  }) {
    final body = normalizeBody(raw.body);
    return DedupCandidate(
      id: id ?? raw.id,
      amount: parsed.amount,
      direction: parsed.direction,
      occurredAt: parsed.occurredAt,
      receivedAt: raw.receivedAt,
      bodyKey: dedupBodyKey(raw.body),
      ref: parsed.ref,
      accountTail: parsed.accountTail,
      cardTail: parsed.cardTail,
      merchantKey: merchantKeyOf(parsed.merchantRaw ?? parsed.vpa),
      issuer: raw.senderHeader?.toUpperCase(),
      isPsp: isPsp,
      isCardInstrument:
          parsed.cardTail != null || _cardInstrumentPattern.hasMatch(body),
      datePrecision: parsed.datePrecision,
    );
  }

  /// The caller's identifier for this record - a transaction id, or the raw
  /// message id before one exists.
  final String id;
  final Money amount;
  final TxnDirection direction;
  final DateTime occurredAt;
  final DateTime receivedAt;

  /// Case-folded, whitespace-collapsed body. The layer-0 key.
  final String bodyKey;

  /// Normalised RRN / UTR / IMPS ref, or `null`.
  final String? ref;

  final String? accountTail;
  final String? cardTail;

  /// Lower-cased alphanumerics of the merchant or VPA, or `null`.
  final String? merchantKey;

  /// Normalised sender principal (`HDFCBK`), never the telco prefix.
  final String? issuer;

  final bool isPsp;

  /// Whether the money moved on a card rather than a bank account. Needed
  /// because the card side of a bill payment often carries no mask at all.
  final bool isCardInstrument;

  final DatePrecision datePrecision;

  /// The tail that identifies the instrument, card first.
  String? get instrumentTail => cardTail ?? accountTail;

  /// True when the stated time is really the SMS receipt time, which is the
  /// case for the templates that carry no date at all.
  bool get timeIsApproximate =>
      datePrecision == DatePrecision.receivedFallback ||
      datePrecision == DatePrecision.inferredYear;

  /// `swiggy@axisbank` and `SWIGGY` collapse to `swiggy`; `null` stays `null`.
  static String? merchantKeyOf(String? raw) {
    if (raw == null) return null;
    final at = raw.indexOf('@');
    final base = at > 0 ? raw.substring(0, at) : raw;
    final key = base.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
    return key.length < 3 ? null : key;
  }

  static final RegExp _cardInstrumentPattern = RegExp(
    r'\b(?:credit\s*card|debit\s*card|\bcc\b|\bdc\b|card\s*(?:no\.?|ending|xx))',
    caseSensitive: false,
  );

  @override
  String toString() => 'DedupCandidate($id, ${amount.format()}, '
      '${direction.wire}, ref=${ref ?? '-'})';
}

/// What the index concluded, and why.
@immutable
class DedupResult {
  const DedupResult(this.relation, {this.matchId, this.reason = ''});

  static const DedupResult unique = DedupResult(DedupRelation.unique);

  final DedupRelation relation;

  /// The [DedupCandidate.id] this matched, when it matched something.
  final String? matchId;

  /// A short, content-free note naming the layer that decided.
  final String reason;

  bool get isUnique => relation == DedupRelation.unique;

  bool get collapses => relation.collapses;

  bool get links => relation.links;

  @override
  String toString() =>
      'DedupResult(${relation.wire}, match=${matchId ?? '-'}, $reason)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DedupResult &&
          other.relation == relation &&
          other.matchId == matchId &&
          other.reason == reason;

  @override
  int get hashCode => Object.hash(relation, matchId, reason);
}

/// A rolling window of recent events, answering "have I seen this before?".
///
/// Thresholds are constructor parameters rather than constants because they
/// are product judgements, not facts: widen the fuzzy window and you swallow
/// genuine repeat payments; narrow it and a bank/PSP pair books twice.
class DedupIndex {
  DedupIndex({
    this.redeliveryWindow = const Duration(hours: 24),
    this.fuzzyWindow = const Duration(seconds: 180),
    this.approximateFuzzyWindow = const Duration(minutes: 15),
    this.anonymousFuzzyWindow = const Duration(seconds: 60),
    this.transferWindow = const Duration(days: 2),
    this.reversalWindow = const Duration(days: 30),
    this.retention = const Duration(days: 35),
  });

  /// How long a byte-identical body counts as a re-delivery.
  final Duration redeliveryWindow;

  /// Default window for matching two records that carry no usable reference.
  final Duration fuzzyWindow;

  /// Widened window when one side has no in-body timestamp and is therefore
  /// using SMS receipt time. Never widened past this: repeated identical small
  /// payments are common and must stay separate.
  final Duration approximateFuzzyWindow;

  /// Tightened window when one side names no instrument, so the tail cannot be
  /// part of the key.
  final Duration anonymousFuzzyWindow;

  /// How far apart the two legs of one transfer may be.
  final Duration transferWindow;

  /// How long after a spend a refund may still be linked to it. Marketplace
  /// refunds routinely take a fortnight.
  final Duration reversalWindow;

  /// How long records are kept for matching.
  final Duration retention;

  final List<DedupCandidate> _entries = <DedupCandidate>[];

  int get size => _entries.length;

  /// Most recent first. The scan order, and therefore the tie-break: when two
  /// stored records match equally well the later one wins, deterministically.
  List<DedupCandidate> get entries => List<DedupCandidate>.unmodifiable(_entries);

  void clear() => _entries.clear();

  /// Adds [candidate] to the window without classifying it.
  void remember(DedupCandidate candidate) {
    _entries.add(candidate);
    _entries.sort((a, b) {
      final byTime = b.receivedAt.compareTo(a.receivedAt);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    _pruneOlderThan(candidate.receivedAt.subtract(retention));
  }

  /// Classifies [candidate] and then remembers it, which is what an ingestion
  /// loop wants. A collapsed duplicate is still remembered: a third delivery
  /// of the same body must also be caught.
  DedupResult add(DedupCandidate candidate) {
    final result = classify(candidate);
    remember(candidate);
    return result;
  }

  void _pruneOlderThan(DateTime cutoff) {
    _entries.removeWhere((e) => e.receivedAt.isBefore(cutoff));
  }

  /// Decides how [candidate] relates to what has already been seen.
  DedupResult classify(DedupCandidate candidate) {
    // LAYER 0 - the same body from the same entity. Dual-SIM delivery arrives
    // under different telco prefixes but the same principal entity, which is
    // why `issuer` is the normalised header and not the raw address.
    for (final other in _entries) {
      if (other.bodyKey != candidate.bodyKey) continue;
      if (other.issuer != candidate.issuer) continue;
      if (_gap(candidate.receivedAt, other.receivedAt) > redeliveryWindow) {
        continue;
      }
      return DedupResult(
        DedupRelation.duplicateDelivery,
        matchId: other.id,
        reason: 'l0:body_hash',
      );
    }

    // LAYER 1 - the reference number. Not time-bounded: a settlement
    // confirmation for the same UTR can arrive the next morning.
    if (candidate.ref != null) {
      for (final other in _entries) {
        if (other.ref != candidate.ref) continue;
        if (other.direction == candidate.direction) {
          if (_tailsCompatible(candidate, other)) {
            return DedupResult(
              DedupRelation.sameEvent,
              matchId: other.id,
              reason: 'l1:ref',
            );
          }
          // Same reference, same direction, different instruments: two
          // distinct postings sharing a rail reference. Link, never collapse.
          return DedupResult(
            DedupRelation.transferLeg,
            matchId: other.id,
            reason: 'l1:ref_split_instruments',
          );
        }
        // Opposite directions on one reference. Both legs on the user's own
        // instruments is a transfer; otherwise it is the counterparty's leg
        // being confirmed back to us, which is the same event.
        final bothOwned = tailKey(candidate.instrumentTail) != null &&
            tailKey(other.instrumentTail) != null;
        if (bothOwned && !tailsMatch(candidate.instrumentTail, other.instrumentTail)) {
          return DedupResult(
            DedupRelation.transferLeg,
            matchId: other.id,
            reason: 'l1:ref_two_legs',
          );
        }
        return DedupResult(
          DedupRelation.followUp,
          matchId: other.id,
          reason: 'l1:ref_confirmation',
        );
      }
    }

    // LAYER 2 - no usable reference on at least one side. Amount, direction,
    // instrument and a time bucket.
    for (final other in _entries) {
      if (_refsContradict(candidate, other)) continue;
      if (other.direction != candidate.direction) continue;
      if (!_sameAmount(candidate, other)) continue;
      final window = _fuzzyWindowFor(candidate, other);
      if (_gap(candidate.occurredAt, other.occurredAt) > window) continue;

      final left = tailKey(candidate.instrumentTail);
      final right = tailKey(other.instrumentTail);
      if (left != null && right != null) {
        if (left != right) continue;
        return DedupResult(
          DedupRelation.sameEvent,
          matchId: other.id,
          reason: 'l2:amount_tail_time',
        );
      }
      // One side names no instrument. Demand a matching counterparty instead,
      // or the two Rs 50 auto-rickshaw payments become one.
      if (candidate.merchantKey != null &&
          candidate.merchantKey == other.merchantKey) {
        return DedupResult(
          DedupRelation.sameEvent,
          matchId: other.id,
          reason: 'l2:amount_merchant_time',
        );
      }
    }

    // Refunds and authorisation reversals: opposite direction, same money, on
    // the SAME instrument. No reversal message carries the original's
    // reference, so this has to match on shape over a long window.
    for (final other in _entries) {
      if (other.direction == candidate.direction) continue;
      if (!_sameAmount(candidate, other)) continue;
      if (_gap(candidate.occurredAt, other.occurredAt) > reversalWindow) continue;
      if (candidate.occurredAt.isBefore(other.occurredAt)) continue;
      if (!_sameInstrument(candidate, other)) continue;
      // A refund comes back from the merchant it was paid to. Two named but
      // different counterparties on one account are rent going out and salary
      // coming in, which happen to be the same number - not a reversal.
      if (!_counterpartiesCompatible(candidate, other)) continue;
      return DedupResult(
        DedupRelation.reversalOf,
        matchId: other.id,
        reason: 'reversal:amount_instrument',
      );
    }

    // The user's own money moving between two things the user owns: a
    // credit-card bill payment, a self-transfer. Opposite direction, same
    // money, DIFFERENT instruments.
    for (final other in _entries) {
      if (other.direction == candidate.direction) continue;
      if (!_sameAmount(candidate, other)) continue;
      if (_gap(candidate.occurredAt, other.occurredAt) > transferWindow) continue;
      if (!_instrumentsDiffer(candidate, other)) continue;
      final cardInvolved = candidate.isCardInstrument || other.isCardInstrument;
      final anonymousPair =
          candidate.merchantKey == null && other.merchantKey == null;
      if (!cardInvolved && !anonymousPair) continue;
      return DedupResult(
        DedupRelation.transferLeg,
        matchId: other.id,
        reason: cardInvolved ? 'transfer:card_bill' : 'transfer:own_accounts',
      );
    }

    return DedupResult.unique;
  }

  // -------------------------------------------------------------------------

  static Duration _gap(DateTime a, DateTime b) => a.difference(b).abs();

  static bool _sameAmount(DedupCandidate a, DedupCandidate b) =>
      a.amount.paise == b.amount.paise &&
      a.amount.currency == b.amount.currency;

  /// Two records that BOTH carry a reference and disagree are two events.
  /// This is the rule that keeps a retried UPI payment from being swallowed.
  static bool _refsContradict(DedupCandidate a, DedupCandidate b) =>
      a.ref != null && b.ref != null && a.ref != b.ref;

  static bool _tailsCompatible(DedupCandidate a, DedupCandidate b) {
    final left = tailKey(a.instrumentTail);
    final right = tailKey(b.instrumentTail);
    if (left == null || right == null) return true;
    return left == right;
  }

  static bool _sameInstrument(DedupCandidate a, DedupCandidate b) {
    if (tailsMatch(a.instrumentTail, b.instrumentTail)) return true;
    if (tailKey(a.instrumentTail) != null && tailKey(b.instrumentTail) != null) {
      return false;
    }
    return a.merchantKey != null && a.merchantKey == b.merchantKey;
  }

  /// Counterparties agree, or at least one side does not name one. Two
  /// DIFFERENT named counterparties are evidence against a link.
  static bool _counterpartiesCompatible(DedupCandidate a, DedupCandidate b) {
    if (a.merchantKey == null || b.merchantKey == null) return true;
    return a.merchantKey == b.merchantKey;
  }

  static bool _instrumentsDiffer(DedupCandidate a, DedupCandidate b) {
    final left = tailKey(a.instrumentTail);
    final right = tailKey(b.instrumentTail);
    if (left != null && right != null) return left != right;
    return a.isCardInstrument != b.isCardInstrument;
  }

  Duration _fuzzyWindowFor(DedupCandidate a, DedupCandidate b) {
    final anonymous = tailKey(a.instrumentTail) == null ||
        tailKey(b.instrumentTail) == null;
    if (anonymous) return anonymousFuzzyWindow;
    if (a.timeIsApproximate || b.timeIsApproximate) {
      return approximateFuzzyWindow;
    }
    return fuzzyWindow;
  }
}
