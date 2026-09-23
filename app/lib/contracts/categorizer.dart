import '../core/result.dart';
import '../models/models.dart';

/// Decides which category a parsed message belongs to.
///
/// Hard requirements on every implementation:
/// * 100% ON-DEVICE. It consults the loaded [RuleSet] and the user's own
///   rules, and nothing else. It never calls a network service to identify a
///   merchant - not as a fallback, not "just for unknown ones".
/// * NEVER GUESSES. When nothing matches it returns
///   `CategoryResult.uncategorized` so the transaction lands in the
///   Uncategorized queue and the app ASKS the user. A wrong category the user
///   has to find and fix is worse than an empty one the app admits to.
/// * ALWAYS EXPLAINS. Every result carries a human sentence in
///   `CategoryResult.explanation` - "Matched merchant SWIGGYUPI".
/// * TOTAL and SYNCHRONOUS. [categorize] never throws and never awaits.
abstract interface class Categorizer {
  /// Whether [load] has completed successfully.
  bool get isReady;

  /// Loads the shipped taxonomy and merchant dictionary, plus the user's own
  /// rules. Called at startup and again whenever either changes.
  ///
  /// Fails with `ErrorCodes.corruptRules` when [rules] has no categories,
  /// because categorising against an empty taxonomy would send every
  /// transaction to Uncategorized.
  Future<Result<void>> load(RuleSet rules, {List<UserRule> userRules = const <UserRule>[]});

  /// Categorises one parsed message.
  ///
  /// Precedence, which implementations must preserve:
  /// 1. `UserRule` matches, highest `priority` first, then newest
  ///    -> `CategorySource.userRule`.
  /// 2. `ParsedMessage.forcedCategoryPath` from the matching parser rule
  ///    -> `CategorySource.parserRule`.
  /// 3. Exact merchant alias, then full-VPA prefix
  ///    -> `CategorySource.dictionary` / `.vpa`, confidence
  ///    `CategoryResult.dictionaryConfidence`.
  /// 4. Token containment -> `CategorySource.dictionary`, confidence
  ///    `CategoryResult.tokenConfidence`.
  /// 5. Channel-only inference, and ONLY where the channel is decisive - an
  ///    ATM withdrawal is a transfer to cash, never a purchase
  ///    -> `CategorySource.channel`.
  /// 6. `CategoryResult.uncategorized`.
  ///
  /// Never returns a path that is absent from the loaded taxonomy.
  CategoryResult categorize(ParsedMessage message);

  /// The normalisation applied to `ParsedMessage.merchantRaw` before lookup:
  /// upper case, acquirer prefixes stripped (`RAZ*`, `PAYU`, `UPI/`), trailing
  /// terminal digits stripped, punctuation collapsed.
  ///
  /// Exposed because `UserRule.pattern` must be normalised the same way, or a
  /// rule the user creates from a transaction will not match the next one.
  String normalizeMerchant(String? raw);

  /// The kind of a `'<category>/<subcategory>'` path, or `null` when the path
  /// is not in the loaded taxonomy. Callers must treat `null` as "do not
  /// count", never as expense.
  CategoryKind? kindOf(String categoryPath);

  /// The dictionary entry behind a category decision, for the UI.
  MerchantEntry? merchantFor(String normalizedMerchant);

  /// Adds or replaces a user rule and re-indexes. Fails with
  /// `ErrorCodes.invalidArgument` when `rule.categoryPath` is not in the
  /// taxonomy. Persisting the rule is the repository's job, not this one's.
  Future<Result<void>> upsertUserRule(UserRule rule);

  /// Removes a user rule. Succeeds even when the id is unknown.
  Future<Result<void>> removeUserRule(String ruleId);
}
