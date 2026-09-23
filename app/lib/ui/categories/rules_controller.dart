/// Editing the rules the app has learned.
///
/// A learned rule is a decision the user made once and the app now repeats
/// forever. That is only acceptable if the user can find it, see what it is
/// doing, change it, and delete it - which is what this file is for.
///
/// Every write goes to two places: the repository, which is the durable copy,
/// and the categoriser, which is the live index the next SMS is matched
/// against. Writing only one of them leaves the app disagreeing with itself.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

/// How far back a "apply this rule to what I already have" sweep will look.
const int kRuleSweepScanLimit = 2000;

final NotifierProvider<RulesController, bool> rulesControllerProvider =
    NotifierProvider<RulesController, bool>(RulesController.new);

class RulesController extends Notifier<bool> {
  @override
  bool build() => false;

  LedgerRepository get _repo => ref.read(ledgerRepositoryProvider);
  Categorizer get _categorizer => ref.read(categorizerProvider);

  /// Stores an edited rule and re-indexes it.
  ///
  /// Fails with `ErrorCodes.invalidArgument` when the category is not in the
  /// loaded taxonomy - which happens for real, when a rules pack drops a
  /// category a rule was pointing at. Saying so is better than storing a rule
  /// that will never match anything.
  Future<Result<UserRule>> save(UserRule rule) async {
    if (rule.pattern.trim().isEmpty) {
      return Err<UserRule>(
        AppError.invalidArgument('A rule needs something to match on.'),
      );
    }
    state = true;
    try {
      final Result<UserRule> stored = await _repo.upsertUserRule(rule);
      if (stored.isErr) return stored;
      final Result<void> indexed = await _categorizer.upsertUserRule(rule);
      final AppError? indexError = indexed.errorOrNull;
      if (indexError != null) return Err<UserRule>(indexError);
      return stored;
    } finally {
      state = false;
    }
  }

  /// Deletes a rule from both the database and the live index.
  ///
  /// Transactions the rule already categorised keep their category: the user
  /// asked to stop the rule, not to un-decide the past. Undoing the past is a
  /// separate, explicit action.
  Future<Result<void>> delete(String ruleId) async {
    state = true;
    try {
      final Result<void> removed = await _repo.deleteUserRule(ruleId);
      if (removed.isErr) return removed;
      return await _categorizer.removeUserRule(ruleId);
    } finally {
      state = false;
    }
  }

  /// Turns a rule on or off without losing it.
  Future<Result<UserRule>> setEnabled(UserRule rule, bool enabled) =>
      save(rule.copyWith(
        enabled: enabled,
        updatedAt: ref.read(clockProvider)(),
      ));

  /// Transactions the rule matches that are not already filed where it says.
  ///
  /// Read-only: it is the preview the user sees before agreeing to a sweep.
  /// Transactions the user categorised by hand are excluded, because a rule
  /// must never silently overrule a deliberate decision.
  ///
  /// Only merchant and UPI rules can be swept. A `senderExact` or
  /// `bodyContains` rule matches on the message, and a [Transaction] does not
  /// carry the message - the sweep says "0 matches" rather than matching on
  /// the wrong field, which would file every payment to a bank under one
  /// category.
  Future<List<Transaction>> preview(UserRule rule) async {
    final Result<List<Transaction>> result = await _repo.transactions(
      const TxnQuery(limit: kRuleSweepScanLimit, includeExcluded: true),
    );
    final List<Transaction> all = result.getOrElse(const <Transaction>[]);
    return <Transaction>[
      for (final Transaction txn in all)
        if (_isSweepCandidate(txn, rule)) txn,
    ];
  }

  /// Applies a rule to transactions already in the ledger. Returns how many
  /// changed.
  Future<int> applyToExisting(UserRule rule) async {
    final List<Transaction> candidates = await preview(rule);
    if (candidates.isEmpty) return 0;
    state = true;
    try {
      final CategoryResult category = CategoryResult(
        categoryPath: rule.categoryPath,
        kind: rule.kind,
        confidence: 1,
        source: CategorySource.userRule,
        explanation: rule.explanation,
        merchantName: rule.merchantName,
        matchedOn: rule.pattern,
      );
      int changed = 0;
      for (final Transaction txn in candidates) {
        final Result<Transaction> result =
            await _repo.recategorize(txn.id, category);
        if (result.isOk) changed++;
      }
      return changed;
    } finally {
      state = false;
    }
  }

  bool _isSweepCandidate(Transaction txn, UserRule rule) {
    if (txn.status == TxnStatus.voided) return false;
    if (txn.categoryPath == rule.categoryPath) return false;
    if (txn.categorySource == CategorySource.manual && !txn.isUncategorized) {
      return false;
    }
    switch (rule.match) {
      case UserRuleMatch.merchantExact:
      case UserRuleMatch.merchantContains:
      case UserRuleMatch.vpaExact:
      case UserRuleMatch.vpaPrefix:
        return rule.matches(
          merchantNormalized:
              _categorizer.normalizeMerchant(txn.merchantRaw ?? txn.merchantName),
          vpa: txn.vpa,
        );
      case UserRuleMatch.senderExact:
      case UserRuleMatch.bodyContains:
        // Needs the raw message, which a transaction does not carry.
        return false;
    }
  }
}
