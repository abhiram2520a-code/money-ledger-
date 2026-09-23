/// The negative grammar: deciding whether a message is even a candidate.
///
/// Header trust alone is not enough. `VM-HDFCBK-S` is a genuinely registered
/// HDFC header and it legitimately carries transaction alerts, OTPs, statement
/// reminders and marketing from the same address. An OTP that quotes
/// `Rs 4,999 at AMAZON on card XX4455` has an amount, a merchant, a card tail
/// and a transaction verb; booking it invents money the user never spent, and
/// if the payment then fails the phantom is permanent.
///
/// So this file answers two questions, cheaply, on every message:
///   1. Is the sender a registered DLT header at all? (a 10-digit number is
///      spoof territory - under DLT nobody can send from `VM-HDFCBK`)
///   2. Is the body a class of message that moves no money?
///
/// The asymmetry that governs every judgement here: an invented transaction
/// destroys trust far faster than a missing one, but a rejected genuine
/// transaction is invisible to the user. So the built-in guards are narrow,
/// and the ones that could plausibly fire on a real alert are conditional on
/// the body NOT showing a completed money movement bound to an account or card
/// mask - which is what actually separates an alert from an advertisement.
library;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'normalize.dart';
import 'rule_loader.dart';

/// What the gate decided.
enum TrustVerdictKind {
  /// Hand the message to the rules.
  candidate,

  /// The sender is not a registered financial header. The body is not parsed.
  untrustedSender,

  /// A registered sender, but this message is not a transaction.
  rejected,
}

/// The gate's decision, with a reason that is safe to store.
///
/// [reason] never contains message text - only the name of the guard or the
/// source of the reject pattern that fired.
@immutable
class TrustVerdict {
  const TrustVerdict({
    required this.kind,
    this.sender,
    this.classifiedAs = TxnType.unknown,
    this.reason = '',
  });

  factory TrustVerdict.candidate(SenderId sender) =>
      TrustVerdict(kind: TrustVerdictKind.candidate, sender: sender);

  factory TrustVerdict.untrusted(String reason) =>
      TrustVerdict(kind: TrustVerdictKind.untrustedSender, reason: reason);

  factory TrustVerdict.reject(
    TxnType classifiedAs,
    String reason, {
    SenderId? sender,
  }) =>
      TrustVerdict(
        kind: TrustVerdictKind.rejected,
        sender: sender,
        classifiedAs: classifiedAs,
        reason: reason,
      );

  final TrustVerdictKind kind;
  final SenderId? sender;
  final TxnType classifiedAs;
  final String reason;

  bool get isCandidate => kind == TrustVerdictKind.candidate;

  /// The outcome to return when this verdict is not [isCandidate].
  ParseOutcome toOutcome() => switch (kind) {
        TrustVerdictKind.candidate =>
          ParseOutcome.noRuleMatched(reason: 'gate:candidate'),
        TrustVerdictKind.untrustedSender =>
          ParseOutcome.untrustedSender(reason: reason),
        TrustVerdictKind.rejected => ParseOutcome.rejected(classifiedAs, reason),
      };

  @override
  String toString() => 'TrustVerdict(${kind.name}, ${classifiedAs.wire}, $reason)';
}

/// The cheap pre-rule screen.
///
/// Stateless and allocation-free per message apart from the regex matches:
/// it runs on every SMS the device receives, including the 70% of a real inbox
/// that is promotional noise.
@immutable
class TrustGate {
  const TrustGate({
    this.rejectPatterns = const <NamedPattern>[],
    this.builtInGuards = true,
  });

  /// Compiled `reject_patterns` from the pack in force. These are the
  /// updatable half of the negative grammar: a false positive found next month
  /// is fixed by shipping a pattern, not a release.
  final List<NamedPattern> rejectPatterns;

  /// Whether the built-in structural guards run. Exists so the guards can be
  /// tested in isolation and switched off if a pack ever needs to override
  /// them; production always leaves this on.
  final bool builtInGuards;

  /// Builds a gate from a compiled pack.
  factory TrustGate.fromRules(CompiledRules rules, {bool builtInGuards = true}) =>
      TrustGate(
        rejectPatterns: rules.rejectPatterns,
        builtInGuards: builtInGuards,
      );

