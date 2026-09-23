import 'package:ledger/core/result.dart';
import 'package:ledger/data/data.dart';
import 'package:ledger/models/models.dart';

/// Fixtures shared by the data-layer tests.
///
/// Everything here runs against [MemoryLedgerStore], which enforces the same
/// unique indices as the SQLite store. That keeps these tests honest while
/// letting them run anywhere, with no native SQLite binary and no device.
class TestLedger {
  TestLedger({DateTime? now})
      : _now = now ?? DateTime(2026, 5, 20, 10),
        store = MemoryLedgerStore() {
    repository = LedgerRepositoryImpl(store: store, clock: () => _now);
  }

  final DateTime _now;
  final MemoryLedgerStore store;
  late final LedgerRepositoryImpl repository;

  DateTime get now => _now;

  Future<void> open() async {
    final Result<void> result = await repository.init();
    if (result.isErr) {
      throw StateError('init failed: ${result.errorOrNull?.message}');
    }
  }

  Future<Transaction> post(Transaction txn) async {
    final Result<Transaction> result = await repository.postTransaction(txn);
    return switch (result) {
      Ok<Transaction>(value: final Transaction t) => t,
      Err<Transaction>(error: final AppError e) =>
        throw StateError('postTransaction failed: ${e.message}'),
    };
  }

  Future<Money> spendBetween(DateTime from, DateTime to) async {
    final Result<Money> result = await repository.totalSpend(from: from, to: to);
    return result.getOrElse(Money.zero);
  }

  /// Every posting in the ledger, for the invariant checks.
  Future<List<Posting>> allPostings() async {
    final List<StoredRow> rows = await store.query(LedgerCollections.postings);
    return <Posting>[for (final StoredRow row in rows) Posting.fromJson(row.doc)];
  }
}

/// Builds a transaction the way the parser and categoriser would, so a test
/// never accidentally constructs a row the app could not produce.
Transaction makeTxn({
  required String id,
  required int rupees,
  required DateTime occurredAt,
  TxnDirection direction = TxnDirection.debit,
  CategoryKind kind = CategoryKind.expense,
  String categoryPath = 'food_dining/food_delivery',
  TxnChannel channel = TxnChannel.upi,
  String? merchantName,
  String? merchantRaw,
  String? accountTail,
  String? cardTail,
  String? accountId,
  String? ref,
  String? vpa,
  String? rawMessageId,
  String? note,
  TxnStatus status = TxnStatus.posted,
  int paise = 0,
  bool excluded = false,
}) {
  final DateTime created = occurredAt;
  return Transaction(
    id: id,
    amount: Money(rupees * 100 + paise),
    direction: direction,
    occurredAt: occurredAt,
    bookingDate: jDateKey(occurredAt.toLocal()),
    kind: kind,
    categoryPath: categoryPath,
    createdAt: created,
    updatedAt: created,
    status: status,
    channel: channel,
    merchantName: merchantName,
    merchantRaw: merchantRaw,
    accountTail: accountTail,
    cardTail: cardTail,
    accountId: accountId,
    ref: ref,
    vpa: vpa,
    note: note,
    rawMessageId: rawMessageId,
    categorySource: CategorySource.dictionary,
    categoryExplanation: 'test fixture',
    isExcludedFromTotals: excluded,
  );
}

RawMessage makeMessage({
  required String id,
  required String sender,
  required String body,
  required DateTime receivedAt,
  IngestSource source = IngestSource.smsRealtime,
  int? providerId,
}) =>
    RawMessage(
      id: id,
      senderRaw: sender,
      body: body,
      receivedAt: receivedAt,
      source: source,
      providerId: providerId,
    );

/// The two accounts every double-count test needs: a bank and the card whose
/// bill is paid from it.
Account bankAccount(DateTime now) => Account(
      id: 'acc-hdfc',
      type: AccountType.savings,
      displayName: 'HDFC Savings 0601',
      createdAt: now,
      updatedAt: now,
      institutionId: 'HDFC',
      tail: '0601',
    );

Account cardAccount(DateTime now) => Account(
      id: 'acc-hdfc-card',
      type: AccountType.creditCard,
      displayName: 'HDFC Card 4455',
      createdAt: now,
      updatedAt: now,
      institutionId: 'HDFC',
      tail: '4455',
      creditLimit: const Money(20000000),
    );
