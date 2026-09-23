import 'package:flutter/foundation.dart';

import '../core/result.dart';
import '../models/models.dart';

/// Filter for reading transactions. Every field is optional; omitted fields do
/// not constrain the query. All ranges are half-open: `from` inclusive, `to`
/// exclusive, so adjacent months never double-count a midnight transaction.
@immutable
class TxnQuery {
  const TxnQuery({
    this.from,
    this.to,
    this.categoryPaths,
    this.kinds,
    this.statuses,
    this.accountIds,
    this.channels,
    this.direction,
    this.merchantName,
    this.search,
    this.onlyUncategorized = false,
    this.onlyNeedsReview = false,
    this.includeExcluded = false,
    this.limit = 100,
    this.offset = 0,
    this.newestFirst = true,
  });

  final DateTime? from;
  final DateTime? to;
  final Set<String>? categoryPaths;
  final Set<CategoryKind>? kinds;
  final Set<TxnStatus>? statuses;
  final Set<String>? accountIds;
  final Set<TxnChannel>? channels;
  final TxnDirection? direction;
  final String? merchantName;

  /// Case-insensitive substring over merchant, note and ref.
  final String? search;

  final bool onlyUncategorized;
  final bool onlyNeedsReview;

  /// Include rows the user excluded from totals. Off by default.
  final bool includeExcluded;

  final int limit;
  final int offset;
  final bool newestFirst;

  TxnQuery copyWith({
    DateTime? from,
    DateTime? to,
    Set<String>? categoryPaths,
    Set<CategoryKind>? kinds,
    Set<TxnStatus>? statuses,
    Set<String>? accountIds,
    Set<TxnChannel>? channels,
    TxnDirection? direction,
    String? merchantName,
    String? search,
    bool? onlyUncategorized,
    bool? onlyNeedsReview,
    bool? includeExcluded,
    int? limit,
    int? offset,
    bool? newestFirst,
  }) {
    return TxnQuery(
      from: from ?? this.from,
      to: to ?? this.to,
      categoryPaths: categoryPaths ?? this.categoryPaths,
      kinds: kinds ?? this.kinds,
      statuses: statuses ?? this.statuses,
      accountIds: accountIds ?? this.accountIds,
      channels: channels ?? this.channels,
      direction: direction ?? this.direction,
      merchantName: merchantName ?? this.merchantName,
      search: search ?? this.search,
      onlyUncategorized: onlyUncategorized ?? this.onlyUncategorized,
      onlyNeedsReview: onlyNeedsReview ?? this.onlyNeedsReview,
      includeExcluded: includeExcluded ?? this.includeExcluded,
      limit: limit ?? this.limit,
      offset: offset ?? this.offset,
      newestFirst: newestFirst ?? this.newestFirst,
    );
  }
}

/// One row of a spend rollup.
@immutable
class SpendBucket {
  const SpendBucket({
    required this.key,
    required this.total,
    required this.count,
    this.label,
    this.kind = CategoryKind.expense,
  });

  /// Category path, merchant name, or `'YYYY-MM'` / `'YYYY-MM-DD'`, depending
  /// on which rollup produced it.
  final String key;

  final Money total;
  final int count;
  final String? label;
  final CategoryKind kind;
}

/// The result of storing a raw message, which may be a duplicate.
@immutable
class IngestReceipt {
  const IngestReceipt({
    required this.id,
    required this.isDuplicate,
    this.mergedIntoId,
  });

  /// The id of the stored message - the existing row's id when
  /// [isDuplicate] is true.
  final String id;

  /// True when this message had already been ingested. The same SMS arrives
  /// once live and again during inbox backfill; booking both would double the
  /// user's spend.
  final bool isDuplicate;

  /// Set when the message was folded into an existing row.
  final String? mergedIntoId;
}

/// All persistence. The single owner of the local database.
///
/// Hard requirements on every implementation:
/// * 100% LOCAL. No network I/O of any kind, ever. Nothing in this interface
///   may be implemented against a server.
/// * NEVER THROWS across the boundary. Every failure comes back as an
///   `Err` with a code from `ErrorCodes`.
/// * `watch*` streams emit the current value immediately on listen, then again
///   on every change, and never emit errors.
/// * Writes are atomic per call. [postTransaction] either stores the
///   transaction and its links or changes nothing.
abstract interface class LedgerRepository {
  /// Opens the database and runs migrations. Must be awaited before anything
  /// else. Idempotent. Fails with `ErrorCodes.database`.
  Future<Result<void>> init();

  // --- raw messages -------------------------------------------------------

  /// Stores a raw message, de-duplicating on `(bodyHash, senderHeader)` within
  /// a short receipt window and on `providerId` when present.
  ///
  /// Returns `isDuplicate: true` and the existing id instead of failing.
  Future<Result<IngestReceipt>> saveRawMessage(RawMessage message);

  /// Batch form of [saveRawMessage], for backfill. Returns one receipt per
  /// input, in order. Atomic: a failure stores nothing.
  Future<Result<List<IngestReceipt>>> saveRawMessages(List<RawMessage> messages);

  Future<Result<RawMessage?>> rawMessageById(String id);

  /// Messages in the given states, oldest first. Drives the re-parse sweep.
  Future<Result<List<RawMessage>>> rawMessagesByState(
    Set<ParseState> states, {
    int limit = 200,
    int offset = 0,
    int? olderThanParserVersion,
  });

  /// Records what the parser decided. Does not create a transaction.
  Future<Result<void>> updateParseState(
    String rawMessageId, {
    required ParseState state,
    int? parserVersion,
    String? ruleId,
    String? txnId,
    String? reason,
  });