  /// Screens one message.
  ///
  /// [senderHeader] is `RawMessage.senderHeader`: `null` means the ingestion
  /// layer could not normalise the address, which is a hard reject. [senderRaw]
  /// is still read, for the TCCCPR category suffix.
  ///
  /// [body] must already be normalised by [normalizeBody].
  TrustVerdict screen({
    required String? senderHeader,
    required String senderRaw,
    required String body,
  }) {
    if (senderHeader == null || senderHeader.trim().isEmpty) {
      return TrustVerdict.untrusted('sender:not_normalised');
    }

    final sender = SenderId.parse(senderRaw) ?? SenderId.parse(senderHeader);
    if (sender == null) {
      // A numeric originating address is spoof and personal-contact territory:
      // under DLT nobody can send from `VM-HDFCBK`, but anybody can send from
      // a phone. Body content is irrelevant here.
      return TrustVerdict.untrusted('sender:not_a_dlt_header');
    }

    if (sender.isPromotional) {
      return TrustVerdict.reject(
        TxnType.promo,
        'sender:category_p',
        sender: sender,
      );
    }

    if (body.trim().isEmpty) {
      return TrustVerdict.reject(
        TxnType.unknown,
        'body:empty',
        sender: sender,
      );
    }

    if (builtInGuards) {
      final guard = classifyNonTransaction(body);
      if (guard != null) {
        return TrustVerdict.reject(guard.type, guard.reason, sender: sender);
      }
    }

    for (final pattern in rejectPatterns) {
      if (pattern.hasMatch(body)) {
        return TrustVerdict.reject(
          _classifyRejectPattern(pattern.source, body),
          'reject:${pattern.source}',
          sender: sender,
        );
      }
    }

    return TrustVerdict.candidate(sender);
  }

  // -------------------------------------------------------------------------
  // Structural signals
  // -------------------------------------------------------------------------

  /// A completed, past-tense money verb. `debit` (the noun) and `auto debit`
  /// are deliberately absent: `AUTO DEBIT OF PREMIUM OF RS.20/- BETWEEN
  /// 25/05 AND 01/06` is a pre-notice, not a debit.
  static final RegExp settledVerbPattern = RegExp(
    r'\b(?:debited|credited|spent|withdrawn|withdrawal|sent|received|paid|'
    r'deducted|reversed|refunded|redeemed|transferred|deposited|charged|'
    r'purchased)\b|\b(?:dr|cr)\.',
    caseSensitive: false,
  );

  /// An account or card mask in any dialect: `A/c XX1234`, `Card ending 0000`,
  /// `a/c *1234`, `000***000000`, `...1055`, `xxXX6438`.
  static final RegExp maskPattern = RegExp(
    r'\b(?:a/?c|acct|account|card)\s*(?:no\.?|number|ending(?:\s*in)?)?\s*'
    r'[xX*#.…]{0,8}\s*\d{3,}'
    r'|(?<![A-Za-z0-9])[xX*]{1,4}\d{3,6}\b'
    r'|…\d{3,6}\b'
    r'|\.{3}\d{3,6}\b'
    r'|\d{2,}\*{2,}\d{3,}',
    caseSensitive: false,
  );

  /// True when the body shows money that has actually moved, attributed to an
  /// instrument. This is the discriminator the whole file turns on: an advert
  /// says "spend Rs 5,000 and get Rs 500 back" with no mask, while an alert
  /// says "Rs 5,000 debited from A/c XX1234".
  static bool hasSettledMoneyMovement(String body) =>
      settledVerbPattern.hasMatch(body) && maskPattern.hasMatch(body);

  // -------------------------------------------------------------------------
  // Guards
  // -------------------------------------------------------------------------

  /// One-time passwords. Unconditional: an OTP is never a settled movement,
  /// however many amounts, merchants and card tails it quotes.
  static final RegExp otpPattern = RegExp(
    r'\botp\b'
    r'|\bone[\s-]?time[\s-]?(?:password|passcode|pin|code)\b'
    r'|\bverification code\b|\bsecurity code\b|\bsecret code\b'
    r'|\blogin code\b|\bauth(?:orisation|orization)?\s+code\b'
    r'|\bdo\s*n[o’\x27]?t\s*share\b[^.]{0,48}\b(?:otp|pin|password|code)\b'
    r'|\b(?:otp|pin|password|code)\b[^.]{0,48}\bdo\s*n[o’\x27]?t\s*share\b'
    r'|\bnever\s+share\b[^.]{0,48}\b(?:otp|pin|password|code)\b',
    caseSensitive: false,
  );

