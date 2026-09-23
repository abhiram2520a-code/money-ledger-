/// State for the category browser and the rule manager.
///
/// Two things the user wants from this screen and cannot get anywhere else:
/// where the money went, broken down by the taxonomy, and what the app has
/// learned from them - with a way to take any of it back.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

/// A half-open month `[from, to)` in local time.
///
/// Half-open on purpose: a transaction at exactly midnight on the 1st belongs
/// to the new month and to nothing else, so two adjacent months can never
/// double-count it.
@immutable
class MonthRange {
  const MonthRange(this.from, this.to);

  factory MonthRange.of(DateTime instant) {
    final DateTime local = instant.toLocal();
    return MonthRange(
      DateTime(local.year, local.month),
      DateTime(local.year, local.month + 1),
    );
  }

  final DateTime from;
  final DateTime to;

  MonthRange get previous => MonthRange.of(DateTime(from.year, from.month - 1));

  MonthRange get next => MonthRange.of(DateTime(from.year, from.month + 1));

  bool containsNow(DateTime now) => !now.isBefore(from) && now.isBefore(to);

  @override
  String toString() => 'MonthRange($from -> $to)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MonthRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}

/// One row of the category browser: a top-level category and what it cost.
@immutable
class CategoryRollup {
  const CategoryRollup({
    required this.categoryId,
    required this.name,
    required this.kind,
    required this.total,
    required this.count,
    required this.subtotals,
  });

  final String categoryId;
  final String name;
  final CategoryKind kind;

  /// The sum over this category in the selected month.
  final Money total;

  final int count;

  /// Per-subcategory totals, descending. Keys are full `'cat/sub'` paths.
  final List<SpendBucket> subtotals;

  bool get isEmpty => count == 0;

  /// Only expense categories are spending. Transfers and investments appear in
  /// this list with their totals, clearly labelled, because the user still
  /// wants to see them - they are just never added to the spend figure.
  bool get countsAsSpend => kind.countsAsSpend;
}

/// The month the category screens are looking at.
final StateProvider<MonthRange> categoriesMonthProvider =
    StateProvider<MonthRange>((Ref ref) => MonthRange.of(ref.read(clockProvider)()));

/// Spend per category path for the selected month, straight from the
/// repository so the numbers on this screen and on the dashboard are computed
/// by the same query.
final FutureProvider<List<SpendBucket>> categorySpendProvider =
    FutureProvider<List<SpendBucket>>((Ref ref) async {
  final MonthRange month = ref.watch(categoriesMonthProvider);
  final Result<List<SpendBucket>> result = await ref
      .watch(ledgerRepositoryProvider)
      .spendByCategory(from: month.from, to: month.to);
  return result.fold(
    (List<SpendBucket> buckets) => buckets,
    (AppError error) => throw error,
  );
});

/// Total spend for the selected month. Only `CategoryKind.expense` debits, by
/// the repository's own `countsAsSpend` rule.
final FutureProvider<Money> categoriesMonthSpendProvider =
    FutureProvider<Money>((Ref ref) async {
  final MonthRange month = ref.watch(categoriesMonthProvider);
  final Result<Money> result = await ref
      .watch(ledgerRepositoryProvider)
      .totalSpend(from: month.from, to: month.to);
  return result.getOrElse(Money.zero);
});

/// The browser rows: every category in the taxonomy, with the month's totals
/// folded in. Categories with no activity are included with a zero total, so
/// the taxonomy stays browsable in a month where nothing was spent.
final Provider<List<CategoryRollup>> categoryRollupsProvider =
    Provider<List<CategoryRollup>>((Ref ref) {
  final List<CategoryDef> taxonomy = ref.watch(taxonomyProvider);
  final List<SpendBucket> buckets =
      ref.watch(categorySpendProvider).valueOrNull ?? const <SpendBucket>[];
  return rollUpByCategory(taxonomy, buckets);
});

/// Folds per-path buckets into per-category rollups.
///
/// Pure and total: a bucket whose path is not in the taxonomy is dropped
/// rather than counted, because a path the taxonomy does not define has no
/// known kind, and guessing "expense" is how a transfer inflates a total.
List<CategoryRollup> rollUpByCategory(
  List<CategoryDef> taxonomy,
  List<SpendBucket> buckets,
) {
  final Map<String, List<SpendBucket>> byCategory = <String, List<SpendBucket>>{};
  for (final SpendBucket bucket in buckets) {
    final (String categoryId, _) = CategoryDef.splitPath(bucket.key);
    byCategory.putIfAbsent(categoryId, () => <SpendBucket>[]).add(bucket);
  }

  final List<CategoryRollup> rollups = <CategoryRollup>[];
  for (final CategoryDef def in taxonomy) {
    final List<SpendBucket> mine = byCategory[def.id] ?? const <SpendBucket>[];
    final List<SpendBucket> sorted = List<SpendBucket>.of(mine)
      ..sort((SpendBucket a, SpendBucket b) => b.total.compareTo(a.total));
    rollups.add(
      CategoryRollup(
        categoryId: def.id,
        name: def.name,
        kind: def.kind,
        total: Money.sum(mine.map((SpendBucket b) => b.total)),
        count: mine.fold<int>(0, (int sum, SpendBucket b) => sum + b.count),
        subtotals: List<SpendBucket>.unmodifiable(sorted),
      ),
    );
  }

  rollups.sort((CategoryRollup a, CategoryRollup b) {
    final int byTotal = b.total.compareTo(a.total);
    if (byTotal != 0) return byTotal;
    return a.name.compareTo(b.name);
  });
  return List<CategoryRollup>.unmodifiable(rollups);
}

/// Which category's transactions to list, for the drill-down.
@immutable
class CategoryFeedArgs {
  const CategoryFeedArgs({
    required this.categoryId,
    required this.month,
    this.subcategoryPath,
  });

