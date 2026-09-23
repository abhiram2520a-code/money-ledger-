/// The write side of the review queue.
///
/// Everything the user can do to an unknown transaction happens here, so the
/// screen stays a screen: categorise a group, remember the choice as a rule,
/// sweep the same rule over older transactions, or say the row is not a
/// transaction at all.
///
/// Two invariants the widgets rely on:
/// * Nothing throws. Every repository call is a `Result`, and failures come
///   back as a message the screen can show.
/// * A rule is never created that the categoriser would not match. The pattern
///   is produced by `Categorizer.normalizeMerchant`, the same function that
///   will normalise the next message.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:ledger/ui/widgets/widgets.dart';

import 'review_queue.dart';

/// Whether a choice in the queue also becomes a durable rule.
///
/// On by default, because the queue only ever shrinks if the app learns. The
/// user can turn it off for a one-off payment they never expect again.
final StateProvider<bool> rememberChoicesProvider =
    StateProvider<bool>((Ref ref) => true);

/// Busy flag, so a double tap cannot post the same category twice.
final NotifierProvider<ReviewController, bool> reviewControllerProvider =
    NotifierProvider<ReviewController, bool>(ReviewController.new);

class ReviewController extends Notifier<bool> {
  @override
  bool build() => false;

  LedgerRepository get _repo => ref.read(ledgerRepositoryProvider);
  Categorizer get _categorizer => ref.read(categorizerProvider);
  DateTime get _now => ref.read(clockProvider)();

  /// Categorises every transaction in [group], optionally remembering the
  /// choice as a rule, and reports which older transactions the same rule
  /// would also cover.
  ///
  /// The older ones are reported, not changed: the user asked about these
  /// transactions, and quietly rewriting last month's totals underneath them
  /// is not an answer to that question.
  Future<ReviewApplyResult> applyToGroup({
    required PayeeGroup group,
    required CategoryPick pick,
    required bool remember,
  }) async {
    if (state) {
      return const ReviewApplyResult(
        categorized: 0,
        ruleCreated: false,
        pastCandidateIds: <String>[],
      );
    }
    state = true;
    try {
      final CategoryResult category = CategoryResult.manual(pick.path, pick.kind);

      int done = 0;
      for (final Transaction txn in group.transactions) {
        final Result<Transaction> result = await _repo.recategorize(txn.id, category);
        if (result.isErr) return ReviewApplyResult.failed(result.errorOrNull!);
        done++;
      }

      bool ruleCreated = false;
      List<String> pastCandidates = const <String>[];

      if (remember && group.canMakeRule) {
        final UserRule rule = buildRuleFor(group, pick, now: _now);
        final Result<UserRule> stored = await _repo.upsertUserRule(rule);
        if (stored.isErr) {
          // The categorisation stuck; only the memory failed. Say so rather
          // than pretending the whole action failed.
          return ReviewApplyResult(
            categorized: done,
            ruleCreated: false,
            pastCandidateIds: const <String>[],
            error: stored.errorOrNull,
          );
        }
        final Result<void> indexed = await _categorizer.upsertUserRule(rule);
        ruleCreated = indexed.isOk;
        pastCandidates = await _findPastMatches(rule, exclude: group.ids);
      }

      return ReviewApplyResult(
        categorized: done,
        ruleCreated: ruleCreated,
        pastCandidateIds: pastCandidates,
      );
    } finally {
      state = false;
    }
  }

  /// Applies [pick] to transactions the user explicitly agreed to sweep.
  /// Returns how many actually changed.
  Future<int> applyToIds(List<String> ids, CategoryPick pick) async {
    if (ids.isEmpty || state) return 0;
    state = true;
    try {
      final CategoryResult category = CategoryResult.manual(pick.path, pick.kind);
      int changed = 0;
      for (final String id in ids) {
        final Result<Transaction> result = await _repo.recategorize(id, category);
        if (result.isOk) changed++;
      }
      return changed;
    } finally {
      state = false;
    }
  }

  /// Marks a row as "not a real transaction".
  ///
  /// A soft delete: the transaction becomes `TxnStatus.voided` and leaves every
  /// total, while its raw message stays so the audit trail - and a later
  /// re-parse after a rules update - still works.
  Future<Result<void>> discard(String transactionId) =>
      _repo.deleteTransaction(transactionId);

  /// Keeps the transaction but takes it out of the totals, for a payment the
  /// user does not consider theirs (a reimbursed bill, a friend's share).
  Future<Result<void>> excludeFromTotals(Transaction txn) async {
    final Transaction updated = txn
        .copyWith(isExcludedFromTotals: true, updatedAt: _now)
        .markEdited(const <String>['isExcludedFromTotals'], now: _now);
    final Result<Transaction> result = await _repo.updateTransaction(updated);
    return result.map<void>((Transaction _) {});
  }

  /// Older, already-categorised transactions the new rule would also match.
  ///
  /// Scans a bounded window of history rather than the whole table, and skips
  /// anything the user categorised by hand - a rule created today must not
  /// overwrite a decision the user made deliberately last month.
  Future<List<String>> _findPastMatches(
    UserRule rule, {
    required Set<String> exclude,
  }) async {
    final Result<List<Transaction>> result = await _repo.transactions(
      const TxnQuery(limit: kBackfillScanLimit, includeExcluded: true),
    );
    final List<Transaction> all = result.getOrElse(const <Transaction>[]);
    final List<String> matches = <String>[];
    for (final Transaction txn in all) {
      if (exclude.contains(txn.id)) continue;
      if (txn.status == TxnStatus.voided) continue;
      if (txn.categorySource.isUserAuthored && !txn.isUncategorized) continue;
      if (txn.categoryPath == rule.categoryPath) continue;
      final bool hit = rule.matches(
        merchantNormalized:
            _categorizer.normalizeMerchant(txn.merchantRaw ?? txn.merchantName),
        vpa: txn.vpa,
      );
      if (hit) matches.add(txn.id);
    }
    return List<String>.unmodifiable(matches);
  }
}

/// The rule a review decision turns into.
///
/// Exact matches only. A "contains" rule created from one payment is how an
/// expense tracker quietly starts filing everything from `AMAZON PAY` under
/// Groceries; the user can loosen a rule later on the Rules screen, where the
/// consequence is visible.
///
/// Pure, so the mapping from a decision to a rule is testable on its own.
UserRule buildRuleFor(
  PayeeGroup group,
  CategoryPick pick, {
  required DateTime now,
}) {
  final String? merchant = group.merchantNormalized;
  final bool byMerchant = merchant != null && merchant.isNotEmpty;
  return UserRule(
    id: 'ur_${now.microsecondsSinceEpoch}',
    match: byMerchant ? UserRuleMatch.merchantExact : UserRuleMatch.vpaExact,
    pattern: byMerchant ? merchant : (group.vpa ?? ''),
    categoryPath: pick.path,
    kind: pick.kind,
    createdAt: now,
    merchantName: group.label,
    applyToExisting: false,
  );
}
