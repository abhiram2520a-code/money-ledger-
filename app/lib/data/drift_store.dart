// The ONE file in the app that knows drift exists. Everything else talks to
// `LedgerStore`, so a change in the database library cannot reach the ledger
// logic, and the ledger logic can be tested without a native SQLite binary.
//
// ignore_for_file: annotate_overrides, use_super_parameters

import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'ledger_store.dart';
import 'schema.dart';

/// Opens (and creates) the on-device database file.
///
/// `drift_flutter` puts it in the application-support directory, which is
/// app-private on Android: no other app can read it without root, and it is
/// excluded from cloud backup by the manifest. See `LedgerEncryption` for an
/// honest account of what that does and does not protect.
QueryExecutor openLedgerDatabaseFile({String name = 'ledger'}) =>
    driftDatabase(name: name);

/// A drift database with no generated code.
///
/// Every table in this app is `(id, indexed columns..., doc JSON)` and is
/// created by [LedgerSchema], so there is nothing for a code generator to
/// generate - and, more usefully, nothing that stops the app compiling if
/// `build_runner` was not run before the build.
///
/// Schema versioning does NOT use drift's migrator or SQLite's `user_version`:
/// it uses a row in the `meta` table, written by [DriftLedgerStore.open]. That
/// keeps one version axis instead of two, and every `CREATE TABLE` is
/// `IF NOT EXISTS`, so opening an existing file never touches existing rows.
class LedgerDriftDatabase extends GeneratedDatabase {
  LedgerDriftDatabase(QueryExecutor executor) : super(executor);

  Iterable<TableInfo<Table, dynamic>> get allTables =>
      const <TableInfo<Table, dynamic>>[];

  Iterable<DatabaseSchemaEntity> get allSchemaEntities =>
      const <DatabaseSchemaEntity>[];

  int get schemaVersion => 1;
}

/// [LedgerStore] on SQLite, via drift.
class DriftLedgerStore implements LedgerStore {
  DriftLedgerStore(this._db);

  /// Opens the app's real database file.
  factory DriftLedgerStore.openFile({String name = 'ledger'}) =>
      DriftLedgerStore(LedgerDriftDatabase(openLedgerDatabaseFile(name: name)));

  final LedgerDriftDatabase _db;

  bool _opened = false;

  @override
  Future<void> open() async {
    if (_opened) return;
    for (final String statement in LedgerSchema.createStatements()) {
      await _db.customStatement(statement);
    }
    await _applyMigrations();
    _opened = true;
  }

  /// The structure version lives in `meta`, not in `PRAGMA user_version`, so
  /// this code owns it outright.
  Future<void> _applyMigrations() async {
    final StoredRow? row = await get(LedgerCollections.meta, LedgerMetaKeys.schemaVersion);
    final int found = row == null ? 0 : (row.doc['value'] as num?)?.toInt() ?? 0;
    if (found == LedgerSchema.version) return;
    if (found > 0) {
      for (final String statement
          in LedgerSchema.migrationsFrom(found, LedgerSchema.version)) {
        await _db.customStatement(statement);
      }
      // A migration may add an index to a table that already existed.
      for (final String statement in LedgerSchema.createStatements()) {
        await _db.customStatement(statement);
      }
    }
    await put(
      LedgerCollections.meta,
      StoredRow(
        id: LedgerMetaKeys.schemaVersion,
        index: const <String, Object?>{},
        doc: <String, dynamic>{'value': LedgerSchema.version},
      ),
    );
  }

  @override
  Future<void> close() async {
    await _db.close();
    _opened = false;
  }

  @override
  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction<T>(action);

  @override
  Future<StoredRow?> get(String collection, String id) async {
    final CollectionDef def = _def(collection);
    final List<QueryRow> rows = await _db.customSelect(
      'SELECT * FROM $collection WHERE id = ? LIMIT 1',
      variables: <Variable<Object>>[Variable<Object>(id)],
    ).get();
    if (rows.isEmpty) return null;
    return _toRow(def, rows.first.data);
  }