  final String categoryId;
  final MonthRange month;

  /// When set, narrows the feed to one `'cat/sub'` path.
  final String? subcategoryPath;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CategoryFeedArgs &&
          other.categoryId == categoryId &&
          other.month == month &&
          other.subcategoryPath == subcategoryPath;

  @override
  int get hashCode => Object.hash(categoryId, month, subcategoryPath);
}

/// The transactions behind a category total, newest first.
final FutureProviderFamily<List<Transaction>, CategoryFeedArgs>
    categoryFeedProvider =
    FutureProvider.family<List<Transaction>, CategoryFeedArgs>(
        (Ref ref, CategoryFeedArgs args) async {
  final List<CategoryDef> taxonomy = ref.watch(taxonomyProvider);
  final Set<String> paths = <String>{};
  if (args.subcategoryPath != null) {
    paths.add(args.subcategoryPath!);
  } else {
    for (final CategoryDef def in taxonomy) {
      if (def.id == args.categoryId) paths.addAll(def.paths);
    }
  }
  if (paths.isEmpty) return const <Transaction>[];

  final Result<List<Transaction>> result =
      await ref.watch(ledgerRepositoryProvider).transactions(
            TxnQuery(
              from: args.month.from,
              to: args.month.to,
              categoryPaths: paths,
              includeExcluded: true,
              limit: 500,
            ),
          );
  return result.getOrElse(const <Transaction>[]);
});

/// Every rule the user has taught the app, newest decision first.
final Provider<List<UserRule>> sortedUserRulesProvider =
    Provider<List<UserRule>>((Ref ref) {
  final List<UserRule> rules =
      ref.watch(userRulesProvider).valueOrNull ?? const <UserRule>[];
  final List<UserRule> sorted = List<UserRule>.of(rules)
    ..sort((UserRule a, UserRule b) =>
        (b.updatedAt ?? b.createdAt).compareTo(a.updatedAt ?? a.createdAt));
  return List<UserRule>.unmodifiable(sorted);
});
