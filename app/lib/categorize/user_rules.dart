import 'package:flutter/foundation.dart';

import '../core/result.dart';
import '../models/models.dart';
import 'merchant_normalizer.dart';
import 'vpa_heuristics.dart';

/// What one [UserRuleStore.upsert] did, so the repository can persist a
/// coherent rule list and the UI can tell the user what changed.
@immutable
class UserRuleChange {
  const UserRuleChange({
    required this.applied,
    this.superseded = const <UserRule>[],
    this.replaced,
  });

  /// The rule that is now live, with its pattern normalised.
  final UserRule applied;

  /// Rules that contradicted [applied] and were disabled by it. They are
  /// returned - not deleted - so the repository writes the disabled row and
  /// the Rules screen can show a coherent, non-contradictory list.
  final List<UserRule> superseded;

  /// The previous version of the same rule id, when this was an edit.
  final UserRule? replaced;

  bool get changedSomething =>
      replaced == null || replaced != applied || superseded.isNotEmpty;

  /// One sentence for the toast: "Updated your rule for Swiggy (was
  /// Groceries)."
  String get summary {
    final name = applied.merchantName ?? applied.pattern;
    if (superseded.isEmpty) return 'Saved your rule for $name';
    final previous = superseded.first.categoryPath;
    return 'Updated your rule for $name (was $previous)';
  }

  @override
  String toString() =>
      'UserRuleChange(${applied.id}, superseded ${superseded.length})';
}

/// The user's own categorisation rules: the memory that turns "what is
/// q9876543210@ybl?" into "Chai, Food & Dining" forever after one tap.
///
/// ## The one bug this class exists to prevent
///
/// "The correction does not stick" is the most common one-star review in this
/// whole app category, and it is never one bug. The structural defences here:
///
/// * **Patterns are normalised, never raw.** A rule born from
///   `RAZ*SwiggyIN29481` is stored as `SWIGGY`, so it still fires next week
///   when the terminal id is different. [fromCorrection] is the only sane way
///   to build a rule and it does this for you.
/// * **Patterns are re-normalised on every load.** If
///   [MerchantNormalizer.version] is ever bumped, stored patterns are brought
///   forward instead of silently never matching again. The normaliser is
///   idempotent, so this is safe to repeat.
/// * **Contradictions are resolved, not stacked.** Upserting a rule disables
///   every live rule with the same scope and pattern, and hands them back so
///   they are actually persisted. Two live contradictory rules would make the
///   winner depend on iteration order, which is a bug nobody can reproduce.
/// * **Resolution is total and deterministic.** Ties are broken all the way
///   down to the rule id, so the same inputs always give the same rule.
/// * **A rule pointing at a category that no longer exists is surfaced**, via
///   [orphanedRules], rather than quietly matching nothing.
class UserRuleStore {
  UserRuleStore();

  final Map<String, UserRule> _rules = <String, UserRule>{};
  Set<String> _validPaths = const <String>{};

  /// Every live rule, in a stable order, ready to be persisted verbatim.
  List<UserRule> get rules {
    final all = _rules.values.toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    return List<UserRule>.unmodifiable(all);
  }

  /// Rules whose [UserRule.categoryPath] is not in the loaded taxonomy. They
  /// are kept, never applied, and shown in Settings as "needs attention" -
  /// because dropping them would be exactly the silent failure this class is
  /// built to avoid.
  List<UserRule> get orphanedRules => List<UserRule>.unmodifiable(
        rules.where((r) => !_isKnownPath(r.categoryPath)),
      );

  int get length => _rules.length;

  /// Replaces the whole set. [validPaths] is the loaded taxonomy; patterns are
  /// re-normalised with the CURRENT normaliser as they are read.
  void loadAll(Iterable<UserRule> rules, {Set<String> validPaths = const <String>{}}) {
    _validPaths = validPaths;
    _rules.clear();
    for (final rule in rules) {
      final canonical = canonicalize(rule);
      if (canonical.pattern.isEmpty) continue;
      _rules[canonical.id] = canonical;
    }
  }

