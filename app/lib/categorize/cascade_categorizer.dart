import '../contracts/categorizer.dart';
import '../core/result.dart';
import '../models/models.dart';
import 'channel_signals.dart';
import 'merchant_index.dart';
import 'merchant_normalizer.dart';
import 'user_rules.dart';
import 'vpa_heuristics.dart';

/// The categorisation engine: a cheap-first cascade over the shipped merchant
/// dictionary, UPI address shapes, the payment rail, and the user's own rules.
///
/// ## The cascade
///
/// Cost order and authority order are two different axes, and mixing them up
/// is how this class gets "optimised" into the wrong shape six months from
/// now. Cost order is: hash lookup, prefix lookup, token index, regex.
/// Authority order is: the user beats a parser rule beats the shipped
/// dictionary beats a rail heuristic beats nothing.
///
/// A user rule happens to be both the cheapest lookup AND the highest
/// authority, so it runs first and hard short-circuits.
///
/// 1. **User rule** -> `CategorySource.userRule`, 0.99. The user already
///    answered this question; never ask again, never override.
/// 2. **Parser-rule forced category** -> `CategorySource.parserRule`. An ATM
///    rule that declares `transfer/cash_withdrawal` knows better than any
///    merchant string.
/// 3. **Exact merchant alias** -> `CategorySource.dictionary`,
///    `CategoryResult.dictionaryConfidence`.
/// 4. **Full VPA prefix** (`swiggy@`) -> `CategorySource.vpa`, same
///    confidence. A bare PSP handle (`@ybl`) can never get here.
/// 5. **Token match** -> `CategorySource.dictionary`,
///    `CategoryResult.tokenConfidence`.
/// 6. **Rail signals** -> `CategorySource.channel`, and only where the rail is
///    decisive.
/// 7. **Uncategorized**, with a sentence saying exactly what we could not
///    identify. This is a correct outcome, not a failure.
///
/// ## Three rules that are not negotiable
///
/// * **100% on-device.** There is no network call in this file, no fallback
///   "just for the unknown ones", and there never will be. The merchant
///   dictionary ships inside the APK, so the cascade behaves identically with
///   the config server permanently unreachable.
/// * **Never guess.** Every stage either clears its bar or stays silent. An
///   empty answer the app admits to costs one tap; a wrong answer costs the
///   user's trust in every other number on the screen.
/// * **Never wrongly exclude from spend.** A transfer or investment verdict
///   has to clear [ChannelSignals.minConfidenceToExcludeFromSpend], because
///   under-counting is invisible to the user and over-counting is not.
class CascadeCategorizer implements Categorizer {
  CascadeCategorizer({this.isCardTracked});

  /// Answers "have we seen this credit card's own transactions?".
  ///
  /// A credit-card bill payment is a transfer only when the app already
  /// counted the swipes. When the card is invisible to this phone the bill is
  /// the only evidence the money was spent, and treating it as a transfer
  /// would under-count the month. Null means "assume tracked", which is the
  /// common case.
  final bool Function(String? cardTail)? isCardTracked;

  final UserRuleStore _userRules = UserRuleStore();

  RuleSet _rules = RuleSet.empty;
  MerchantIndex _index = MerchantIndex.empty;
  Set<String> _validPaths = const <String>{};
  Map<String, String> _categoryNames = const <String, String>{};
  bool _ready = false;
  UserRuleChange? _lastRuleChange;

  /// User-rule hits are this confident: the user said so, and the only thing
  /// above it is the user saying so again on this exact transaction.
  static const double userRuleConfidence = 0.99;

  /// A `forced_category` on the matching parser rule.
  static const double parserRuleConfidence = 0.95;

  @override
  bool get isReady => _ready;

  /// The rule set currently loaded.
  RuleSet get rules => _rules;

  /// The merchant index currently loaded, for diagnostics.
  MerchantIndex get index => _index;

  /// The user's rules, in a stable order. Persist this list after every
  /// [upsertUserRule] or [removeUserRule]: an upsert may have disabled a
  /// contradicting rule, and leaving that unwritten is how a "fixed"
  /// correction comes back after a restart.
  List<UserRule> get userRules => _userRules.rules;

  /// Rules pointing at a category that is not in the loaded taxonomy. Show
  /// these in Settings as "needs attention"; they are never applied, and they
  /// are never silently dropped either.
  List<UserRule> get orphanedUserRules => _userRules.orphanedRules;

  /// What the last [upsertUserRule] did, including anything it superseded.
  UserRuleChange? get lastRuleChange => _lastRuleChange;

