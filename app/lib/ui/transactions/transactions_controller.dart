import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

/// What the user has narrowed the list down to.
///
/// Kept separate from [TxnQuery] because the UI needs to describe the filter
/// ("September, Food & Dining, 'swiggy'") and to toggle parts of it, and a
/// query object is the wrong shape for that.
@immutable
class TxnFilter {
  const TxnFilter({
    this.from,
    this.to,
    this.categoryPaths = const <String>{},
    this.accountIds = const <String>{},
    this.kinds = const <CategoryKind>{},
    this.search = '',
    this.onlyUncategorized = false,
  });

  final DateTime? from;
  final DateTime? to;
  final Set<String> categoryPaths;
  final Set<String> accountIds;

  /// Empty means every kind. Transfers and investments are shown by default -
  /// they are part of the story of the month - they are simply never counted as
  /// spending.
  final Set<CategoryKind> kinds;

  final String search;
  final bool onlyUncategorized;

  bool get isActive =>
      from != null ||
      to != null ||
      categoryPaths.isNotEmpty ||
      accountIds.isNotEmpty ||
      kinds.isNotEmpty ||
      search.trim().isNotEmpty ||
      onlyUncategorized;

  /// How many independent conditions are on, for the badge on the filter button.
  int get activeCount {
    int n = 0;
    if (from != null || to != null) n++;
    if (categoryPaths.isNotEmpty) n++;
    if (accountIds.isNotEmpty) n++;
    if (kinds.isNotEmpty) n++;
    if (search.trim().isNotEmpty) n++;
    if (onlyUncategorized) n++;
    return n;
  }

  TxnQuery toQuery({required int limit, required int offset}) {
    final String trimmed = search.trim();
    return TxnQuery(
      from: from,
      to: to,
      categoryPaths: categoryPaths.isEmpty ? null : categoryPaths,
      kinds: kinds.isEmpty ? null : kinds,
      accountIds: accountIds.isEmpty ? null : accountIds,
      search: trimmed.isEmpty ? null : trimmed,
      onlyUncategorized: onlyUncategorized,
      limit: limit,
      offset: offset,
    );
  }

