import 'package:flutter/foundation.dart';

/// The physical shape of the local database, shared by every [LedgerStore]
/// implementation so the in-memory store and the SQLite store cannot drift
/// apart.
///
/// ## Why rows are `(indexed columns + one JSON document)`
///
/// Every model in `lib/models` already has a reviewed, round-tripped
/// `toJson`/`fromJson`. Re-expressing thirty-odd fields a second time as SQL
/// columns would buy nothing except a second place for a typo to change a
/// user's money. So each table stores:
///
/// * the handful of columns that queries actually filter, sort or group on -
///   real columns, with real indices, so a month range is one index range
///   scan; and
/// * `doc`, the model's own JSON, which is what is read back.
///
/// Aggregation happens in Dart over the rows the index already narrowed to.
/// For a month of an Indian retail user's SMS that is a few hundred rows; the
/// index is doing the work that matters.
///
/// ## Versions
///
/// [version] is the STRUCTURE version and nothing else. The parser version and
/// the rules-pack version are tracked separately (in [LedgerCollections.meta])
/// because a parser change needs a re-parse sweep, not a migration, and
/// conflating the three is what forces destructive migrations.
abstract final class LedgerSchema {
  /// Bump ONLY when a table, column or index changes. See [migrationsFrom].
  static const int version = 1;