  /// The Android SMS Retriever prefix. Only ever present on an app-bound
  /// verification message.
  static final RegExp smsRetrieverPrefix = RegExp(r'^\s*<#>');

  /// The 11-character app hash SMS Retriever appends on the last line. A weak
  /// tell on its own, so it is only honoured when nothing moved.
  static final RegExp appHashSuffix = RegExp(r'(?:^|\s)[A-Za-z0-9+/]{11}$');

  /// Failed, declined and rejected attempts. Structurally identical to a
  /// successful debit except for one word, which is usually placed AFTER the
  /// merchant - so the check is over the whole body, not near the verb.
  static final RegExp failedPattern = RegExp(
    r'\b(?:failed|failure|declined|unsuccessful|not\s+processed|'
    r'could\s+not\s+be\s+(?:processed|completed)|has\s+been\s+rejected|'
    r'transaction\s+rejected|insufficient\s+funds)\b',
    caseSensitive: false,
  );

  /// Balance pushes and enquiry replies. An account mask plus an amount but no
  /// money verb.
  static final RegExp balanceOnlyPattern = RegExp(
    r'\b(?:available\s+balance|avl\.?\s*bal|avlbal|avbl\s*bal|'
    r'a/?c\s+balance|account\s+balance|clear\s+balance|ledger\s+balance|'
    r'closing\s+balance|balance\s+in\s+your|balance\s+enquiry|'
    r'total\s+available\s+balance)\b',
    caseSensitive: false,
  );

  /// Marketing. Conditional, because genuine alerts carry marketing tails:
  /// ICICI appends `To convert this txn to EMI give a missed call on ...`,
  /// OneCard opens real spend alerts with `Tank's full!` and `Reward points
  /// added`. Rejecting on hype alone throws away real money movements.
  static final RegExp promoPattern = RegExp(
    r'\bspend\b[^.]{0,40}\band\s+get\b'
    r'|\bup\s?to\s+(?:rs|inr|₹)|\bupto\s+(?:rs|inr|₹)'
    r'|\bapply\s+now\b|\bavail\s+(?:now|this|the|your)\b|\beligible\s+for\b'
    r'|\bpre[\s-]?approved\b|\bpre[\s-]?qualified\b|\boffer\s+valid\b'
    r'|\blimited\s+period\b|\bhurry\b|\bt&c\s+apply\b|\bclick\s+(?:here|below)\b'
    r'|\bcongratulations\b|\byou\s+have\s+won\b'
    r'|\bcashback\s+(?:up\s?to|upto|worth)\b|\breward\s+points\s+worth\b'
    r'|\bloan\s+on\s+card\b|\binstant\s+loan\b|\bpersonal\s+loan\s+of\b'
    r'|\bcredit\s+limit\s+(?:increase|enhancement)\b'
    r'|\bbook\s+now\b|\bshop\s+now\b|\bexclusive\s+offer\b',
    caseSensitive: false,
  );

  /// Smishing. These arrive overwhelmingly from unregistered senders and are
  /// already stopped by the header check; the pattern is a second line for the
  /// case where a look-alike header slips through.
  static final RegExp phishingPattern = RegExp(
    r'\bclaim\s+(?:your|the)\b|\bverify\s+your\s+(?:bank\s+)?account\b'
    r'|\benter\s+(?:your\s+)?upi\s+pin\b|\bapprove\s+the\s+(?:transfer|request)\b'
    r'|\bkyc\s+(?:will\s+be\s+)?(?:suspend|block|update\s+now)',
    caseSensitive: false,
  );

