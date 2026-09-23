import '../core/result.dart';
import '../models/models.dart';

/// Turns one raw message into fields, using only the loaded [RuleSet].
///
/// Hard requirements on every implementation:
/// * PURE. No I/O, no clock reads beyond what is passed in, no network - ever.
///   Given the same [RuleSet] and [RawMessage] it returns the same outcome, so
///   a re-parse after a rules update is reproducible and testable.
/// * TOTAL. Never throws, for any input. A malformed body, a hostile regex, a
///   50 KB message: all produce a `ParseOutcome`, never an exception.
/// * HONEST. If the amount cannot be read with confidence, the outcome is
///   `ParseStatus.ambiguous` - never a guessed or zero amount. Silent and
///   wrong is worse than visible and missing.
abstract interface class SmsParser {
  /// The version of the rules currently loaded, or 0 before [load].
  int get rulesVersion;

  /// Whether [load] has completed successfully.
  bool get isReady;

  /// Compiles [rules] for use.
  ///
  /// Called at startup with the bundled pack and again whenever a newer pack
  /// is applied. Compiling every regex up front is deliberate: a bad pattern
  /// must fail here, once, and not once per message.
  ///
  /// Fails with `ErrorCodes.corruptRules` if a pattern does not compile or a
  /// rule lacks the `amount` group. On failure the previously loaded rules
  /// stay in force - the parser never ends up with none.
  Future<Result<void>> load(RuleSet rules);

  /// Parses one message. Synchronous by design: it runs inside the ingestion
  /// loop and must not yield.
  ///
  /// Order of operations, which implementations must preserve:
  /// 1. Untrusted sender (`RawMessage.senderHeader == null`) ->
  ///    `ParseOutcome.untrustedSender`.
  /// 2. Body matches any `RuleSet.rejectPatterns` entry ->
  ///    `ParseOutcome.rejected`. This runs BEFORE any rule, so an OTP quoting
  ///    an amount can never be booked.
  /// 3. Rules in `RuleSet.orderedRules`; the first whose sender AND body both
  ///    match wins.
  /// 4. A rule matched but `txnType` is not `createsLedgerEntry` ->
  ///    `ParseOutcome.rejected` carrying that type.
  /// 5. Otherwise a `ParsedMessage`, or `ParseOutcome.ambiguous` when required
  ///    fields contradict each other.
  /// 6. No rule matched -> `ParseOutcome.noRuleMatched`.
  ///
  /// [now] is the reference time used when a message carries no year, so the
  /// result stays deterministic in tests. Defaults to the wall clock.
  ParseOutcome parse(RawMessage message, {DateTime? now});

  /// Convenience for a batch, preserving order. Same rules as [parse].
  List<ParseOutcome> parseAll(Iterable<RawMessage> messages, {DateTime? now});

  /// The ids of rules whose pattern differs between [from] and [to].
  ///
  /// The re-parse sweep uses this to re-run only the messages a pack actually
  /// changed, instead of every message ever received.
  Set<String> changedRuleIds({required RuleSet from, required RuleSet to});
}