  @override
  Future<Result<void>> load(
    RuleSet rules, {
    List<UserRule> userRules = const <UserRule>[],
  }) async {
    if (rules.categories.isEmpty) {
      _ready = false;
      _rules = RuleSet.empty;
      _index = MerchantIndex.empty;
      _validPaths = const <String>{};
      _categoryNames = const <String, String>{};
      _userRules.loadAll(userRules);
      return Result<void>.err(
        AppError.corruptRules(
          'The rules pack has no categories, so everything would land in '
          'Uncategorized. Refusing to load it.',
        ),
      );
    }

    return Result.guard<void>(
      () {
        final paths = <String>{};
        final names = <String, String>{};
        for (final category in rules.categories) {
          paths.add(category.id);
          paths.addAll(category.paths);
          names[category.id] = category.name;
          for (final sub in category.subcategories) {
            names[category.pathFor(sub.id)] = '${category.name} - ${sub.name}';
          }
        }
        // The Uncategorized queue is a real destination, not a category.
        paths.add(CategoryResult.uncategorizedPath);
        names[CategoryResult.uncategorizedPath] = 'Uncategorized';

        _rules = rules;
        _index = MerchantIndex.build(rules.merchants);
        _validPaths = Set<String>.unmodifiable(paths);
        _categoryNames = Map<String, String>.unmodifiable(names);
        _userRules.loadAll(userRules, validPaths: _validPaths);
        _ready = true;
      },
      code: ErrorCodes.corruptRules,
      message: 'Could not index the rules pack',
    );
  }

  @override
  CategoryResult categorize(ParsedMessage message) => categorizeMessage(message);

  /// [categorize] plus the two fields a `ParsedMessage` cannot carry.
  ///
  /// The ingest pipeline has the `RawMessage` and should call this, so that
  /// `UserRuleMatch.bodyContains` and `UserRuleMatch.senderExact` rules can
  /// actually fire. [body] is used for matching only - it is never stored,
  /// never logged and never leaves this call.
  CategoryResult categorizeMessage(
    ParsedMessage message, {
    String? senderHeader,
    String? body,
  }) {
    try {
      return _decide(message, senderHeader: senderHeader, body: body);
    } catch (_) {
      // Total by contract: a bad rules pack must produce a question for the
      // user, never an exception on the ingest path.
      return CategoryResult.uncategorized(
        explanation: 'We could not work this one out - tap to choose a category',
      );
    }
  }