  /// Adds or replaces [rule], disabling anything it contradicts.
  UserRuleChange upsert(UserRule rule) {
    final canonical = canonicalize(rule);
    final replaced = _rules[canonical.id];
    final superseded = <UserRule>[];

    for (final existing in _rules.values.toList()) {
      if (existing.id == canonical.id) continue;
      if (!existing.enabled) continue;
      if (existing.match != canonical.match) continue;
      if (existing.pattern != canonical.pattern) continue;
      final disabled = existing.copyWith(
        enabled: false,
        updatedAt: canonical.updatedAt ?? canonical.createdAt,
      );
      _rules[disabled.id] = disabled;
      superseded.add(disabled);
    }

    _rules[canonical.id] = canonical;
    superseded.sort((a, b) => a.id.compareTo(b.id));
    return UserRuleChange(
      applied: canonical,
      superseded: List<UserRule>.unmodifiable(superseded),
      replaced: replaced,
    );
  }

  /// Removes a rule. Returns the removed rule, or null when the id is unknown
  /// (which is not an error - the caller may be replaying a deletion).
  UserRule? remove(String ruleId) => _rules.remove(ruleId);

  /// Records that [ruleId] categorised a transaction. Deliberately NOT called
  /// from the categoriser: counting a hit is a side effect, and categorising
  /// must stay a pure, synchronous function. The ingest pipeline calls this
  /// once it has actually committed the transaction, then persists [rules].
  UserRule? noteHit(String ruleId, {DateTime? now}) {
    final rule = _rules[ruleId];
    if (rule == null) return null;
    final updated = rule.copyWith(
      hitCount: rule.hitCount + 1,
      updatedAt: now ?? DateTime.now(),
    );
    _rules[ruleId] = updated;
    return updated;
  }

  /// The rule that decides this message, or null.
  ///
  /// A rule whose category no longer exists STILL wins here. Falling through
  /// to auto-categorisation would quietly overrule a decision the user made,
  /// which is the bug this whole class exists to prevent; the caller checks
  /// the path and tells the user the rule needs attention instead.
  ///
  /// Precedence, exactly as the `Categorizer` contract specifies, and
  /// deterministic all the way down:
  /// 1. highest [UserRule.priority]
  /// 2. then newest [UserRule.createdAt]
  /// 3. then most specific scope (an exact VPA beats a body substring)
  /// 4. then rule id, so there is never an order-dependent answer.
  UserRule? resolve({
    String? merchantNormalized,
    String? vpa,
    String? sender,
    String? body,
  }) {
    UserRule? best;
    for (final rule in _rules.values) {
      if (!rule.enabled) continue;
      final matches = rule.matches(
        merchantNormalized: merchantNormalized,
        vpa: vpa,
        sender: sender,
        body: body,
      );
      if (!matches) continue;
      if (best == null || _beats(rule, best)) best = rule;
    }
    return best;
  }

  /// True when [a] outranks [b].
  static bool _beats(UserRule a, UserRule b) {
    if (a.priority != b.priority) return a.priority > b.priority;
    final byDate = a.createdAt.compareTo(b.createdAt);
    if (byDate != 0) return byDate > 0;
    final aRank = specificityOf(a.match);
    final bRank = specificityOf(b.match);
    if (aRank != bRank) return aRank > bRank;
    return a.id.compareTo(b.id) < 0;
  }

  /// How specific a scope is. Higher wins: an exact VPA names one payee, a
  /// sender header names a whole bank.
  static int specificityOf(UserRuleMatch match) => switch (match) {
        UserRuleMatch.vpaExact => 60,
        UserRuleMatch.merchantExact => 50,
        UserRuleMatch.vpaPrefix => 45,
        UserRuleMatch.merchantContains => 30,
        UserRuleMatch.bodyContains => 20,
        UserRuleMatch.senderExact => 10,
      };

  /// The default priority for a rule the app creates from a correction.
  /// Derived from the scope so that, under the contract's "priority first"
  /// ordering, the more specific rule still wins.
  static int defaultPriorityFor(UserRuleMatch match) =>
      100 + specificityOf(match);

  /// Normalises a rule's pattern for its scope. Idempotent.
  static UserRule canonicalize(UserRule rule) {
    final pattern = canonicalPattern(rule.match, rule.pattern);
    return pattern == rule.pattern ? rule : rule.copyWith(pattern: pattern);
  }

