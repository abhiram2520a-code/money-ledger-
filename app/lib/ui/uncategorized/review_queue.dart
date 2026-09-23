/// The review queue: what the app could not name, grouped the way a person
/// would think about it.
///
/// The app never guesses a merchant and never asks a server, so some
/// transactions arrive with no category. That is a promise being kept, not a
/// failure - and this file turns it into something quick to clear: repeated
/// payees collapse into one card, one tap categorises the whole group, and the
/// choice becomes a rule so the same payee is never asked about twice.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

/// How many uncategorised rows the queue holds in memory at once.
///
/// A queue longer than this is a first-run backfill, and the user clears it
/// from the top; loading ten thousand rows to render twenty is how a review
/// screen becomes the slowest screen in the app.
const int kQueuePageSize = 300;

/// How many historical rows a "fix the older ones too" sweep will scan.
///
/// Bounded on purpose. The alternative - an unbounded table scan on the main
/// isolate - stutters the UI on exactly the phones that have the most history.
const int kBackfillScanLimit = 2000;

/// A run of uncategorised transactions that are plainly the same payee.
@immutable
class PayeeGroup {
  const PayeeGroup({
    required this.key,
    required this.label,
    required this.transactions,
    required this.total,
    this.merchantNormalized,
    this.vpa,
  });

  /// Stable identity for the group, used as a widget key and for expansion
  /// state. Never shown to the user.
  final String key;

  /// What to call this payee on screen.
  final String label;

  /// Oldest first, because the oldest is the one the user is most likely to
  /// have forgotten and most wants to see the message for.
  final List<Transaction> transactions;

  /// The sum of the group, as a magnitude. Debits and credits are not netted:
  /// a group is one payee, not a statement.
  final Money total;

  /// The normalised merchant string, when the transactions have one. This is
  /// what a merchant rule matches on, normalised by the categoriser itself so
  /// a rule created here matches the next message exactly.
  final String? merchantNormalized;

  /// The UPI id, when the transactions share one.
  final String? vpa;

  int get count => transactions.length;

  bool get isSingle => transactions.length == 1;

  /// Whether a durable rule can be built from this group at all. A payment
  /// with no merchant string and no UPI id has nothing to key a rule on, so
  /// the app categorises the row and honestly does not promise to remember.
  bool get canMakeRule =>
      (merchantNormalized != null && merchantNormalized!.isNotEmpty) ||
      (vpa != null && vpa!.isNotEmpty);

  Set<String> get ids => transactions.map((Transaction t) => t.id).toSet();
}

/// The result of one review action, so the screen can say exactly what it did.
@immutable
class ReviewApplyResult {
  const ReviewApplyResult({
    required this.categorized,
    required this.ruleCreated,
    required this.pastCandidateIds,
    this.error,
  });

  const ReviewApplyResult.failed(AppError this.error)
      : categorized = 0,
        ruleCreated = false,
        pastCandidateIds = const <String>[];

  /// How many transactions in the group were re-categorised.
  final int categorized;

  /// Whether a [UserRule] was stored, so the app will not ask again.
  final bool ruleCreated;

  /// Already-categorised older transactions the new rule would also match.
  /// Offered to the user; never applied without being asked, because silently
  /// rewriting history is how an app loses a user's trust in its totals.
  final List<String> pastCandidateIds;

  final AppError? error;

  bool get isOk => error == null;
}

/// The live queue: every uncategorised transaction, oldest first.
///
/// A stream rather than a one-shot read, so clearing an item removes its card
/// without a manual refresh, and so a message arriving while the user is
/// reviewing simply appears at the end.
final StreamProvider<List<Transaction>> uncategorizedQueueProvider =
    StreamProvider<List<Transaction>>((Ref ref) {
  return ref.watch(ledgerRepositoryProvider).watchTransactions(
        const TxnQuery(
          onlyUncategorized: true,
          includeExcluded: true,
          newestFirst: false,
          limit: kQueuePageSize,
        ),
      );
});

/// The queue, collapsed into payee groups. Groups with more than one
/// transaction come first: they are where a single tap does the most work.
final Provider<List<PayeeGroup>> payeeGroupsProvider =
    Provider<List<PayeeGroup>>((Ref ref) {
  final List<Transaction> queue =
      ref.watch(uncategorizedQueueProvider).valueOrNull ?? const <Transaction>[];
  if (queue.isEmpty) return const <PayeeGroup>[];
  final Categorizer categorizer = ref.watch(categorizerProvider);
  return groupByPayee(queue, normalize: categorizer.normalizeMerchant);
});