  /// Future tense and obligation: statements, due reminders, RBI-mandated
  /// e-mandate pre-notices, ASBA blocks.
  ///
  /// NOTE this is NOT used by [screen]. A pack may legitimately carry a
  /// `bill_reminder` rule that turns these into a [Bill], so rejecting them
  /// before the rules run would break that. The parser calls
  /// [classifyObligation] AFTER a rule matched, and only demotes a rule that
  /// claimed the message was a settled transaction.
  static final RegExp obligationPattern = RegExp(
    r'\bis\s+due\b|\bdue\s+on\b|\bdue\s+by\b|\bdue\s+date\b|\bpay\s+by\b'
    r'|\bpay\s+before\b|\bplease\s+pay\b|\bkindly\s+pay\b|\bnon[\s-]?payment\b'
    r'|\bstatement\s+(?:for|of|is)\b|\bis\s+generated\b|\bbill\s+is\s+ready\b'
    r'|\bpayment\s+is\s+due\b|\btotal\s+amount\s+due\b',
    caseSensitive: false,
  );

  /// Money that has not moved yet.
  static final RegExp preDebitPattern = RegExp(
    r'\bwill\s+be\s+(?:debited|deducted|charged|auto[\s-]?debited)\b'
    r'|\bscheduled\s+(?:on|for)\b|\bkindly\s+maintain\b'
    r'|\bensure\s+(?:sufficient|adequate)\s+balance\b'
    r'|\bmaintain\s+(?:sufficient|adequate)\s+balance\b'
    r'|\bauto\s+debit\s+of\b|\bis\s+blocked\s+in\s+your\b'
    r'|\bwill\s+be\s+presented\b|\bdue\s+for\s+(?:payment|debit)\b',
    caseSensitive: false,
  );

  /// Runs the built-in guards in order, returning the first hit.
  static TrustGuardHit? classifyNonTransaction(String body) {
    if (otpPattern.hasMatch(body) || smsRetrieverPrefix.hasMatch(body)) {
      return const TrustGuardHit(TxnType.otp, 'guard:otp');
    }
    if (failedPattern.hasMatch(body)) {
      return const TrustGuardHit(TxnType.unknown, 'guard:failed');
    }

    if (hasSettledMoneyMovement(body)) return null;

    if (appHashSuffix.hasMatch(body.trim()) && !maskPattern.hasMatch(body)) {
      return const TrustGuardHit(TxnType.otp, 'guard:app_hash');
    }
    if (phishingPattern.hasMatch(body)) {
      return const TrustGuardHit(TxnType.unknown, 'guard:phishing');
    }
    if (balanceOnlyPattern.hasMatch(body)) {
      return const TrustGuardHit(TxnType.balanceInfo, 'guard:balance_only');
    }
    if (promoPattern.hasMatch(body)) {
      return const TrustGuardHit(TxnType.promo, 'guard:promo');
    }
    return null;
  }

  /// Classifies a body that a rule claimed was a settled transaction but whose
  /// language says the money has not moved.
  ///
  /// Returns `null` when the body shows a completed movement - which is why
  /// ICICI's refund alert survives despite carrying `Revised total due` and
  /// `minimum due`, and why a real card spend survives its `Convert to EMI?`
  /// footer.
  static TxnType? classifyObligation(String body) {
    if (hasSettledMoneyMovement(body)) return null;
    if (preDebitPattern.hasMatch(body)) return TxnType.preDebitNotice;
    if (obligationPattern.hasMatch(body)) return TxnType.billReminder;
    return null;
  }

  /// Names the class a pack-supplied reject pattern caught, so the rejection
  /// is stored as something more useful than "rejected".
  static TxnType _classifyRejectPattern(String source, String body) {
    final guard = classifyNonTransaction(body);
    if (guard != null) return guard.type;
    final lowered = source.toLowerCase();
    if (lowered.contains('otp') || lowered.contains('password')) {
      return TxnType.otp;
    }
    if (lowered.contains('fail') || lowered.contains('declin')) {
      return TxnType.unknown;
    }
    if (obligationPattern.hasMatch(body) || preDebitPattern.hasMatch(body)) {
      return TxnType.billReminder;
    }
    return TxnType.promo;
  }
}

/// A guard hit: the class of message and the name of the guard that said so.
@immutable
class TrustGuardHit {
  const TrustGuardHit(this.type, this.reason);

  /// What the message turned out to be.
  final TxnType type;

  /// The guard's name, e.g. `guard:otp`. Content-free and safe to store.
  final String reason;

  @override
  String toString() => 'TrustGuardHit(${type.wire}, $reason)';
}