  CategoryResult _decide(
    ParsedMessage message, {
    String? senderHeader,
    String? body,
  }) {
    if (!_ready) {
      return CategoryResult.uncategorized(
        explanation: 'Categories are still loading - tap to choose one',
      );
    }

    final merchant = MerchantNormalizer.normalize(message.merchantRaw);
    final vpa = VpaHeuristics.parse(message.vpa);
    final sender = (senderHeader ?? message.issuer)?.trim().toUpperCase();

    // --- 1. the user's own rules -------------------------------------------
    final rule = _userRules.resolve(
      merchantNormalized: merchant.key.isEmpty ? null : merchant.key,
      vpa: vpa.isEmpty ? null : vpa.full,
      sender: sender,
      body: body,
    );
    if (rule != null) {
      if (!_isKnownPath(rule.categoryPath)) {
        // Do NOT fall through to auto-categorisation here. The user answered
        // this question once; quietly overruling them with the dictionary is
        // exactly the "my correction did not stick" bug.
        return CategoryResult.uncategorized(
          explanation:
              'Your rule for ${rule.merchantName ?? rule.pattern} points at a '
              'category that no longer exists - tap to pick a new one',
        );
      }
      final label = _labelOf(rule.categoryPath);
      final who = rule.merchantName ?? rule.pattern;
      return CategoryResult(
        categoryPath: rule.categoryPath,
        kind: _kindOf(rule.categoryPath) ?? rule.kind,
        confidence: userRuleConfidence,
        source: CategorySource.userRule,
        explanation: 'You categorised $who as $label',
        merchantName: rule.merchantName,
        matchedOn: rule.pattern,
      );
    }

    // --- 2. a forced category from the parser rule -------------------------
    final forced = message.forcedCategoryPath;
    if (forced != null && forced.isNotEmpty && _isKnownPath(forced)) {
      if (forced == CategoryResult.uncategorizedPath) {
        return CategoryResult.uncategorized(
          explanation:
              'This message type never says what the money was for - tap to '
              'choose a category',
        );
      }
      return CategoryResult(
        categoryPath: forced,
        kind: _kindOf(forced) ?? CategoryKind.expense,
        confidence: parserRuleConfidence,
        source: CategorySource.parserRule,
        explanation: 'Messages like this one are always ${_labelOf(forced)}',
        matchedOn: message.ruleId,
      );
    }

    // --- 3. exact merchant alias -------------------------------------------
    final exact = _index.lookupExact(merchant);
    if (exact != null) {
      final result = _fromMerchant(
        exact,
        source: CategorySource.dictionary,
        confidence: CategoryResult.dictionaryConfidence,
        explanation: _exactExplanation(exact),
      );
      if (result != null) return result;
    }

    // A gateway we recognise but the dictionary does not carry.
    if (_index.isGatewayKey(merchant.key) || _index.isGatewayKey(merchant.base)) {
      return _gatewayResult(merchant.key.isEmpty ? merchant.base : merchant.key);
    }

    // --- 4. full VPA prefix -------------------------------------------------
    final vpaMatch = _index.lookupVpa(vpa.full);
    if (vpaMatch != null && !VpaHeuristics.isAcquirerPrefix(vpaMatch.matchedOn)) {
      final result = _fromMerchant(
        vpaMatch,
        source: CategorySource.vpa,
        confidence: CategoryResult.dictionaryConfidence,
        explanation:
            'Matched UPI id ${vpaMatch.matchedOn} to ${vpaMatch.entry.name}',
      );
      if (result != null) return result;
    }

    // --- 5. token match -----------------------------------------------------
    final tokenMatch = _index.lookupTokens(merchant);
    if (tokenMatch != null) {
      final kind = _kindOf(tokenMatch.entry.categoryPath);
      // A fuzzy name match must never be the reason money leaves the spend
      // total. Matching SBI against SBICARD would turn a purchase into a card
      // bill; forbid the whole class of error structurally.
      if (kind != null && !kind.isNetZero) {
        final result = _fromMerchant(
          tokenMatch,
          source: CategorySource.dictionary,
          confidence: CategoryResult.tokenConfidence,
          explanation: '"${merchant.key}" looks like ${tokenMatch.entry.name} '
              '- tap to change it if that is wrong',
        );
        if (result != null) return result;
      }
    }

    // --- 6. the payment rail ------------------------------------------------
    final signal = ChannelSignals.resolve(
      channel: message.channel,
      direction: message.direction,
      text: _searchText(message, body),
      isCardTransaction: message.isCardTransaction,
      cardIsTracked: isCardTracked?.call(message.cardTail) ?? true,
    );
    if (signal != null && _isKnownPath(signal.categoryPath)) {
      final kind = _kindOf(signal.categoryPath);
      final excludesFromSpend = kind != null && kind.isNetZero;
      if (kind != null &&
          (!excludesFromSpend ||
              signal.confidence >= ChannelSignals.minConfidenceToExcludeFromSpend)) {
        return CategoryResult(
          categoryPath: signal.categoryPath,
          kind: kind,
          confidence: signal.confidence,
          source: CategorySource.channel,
          explanation: signal.explanation,
          matchedOn: signal.matchedOn,
        );
      }
    }

    // --- 7. say precisely what we could not identify ------------------------
    return _unidentified(merchant, vpa);
  }

  /// Turns a dictionary hit into a result, or null when the hit does not
  /// actually identify anyone.
  CategoryResult? _fromMerchant(
    MerchantMatch match, {
    required CategorySource source,
    required double confidence,
    required String explanation,
  }) {
    final entry = match.entry;
    if (_index.isGateway(entry)) return _gatewayResult(entry.name);

    final path = entry.categoryPath;
    if (path == CategoryResult.uncategorizedPath) {
      return _gatewayResult(entry.name);
    }
    final kind = _kindOf(path);
    if (kind == null) {
      // The dictionary points at a category this taxonomy does not have. Do
      // not invent one: ask.
      return CategoryResult.uncategorized(
        explanation:
            '${entry.name} is filed under a category this version does not '
            'know - tap to choose one',
      );
    }
    return CategoryResult(
      categoryPath: path,
      kind: kind,
      confidence: confidence,
      source: source,
      explanation: explanation,
      merchantName: entry.name,
      matchedOn: match.matchedOn,
    );
  }

  /// Money went THROUGH a payment gateway. The shop is genuinely not in the
  /// message, so there is nothing honest to categorise it as.
  CategoryResult _gatewayResult(String gatewayName) =>
      CategoryResult.uncategorized(
        explanation:
            'Paid through $gatewayName, a payment gateway - the shop is not in '
            'the message, so tap to tell us what it was',
      );