  /// Every table, in creation order.
  static const List<CollectionDef> collections = <CollectionDef>[
    CollectionDef(
      name: LedgerCollections.meta,
      columns: <ColumnDef>[],
      indices: <IndexDef>[],
    ),
    CollectionDef(
      name: LedgerCollections.accounts,
      columns: <ColumnDef>[
        ColumnDef('type', ColumnType.text),
        ColumnDef('tail', ColumnType.text),
        ColumnDef('institution_id', ColumnType.text),
        ColumnDef('is_archived', ColumnType.integer),
        ColumnDef('is_tracked', ColumnType.integer),
        ColumnDef('sort_order', ColumnType.integer),
      ],
      indices: <IndexDef>[
        IndexDef('idx_accounts_tail', <String>['tail', 'type']),
        IndexDef('idx_accounts_listing', <String>['is_archived', 'sort_order']),
      ],
    ),
    CollectionDef(
      name: LedgerCollections.categories,
      columns: <ColumnDef>[
        ColumnDef('kind', ColumnType.text),
        ColumnDef('sort_order', ColumnType.integer),
      ],
      indices: <IndexDef>[
        IndexDef('idx_categories_kind', <String>['kind', 'sort_order']),
      ],
    ),
    CollectionDef(
      name: LedgerCollections.merchants,
      columns: <ColumnDef>[
        ColumnDef('name_norm', ColumnType.text),
        ColumnDef('category_path', ColumnType.text),
        ColumnDef('is_biller', ColumnType.integer),
      ],
      indices: <IndexDef>[
        IndexDef('idx_merchants_name', <String>['name_norm']),
        IndexDef('idx_merchants_biller', <String>['is_biller']),
      ],
    ),
    CollectionDef(
      name: LedgerCollections.rawMessages,
      columns: <ColumnDef>[
        ColumnDef('received_at', ColumnType.integer),
        ColumnDef('received_minute', ColumnType.integer),
        ColumnDef('sender_header', ColumnType.text),
        ColumnDef('body_hash', ColumnType.text),
        ColumnDef('provider_id', ColumnType.integer),
        ColumnDef('parse_state', ColumnType.text),
        ColumnDef('parser_version', ColumnType.integer),
        ColumnDef('txn_id', ColumnType.text),
        ColumnDef('has_body', ColumnType.integer),
      ],
      indices: <IndexDef>[
        IndexDef('idx_raw_received', <String>['received_at']),
        IndexDef('idx_raw_state', <String>['parse_state', 'parser_version']),
        IndexDef(
          'idx_raw_dedupe',
          <String>['body_hash', 'sender_header', 'received_minute'],
        ),
        IndexDef('idx_raw_provider', <String>['provider_id']),
      ],
    ),
    CollectionDef(
      name: LedgerCollections.transactions,
      columns: <ColumnDef>[
        ColumnDef('occurred_at', ColumnType.integer),
        ColumnDef('booking_date', ColumnType.text),
        ColumnDef('status', ColumnType.text),
        ColumnDef('kind', ColumnType.text),
        ColumnDef('direction', ColumnType.text),
        ColumnDef('channel', ColumnType.text),
        ColumnDef('category_path', ColumnType.text),
        ColumnDef('account_id', ColumnType.text),
        ColumnDef('account_tail', ColumnType.text),
        ColumnDef('card_tail', ColumnType.text),
        ColumnDef('merchant_name', ColumnType.text),
        ColumnDef('ref', ColumnType.text),
        ColumnDef('amount_paise', ColumnType.integer),
        ColumnDef('counts_spend', ColumnType.integer),
        ColumnDef('counts_income', ColumnType.integer),
        ColumnDef('is_excluded', ColumnType.integer),
        ColumnDef('transfer_group_id', ColumnType.text),
        ColumnDef('reversal_of_id', ColumnType.text),
        ColumnDef('bill_id', ColumnType.text),
        ColumnDef('series_id', ColumnType.text),
        ColumnDef('raw_message_id', ColumnType.text),
        ColumnDef('fingerprint', ColumnType.text),
        ColumnDef('search', ColumnType.text),
      ],
      indices: <IndexDef>[
        // Keyset paging and every month range.
        IndexDef('idx_txn_date', <String>['booking_date', 'occurred_at']),
        IndexDef('idx_txn_account', <String>['account_id', 'booking_date']),
        IndexDef('idx_txn_category', <String>['category_path', 'booking_date']),
        IndexDef('idx_txn_merchant', <String>['merchant_name', 'booking_date']),
        // The de-duplication lookups. `ref` is the money event's own identity.
        IndexDef('idx_txn_ref', <String>['ref', 'amount_paise']),
        IndexDef('idx_txn_fingerprint', <String>['fingerprint']),
        IndexDef('idx_txn_raw', <String>['raw_message_id']),
        IndexDef('idx_txn_group', <String>['transfer_group_id']),
        IndexDef('idx_txn_bill', <String>['bill_id']),
        IndexDef('idx_txn_status', <String>['status', 'booking_date']),
      ],
    ),
    CollectionDef(
      name: LedgerCollections.postings,
      columns: <ColumnDef>[
        ColumnDef('txn_id', ColumnType.text),
        ColumnDef('account_id', ColumnType.text),
        ColumnDef('account_class', ColumnType.text),
        ColumnDef('amount_paise', ColumnType.integer),
        ColumnDef('occurred_at', ColumnType.integer),
        ColumnDef('booking_date', ColumnType.text),
        ColumnDef('leg', ColumnType.text),
      ],
      indices: <IndexDef>[
        IndexDef('idx_postings_txn', <String>['txn_id']),
        // The reconciliation window sum: one range scan, no join.
        IndexDef('idx_postings_acct_time', <String>['account_id', 'occurred_at']),
        IndexDef('idx_postings_acct_date', <String>['account_id', 'booking_date']),
        IndexDef('idx_postings_class', <String>['account_class', 'booking_date']),
      ],
    ),
    CollectionDef(
      name: LedgerCollections.userRules,
      columns: <ColumnDef>[
        ColumnDef('enabled', ColumnType.integer),
        ColumnDef('priority', ColumnType.integer),
        ColumnDef('match_kind', ColumnType.text),
        ColumnDef('pattern', ColumnType.text),
      ],
      indices: <IndexDef>[
        IndexDef('idx_rules_order', <String>['enabled', 'priority']),
      ],
    ),
    CollectionDef(
      name: LedgerCollections.bills,
      columns: <ColumnDef>[
        ColumnDef('status', ColumnType.text),
        ColumnDef('due_date', ColumnType.integer),
        ColumnDef('account_id', ColumnType.text),
        ColumnDef('account_tail', ColumnType.text),
        ColumnDef('card_tail', ColumnType.text),
        ColumnDef('merchant_name', ColumnType.text),
        ColumnDef('cycle_key', ColumnType.text),
        ColumnDef('paid_txn_id', ColumnType.text),
        ColumnDef('amount_due_paise', ColumnType.integer),
        ColumnDef('amount_paid_paise', ColumnType.integer),
      ],
      indices: <IndexDef>[
        IndexDef('idx_bills_due', <String>['status', 'due_date']),
        // Bill idempotency: reminders re-send the same bill three to five
        // times, and every one of them must land on the same row.
        IndexDef('idx_bills_cycle', <String>['cycle_key'], unique: true),
        IndexDef('idx_bills_account', <String>['account_id']),
      ],
    ),
    CollectionDef(
      name: LedgerCollections.billPayments,
      columns: <ColumnDef>[
        ColumnDef('bill_id', ColumnType.text),
        ColumnDef('txn_id', ColumnType.text),
        ColumnDef('applied_paise', ColumnType.integer),
        ColumnDef('confidence', ColumnType.integer),
      ],
      indices: <IndexDef>[
        IndexDef('idx_billpay_bill', <String>['bill_id']),
        // One transaction can settle at most one bill.
        IndexDef('idx_billpay_txn', <String>['txn_id'], unique: true),
      ],
    ),
    CollectionDef(
      name: LedgerCollections.recurringSeries,
      columns: <ColumnDef>[
        ColumnDef('group_key', ColumnType.text),
        ColumnDef('account_id', ColumnType.text),
        ColumnDef('merchant_name', ColumnType.text),
        ColumnDef('state', ColumnType.text),
        ColumnDef('next_expected', ColumnType.integer),
      ],
      indices: <IndexDef>[
        IndexDef('idx_series_group', <String>['group_key'], unique: true),
        IndexDef('idx_series_next', <String>['state', 'next_expected']),
      ],
    ),
    CollectionDef(
      name: LedgerCollections.quarantinedMessages,
      columns: <ColumnDef>[
        ColumnDef('raw_message_id', ColumnType.text),
        ColumnDef('received_at', ColumnType.integer),
        ColumnDef('amount_paise', ColumnType.integer),
        ColumnDef('reason', ColumnType.text),
        ColumnDef('resolved', ColumnType.integer),
      ],
      indices: <IndexDef>[
        IndexDef('idx_quarantine_time', <String>['received_at']),
        // Hypothesis H1: an unreadable message whose amount explains the gap.
        IndexDef('idx_quarantine_amount', <String>['amount_paise', 'resolved']),
        IndexDef('idx_quarantine_raw', <String>['raw_message_id'], unique: true),
      ],
    ),
    CollectionDef(
      name: LedgerCollections.balanceSnapshots,
      columns: <ColumnDef>[
        ColumnDef('account_id', ColumnType.text),
        ColumnDef('as_of', ColumnType.integer),
        ColumnDef('precedence', ColumnType.integer),
        ColumnDef('kind', ColumnType.text),
        ColumnDef('stated_paise', ColumnType.integer),
        ColumnDef('ledger_paise', ColumnType.integer),
        ColumnDef('trusted', ColumnType.integer),
        ColumnDef('txn_id', ColumnType.text),
        ColumnDef('raw_message_id', ColumnType.text),
      ],
      indices: <IndexDef>[
        IndexDef('idx_balance_acct_time', <String>['account_id', 'as_of', 'precedence']),
      ],
    ),
    CollectionDef(
      name: LedgerCollections.driftEvents,
      columns: <ColumnDef>[
        ColumnDef('account_id', ColumnType.text),
        ColumnDef('state', ColumnType.text),
        ColumnDef('window_start', ColumnType.integer),
        ColumnDef('window_end', ColumnType.integer),
        ColumnDef('drift_paise', ColumnType.integer),
        ColumnDef('window_key', ColumnType.text),
      ],
      indices: <IndexDef>[
        IndexDef('idx_drift_open', <String>['account_id', 'state', 'window_start']),
        IndexDef('idx_drift_window', <String>['window_key'], unique: true),
      ],
    ),
  ];