  /// The stored form of a pattern: merchant patterns go through
  /// [MerchantNormalizer], VPAs are lower-cased, senders upper-cased.
  static String canonicalPattern(UserRuleMatch match, String pattern) {
    final trimmed = pattern.trim();
    if (trimmed.isEmpty) return '';
    return switch (match) {
      UserRuleMatch.merchantExact ||
      UserRuleMatch.merchantContains =>
        MerchantNormalizer.key(trimmed),
      UserRuleMatch.vpaExact || UserRuleMatch.vpaPrefix => trimmed.toLowerCase(),
      UserRuleMatch.senderExact => trimmed.toUpperCase(),
      UserRuleMatch.bodyContains => trimmed.toUpperCase(),
    };
  }

  bool _isKnownPath(String path) =>
      _validPaths.isEmpty || _validPaths.contains(path);

  /// Builds the rule behind a user's correction.
  ///
  /// This is the ONLY supported way to create a rule from a transaction,
  /// because it picks the scope and the normalised pattern together. A UI that
  /// builds its own rule from `merchantRaw` re-introduces the "correction does
  /// not stick" bug on day one.
  ///
  /// Scope selection, most durable first:
  /// * an opaque QR code or a person's UPI id -> exact VPA, because that
  ///   string IS the payee's identity and never changes;
  /// * a named merchant VPA -> the `name@` prefix, so it keeps matching when
  ///   the merchant switches sponsor bank;
  /// * otherwise the normalised merchant string;
  /// * otherwise the sender header, which at least pins one bank.
  ///
  /// Returns `Err(invalidArgument)` when there is nothing stable to match on.
  /// That is deliberate: the caller must show the user that only this one
  /// transaction was changed, rather than promise a rule that cannot exist.
  static Result<UserRule> fromCorrection({
    required String id,
    required String categoryPath,
    required CategoryKind kind,
    required DateTime now,
    String? merchantRaw,
    String? vpa,
    String? senderHeader,
    String? merchantName,
    UserRuleMatch? preferredMatch,
    bool applyToExisting = true,
  }) {
    final normalized = MerchantNormalizer.normalize(merchantRaw);
    final parts = VpaHeuristics.parse(vpa);

    UserRuleMatch? match;
    String pattern = '';

    if (preferredMatch != null) {
      match = preferredMatch;
      pattern = switch (preferredMatch) {
        UserRuleMatch.vpaExact => parts.full,
        UserRuleMatch.vpaPrefix =>
          parts.local.isEmpty ? '' : '${parts.local}@',
        UserRuleMatch.merchantExact ||
        UserRuleMatch.merchantContains =>
          normalized.key,
        UserRuleMatch.senderExact => senderHeader?.trim().toUpperCase() ?? '',
        UserRuleMatch.bodyContains => '',
      };
    }

    if (pattern.isEmpty && !parts.isEmpty && parts.local.isNotEmpty) {
      if (parts.isOpaqueMerchant || parts.isPerson) {
        match = UserRuleMatch.vpaExact;
        pattern = parts.full;
      } else if (parts.shape == VpaShape.merchantNamed) {
        match = UserRuleMatch.vpaPrefix;
        pattern = '${parts.local}@';
      }
    }

    if (pattern.isEmpty && normalized.isNotEmpty) {
      match = UserRuleMatch.merchantExact;
      pattern = normalized.key;
    }

    if (pattern.isEmpty && (senderHeader?.trim().isNotEmpty ?? false)) {
      match = UserRuleMatch.senderExact;
      pattern = senderHeader!.trim().toUpperCase();
    }

    if (match == null || pattern.isEmpty) {
      return Result<UserRule>.err(
        AppError.invalidArgument(
          'This message has no merchant, UPI id or sender to build a rule on',
          details: <String, Object?>{
            'merchantRaw': merchantRaw == null ? 'null' : 'present',
            'vpa': vpa == null ? 'null' : 'present',
          },
        ),
      );
    }

    return Result<UserRule>.ok(
      UserRule(
        id: id,
        match: match,
        pattern: canonicalPattern(match, pattern),
        categoryPath: categoryPath,
        kind: kind,
        createdAt: now,
        merchantName: merchantName,
        priority: defaultPriorityFor(match),
        applyToExisting: applyToExisting,
      ),
    );
  }
}