  @override
  Future<List<StoredRow>> query(String collection, [StoreQuery? query]) async {
    final CollectionDef def = _def(collection);
    final StoreQuery q = query ?? const StoreQuery();
    final _Sql where = _whereSql(def, q);
    final StringBuffer sql = StringBuffer('SELECT * FROM ')
      ..write(collection)
      ..write(where.text)
      ..write(_orderSql(def, q));
    final int? limit = q.limit;
    if (limit != null) {
      sql
        ..write(' LIMIT ')
        ..write(limit);
    } else if (q.offset > 0) {
      // SQLite requires a LIMIT before an OFFSET.
      sql.write(' LIMIT -1');
    }
    if (q.offset > 0) {
      sql
        ..write(' OFFSET ')
        ..write(q.offset);
    }
    final List<QueryRow> rows =
        await _db.customSelect(sql.toString(), variables: where.variables).get();
    return <StoredRow>[
      for (final QueryRow row in rows) _toRow(def, row.data),
    ];
  }

  @override
  Future<int> count(String collection, [StoreQuery? query]) async {
    final CollectionDef def = _def(collection);
    final _Sql where = _whereSql(def, query ?? const StoreQuery());
    final List<QueryRow> rows = await _db.customSelect(
      'SELECT COUNT(*) AS n FROM $collection${where.text}',
      variables: where.variables,
    ).get();
    if (rows.isEmpty) return 0;
    return (rows.first.data['n'] as num?)?.toInt() ?? 0;
  }

  @override
  Future<void> put(String collection, StoredRow row) =>
      putAll(collection, <StoredRow>[row]);

  @override
  Future<void> putAll(String collection, List<StoredRow> rows) async {
    if (rows.isEmpty) return;
    final CollectionDef def = _def(collection);
    final List<String> columns = <String>[
      'id',
      for (final ColumnDef c in def.columns) c.name,
      'doc',
    ];
    final String placeholders = List<String>.filled(columns.length, '?').join(', ');
    final String sql = 'INSERT OR REPLACE INTO $collection '
        '(${columns.join(', ')}) VALUES ($placeholders)';
    for (final StoredRow row in rows) {
      final List<Object?> args = <Object?>[
        row.id,
        for (final ColumnDef c in def.columns) _columnValue(c, row.index[c.name]),
        jsonEncode(row.doc),
      ];
      await _db.customStatement(sql, args);
    }
  }

  @override
  Future<void> delete(String collection, String id) async {
    _def(collection);
    await _db.customStatement(
      'DELETE FROM $collection WHERE id = ?',
      <Object?>[id],
    );
  }

  @override
  Future<int> deleteWhere(String collection, StoreQuery query) async {
    final CollectionDef def = _def(collection);
    final _Sql where = _whereSql(def, query);
    // Counted first: SQLite reports changes, but going through one code path
    // keeps the two stores' return values identical.
    final int n = await count(collection, query);
    await _db.customStatement(
      'DELETE FROM $collection${where.text}',
      where.variables.map((Variable<Object> v) => v.value).toList(),
    );
    return n;
  }

  @override
  Future<void> wipe() async {
    for (final CollectionDef c in LedgerSchema.collections) {
      await _db.customStatement('DELETE FROM ${c.name}');
    }
  }

  CollectionDef _def(String collection) {
    final CollectionDef? def = LedgerSchema.collection(collection);
    if (def == null) {
      throw StateError('Unknown collection "$collection". Declare it in LedgerSchema.');
    }
    return def;
  }