  static CollectionDef? collection(String name) {
    for (final CollectionDef c in collections) {
      if (c.name == name) return c;
    }
    return null;
  }

  /// Every `CREATE TABLE` / `CREATE INDEX` for a fresh database.
  static List<String> createStatements() {
    final List<String> out = <String>[];
    for (final CollectionDef c in collections) {
      out.add(c.createTableSql());
      out.addAll(c.createIndexSql());
    }
    return out;
  }

  /// The statements that move a database from [from] to [to].
  ///
  /// Returns an empty list for an unchanged version and throws for a
  /// downgrade, because silently reopening a newer file with older code is how
  /// a ledger loses rows. There is deliberately no destructive fallback: a
  /// migration this code does not know about must surface, not wipe.
  static List<String> migrationsFrom(int from, int to) {
    if (from == to) return const <String>[];
    if (from > to) {
      throw StateError(
        'Refusing to downgrade the ledger database from v$from to v$to. '
        'The data belongs to a newer build.',
      );
    }
    final List<String> out = <String>[];
    for (int v = from + 1; v <= to; v++) {
      final List<String>? step = _upgrades[v];
      if (step == null) {
        throw StateError('No migration registered for ledger database v$v.');
      }
      out.addAll(step);
    }
    return out;
  }

  /// Keyed by the version each step ARRIVES at. v1 is the initial schema and
  /// therefore has no entry - it is produced by [createStatements].
  static const Map<int, List<String>> _upgrades = <int, List<String>>{};
}

