import 'package:flutter/foundation.dart';

/// One stored row: its id, the columns SQL filters on, and the model's own
/// JSON.
///
/// [index] must only contain `String`, `int` or `null` values, and every key
/// must be a column declared for the collection in `LedgerSchema`. A value
/// that is not declared is dropped rather than written, because a store that
/// silently invents columns cannot be migrated.
@immutable
class StoredRow {
  const StoredRow({
    required this.id,
    required this.index,
    required this.doc,
  });

  final String id;
  final Map<String, Object?> index;
  final Map<String, dynamic> doc;

  Object? column(String name) => name == 'id' ? id : index[name];

  @override
  String toString() => 'StoredRow($id, ${index.length} cols)';
}

/// The comparisons a [StoreQuery] may make. Deliberately small: anything more
/// expressive would have to be implemented twice, identically, in two stores.
enum StoreOp {
  eq,
  ne,
  isIn,
  gte,
  gt,
  lte,
  lt,

  /// Case-sensitive substring. Columns meant for search are stored already
  /// lower-cased, so the caller lower-cases the needle and the comparison is
  /// identical in SQL and in Dart.
  contains,
  isNull,
  isNotNull,
}

@immutable
class StoreCondition {
  const StoreCondition(this.column, this.op, [this.value]);

  const StoreCondition.eq(String column, Object value)
      : this(column, StoreOp.eq, value);

  const StoreCondition.isNull(String column) : this(column, StoreOp.isNull);

  final String column;
  final StoreOp op;
  final Object? value;
}

/// A read against one collection. Conditions are ANDed.
@immutable
class StoreQuery {
  const StoreQuery({
    this.conditions = const <StoreCondition>[],
    this.orderBy,
    this.thenBy,
    this.descending = false,
    this.limit,
    this.offset = 0,
  });

  final List<StoreCondition> conditions;

  /// An indexed column, or `'id'`. Ordering by anything else is impossible on
  /// purpose - it would mean a table scan plus a sort.
  final String? orderBy;

  /// Tie-breaker, so paging is stable when [orderBy] repeats. Sorted in the
  /// same direction as [orderBy].
  final String? thenBy;

  final bool descending;
  final int? limit;
  final int offset;

  StoreQuery withLimit(int? newLimit, {int newOffset = 0}) => StoreQuery(
        conditions: conditions,
        orderBy: orderBy,
        thenBy: thenBy,
        descending: descending,
        limit: newLimit,
        offset: newOffset,
      );
}

/// Row-level persistence. The only thing in the app that knows what a database
/// is.
///
/// Everything above this interface - de-duplication, double-entry postings,
/// rollups, reconciliation, bill matching - is plain Dart operating on models,
/// which is what makes it testable without a native SQLite binary on the
/// machine running the tests.
///
/// Implementations MAY throw; [LedgerRepositoryImpl] is what converts a throw
/// into an `Err`, so no exception ever crosses a module boundary.
abstract interface class LedgerStore {
  /// Creates or migrates the database. Idempotent.
  Future<void> open();

  Future<void> close();

  /// Runs [action] atomically. Nested calls join the outer transaction.
  Future<T> transaction<T>(Future<T> Function() action);

  Future<StoredRow?> get(String collection, String id);

  Future<List<StoredRow>> query(String collection, [StoreQuery? query]);

  Future<int> count(String collection, [StoreQuery? query]);

  /// Insert or replace.
  Future<void> put(String collection, StoredRow row);

  Future<void> putAll(String collection, List<StoredRow> rows);

  Future<void> delete(String collection, String id);

  Future<int> deleteWhere(String collection, StoreQuery query);

  /// Deletes every row in every collection.
  Future<void> wipe();
}

/// Shared filtering and ordering, so the in-memory store and any future store
/// cannot disagree about what a [StoreQuery] means.
abstract final class StoreQueryEval {
  static bool matches(StoredRow row, StoreQuery query) {
    for (final StoreCondition c in query.conditions) {
      if (!matchesCondition(row.column(c.column), c)) return false;
    }
    return true;
  }

  static bool matchesCondition(Object? actual, StoreCondition c) {
    switch (c.op) {
      case StoreOp.isNull:
        return actual == null;
      case StoreOp.isNotNull:
        return actual != null;
      case StoreOp.eq:
        return actual == c.value;
      case StoreOp.ne:
        return actual != c.value;
      case StoreOp.isIn:
        final Object? v = c.value;
        if (v is Iterable) return v.contains(actual);
        return false;
      case StoreOp.contains:
        if (actual is! String) return false;
        final Object? needle = c.value;
        return needle is String && actual.contains(needle);
      case StoreOp.gte:
      case StoreOp.gt:
      case StoreOp.lte:
      case StoreOp.lt:
        final int? cmp = _compare(actual, c.value);
        if (cmp == null) return false;
        if (c.op == StoreOp.gte) return cmp >= 0;
        if (c.op == StoreOp.gt) return cmp > 0;
        if (c.op == StoreOp.lte) return cmp <= 0;
        return cmp < 0;
    }
  }

  static List<StoredRow> sortAndPage(List<StoredRow> rows, StoreQuery query) {
    final String? orderBy = query.orderBy;
    if (orderBy != null) {
      rows.sort((StoredRow a, StoredRow b) {
        int r = _compare(a.column(orderBy), b.column(orderBy)) ?? 0;
        final String? thenBy = query.thenBy;
        if (r == 0 && thenBy != null) {
          r = _compare(a.column(thenBy), b.column(thenBy)) ?? 0;
        }
        if (r == 0) r = a.id.compareTo(b.id);
        return query.descending ? -r : r;
      });
    }
    final int start = query.offset < 0 ? 0 : query.offset;
    if (start >= rows.length) return <StoredRow>[];
    final int? limit = query.limit;
    final int end = limit == null
        ? rows.length
        : (start + limit).clamp(start, rows.length).toInt();
    return rows.sublist(start, end);
  }

  /// `null` when the two values are not comparable, which a condition treats
  /// as "does not match" rather than as an error. A row whose column is null
  /// is simply outside every range.
  static int? _compare(Object? a, Object? b) {
    if (a == null || b == null) {
      if (a == null && b == null) return 0;
      return null;
    }
    if (a is num && b is num) return a.compareTo(b);
    if (a is String && b is String) return a.compareTo(b);
    return null;
  }
}
