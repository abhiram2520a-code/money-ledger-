/// The rule-driven SMS parser.
///
/// Pure, total and deterministic: given the same pack and the same message it
/// returns the same outcome, so a re-parse after a rules update is
/// reproducible and every case in `test/parser/` is a fixed point. It never
/// throws, never reads the clock unless you let it, and never touches I/O.
///
/// The one judgement encoded here, above all the regex plumbing: a silently
/// wrong transaction is worse than a visibly missing one. When the amount
/// cannot be read, when it is bound to a balance rather than to the money that
/// moved, when the direction contradicts itself, or when the currency is not
/// rupees, the answer is `ParseStatus.ambiguous` - never a guess, never a
/// zero, never "close enough".
library;

import '../contracts/sms_parser.dart';
import '../core/result.dart';
import '../models/models.dart';
import 'normalize.dart';
import 'rule_loader.dart';
import 'trust_gate.dart';

/// Currencies that are not rupees but do appear on Indian card alerts.
///
/// `Card XX4455 used for USD 42.50 at OPENAI` must never be booked as
/// Rs 42.50 - that is a 99% under-count that looks completely normal in the
/// UI. If a rule captures a foreign amount the outcome is ambiguous and the
/// user is asked, because the rupee figure genuinely is not in the message.
final RegExp _foreignCurrencyPrefix = RegExp(
  r'\b(USD|EUR|GBP|AED|SGD|AUD|CAD|JPY|CHF|CNY|THB|MYR|HKD|NZD|SAR|QAR|KWD)\b'
  r'[\s.:]*$',
  caseSensitive: false,
);

/// [SmsParser] backed by a compiled rules pack.
class RuleBasedSmsParser implements SmsParser {
  RuleBasedSmsParser({RuleLoader? loader, this.builtInGuards = true})
      : _loader = loader ?? RuleLoader() {
    _gate = TrustGate.fromRules(_loader.current, builtInGuards: builtInGuards);
  }

  /// Whether the parser's own structural guards run alongside the pack's
  /// `reject_patterns`. Production leaves this on.
  final bool builtInGuards;

  final RuleLoader _loader;
  late TrustGate _gate;

  /// The loader, exposed so a caller can inspect warnings from a salvaged pack
  /// or reset to the bundled one.
  RuleLoader get loader => _loader;

  /// The gate in force. Useful in tests; production never swaps it.
  TrustGate get gate => _gate;

  @override
  int get rulesVersion => _loader.current.version;

  @override
  bool get isReady => _loader.isReady;

  @override
  Future<Result<void>> load(RuleSet rules) async => loadSync(rules);

  /// The synchronous half of [load].
  ///
  /// Compiling is CPU-only, so there is nothing to await; [load] exists to
  /// satisfy the contract and to leave room for an implementation that reads
  /// the pack off disk.
  Result<void> loadSync(RuleSet rules) {
    final outcome =
        _loader.isReady ? _loader.adopt(rules) : _loader.adoptBundled(rules);
    _gate = TrustGate.fromRules(_loader.current, builtInGuards: builtInGuards);
    return outcome.map<void>((_) {});
  }

  @override
  List<ParseOutcome> parseAll(Iterable<RawMessage> messages, {DateTime? now}) =>
      messages.map((m) => parse(m, now: now)).toList(growable: false);

  @override
  Set<String> changedRuleIds({required RuleSet from, required RuleSet to}) =>
      RuleLoader.changedRuleIds(from: from, to: to);

  @override
  ParseOutcome parse(RawMessage message, {DateTime? now}) {
    try {
      return _parse(message, now);
    } on Object {
      // TOTAL: a hostile pattern, a pathological body or a bug must not take
      // down the ingestion loop. Quarantine the message so it is visible.
      return ParseOutcome.ambiguous('parser:internal_error');
    }
  }