/// Table names. String constants rather than an enum because they are written
/// into SQL and into the export document, and both are persisted user data.
abstract final class LedgerCollections {
  static const String meta = 'meta';
  static const String accounts = 'accounts';
  static const String categories = 'categories';
  static const String merchants = 'merchants';
  static const String rawMessages = 'raw_messages';
  static const String transactions = 'transactions';
  static const String postings = 'postings';
  static const String userRules = 'user_rules';
  static const String bills = 'bills';
  static const String billPayments = 'bill_payments';
  static const String recurringSeries = 'recurring_series';
  static const String quarantinedMessages = 'quarantined_messages';
  static const String balanceSnapshots = 'balance_snapshots';
  static const String driftEvents = 'drift_events';

  /// The collections carried by an export document, in restore order.
  static const List<String> exportable = <String>[
    accounts,
    categories,
    merchants,
    rawMessages,
    transactions,
    postings,
    userRules,
    bills,
    billPayments,
    recurringSeries,
    quarantinedMessages,
    balanceSnapshots,
    driftEvents,
  ];
}

/// Keys used in [LedgerCollections.meta].
abstract final class LedgerMetaKeys {
  static const String schemaVersion = 'schema_version';
  static const String parserVersion = 'parser_version';
  static const String rulesVersion = 'rules_version';
  static const String createdAt = 'created_at';
  static const String lastBackfillAt = 'last_backfill_at';
  static const String bodyRetentionDays = 'body_retention_days';
}

enum ColumnType { text, integer }

@immutable
class ColumnDef {
  const ColumnDef(this.name, this.type);

  final String name;
  final ColumnType type;

  String get sqlType => type == ColumnType.integer ? 'INTEGER' : 'TEXT';
}

@immutable
class IndexDef {
  const IndexDef(this.name, this.columns, {this.unique = false});

  final String name;
  final List<String> columns;
  final bool unique;
}

@immutable
class CollectionDef {
  const CollectionDef({
    required this.name,
    required this.columns,
    required this.indices,
  });

  final String name;

  /// The columns lifted out of the document so SQL can filter on them.
  final List<ColumnDef> columns;

  final List<IndexDef> indices;

  bool hasColumn(String column) {
    if (column == 'id') return true;
    for (final ColumnDef c in columns) {
      if (c.name == column) return true;
    }
    return false;
  }

  String createTableSql() {
    final StringBuffer sql = StringBuffer('CREATE TABLE IF NOT EXISTS ')
      ..write(name)
      ..write(' (id TEXT NOT NULL PRIMARY KEY');
    for (final ColumnDef c in columns) {
      sql
        ..write(', ')
        ..write(c.name)
        ..write(' ')
        ..write(c.sqlType);
    }
    sql.write(', doc TEXT NOT NULL)');
    return sql.toString();
  }

  List<String> createIndexSql() {
    return <String>[
      for (final IndexDef i in indices)
        'CREATE ${i.unique ? 'UNIQUE ' : ''}INDEX IF NOT EXISTS ${i.name} '
            'ON $name (${i.columns.join(', ')})',
    ];
  }
}