/// Category paths the user has reached for recently, newest first.
///
/// Sourced from their own rules rather than from a "popular categories" list,
/// because the shortcut that helps is the one that reflects what *this* person
/// actually spends on.
final Provider<List<String>> recentCategoryPathsProvider =
    Provider<List<String>>((Ref ref) {
  final List<UserRule> rules =
      ref.watch(userRulesProvider).valueOrNull ?? const <UserRule>[];
  final List<UserRule> sorted = List<UserRule>.of(rules)
    ..sort((UserRule a, UserRule b) =>
        (b.updatedAt ?? b.createdAt).compareTo(a.updatedAt ?? a.createdAt));
  final Set<String> paths = <String>{
    for (final UserRule r in sorted) r.categoryPath,
  };
  return List<String>.unmodifiable(paths.take(8));
});

/// Groups uncategorised transactions by payee.
///
/// [normalize] is `Categorizer.normalizeMerchant`, passed in rather than
/// reimplemented: a rule created from a group must match on exactly the string
/// the categoriser will produce for the next message, or the user teaches the
/// app something it then fails to apply.
///
/// Pure and total, so it is testable without a database.
List<PayeeGroup> groupByPayee(
  List<Transaction> transactions, {
  required String Function(String?) normalize,
}) {
  final Map<String, List<Transaction>> buckets = <String, List<Transaction>>{};
  final Map<String, String> labels = <String, String>{};
  final Map<String, String?> merchantKeys = <String, String?>{};
  final Map<String, String?> vpaKeys = <String, String?>{};

  for (final Transaction txn in transactions) {
    final String merchant = normalize(txn.merchantRaw ?? txn.merchantName);
    final String vpa = (txn.vpa ?? '').trim();

    final String key;
    final String label;
    String? merchantKey;
    String? vpaKey;

    if (merchant.isNotEmpty) {
      key = 'm:$merchant';
      label = _prettyLabel(txn.merchantName, txn.merchantRaw, merchant);
      merchantKey = merchant;
      vpaKey = vpa.isEmpty ? null : vpa;
    } else if (vpa.isNotEmpty) {
      key = 'v:${vpa.toLowerCase()}';
      label = vpa;
      vpaKey = vpa;
    } else {
      // Nothing to group on. Its own group of one, so it is still reviewable.
      key = 't:${txn.id}';
      label = txn.direction.isCredit ? 'Money in' : 'Payment';
    }

    buckets.putIfAbsent(key, () => <Transaction>[]).add(txn);
    labels.putIfAbsent(key, () => label);
    merchantKeys.putIfAbsent(key, () => merchantKey);
    vpaKeys.putIfAbsent(key, () => vpaKey);
  }

  final List<PayeeGroup> groups = <PayeeGroup>[
    for (final MapEntry<String, List<Transaction>> e in buckets.entries)
      PayeeGroup(
        key: e.key,
        label: labels[e.key] ?? 'Payment',
        transactions: List<Transaction>.unmodifiable(e.value),
        total: Money.sum(e.value.map((Transaction t) => t.amount.abs)),
        merchantNormalized: merchantKeys[e.key],
        vpa: vpaKeys[e.key],
      ),
  ];

  groups.sort((PayeeGroup a, PayeeGroup b) {
    // Repeated payees first: one tap there clears the most rows.
    final int byCount = b.count.compareTo(a.count);
    if (byCount != 0) return byCount;
    // Then biggest money, because that is what the user cares about getting
    // right.
    final int byTotal = b.total.compareTo(a.total);
    if (byTotal != 0) return byTotal;
    return a.label.compareTo(b.label);
  });

  return List<PayeeGroup>.unmodifiable(groups);
}

String _prettyLabel(String? merchantName, String? merchantRaw, String normalized) {
  final String name = merchantName?.trim() ?? '';
  if (name.isNotEmpty) return name;
  final String raw = merchantRaw?.trim() ?? '';
  if (raw.isNotEmpty && raw.length <= 40) return raw;
  return normalized;
}

/// The message a transaction was read from, for the "show me why" card.
///
/// Returns `null` rather than failing when the body has been purged by the
/// retention job or the transaction was entered by hand - both are normal, and
/// the card says which it is.
final FutureProviderFamily<RawMessage?, String> rawMessageProvider =
    FutureProvider.family<RawMessage?, String>((Ref ref, String id) async {
  final Result<RawMessage?> result =
      await ref.watch(ledgerRepositoryProvider).rawMessageById(id);
  return result.getOrElse(null);
});