  ParseOutcome _parse(RawMessage message, DateTime? now) {
    final rules = _loader.current;
    if (rules.isEmpty) {
      // Not an error state: the sweep will re-run these once a pack loads.
      return ParseOutcome.noRuleMatched(reason: 'rules:not_loaded');
    }

    final normalized = normalizeBody(message.body);
    final truncated = normalized.length > maxMatchableBodyChars;
    final body =
        truncated ? normalized.substring(0, maxMatchableBodyChars) : normalized;

    final verdict = _gate.screen(
      senderHeader: message.senderHeader,
      senderRaw: message.senderRaw,
      body: body,
    );
    if (!verdict.isCandidate) return verdict.toOutcome();

    final candidates = verdict.sender!.matchCandidates;
    for (final rule in rules.rules) {
      if (!rule.matchesSender(candidates)) continue;
      final match = rule.matchBody(body);
      if (match == null) continue;
      return _build(
        rule: rule,
        match: match,
        body: body,
        message: message,
        reference: now ?? message.receivedAt,
        truncated: truncated,
        rulesVersion: rules.version,
        debitWords: rules.debitWords,
        creditWords: rules.creditWords,
      );
    }

    return ParseOutcome.noRuleMatched(
      reason: truncated ? 'no_rule:body_truncated' : 'no_rule',
    );
  }