  /// The last word: a specific sentence about what we could not identify.
  /// Vague failures make users think the app is broken; precise ones make them
  /// answer the question.
  CategoryResult _unidentified(NormalizedMerchant merchant, VpaParts vpa) {
    final app = vpa.paymentApp;
    final via = app == null ? '' : ' through $app';

    switch (vpa.shape) {
      case VpaShape.merchantQrOpaque:
        return CategoryResult.uncategorized(
          explanation: 'Paid to a UPI QR code$via - the shop puts nothing in '
              'the message, so tap once and we will remember it',
        );
      case VpaShape.personPhone:
      case VpaShape.personName:
        return CategoryResult.uncategorized(
          explanation: 'Paid to a person (${vpa.full})$via - tap to tell us '
              'what it was for',
        );
      case VpaShape.merchantNamed:
      case VpaShape.ambiguous:
        if (vpa.local.isEmpty && app != null) {
          return CategoryResult.uncategorized(
            explanation:
                'This message names only the payment app ($app), not the shop '
                '- tap to choose a category',
          );
        }
        return CategoryResult.uncategorized(
          explanation: 'We do not know ${vpa.full} yet - tap once and we will '
              'remember it',
        );
      case VpaShape.none:
        break;
    }

    if (merchant.isNotEmpty) {
      return CategoryResult.uncategorized(
        explanation: 'We do not know "${merchant.key}" yet - tap once and we '
            'will remember it',
      );
    }
    return CategoryResult.uncategorized();
  }

  String _exactExplanation(MerchantMatch match) {
    final surface = match.matchedOn.toUpperCase();
    final name = match.entry.name;
    if (surface == name.toUpperCase()) return 'Matched merchant $name';
    return 'Matched merchant $surface ($name)';
  }

  /// Everything the rail heuristics may read: the counterparty string and,
  /// when the pipeline passes it, the message body. Upper-cased once.
  String _searchText(ParsedMessage message, String? body) {
    final parts = <String>[?message.merchantRaw, ?body];
    return parts.join(' ').toUpperCase();
  }

  @override
  String normalizeMerchant(String? raw) => MerchantNormalizer.key(raw);

  @override
  CategoryKind? kindOf(String categoryPath) => _kindOf(categoryPath);

  @override
  MerchantEntry? merchantFor(String normalizedMerchant) =>
      _index.entryForKey(normalizedMerchant);

  @override
  Future<Result<void>> upsertUserRule(UserRule rule) async {
    if (!_isKnownPath(rule.categoryPath) ||
        rule.categoryPath == CategoryResult.uncategorizedPath) {
      return Result<void>.err(
        AppError.invalidArgument(
          'No category "${rule.categoryPath}" in this taxonomy',
          details: <String, Object?>{'ruleId': rule.id},
        ),
      );
    }
    if (rule.pattern.trim().isEmpty) {
      return Result<void>.err(
        AppError.invalidArgument(
          'A rule with an empty pattern would match nothing',
          details: <String, Object?>{'ruleId': rule.id},
        ),
      );
    }
    _lastRuleChange = _userRules.upsert(rule);
    return okVoid;
  }

  @override
  Future<Result<void>> removeUserRule(String ruleId) async {
    _userRules.remove(ruleId);
    _lastRuleChange = null;
    return okVoid;
  }

  /// Builds the rule behind a correction, keyed the way this categoriser
  /// looks things up. Use this rather than constructing a [UserRule] by hand:
  /// a rule keyed on a raw merchant string stops matching the moment the
  /// terminal id changes.
  Result<UserRule> ruleFromCorrection({
    required String id,
    required String categoryPath,
    required DateTime now,
    ParsedMessage? message,
    String? merchantRaw,
    String? vpa,
    String? senderHeader,
    String? merchantName,
    UserRuleMatch? preferredMatch,
    bool applyToExisting = true,
  }) {
    if (!_isKnownPath(categoryPath) ||
        categoryPath == CategoryResult.uncategorizedPath) {
      return Result<UserRule>.err(
        AppError.invalidArgument('No category "$categoryPath" in this taxonomy'),
      );
    }
    return UserRuleStore.fromCorrection(
      id: id,
      categoryPath: categoryPath,
      kind: _kindOf(categoryPath) ?? CategoryKind.expense,
      now: now,
      merchantRaw: merchantRaw ?? message?.merchantRaw,
      vpa: vpa ?? message?.vpa,
      senderHeader: senderHeader ?? message?.issuer,
      merchantName: merchantName,
      preferredMatch: preferredMatch,
      applyToExisting: applyToExisting,
    );
  }

  /// Records that [ruleId] categorised a transaction. Call it after the
  /// transaction is committed, then persist [userRules].
  UserRule? noteRuleHit(String ruleId, {DateTime? now}) =>
      _userRules.noteHit(ruleId, now: now);

  bool _isKnownPath(String path) => _validPaths.contains(path);

  CategoryKind? _kindOf(String path) {
    if (!_validPaths.contains(path)) return null;
    if (path == CategoryResult.uncategorizedPath) {
      // Not a real category: the queue. An unidentified debit still counts
      // toward the spend total, because under-counting is the error the user
      // cannot see.
      return CategoryKind.expense;
    }
    return _rules.kindOfPath(path);
  }

  /// The human label for a path: "Food & Dining - Food Delivery".
  String _labelOf(String path) => _categoryNames[path] ?? path;
}