  TxnFilter copyWith({
    DateTime? from,
    DateTime? to,
    Set<String>? categoryPaths,
    Set<String>? accountIds,
    Set<CategoryKind>? kinds,
    String? search,
    bool? onlyUncategorized,
    bool clearDates = false,
  }) {
    return TxnFilter(
      from: clearDates ? null : (from ?? this.from),
      to: clearDates ? null : (to ?? this.to),
      categoryPaths: categoryPaths ?? this.categoryPaths,
      accountIds: accountIds ?? this.accountIds,
      kinds: kinds ?? this.kinds,
      search: search ?? this.search,
      onlyUncategorized: onlyUncategorized ?? this.onlyUncategorized,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TxnFilter &&
      _sameInstant(other.from, from) &&
      _sameInstant(other.to, to) &&
      setEquals(other.categoryPaths, categoryPaths) &&
      setEquals(other.accountIds, accountIds) &&
      setEquals(other.kinds, kinds) &&
      other.search == search &&
      other.onlyUncategorized == onlyUncategorized;

  @override
  int get hashCode => Object.hash(
        from?.millisecondsSinceEpoch,
        to?.millisecondsSinceEpoch,
        Object.hashAllUnordered(categoryPaths),
        Object.hashAllUnordered(accountIds),
        Object.hashAllUnordered(kinds),
        search,
        onlyUncategorized,
      );

  static bool _sameInstant(DateTime? a, DateTime? b) {
    if (a == null || b == null) return a == b;
    return a.isAtSameMomentAs(b);
  }
}

/// The filter the transactions tab is currently showing. Global on purpose: the
/// dashboard narrows it ("show me this month's Food & Dining") and then sends
/// the user to the tab, and the tab remembers it while the app is open.
class TxnFilterController extends Notifier<TxnFilter> {
  @override
  TxnFilter build() => const TxnFilter();

  void replace(TxnFilter filter) => state = filter;

  void clear() => state = const TxnFilter();

  void setSearch(String value) => state = state.copyWith(search: value);

  void setRange(DateTime? from, DateTime? to) =>
      state = from == null && to == null
          ? state.copyWith(clearDates: true)
          : state.copyWith(from: from, to: to);

  void toggleCategory(String path) {
    final Set<String> next = <String>{...state.categoryPaths};
    if (!next.remove(path)) next.add(path);
    state = state.copyWith(categoryPaths: next);
  }

  void toggleAccount(String id) {
    final Set<String> next = <String>{...state.accountIds};
    if (!next.remove(id)) next.add(id);
    state = state.copyWith(accountIds: next);
  }

  void toggleKind(CategoryKind kind) {
    final Set<CategoryKind> next = <CategoryKind>{...state.kinds};
    if (!next.remove(kind)) next.add(kind);
    state = state.copyWith(kinds: next);
  }

  void setOnlyUncategorized(bool value) =>
      state = state.copyWith(onlyUncategorized: value);
}

final NotifierProvider<TxnFilterController, TxnFilter> txnFilterProvider =
    NotifierProvider<TxnFilterController, TxnFilter>(TxnFilterController.new);

/// One page-aware view of the transaction list.
@immutable
class TxnListState {
  const TxnListState({
    required this.items,
    required this.hasMore,
    required this.filter,
    this.loadingMore = false,
    this.pageError,
  });

  final List<Transaction> items;
  final bool hasMore;
  final TxnFilter filter;

  /// True while the next page is in flight, so the footer can say so instead of
  /// the whole list flashing a spinner.
  final bool loadingMore;

  /// A failure while paging. The rows already loaded stay on screen.
  final String? pageError;

  bool get isEmpty => items.isEmpty;

  TxnListState copyWith({
    List<Transaction>? items,
    bool? hasMore,
    TxnFilter? filter,
    bool? loadingMore,
    String? pageError,
    bool clearPageError = false,
  }) {
    return TxnListState(
      items: items ?? this.items,
      hasMore: hasMore ?? this.hasMore,
      filter: filter ?? this.filter,
      loadingMore: loadingMore ?? this.loadingMore,
      pageError: clearPageError ? null : (pageError ?? this.pageError),
    );
  }
}

/// The paged, filtered transaction list.
///
/// Paging is offset-based against the repository rather than loading everything
/// and filtering in Dart, because "smooth over thousands of rows" has to mean
/// the app never holds thousands of rows in memory to begin with.
///
/// When the ledger changes underneath (a new SMS arrives, a category is fixed)
/// the already-loaded pages are re-read rather than reset, so the list does not
/// jump to the top while the user is reading it.
class TransactionListController extends AsyncNotifier<TxnListState> {
  static const int _maxRefetchPages = 5;

  int _loadedPages = 1;
  TxnFilter? _lastFilter;

  @override
  Future<TxnListState> build() async {
    final TxnFilter filter = ref.watch(txnFilterProvider);
    // Any write to the ledger invalidates what is on screen.
    ref.watch(ledgerTickProvider);

    if (_lastFilter != filter) {
      _loadedPages = 1;
      _lastFilter = filter;
    }

    final int pages = _loadedPages.clamp(1, _maxRefetchPages);
    final int take = pages * Sizes.pageSize;
    final List<Transaction> rows = await _fetch(filter, offset: 0, limit: take + 1);
    return TxnListState(
      items: rows.length > take ? rows.sublist(0, take) : rows,
      hasMore: rows.length > take,
      filter: filter,
    );
  }

  Future<List<Transaction>> _fetch(
    TxnFilter filter, {
    required int offset,
    required int limit,
  }) async {
    final LedgerRepository repo = ref.read(ledgerRepositoryProvider);
    return unwrap(await repo.transactions(filter.toQuery(limit: limit, offset: offset)));
  }

  /// Appends the next page. Safe to call from a scroll listener: repeated calls
  /// while a page is in flight are ignored.
  Future<void> loadMore() async {
    final TxnListState? current = state.valueOrNull;
    if (current == null || !current.hasMore || current.loadingMore) return;
    state = AsyncData<TxnListState>(
      current.copyWith(loadingMore: true, clearPageError: true),
    );

    try {
      final List<Transaction> rows = await _fetch(
        current.filter,
        offset: current.items.length,
        limit: Sizes.pageSize + 1,
      );
      final bool more = rows.length > Sizes.pageSize;
      final List<Transaction> page =
          more ? rows.sublist(0, Sizes.pageSize) : rows;
      _loadedPages++;
      state = AsyncData<TxnListState>(current.copyWith(
        items: <Transaction>[...current.items, ...page],
        hasMore: more,
        loadingMore: false,
        clearPageError: true,
      ));
    } on Object catch (error) {
      state = AsyncData<TxnListState>(current.copyWith(
        loadingMore: false,
        pageError: describeError(error),
      ));
    }
  }

  /// Pull-to-refresh: back to the first page.
  Future<void> refresh() async {
    _loadedPages = 1;
    ref.invalidateSelf();
    await future;
  }
}

final AsyncNotifierProvider<TransactionListController, TxnListState>
    transactionListProvider =
    AsyncNotifierProvider<TransactionListController, TxnListState>(
  TransactionListController.new,
);

/// A transaction plus the evidence behind it: the message it came from, and the
/// user rule that decided its category, when there was one.
@immutable
class TransactionDetail {
  const TransactionDetail({
    required this.transaction,
    this.rawMessage,
    this.matchedRule,
  });

  final Transaction transaction;

  /// The SMS. `null` when the row was entered by hand, or when the body was
  /// purged by the retention setting.
  final RawMessage? rawMessage;

  final UserRule? matchedRule;
}

final transactionDetailProvider =
    FutureProvider.family<TransactionDetail, String>((Ref ref, String txnId) async {
  ref.watch(ledgerTickProvider);
  final LedgerRepository repo = ref.watch(ledgerRepositoryProvider);
  final Transaction? txn = unwrap(await repo.transactionById(txnId));
  if (txn == null) {
    throw const LedgerUiException('This transaction is no longer in the ledger.');
  }

  RawMessage? raw;
  final String? rawId = txn.rawMessageId;
  if (rawId != null) {
    final Result<RawMessage?> result = await repo.rawMessageById(rawId);
    raw = result.valueOrNull;
  }

  UserRule? rule;
  if (txn.categorySource == CategorySource.userRule) {
    final List<UserRule> rules = unwrap(await repo.userRules());
    for (final UserRule candidate in rules) {
      if (candidate.categoryPath != txn.categoryPath) continue;
      final bool hit = candidate.matches(
        merchantNormalized: txn.merchantRaw ?? txn.merchantName,
        vpa: txn.vpa,
        body: raw?.body,
      );
      if (hit) {
        rule = candidate;
        break;
      }
    }
  }

  return TransactionDetail(transaction: txn, rawMessage: raw, matchedRule: rule);
});

/// Applies a category the user picked, optionally turning it into a standing
/// rule so the same merchant is never asked about again.
///
/// Returns the failure message, or `null` on success.
Future<String?> applyCategory(
  WidgetRef ref, {
  required Transaction transaction,
  required String categoryPath,
  required CategoryKind kind,
  required bool createUserRule,
}) async {
  final LedgerRepository repo = ref.read(ledgerRepositoryProvider);
  final Result<Transaction> result = await repo.recategorize(
    transaction.id,
    CategoryResult.manual(categoryPath, kind),
    createUserRule: createUserRule,
  );
  if (result.isErr) return result.errorOrNull?.message ?? 'Could not save that.';
  ref.invalidate(transactionDetailProvider(transaction.id));
  return null;
}
