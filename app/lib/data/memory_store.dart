import 'ledger_store.dart';
import 'schema.dart';

/// A [LedgerStore] that keeps everything in memory.
///
/// It exists for two reasons, and neither is "a mock":
///
/// 1. **Tests.** The repository, the posting engine, the reconciliation
///    engine and the bill matcher are the parts that can lose a user's money,
///    so they are tested for real - against this store, which needs no native
///    SQLite binary and therefore runs identically on CI, on a laptop and on a
///    phone.
/// 2. **A working app when the database cannot be opened.** A corrupt or
///    unopenable file is rare, but silently crashing on launch is worse than
///    running for one session with an empty ledger and telling the user.
///
/// It enforces the same unique indices as the SQL store so a test cannot pass
/// on a constraint the real database would reject.
class MemoryLedgerStore implements LedgerStore {
  final Map<String, Map<String, StoredRow>> _tables = <String, Map<String, StoredRow>>{};

  bool _open = false;
  int _txnDepth = 0;

  /// Snapshot taken when the outermost transaction opens, restored on failure.
  Map<String, Map<String, StoredRow>>? _rollback;

  @override
  Future<void> open() async {
    if (_open) return;
    for (final CollectionDef c in LedgerSchema.collections) {
      _tables[c.name] = <String, StoredRow>{};
    }
    _open = true;
  }

  @override
  Future<void> close() async {
    _open = false;
  }

  @override
  Future<T> transaction<T>(Future<T> Function() action) async {
    if (_txnDepth > 0) return action();
    _rollback = <String, Map<String, StoredRow>>{
      for (final MapEntry<String, Map<String, StoredRow>> e in _tables.entries)
        e.key: Map<String, StoredRow>.of(e.value),
    };
    _txnDepth++;
    try {
      final T result = await action();
      _rollback = null;
      return result;
    } catch (_) {
      final Map<String, Map<String, StoredRow>>? snapshot = _rollback;
      if (snapshot != null) {
        _tables
          ..clear()
          ..addAll(snapshot);
      }
      _rollback = null;
      rethrow;
    } finally {
      _txnDepth--;
    }
  }

  @override
  Future<StoredRow?> get(String collection, String id) async =>
      _table(collection)[id];

  @override
  Future<List<StoredRow>> query(String collection, [StoreQuery? query]) async {
    final StoreQuery q = query ?? const StoreQuery();
    final List<StoredRow> matched = <StoredRow>[
      for (final StoredRow row in _table(collection).values)
        if (StoreQueryEval.matches(row, q)) row,
    ];
    return StoreQueryEval.sortAndPage(matched, q);
  }

  @override
  Future<int> count(String collection, [StoreQuery? query]) async {
    final StoreQuery q = query ?? const StoreQuery();
    int n = 0;
    for (final StoredRow row in _table(collection).values) {
      if (StoreQueryEval.matches(row, q)) n++;
    }
    return n;
  }

  @override
  Future<void> put(String collection, StoredRow row) async {
    _checkUnique(collection, <StoredRow>[row]);
    _table(collection)[row.id] = row;
  }

  @override
  Future<void> putAll(String collection, List<StoredRow> rows) async {
    if (rows.isEmpty) return;
    _checkUnique(collection, rows);
    final Map<String, StoredRow> table = _table(collection);
    for (final StoredRow row in rows) {
      table[row.id] = row;
    }
  }

  @override
  Future<void> delete(String collection, String id) async {
    _table(collection).remove(id);
  }

  @override
  Future<int> deleteWhere(String collection, StoreQuery query) async {
    final Map<String, StoredRow> table = _table(collection);
    final List<String> doomed = <String>[
      for (final StoredRow row in table.values)
        if (StoreQueryEval.matches(row, query)) row.id,
    ];
    for (final String id in doomed) {
      table.remove(id);
    }
    return doomed.length;
  }

  @override
  Future<void> wipe() async {
    for (final Map<String, StoredRow> table in _tables.values) {
      table.clear();
    }
  }

  Map<String, StoredRow> _table(String collection) {
    final Map<String, StoredRow>? table = _tables[collection];
    if (table == null) {
      throw StateError('Unknown collection "$collection". Declare it in LedgerSchema.');
    }
    return table;
  }

  /// Mirrors what SQLite would do on a unique index, so a test cannot pass on
  /// a write the shipped database would reject.
  void _checkUnique(String collection, List<StoredRow> incoming) {
    final CollectionDef? def = LedgerSchema.collection(collection);
    if (def == null) {
      throw StateError('Unknown collection "$collection". Declare it in LedgerSchema.');
    }
    final List<IndexDef> unique = <IndexDef>[
      for (final IndexDef i in def.indices)
        if (i.unique) i,
    ];
    if (unique.isEmpty) return;
    final Map<String, StoredRow> table = _table(collection);
    for (final IndexDef index in unique) {
      for (final StoredRow row in incoming) {
        final String? key = _indexKey(row, index);
        if (key == null) continue; // SQLite: NULLs are distinct in a unique index.
        for (final StoredRow existing in table.values) {
          if (existing.id == row.id) continue;
          if (_indexKey(existing, index) == key) {
            throw StateError(
              'UNIQUE constraint failed: $collection.${index.name} '
              '(row ${row.id} collides with ${existing.id})',
            );
          }
        }
      }
    }
  }

  String? _indexKey(StoredRow row, IndexDef index) {
    final StringBuffer buf = StringBuffer();
    for (final String column in index.columns) {
      final Object? v = row.column(column);
      if (v == null) return null;
      buf
        ..write(v)
        ..writeCharCode(1);
    }
    return buf.toString();
  }
}