  ParseOutcome _build({
    required CompiledRule rule,
    required RegExpMatch match,
    required String body,
    required RawMessage message,
    required DateTime reference,
    required bool truncated,
    required int rulesVersion,
    required List<String> debitWords,
    required List<String> creditWords,
  }) {
    final def = rule.def;

    // Step 4 of the contract: a rule that classifies the message as something
    // other than money moving is a successful parse that produces no entry.
    if (!def.txnType.createsLedgerEntry) {
      return ParseOutcome.rejected(
        def.txnType,
        'rule:${rule.id}',
        ruleId: rule.id,
      );
    }

    final amountText = rule.group(match, 'amount');
    final partials = <String, String>{};
    void note(String key, String? value) {
      if (value != null && value.isNotEmpty) partials[key] = value;
    }

    note('amount', amountText);
    note('date', rule.group(match, 'date'));
    note('account_tail', rule.group(match, 'account_tail'));
    note('card_tail', rule.group(match, 'card_tail'));
    note('merchant', rule.group(match, 'merchant'));
    note('ref', rule.group(match, 'ref'));

    if (amountText == null) {
      return ParseOutcome.ambiguous(
        'amount:missing',
        ruleId: rule.id,
        partialFields: partials,
      );
    }

    // A foreign-currency amount cannot become a rupee figure by wishing.
    final currency = _currencyBefore(body, amountText, match.start);
    if (currency != null) {
      partials['currency'] = currency;
      return ParseOutcome.ambiguous(
        'amount:foreign_currency',
        ruleId: rule.id,
        partialFields: partials,
      );
    }

    final amount = parseAmount(amountText);
    if (amount == null) {
      return ParseOutcome.ambiguous(
        'amount:unreadable',
        ruleId: rule.id,
        partialFields: partials,
      );
    }

    // The loudest possible failure: booking `Avl Bal Rs 43,210.55` as a spend.
    // A bill reminder is the one exception - there the amount IS the total
    // due, and that is exactly what the rule meant to capture.
    if (def.txnType != TxnType.billReminder &&
        amountLooksBalanceBound(body, amountText, searchFrom: match.start)) {
      return ParseOutcome.ambiguous(
        'amount:balance_bound',
        ruleId: rule.id,
        partialFields: partials,
      );
    }

    final TxnDirection direction;
    final bool directionFromBody;
    final fixedDirection = def.resolvedDirection;
    if (fixedDirection != null) {
      direction = fixedDirection;
      directionFromBody = false;
    } else {
      final fromWord =
          _directionOfWord(rule.group(match, 'direction_word'), debitWords, creditWords);
      final resolved =
          fromWord ?? _directionFromBody(body, debitWords, creditWords);
      if (resolved == null) {
        return ParseOutcome.ambiguous(
          'direction:undetermined',
          ruleId: rule.id,
          partialFields: partials,
        );
      }
      direction = resolved;
      directionFromBody = fromWord == null;
    }

    final dateText = rule.group(match, 'date');
    final parsedDate =
        parseDateToken(dateText, reference: reference, formats: def.dateFormats) ??
            findDateInBody(body, reference: reference, formats: def.dateFormats);
    final stated = _sanityCheckDate(parsedDate, reference);

    // A bill reminder's date is when the money is DUE, never when it moved.
    final isBillReminder = def.txnType == TxnType.billReminder;

    final accountTail = normalizeTail(rule.group(match, 'account_tail'));
    final cardTail = normalizeTail(rule.group(match, 'card_tail'));

    final capturedVpa = rule.group(match, 'vpa');
    final merchantText = rule.group(match, 'merchant');
    final vpa = extractVpa(capturedVpa ?? '') ??
        extractVpa(merchantText ?? '') ??
        extractVpa(body);

    var merchant = cleanMerchant(merchantText);
    if (merchant != null && merchant.contains('@')) {
      merchant = merchantFromVpa(merchant);
    }
    merchant ??= merchantFromVpa(vpa);

    final ref = normalizeRef(rule.group(match, 'ref')) ?? findRefInBody(body);
    final balance = parseAmount(rule.group(match, 'balance'));

    var txnType = def.txnType;
    if (txnType == TxnType.transaction) {
      final demoted = TrustGate.classifyObligation(body);
      if (demoted == TxnType.preDebitNotice) {
        // Money that has not moved yet. Booking it double-counts the EMI when
        // it finally settles.
        return ParseOutcome.rejected(
          TxnType.preDebitNotice,
          'demote:pre_debit_notice',
          ruleId: rule.id,
        );
      }
      if (demoted == TxnType.billReminder) {
        txnType = TxnType.billReminder;
      }
    }

    final treatAsBill = isBillReminder || txnType == TxnType.billReminder;
    final occurredAt = treatAsBill ? message.receivedAt : (stated?.value ?? message.receivedAt);
    final precision = treatAsBill
        ? DatePrecision.receivedFallback
        : (stated?.precision ?? DatePrecision.receivedFallback);
    final dueDate = treatAsBill ? stated?.value : null;

    final confidence = _confidence(
      hasDate: !treatAsBill && stated != null,
      hasRef: ref != null,
      hasTail: accountTail != null || cardTail != null,
      hasCounterparty: merchant != null || vpa != null,
      directionFromBody: directionFromBody,
      truncated: truncated,
      inferredYear: stated?.precision == DatePrecision.inferredYear,
    );

    return ParseOutcome.parsed(
      ParsedMessage(
        amount: amount,
        direction: direction,
        occurredAt: occurredAt,
        channel: def.channel,
        ruleId: rule.id,
        ruleVersion: rulesVersion,
        confidence: confidence,
        txnType: txnType,
        datePrecision: precision,
        accountTail: accountTail,
        cardTail: cardTail,
        merchantRaw: merchant,
        vpa: vpa,
        ref: ref,
        balance: balance,
        issuer: def.issuer.isEmpty ? null : def.issuer,
        rawMessageId: message.id,
        forcedCategoryPath: def.forcedCategoryPath,
        dueDate: dueDate,
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Helpers
  // -------------------------------------------------------------------------

  /// The ISO code sitting immediately in front of the captured amount, when it
  /// is not INR.
  static String? _currencyBefore(String body, String amountText, int searchFrom) {
    final from = searchFrom.clamp(0, body.length);
    final index = body.indexOf(amountText, from);
    if (index < 0) return null;
    final start = index - 12 < 0 ? 0 : index - 12;
    final match = _foreignCurrencyPrefix.firstMatch(body.substring(start, index));
    return match?.group(1)?.toUpperCase();
  }

  /// Classifies a captured `direction_word` against the pack's vocabulary.
  ///
  /// Longest match wins, so `transferred to` beats `transferred`. When both
  /// lists match equally well the word is genuinely ambiguous and the caller
  /// falls through rather than picking a side.
  static TxnDirection? _directionOfWord(
    String? word,
    List<String> debitWords,
    List<String> creditWords,
  ) {
    if (word == null) return null;
    final needle = word.toLowerCase();
    final debit = _longestHit(needle, debitWords);
    final credit = _longestHit(needle, creditWords);
    if (debit > credit) return TxnDirection.debit;
    if (credit > debit) return TxnDirection.credit;
    return null;
  }

  static int _longestHit(String haystack, List<String> words) {
    var best = 0;
    for (final word in words) {
      if (word.length > best && haystack.contains(word)) best = word.length;
    }
    return best;
  }

  /// Falls back to the earliest direction word anywhere in the body.
  ///
  /// Earliest, not most frequent: `Rs 100 spent on your SBI Credit Card` says
  /// `spent` before it says `credit`, and a dual-leg `A debited ... and B
  /// credited` binds to the first leg, which is the user's own account.
  static TxnDirection? _directionFromBody(
    String body,
    List<String> debitWords,
    List<String> creditWords,
  ) {
    final lowered = body.toLowerCase();
    final debitAt = _earliestHit(lowered, debitWords);
    final creditAt = _earliestHit(lowered, creditWords);
    if (debitAt < 0 && creditAt < 0) return null;
    if (creditAt < 0) return TxnDirection.debit;
    if (debitAt < 0) return TxnDirection.credit;
    if (debitAt == creditAt) return null;
    return debitAt < creditAt ? TxnDirection.debit : TxnDirection.credit;
  }

  static int _earliestHit(String haystack, List<String> words) {
    var best = -1;
    for (final word in words) {
      final at = haystack.indexOf(word);
      if (at < 0) continue;
      if (best < 0 || at < best) best = at;
    }
    return best;
  }

  /// Discards a stated date that cannot be right.
  ///
  /// A date more than two days after the message arrived, or more than ten
  /// years before it, is a misparse; falling back to the receipt time with
  /// `DatePrecision.receivedFallback` is honest, while a transaction filed
  /// under 2015 silently disappears from every month view.
  static ParsedDate? _sanityCheckDate(ParsedDate? parsed, DateTime reference) {
    if (parsed == null) return null;
    final value = parsed.value;
    if (value.isAfter(reference.add(const Duration(days: 2)))) return null;
    if (value.isBefore(reference.subtract(const Duration(days: 3653)))) {
      return null;
    }
    return parsed;
  }

  /// Confidence starts at certainty and pays for what the message did not say.
  ///
  /// The scale matters: `ParsedMessage.reviewThreshold` is 0.70, and anything
  /// below it is created as `TxnStatus.needsReview`, which does NOT count in
  /// totals. So a real movement that merely lacks a merchant name must stay
  /// above the line - under-counting real money is its own kind of lie.
  static double _confidence({
    required bool hasDate,
    required bool hasRef,
    required bool hasTail,
    required bool hasCounterparty,
    required bool directionFromBody,
    required bool truncated,
    required bool inferredYear,
  }) {
    var score = 1.0;
    if (!hasDate) score -= 0.10;
    if (!hasRef) score -= 0.06;
    if (!hasTail) score -= 0.10;
    if (!hasCounterparty) score -= 0.06;
    if (directionFromBody) score -= 0.05;
    if (truncated) score -= 0.10;
    if (inferredYear) score -= 0.03;
    final clamped = score < 0.0 ? 0.0 : (score > 1.0 ? 1.0 : score);
    // Two decimals so an expected value in a test is exact, not float noise.
    return double.parse(clamped.toStringAsFixed(2));
  }
}