  /// Deletes stored bodies older than [olderThan], keeping the metadata rows.
  /// Returns how many were purged. The privacy retention job.
  Future<Result<int>> purgeMessageBodies({required DateTime olderThan});

  // --- transactions -------------------------------------------------------

  /// Inserts or replaces a transaction, and links it to its raw message.
  ///
  /// De-duplicates on `ref` + amount when `ref` is present, because the same
  /// money event can arrive as several messages from different senders.
  /// Returns the stored row, whose id may differ from the input when an
  /// existing row was updated.
  ///
  /// Fails with `ErrorCodes.invalidArgument` when the amount is not positive
  /// or the category path is unknown.
  Future<Result<Transaction>> postTransaction(Transaction txn);

  Future<Result<Transaction?>> transactionById(String id);

  /// Reads transactions matching [query], newest first by default.
  Future<Result<List<Transaction>>> transactions(TxnQuery query);

  /// Live version of [transactions]. Emits immediately, then on every change.
  Stream<List<Transaction>> watchTransactions(TxnQuery query);

  /// Applies a user edit. Fields the user touched are recorded in
  /// `Transaction.editedFields` so a later re-parse cannot overwrite them.
  Future<Result<Transaction>> updateTransaction(Transaction txn);

  /// Sets the category and marks it user-authored, so nothing overwrites it.
  Future<Result<Transaction>> recategorize(
    String txnId,
    CategoryResult category, {
    bool createUserRule = false,
  });

  /// Soft-deletes: the row becomes `TxnStatus.voided` and leaves every total.
  /// Its raw message is kept so the audit trail survives.
  Future<Result<void>> deleteTransaction(String id);

  /// Links the two legs of a self-transfer or card bill payment under one
  /// group id, so the pair is reported once and counted as spend zero times.
  Future<Result<void>> linkTransfer(String txnIdA, String txnIdB);

  /// Links a refund to the transaction it reverses.
  Future<Result<void>> linkReversal({required String txnId, required String reversesId});

  /// Transactions the app could not categorise, oldest first. This is the
  /// queue the user is asked about.
  Future<Result<List<Transaction>>> uncategorized({int limit = 100, int offset = 0});

  Stream<int> watchUncategorizedCount();

  // --- rollups ------------------------------------------------------------

  /// Total spend in `[from, to)`.
  ///
  /// Counts ONLY `CategoryKind.expense` debits with a counting status and not
  /// excluded - i.e. exactly `Transaction.countsAsSpend`. Transfers,
  /// investments and card bill payments are never included.
  Future<Result<Money>> totalSpend({required DateTime from, required DateTime to});

  /// Total income in `[from, to)`, by the same rule for
  /// `Transaction.countsAsIncome`.
  Future<Result<Money>> totalIncome({required DateTime from, required DateTime to});

  /// Spend grouped by category path, descending by total.
  Future<Result<List<SpendBucket>>> spendByCategory({
    required DateTime from,
    required DateTime to,
  });

  /// Spend grouped by merchant, descending by total.
  Future<Result<List<SpendBucket>>> spendByMerchant({
    required DateTime from,
    required DateTime to,
    int limit = 20,
  });

  /// Spend grouped by `'YYYY-MM'`, oldest first.
  Future<Result<List<SpendBucket>>> monthlySpend({
    required DateTime from,
    required DateTime to,
  });

  /// Live total spend for `[from, to)`.
  Stream<Money> watchTotalSpend({required DateTime from, required DateTime to});

  // --- accounts -----------------------------------------------------------

  Future<Result<List<Account>>> accounts({bool includeArchived = false});

  Stream<List<Account>> watchAccounts({bool includeArchived = false});

  Future<Result<Account>> upsertAccount(Account account);

  /// Finds the account whose tail matches, using `Account.normalizeTail`.
  /// Returns `null` rather than failing when nothing matches, and never
  /// matches on an empty tail.
  Future<Result<Account?>> accountByTail(String? tail, {AccountType? type});

  Future<Result<void>> deleteAccount(String id);

  // --- bills --------------------------------------------------------------

  Future<Result<List<Bill>>> bills({
    Set<BillStatus>? statuses,
    DateTime? dueBefore,
    int limit = 100,
  });

  Stream<List<Bill>> watchBills({Set<BillStatus>? statuses});

  Future<Result<Bill>> upsertBill(Bill bill);

  /// Marks a bill settled by a transaction, setting both sides of the link.
  Future<Result<void>> markBillPaid({required String billId, required String txnId});

  Future<Result<void>> deleteBill(String id);

  // --- user rules ---------------------------------------------------------

  Future<Result<List<UserRule>>> userRules({bool includeDisabled = false});

  Stream<List<UserRule>> watchUserRules();

  Future<Result<UserRule>> upsertUserRule(UserRule rule);

  Future<Result<void>> deleteUserRule(String id);

  // --- lifecycle ----------------------------------------------------------

  /// Everything the user has, as one JSON document, for the local export /
  /// backup feature. Written to a file the USER chooses; never uploaded.
  Future<Result<Map<String, dynamic>>> exportAll();

  /// Replaces the database from a document produced by [exportAll]. Fails with
  /// `ErrorCodes.invalidArgument` on an unrecognised shape, leaving the
  /// existing data untouched.
  Future<Result<void>> importAll(Map<String, dynamic> document);

  /// Deletes every row. The "erase my data" button. Irreversible.
  Future<Result<void>> wipe();

  Future<void> close();
}