  StoredRow _toRow(CollectionDef def, Map<String, dynamic> data) {
    final Map<String, Object?> index = <String, Object?>{};
    for (final ColumnDef c in def.columns) {
      index[c.name] = data[c.name];
    }
    final Object? raw = data['doc'];
    Map<String, dynamic> doc = <String, dynamic>{};
    if (raw is String && raw.isNotEmpty) {
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        doc = decoded.map(
          (Object? k, Object? v) => MapEntry<String, dynamic>('$k', v),
        );
      }
    }
    return StoredRow(id: data['id'] as String, index: index, doc: doc);
  }

  Object? _columnValue(ColumnDef def, Object? value) {
    if (value == null) return null;
    if (def.type == ColumnType.integer) {
      if (value is int) return value;
      if (value is bool) return value ? 1 : 0;
      if (value is num) return value.toInt();
      return int.tryParse(value.toString());
    }
    return value is String ? value : value.toString();
  }

  _Sql _whereSql(CollectionDef def, StoreQuery query) {
    if (query.conditions.isEmpty) {
      return const _Sql('', <Variable<Object>>[]);
    }
    final List<String> parts = <String>[];
    final List<Variable<Object>> vars = <Variable<Object>>[];
    for (final StoreCondition c in query.conditions) {
      if (!def.hasColumn(c.column)) {
        throw StateError(
          'Column "${c.column}" is not indexed on ${def.name}. '
          'Filtering on it would mean a table scan; add it to LedgerSchema.',
        );
      }
      switch (c.op) {
        case StoreOp.isNull:
          parts.add('${c.column} IS NULL');
        case StoreOp.isNotNull:
          parts.add('${c.column} IS NOT NULL');
        case StoreOp.eq:
          parts.add('${c.column} = ?');
          vars.add(Variable<Object>(c.value!));
        case StoreOp.ne:
          parts.add('(${c.column} IS NULL OR ${c.column} <> ?)');
          vars.add(Variable<Object>(c.value!));
        case StoreOp.isIn:
          final Object? value = c.value;
          final List<Object> values = <Object>[
            if (value is Iterable)
              for (final Object? v in value) ?v,
          ];
          if (values.isEmpty) {
            // An empty IN () is a syntax error in SQLite and matches nothing.
            parts.add('0 = 1');
          } else {
            parts.add(
              '${c.column} IN (${List<String>.filled(values.length, '?').join(', ')})',
            );
            for (final Object v in values) {
              vars.add(Variable<Object>(v));
            }
          }
        case StoreOp.gte:
          parts.add('${c.column} >= ?');
          vars.add(Variable<Object>(c.value!));
        case StoreOp.gt:
          parts.add('${c.column} > ?');
          vars.add(Variable<Object>(c.value!));
        case StoreOp.lte:
          parts.add('${c.column} <= ?');
          vars.add(Variable<Object>(c.value!));
        case StoreOp.lt:
          parts.add('${c.column} < ?');
          vars.add(Variable<Object>(c.value!));
        case StoreOp.contains:
          parts.add("${c.column} LIKE ? ESCAPE '\\'");
          vars.add(Variable<Object>('%${_escapeLike(c.value.toString())}%'));
      }
    }
    return _Sql(' WHERE ${parts.join(' AND ')}', vars);
  }

  String _orderSql(CollectionDef def, StoreQuery query) {
    final String? orderBy = query.orderBy;
    if (orderBy == null) return '';
    if (!def.hasColumn(orderBy)) {
      throw StateError('Cannot order ${def.name} by un-indexed column "$orderBy".');
    }
    final String dir = query.descending ? 'DESC' : 'ASC';
    final StringBuffer sql = StringBuffer(' ORDER BY $orderBy $dir');
    final String? thenBy = query.thenBy;
    if (thenBy != null && def.hasColumn(thenBy)) {
      sql.write(', $thenBy $dir');
    }
    // Ties broken by id, exactly as the in-memory store does, so paging is
    // stable and the two stores return rows in the same order.
    sql.write(', id $dir');
    return sql.toString();
  }

  static String _escapeLike(String input) => input
      .replaceAll('\\', '\\\\')
      .replaceAll('%', '\\%')
      .replaceAll('_', '\\_');
}

class _Sql {
  const _Sql(this.text, this.variables);

  final String text;
  final List<Variable<Object>> variables;
}
