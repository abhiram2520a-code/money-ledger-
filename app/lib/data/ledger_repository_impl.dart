import 'dart:async';

import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';

import 'bill_matching.dart';
import 'encryption.dart';
import 'fingerprints.dart';
import 'ids.dart';
import 'ledger_store.dart';
import 'memory_store.dart';
import 'postings.dart';
import 'recurring.dart';
import 'reconciliation.dart';
import 'schema.dart';
import 'transfer_matching.dart';

/// The single owner of the local database.
///
/// Everything here runs on the device and nothing here can reach a network:
/// there is no HTTP client in this file's imports, and there never may be.
///
/// Three rules shape the implementation:
///
/// 1. **No exception crosses the boundary.** Every method returns a
///    [Result]; the store is allowed to throw and [_guard] converts it.
/// 2. **Writes are atomic per call.** A transaction and its postings, a bill
///    and its payment link, an import and its wipe - each is one store
///    transaction, so a failure changes nothing.
/// 3. **The same money event can arrive many times and must be stored once.**
///    That is [saveRawMessage]'s dedupe window and [postTransaction]'s
///    fingerprint, and it is the difference between a ledger and a rumour.
class LedgerRepositoryImpl implements LedgerRepository {
  LedgerRepositoryImpl({
    LedgerStore? store,
    DateTime Function()? clock,
    this.knownCategoryPaths = const <String>{},
  })  : _store = store ?? MemoryLedgerStore(),
        _clock = clock ?? DateTime.now;

  final LedgerStore _store;
  final DateTime Function() _clock;

  /// When empty, any non-empty category path is accepted. The app passes
  /// `RuleSet.categoryPaths` so a path that is not in the taxonomy is refused
  /// before it can poison a rollup.
  final Set<String> knownCategoryPaths;

  final StreamController<void> _changes = StreamController<void>.broadcast();

  bool _initialized = false;

  DateTime get _now => _clock();

  // --- lifecycle ----------------------------------------------------------

  @override
  Future<Result<void>> init() => _guard(() async {
        if (_initialized) return;
        await _store.open();
        final DateTime now = _now;
        await _putMeta(LedgerMetaKeys.schemaVersion, LedgerSchema.version);
        final StoredRow? created =
            await _store.get(LedgerCollections.meta, LedgerMetaKeys.createdAt);
        if (created == null) {
          await _putMeta(LedgerMetaKeys.createdAt, jMillis(now));
          await _putMeta(
            LedgerMetaKeys.bodyRetentionDays,
            LedgerEncryption.defaultBodyRetention.inDays,
          );
          await _seedSystemAccounts(now);
        }
        _initialized = true;
      });

  @override
  Future<void> close() async {
    await _changes.close();
    await _store.close();
    _initialized = false;
  }

  /// Cash in hand exists from the first launch, because an ATM withdrawal has
  /// to have somewhere to go that is not a spend category.
  Future<void> _seedSystemAccounts(DateTime now) async {
    await upsertAccount(
      Account(
        id: LedgerAccounts.cash,
        type: AccountType.cash,
        displayName: 'Cash in hand',
        createdAt: now,
        updatedAt: now,
        sortOrder: 900,
      ),
    );
  }

  // --- raw messages -------------------------------------------------------

  @override
  Future<Result<IngestReceipt>> saveRawMessage(RawMessage message) =>
      _guard(() => _store.transaction(() => _saveRawMessage(message)));

  @override
  Future<Result<List<IngestReceipt>>> saveRawMessages(List<RawMessage> messages) =>
      _guard(() => _store.transaction(() async {
            final List<IngestReceipt> out = <IngestReceipt>[];
            for (final RawMessage m in messages) {
              out.add(await _saveRawMessage(m));
            }
            _notify();
            return out;
          }));

  Future<IngestReceipt> _saveRawMessage(RawMessage message) async {
    final String hash =
        message.bodyHash.isNotEmpty ? message.bodyHash : Fingerprints.bodyHash(message.body);
    final String header = message.senderHeader ?? Fingerprints.normalizeSender(message.senderRaw);
    final RawMessage normalized = message.copyWith(
      id: message.id.isEmpty ? LedgerIds.generate(now: message.receivedAt) : message.id,
      bodyHash: hash,
      senderHeader: header.isEmpty ? null : header,
    );

    final StoredRow? existing = await _findDuplicate(normalized);
    if (existing != null) {
      // The live broadcast and the inbox backfill are the same message. Fold
      // the backfill's provider id into the row we already have, so the next
      // backfill recognises it immediately instead of relying on the time
      // window again.
      final RawMessage stored = RawMessage.fromJson(existing.doc);
      if (stored.providerId == null && normalized.providerId != null) {
        await _store.put(
          LedgerCollections.rawMessages,
          _rawRow(stored.copyWith(providerId: normalized.providerId)),
        );
      }
      return IngestReceipt(id: stored.id, isDuplicate: true, mergedIntoId: stored.id);
    }

    await _store.put(LedgerCollections.rawMessages, _rawRow(normalized));
    _notify();
    return IngestReceipt(id: normalized.id, isDuplicate: false);
  }

  Future<StoredRow?> _findDuplicate(RawMessage message) async {
    final int? providerId = message.providerId;
    if (providerId != null) {
      final List<StoredRow> byProvider = await _store.query(
        LedgerCollections.rawMessages,
        StoreQuery(
          conditions: <StoreCondition>[
            StoreCondition.eq('provider_id', providerId),
          ],
          limit: 1,
        ),
      );
      if (byProvider.isNotEmpty) return byProvider.first;
    }

    final int minute = Fingerprints.receivedMinute(message.receivedAt);
    final int slack = Fingerprints.duplicateWindow.inMinutes;
    final List<StoredRow> sameBody = await _store.query(
      LedgerCollections.rawMessages,
      StoreQuery(
        conditions: <StoreCondition>[
          StoreCondition.eq('body_hash', message.bodyHash),
          StoreCondition('received_minute', StoreOp.gte, minute - slack),
          StoreCondition('received_minute', StoreOp.lte, minute + slack),
        ],
      ),
    );
    for (final StoredRow row in sameBody) {
      if (row.index['sender_header'] != message.senderHeader) continue;
      final RawMessage stored = RawMessage.fromJson(row.doc);
      final Duration apart = stored.receivedAt.difference(message.receivedAt).abs();
      if (apart <= Fingerprints.duplicateWindow) return row;
    }
    return null;
  }

  @override
  Future<Result<RawMessage?>> rawMessageById(String id) => _guard(() async {
        final StoredRow? row = await _store.get(LedgerCollections.rawMessages, id);
        return row == null ? null : RawMessage.fromJson(row.doc);
      });

  @override
  Future<Result<List<RawMessage>>> rawMessagesByState(
    Set<ParseState> states, {
    int limit = 200,
    int offset = 0,
    int? olderThanParserVersion,
  }) =>
      _guard(() async {
        final List<StoreCondition> conditions = <StoreCondition>[
          StoreCondition(
            'parse_state',
            StoreOp.isIn,
            <String>[for (final ParseState s in states) s.wire],
          ),
          if (olderThanParserVersion != null)
            StoreCondition('parser_version', StoreOp.lt, olderThanParserVersion),
        ];
        final List<StoredRow> rows = await _store.query(
          LedgerCollections.rawMessages,
          StoreQuery(
            conditions: conditions,
            orderBy: 'received_at',
            limit: limit,
            offset: offset,
          ),
        );
        return <RawMessage>[
          for (final StoredRow row in rows) RawMessage.fromJson(row.doc),
        ];
      });

  @override
  Future<Result<void>> updateParseState(
    String rawMessageId, {
    required ParseState state,
    int? parserVersion,
    String? ruleId,
    String? txnId,
    String? reason,
  }) =>
      _guard(() async {
        final StoredRow? row =
            await _store.get(LedgerCollections.rawMessages, rawMessageId);
        if (row == null) {
          throw StateError('No message $rawMessageId');
        }
        final RawMessage updated = RawMessage.fromJson(row.doc).copyWith(
          parseState: state,
          parserVersion: parserVersion,
          ruleId: ruleId,
          txnId: txnId,
          parseReason: reason,
        );
        await _store.put(LedgerCollections.rawMessages, _rawRow(updated));
        _notify();
      });

  @override
  Future<Result<int>> purgeMessageBodies({required DateTime olderThan}) =>
      _guard(() => _store.transaction(() async {
            final List<StoredRow> rows = await _store.query(
              LedgerCollections.rawMessages,
              StoreQuery(
                conditions: <StoreCondition>[
                  StoreCondition('received_at', StoreOp.lt, jMillis(olderThan)),
                  const StoreCondition.eq('has_body', 1),
                ],
              ),
            );
            for (final StoredRow row in rows) {
              // The metadata row survives so the audit trail and the parse
              // state stay intact; only the words go.
              final RawMessage stripped =
                  RawMessage.fromJson(row.doc).copyWith(body: '');
              await _store.put(LedgerCollections.rawMessages, _rawRow(stripped));
            }
            if (rows.isNotEmpty) _notify();
            return rows.length;
          }));

  // --- transactions -------------------------------------------------------

  @override
  Future<Result<Transaction>> postTransaction(Transaction txn) =>
      _guard(() => _store.transaction(() => _postTransaction(txn)));

  Future<Transaction> _postTransaction(Transaction txn) async {
    if (txn.amount.abs.paise <= 0) {
      throw _Invalid('A transaction amount must be positive.');
    }
    if (txn.categoryPath.isEmpty) {
      throw _Invalid('A transaction must have a category path.');
    }
    if (knownCategoryPaths.isNotEmpty &&
        !knownCategoryPaths.contains(txn.categoryPath) &&
        txn.categoryPath != CategoryResult.uncategorizedPath) {
      throw _Invalid('Unknown category path "${txn.categoryPath}".');
    }

    final DateTime now = _now;
    Transaction incoming = txn.id.isEmpty
        ? txn.copyWith(id: LedgerIds.generate(now: txn.occurredAt))
        : txn;
    incoming = incoming.copyWith(
      accountId: incoming.accountId ?? await _resolveAccountId(incoming),
    );

    final Transaction? existing = await _findExisting(incoming);
    final Transaction merged =
        existing == null ? incoming : _merge(existing, incoming, now);

    await _writeTransaction(merged);
    await _linkRawMessage(merged);
    final Transaction paired = await _tryPairTransfer(merged);
    final Transaction billed = await _tryMatchBill(paired);
    _notify();
    return billed;
  }

  /// The three ways one money event can already be in the ledger.
  ///
  /// Order matters. The raw message is the strongest: a re-parse of the same
  /// SMS must update its own row, never add a second. The fingerprint catches
  /// the same event arriving from a different message. The reference catches
  /// the bank and the card issuer both announcing one payment.
  Future<Transaction?> _findExisting(Transaction txn) async {
    final String? rawId = txn.rawMessageId;
    if (rawId != null) {
      final List<StoredRow> byMessage = await _store.query(
        LedgerCollections.transactions,
        StoreQuery(
          conditions: <StoreCondition>[StoreCondition.eq('raw_message_id', rawId)],
          limit: 1,
        ),
      );
      if (byMessage.isNotEmpty) return _txnFrom(byMessage.first);
    }

    final String fingerprint = Fingerprints.transaction(txn);
    final List<StoredRow> byFingerprint = await _store.query(
      LedgerCollections.transactions,
      StoreQuery(
        conditions: <StoreCondition>[
          StoreCondition.eq('fingerprint', fingerprint),
        ],
        limit: 2,
      ),
    );
    for (final StoredRow row in byFingerprint) {
      final Transaction candidate = _txnFrom(row);
      if (candidate.id != txn.id && candidate.status == TxnStatus.voided) continue;
      return candidate;
    }

    final String? ref = txn.ref;
    if (ref != null && ref.length >= 6) {
      final List<StoredRow> byRef = await _store.query(
        LedgerCollections.transactions,
        StoreQuery(
          conditions: <StoreCondition>[
            StoreCondition.eq('ref', ref),
            StoreCondition.eq('amount_paise', txn.amount.abs.paise),
          ],
          limit: 2,
        ),
      );
      for (final StoredRow row in byRef) {
        final Transaction candidate = _txnFrom(row);
        if (candidate.status == TxnStatus.voided) continue;
        // The same reference in the opposite direction is the OTHER leg of a
        // transfer, not a duplicate of this one.
        if (candidate.direction != txn.direction) continue;
        return candidate;
      }
    }
    return null;
  }

  /// Folds a freshly parsed row into the one already stored, without ever
  /// overwriting something the user decided.
  Transaction _merge(Transaction existing, Transaction incoming, DateTime now) {
    final bool categoryIsUsers = existing.categorySource.isUserAuthored ||
        existing.isFieldLocked('categoryPath');
    return existing.copyWith(
      amount: existing.isFieldLocked('amount') ? existing.amount : incoming.amount,
      direction: existing.isFieldLocked('direction') ? existing.direction : incoming.direction,
      occurredAt:
          existing.isFieldLocked('occurredAt') ? existing.occurredAt : incoming.occurredAt,
      bookingDate:
          existing.isFieldLocked('occurredAt') ? existing.bookingDate : incoming.bookingDate,
      kind: categoryIsUsers ? existing.kind : incoming.kind,
      categoryPath: categoryIsUsers ? existing.categoryPath : incoming.categoryPath,
      categorySource: categoryIsUsers ? existing.categorySource : incoming.categorySource,
      categoryExplanation:
          categoryIsUsers ? existing.categoryExplanation : incoming.categoryExplanation,
      merchantName: existing.isFieldLocked('merchantName')
          ? existing.merchantName
          : incoming.merchantName ?? existing.merchantName,
      merchantRaw: incoming.merchantRaw ?? existing.merchantRaw,
      channel: incoming.channel == TxnChannel.unknown ? existing.channel : incoming.channel,
      status: existing.status == TxnStatus.voided ? TxnStatus.voided : incoming.status,
      accountId: incoming.accountId ?? existing.accountId,
      accountTail: incoming.accountTail ?? existing.accountTail,
      cardTail: incoming.cardTail ?? existing.cardTail,
      vpa: incoming.vpa ?? existing.vpa,
      ref: incoming.ref ?? existing.ref,
      balanceAfter: incoming.balanceAfter ?? existing.balanceAfter,
      rawMessageId: existing.rawMessageId ?? incoming.rawMessageId,
      ruleId: incoming.ruleId ?? existing.ruleId,
      ruleVersion: incoming.ruleVersion ?? existing.ruleVersion,
      confidence: incoming.confidence,
      updatedAt: now,
    );
  }

  Future<String?> _resolveAccountId(Transaction txn) async {
    final String? card = Account.normalizeTail(txn.cardTail);
    if (card != null && !PostingEngine.isCardBillPayment(txn)) {
      final Account? match = await _accountByTail(card, type: AccountType.creditCard);
      if (match != null) return match.id;
    }
    final String? bank = Account.normalizeTail(txn.accountTail);
    if (bank != null) {
      final Account? match = await _accountByTail(bank);
      if (match != null) return match.id;
    }
    return null;
  }

  Future<void> _writeTransaction(Transaction txn) async {
    await _store.put(LedgerCollections.transactions, _txnRow(txn));
    await _rewritePostings(txn);
  }

  /// Postings are derived, so they are rewritten wholesale rather than
  /// patched. Their ids are derived from the transaction id, which means a
  /// re-post replaces them instead of adding a second balanced pair.
  Future<void> _rewritePostings(Transaction txn) async {
    await _store.deleteWhere(
      LedgerCollections.postings,
      StoreQuery(
        conditions: <StoreCondition>[StoreCondition.eq('txn_id', txn.id)],
      ),
    );
    if (txn.status == TxnStatus.voided || txn.status == TxnStatus.reversed) return;
    if (txn.isExcludedFromTotals) return;

    final Account? money = txn.accountId == null
        ? null
        : await _accountById(txn.accountId!);
    final Account? counter = await _counterAccountFor(txn);
    final List<Posting> postings = PostingEngine.build(
      txn,
      moneyAccountType: money?.type,
      counterAccountType: counter?.type,
      counterAccountOverride: counter?.id,
    );
    await _store.putAll(
      LedgerCollections.postings,
      <StoredRow>[for (final Posting p in postings) _postingRow(p)],
    );
  }

  /// The account on the other side of a transfer, when the user actually has
  /// it. A card bill payment names the card by its tail; posting it against a
  /// tail-derived placeholder while the card's spends accumulate on the real
  /// account would leave both balances wrong.
  Future<Account?> _counterAccountFor(Transaction txn) async {
    if (txn.kind != CategoryKind.transfer) return null;
    if (PostingEngine.isCardBillPayment(txn)) {
      return _accountByTail(
        Account.normalizeTail(txn.cardTail),
        type: AccountType.creditCard,
      );
    }
    if (txn.categoryPath == TransferPaths.loanRepayment) {
      return _accountByTail(
        Account.normalizeTail(txn.cardTail ?? txn.accountTail),
        type: AccountType.loan,
      );
    }
    if (txn.categoryPath == TransferPaths.atmWithdrawal) {
      return _accountById(LedgerAccounts.cash);
    }
    return null;
  }

  Future<void> _linkRawMessage(Transaction txn) async {
    final String? rawId = txn.rawMessageId;
    if (rawId == null) return;
    final StoredRow? row = await _store.get(LedgerCollections.rawMessages, rawId);
    if (row == null) return;
    final RawMessage stored = RawMessage.fromJson(row.doc);
    if (stored.txnId == txn.id && stored.parseState == ParseState.parsed) return;
    await _store.put(
      LedgerCollections.rawMessages,
      _rawRow(stored.copyWith(txnId: txn.id, parseState: ParseState.parsed)),
    );
  }

  /// Pairs the two halves of one movement of the user's own money.
  Future<Transaction> _tryPairTransfer(Transaction txn) async {
    if (!txn.isNetZero || txn.transferGroupId != null) return txn;
    final DateTime from = txn.occurredAt.subtract(TransferMatcher.slowWindow);
    final DateTime to = txn.occurredAt.add(TransferMatcher.slowWindow);
    final List<StoredRow> rows = await _store.query(
      LedgerCollections.transactions,
      StoreQuery(
        conditions: <StoreCondition>[
          StoreCondition.eq('amount_paise', txn.amount.abs.paise),
          StoreCondition('occurred_at', StoreOp.gte, jMillis(from)),
          StoreCondition('occurred_at', StoreOp.lte, jMillis(to)),
        ],
      ),
    );
    final List<Transaction> pool = <Transaction>[
      for (final StoredRow row in rows)
        if (row.id != txn.id) _txnFrom(row),
    ];
    final TransferMatch? match = TransferMatcher.findPartner(txn, pool);
    if (match == null || !match.canAutoLink) return txn;

    final String group = match.other.transferGroupId ?? LedgerIds.generate();
    final Transaction linked = txn.copyWith(transferGroupId: group);
    await _store.put(LedgerCollections.transactions, _txnRow(linked));
    if (match.other.transferGroupId == null) {
      await _store.put(
        LedgerCollections.transactions,
        _txnRow(match.other.copyWith(transferGroupId: group)),
      );
    }
    return linked;
  }

  /// Links a payment to the bill it settled, when the evidence is strong
  /// enough to do it without asking.
  Future<Transaction> _tryMatchBill(Transaction txn) async {
    if (txn.billId != null) return txn;
    if (!txn.direction.isDebit) return txn;

    final List<StoredRow> rows = await _store.query(
      LedgerCollections.bills,
      StoreQuery(
        conditions: <StoreCondition>[
          StoreCondition(
            'status',
            StoreOp.isIn,
            <String>[
              BillStatus.upcoming.wire,
              BillStatus.due.wire,
              BillStatus.overdue.wire,
            ],
          ),
        ],
      ),
    );

    final List<BillMatch> matches = <BillMatch>[];
    for (final StoredRow row in rows) {
      final Bill bill = Bill.fromJson(row.doc);
      final int paid = await _paidPaiseFor(bill.id);
      final BillMatch? match =
          BillMatcher.score(bill, txn, alreadyPaidPaise: paid);
      if (match == null || !match.canAutoLink) continue;
      matches.add(match);
    }
    if (matches.isEmpty) return txn;
    matches.sort((BillMatch a, BillMatch b) => b.score.compareTo(a.score));
    if (matches.length > 1 &&
        matches[0].score - matches[1].score < BillMatcher.contentionMargin) {
      // Two cards from the same issuer with the same amount due is not a rare
      // shape. Guessing puts the payment on the wrong statement, so the app
      // asks instead.
      return txn;
    }

    final BillMatch best = matches.first;
    await _applyBillPayment(best, byUser: false);
    return txn.copyWith(billId: best.bill.id);
  }

  Future<void> _applyBillPayment(BillMatch match, {required bool byUser}) async {
    final DateTime now = _now;
    final BillPayment payment = BillPayment(
      billId: match.bill.id,
      txnId: match.txn.id,
      appliedPaise: match.appliedPaise,
      confidence: match.score,
      reason: match.reason,
      createdAt: now,
      byUser: byUser,
    );
    await _store.put(LedgerCollections.billPayments, _billPaymentRow(payment));

    final int paid = await _paidPaiseFor(match.bill.id);
    final BillStatus status =
        BillLifecycle.statusFor(match.bill, paidPaise: paid, now: now);
    final Bill updated = match.bill.copyWith(
      status: status,
      paidTxnId: status == BillStatus.paid ? match.txn.id : null,
      paidAt: status == BillStatus.paid ? now : null,
      updatedAt: now,
    );
    await _store.put(LedgerCollections.bills, _billRow(updated, paidPaise: paid));

    final StoredRow? txnRow =
        await _store.get(LedgerCollections.transactions, match.txn.id);
    if (txnRow != null) {
      await _store.put(
        LedgerCollections.transactions,
        _txnRow(_txnFrom(txnRow).copyWith(billId: match.bill.id, updatedAt: now)),
      );
    }
  }

  /// Always re-derived from the payment rows, never incremented. That is what
  /// makes a partial payment survive a re-import unchanged.
  Future<int> _paidPaiseFor(String billId) async {
    final List<StoredRow> rows = await _store.query(
      LedgerCollections.billPayments,
      StoreQuery(
        conditions: <StoreCondition>[StoreCondition.eq('bill_id', billId)],
      ),
    );
    int total = 0;
    for (final StoredRow row in rows) {
      total += (row.index['applied_paise'] as int?) ?? 0;
    }
    return total;
  }

  @override
  Future<Result<Transaction?>> transactionById(String id) => _guard(() async {
        final StoredRow? row = await _store.get(LedgerCollections.transactions, id);
        return row == null ? null : _txnFrom(row);
      });

  @override
  Future<Result<List<Transaction>>> transactions(TxnQuery query) =>
      _guard(() => _readTransactions(query));

  @override
  Stream<List<Transaction>> watchTransactions(TxnQuery query) =>
      _watch(() => _readTransactions(query), const <Transaction>[]);

  Future<List<Transaction>> _readTransactions(TxnQuery query) async {
    final List<StoredRow> rows = await _store.query(
      LedgerCollections.transactions,
      _storeQueryFor(query),
    );
    return <Transaction>[for (final StoredRow row in rows) _txnFrom(row)];
  }

  StoreQuery _storeQueryFor(TxnQuery query) {
    final List<StoreCondition> conditions = <StoreCondition>[];
    final DateTime? from = query.from;
    final DateTime? to = query.to;
    if (from != null) {
      // Both bounds are applied: the booking-date one so SQLite can use the
      // (booking_date, occurred_at) index, the instant one because the range
      // is half-open and a local calendar day is not.
      conditions
        ..add(StoreCondition('booking_date', StoreOp.gte, jDateKey(from.toLocal())))
        ..add(StoreCondition('occurred_at', StoreOp.gte, jMillis(from)));
    }
    if (to != null) {
      conditions
        ..add(StoreCondition('booking_date', StoreOp.lte, jDateKey(to.toLocal())))
        ..add(StoreCondition('occurred_at', StoreOp.lt, jMillis(to)));
    }
    final Set<String>? paths = query.categoryPaths;
    if (paths != null && paths.isNotEmpty) {
      conditions.add(StoreCondition('category_path', StoreOp.isIn, paths.toList()));
    }
    final Set<CategoryKind>? kinds = query.kinds;
    if (kinds != null && kinds.isNotEmpty) {
      conditions.add(
        StoreCondition(
          'kind',
          StoreOp.isIn,
          <String>[for (final CategoryKind k in kinds) k.wire],
        ),
      );
    }
    final Set<TxnStatus>? statuses = query.statuses;
    if (statuses != null && statuses.isNotEmpty) {
      conditions.add(
        StoreCondition(
          'status',
          StoreOp.isIn,
          <String>[for (final TxnStatus s in statuses) s.wire],
        ),
      );
    } else {
      // A voided row is deleted as far as the user is concerned; it stays only
      // so the audit trail survives.
      conditions.add(StoreCondition('status', StoreOp.ne, TxnStatus.voided.wire));
    }
    final Set<String>? accountIds = query.accountIds;
    if (accountIds != null && accountIds.isNotEmpty) {
      conditions.add(StoreCondition('account_id', StoreOp.isIn, accountIds.toList()));
    }
    final Set<TxnChannel>? channels = query.channels;
    if (channels != null && channels.isNotEmpty) {
      conditions.add(
        StoreCondition(
          'channel',
          StoreOp.isIn,
          <String>[for (final TxnChannel c in channels) c.wire],
        ),
      );
    }
    final TxnDirection? direction = query.direction;
    if (direction != null) {
      conditions.add(StoreCondition.eq('direction', direction.wire));
    }
    final String? merchant = query.merchantName;
    if (merchant != null && merchant.isNotEmpty) {
      conditions.add(StoreCondition.eq('merchant_name', merchant));
    }
    final String? search = query.search;
    if (search != null && search.trim().isNotEmpty) {
      conditions.add(
        StoreCondition('search', StoreOp.contains, search.trim().toLowerCase()),
      );
    }
    if (query.onlyUncategorized) {
      conditions.add(
        const StoreCondition.eq('category_path', CategoryResult.uncategorizedPath),
      );
    }
    if (query.onlyNeedsReview) {
      conditions.add(StoreCondition.eq('status', TxnStatus.needsReview.wire));
    }
    if (!query.includeExcluded) {
      conditions.add(const StoreCondition.eq('is_excluded', 0));
    }
    return StoreQuery(
      conditions: conditions,
      orderBy: 'booking_date',
      thenBy: 'occurred_at',
      descending: query.newestFirst,
      limit: query.limit,
      offset: query.offset,
    );
  }

  @override
  Future<Result<Transaction>> updateTransaction(Transaction txn) =>
      _guard(() => _store.transaction(() async {
            final StoredRow? row =
                await _store.get(LedgerCollections.transactions, txn.id);
            if (row == null) throw _NotFound('No transaction ${txn.id}');
            final Transaction updated = txn.copyWith(updatedAt: _now);
            await _writeTransaction(updated);
            await _refreshBillsFor(updated);
            _notify();
            return updated;
          }));

  @override
  Future<Result<Transaction>> recategorize(
    String txnId,
    CategoryResult category, {
    bool createUserRule = false,
  }) =>
      _guard(() => _store.transaction(() async {
            final StoredRow? row =
                await _store.get(LedgerCollections.transactions, txnId);
            if (row == null) throw _NotFound('No transaction $txnId');
            final DateTime now = _now;
            final Transaction existing = _txnFrom(row);
            final Transaction updated = existing
                .copyWith(
                  categoryPath: category.categoryPath,
                  kind: category.kind,
                  categorySource: CategorySource.manual,
                  categoryExplanation: category.explanation,
                  merchantName: category.merchantName ?? existing.merchantName,
                  // A category the user chose is never a review item any more.
                  status: existing.status == TxnStatus.needsReview
                      ? TxnStatus.posted
                      : existing.status,
                  updatedAt: now,
                )
                .markEdited(<String>['categoryPath'], now: now);
            await _writeTransaction(updated);

            if (createUserRule) {
              final String? merchant = updated.merchantName ?? updated.merchantRaw;
              if (merchant != null && merchant.trim().isNotEmpty) {
                final UserRule rule = UserRule(
                  id: LedgerIds.generate(now: now),
                  match: UserRuleMatch.merchantContains,
                  pattern: Fingerprints.normalizeMerchant(merchant),
                  categoryPath: category.categoryPath,
                  kind: category.kind,
                  createdAt: now,
                  merchantName: updated.merchantName,
                );
                await _store.put(LedgerCollections.userRules, _userRuleRow(rule));
              }
            }
            _notify();
            return updated;
          }));

  @override
  Future<Result<void>> deleteTransaction(String id) =>
      _guard(() => _store.transaction(() async {
            final StoredRow? row = await _store.get(LedgerCollections.transactions, id);
            if (row == null) throw _NotFound('No transaction $id');
            final Transaction voided = _txnFrom(row).copyWith(
              status: TxnStatus.voided,
              updatedAt: _now,
            );
            // The row stays, its postings do not: a voided transaction must
            // not move a balance, and the raw message it came from is kept so
            // the audit trail survives.
            await _writeTransaction(voided);
            await _store.deleteWhere(
              LedgerCollections.billPayments,
              StoreQuery(
                conditions: <StoreCondition>[StoreCondition.eq('txn_id', id)],
              ),
            );
            _notify();
          }));

  @override
  Future<Result<void>> linkTransfer(String txnIdA, String txnIdB) =>
      _guard(() => _store.transaction(() async {
            final StoredRow? rowA =
                await _store.get(LedgerCollections.transactions, txnIdA);
            final StoredRow? rowB =
                await _store.get(LedgerCollections.transactions, txnIdB);
            if (rowA == null || rowB == null) {
              throw _NotFound('Both transactions must exist to be linked.');
            }
            final Transaction a = _txnFrom(rowA);
            final Transaction b = _txnFrom(rowB);
            final DateTime now = _now;
            final String group =
                a.transferGroupId ?? b.transferGroupId ?? LedgerIds.generate(now: now);
            await _store.putAll(LedgerCollections.transactions, <StoredRow>[
              _txnRow(a.copyWith(transferGroupId: group, updatedAt: now)),
              _txnRow(b.copyWith(transferGroupId: group, updatedAt: now)),
            ]);
            _notify();
          }));

  @override
  Future<Result<void>> linkReversal({
    required String txnId,
    required String reversesId,
  }) =>
      _guard(() => _store.transaction(() async {
            final StoredRow? refundRow =
                await _store.get(LedgerCollections.transactions, txnId);
            final StoredRow? originalRow =
                await _store.get(LedgerCollections.transactions, reversesId);
            if (refundRow == null || originalRow == null) {
              throw _NotFound('Both transactions must exist to be linked.');
            }
            final DateTime now = _now;
            final Transaction refund = _txnFrom(refundRow);
            final Transaction original = _txnFrom(originalRow);
            await _store.put(
              LedgerCollections.transactions,
              _txnRow(refund.copyWith(reversalOfId: reversesId, updatedAt: now)),
            );
            // A FULL reversal takes the original out of every total with it.
            // A partial refund does not: the user did spend the difference.
            if (refund.amount.abs.paise == original.amount.abs.paise) {
              final Transaction reversed = original.copyWith(
                status: TxnStatus.reversed,
                updatedAt: now,
              );
              await _writeTransaction(reversed);
            }
            _notify();
          }));

  @override
  Future<Result<List<Transaction>>> uncategorized({int limit = 100, int offset = 0}) =>
      _guard(() async {
        final List<StoredRow> rows = await _store.query(
          LedgerCollections.transactions,
          StoreQuery(
            conditions: <StoreCondition>[
              const StoreCondition.eq('category_path', CategoryResult.uncategorizedPath),
              StoreCondition('status', StoreOp.ne, TxnStatus.voided.wire),
            ],
            orderBy: 'occurred_at',
            limit: limit,
            offset: offset,
          ),
        );
        return <Transaction>[for (final StoredRow row in rows) _txnFrom(row)];
      });

  @override
  Stream<int> watchUncategorizedCount() => _watch(
        () => _store.count(
          LedgerCollections.transactions,
          StoreQuery(
            conditions: <StoreCondition>[
              const StoreCondition.eq('category_path', CategoryResult.uncategorizedPath),
              StoreCondition('status', StoreOp.ne, TxnStatus.voided.wire),
            ],
          ),
        ),
        0,
      );

  // --- rollups ------------------------------------------------------------

  @override
  Future<Result<Money>> totalSpend({required DateTime from, required DateTime to}) =>
      _guard(() async => Money.sum(
            <Money>[
              for (final Transaction t in await _spendRows(from: from, to: to))
                t.amount.abs,
            ],
          ));

  @override
  Future<Result<Money>> totalIncome({required DateTime from, required DateTime to}) =>
      _guard(() async {
        final List<Transaction> rows = await _rangeRows(
          from: from,
          to: to,
          countsColumn: 'counts_income',
        );
        return Money.sum(<Money>[for (final Transaction t in rows) t.amount.abs]);
      });

  @override
  Future<Result<List<SpendBucket>>> spendByCategory({
    required DateTime from,
    required DateTime to,
  }) =>
      _guard(() async {
        final Map<String, _Bucket> byPath = <String, _Bucket>{};
        for (final Transaction t in await _spendRows(from: from, to: to)) {
          byPath
              .putIfAbsent(t.categoryPath, () => _Bucket(t.kind))
              .add(t.amount.abs.paise);
        }
        return _sorted(byPath);
      });

  @override
  Future<Result<List<SpendBucket>>> spendByMerchant({
    required DateTime from,
    required DateTime to,
    int limit = 20,
  }) =>
      _guard(() async {
        final Map<String, _Bucket> byMerchant = <String, _Bucket>{};
        for (final Transaction t in await _spendRows(from: from, to: to)) {
          final String key = t.merchantName ?? t.merchantRaw ?? 'Unknown';
          byMerchant
              .putIfAbsent(key, () => _Bucket(t.kind))
              .add(t.amount.abs.paise);
        }
        final List<SpendBucket> all = _sorted(byMerchant);
        return all.length <= limit ? all : all.sublist(0, limit);
      });

  @override
  Future<Result<List<SpendBucket>>> monthlySpend({
    required DateTime from,
    required DateTime to,
  }) =>
      _guard(() async {
        final Map<String, _Bucket> byMonth = <String, _Bucket>{};
        for (final Transaction t in await _spendRows(from: from, to: to)) {
          // bookingDate is already the LOCAL calendar day, so the month key is
          // a substring and never a timezone conversion.
          final String key = t.bookingDate.length >= 7
              ? t.bookingDate.substring(0, 7)
              : t.bookingDate;
          byMonth.putIfAbsent(key, () => _Bucket(t.kind)).add(t.amount.abs.paise);
        }
        final List<SpendBucket> out = _sorted(byMonth)
          ..sort((SpendBucket a, SpendBucket b) => a.key.compareTo(b.key));
        return out;
      });

  @override
  Stream<Money> watchTotalSpend({required DateTime from, required DateTime to}) =>
      _watch(
        () async => Money.sum(
          <Money>[
            for (final Transaction t in await _spendRows(from: from, to: to))
              t.amount.abs,
          ],
        ),
        Money.zero,
      );

  /// Exactly the rows `Transaction.countsAsSpend` accepts.
  ///
  /// The column is written at insert time, and the predicate is re-checked
  /// here on the way out, so a stale column can only ever make the query read
  /// more rows than needed - never fewer, and never wrong.
  Future<List<Transaction>> _spendRows({
    required DateTime from,
    required DateTime to,
  }) =>
      _rangeRows(from: from, to: to, countsColumn: 'counts_spend');

  Future<List<Transaction>> _rangeRows({
    required DateTime from,
    required DateTime to,
    required String countsColumn,
  }) async {
    final List<StoredRow> rows = await _store.query(
      LedgerCollections.transactions,
      StoreQuery(
        conditions: <StoreCondition>[
          StoreCondition('booking_date', StoreOp.gte, jDateKey(from.toLocal())),
          StoreCondition('booking_date', StoreOp.lte, jDateKey(to.toLocal())),
          StoreCondition('occurred_at', StoreOp.gte, jMillis(from)),
          StoreCondition('occurred_at', StoreOp.lt, jMillis(to)),
          StoreCondition.eq(countsColumn, 1),
        ],
        orderBy: 'booking_date',
      ),
    );
    final bool spend = countsColumn == 'counts_spend';
    final List<Transaction> out = <Transaction>[];
    for (final StoredRow row in rows) {
      final Transaction txn = _txnFrom(row);
      if (spend ? txn.countsAsSpend : txn.countsAsIncome) out.add(txn);
    }
    return out;
  }

  List<SpendBucket> _sorted(Map<String, _Bucket> buckets) {
    final List<SpendBucket> out = <SpendBucket>[
      for (final MapEntry<String, _Bucket> e in buckets.entries)
        SpendBucket(
          key: e.key,
          total: Money(e.value.totalPaise),
          count: e.value.count,
          kind: e.value.kind,
        ),
    ]..sort((SpendBucket a, SpendBucket b) => b.total.paise.compareTo(a.total.paise));
    return out;
  }

  // --- accounts -----------------------------------------------------------

  @override
  Future<Result<List<Account>>> accounts({bool includeArchived = false}) =>
      _guard(() => _readAccounts(includeArchived: includeArchived));

  @override
  Stream<List<Account>> watchAccounts({bool includeArchived = false}) => _watch(
        () => _readAccounts(includeArchived: includeArchived),
        const <Account>[],
      );

  Future<List<Account>> _readAccounts({required bool includeArchived}) async {
    final List<StoredRow> rows = await _store.query(
      LedgerCollections.accounts,
      StoreQuery(
        conditions: <StoreCondition>[
          if (!includeArchived) const StoreCondition.eq('is_archived', 0),
        ],
        orderBy: 'sort_order',
      ),
    );
    return <Account>[for (final StoredRow row in rows) Account.fromJson(row.doc)];
  }

  @override
  Future<Result<Account>> upsertAccount(Account account) => _guard(() async {
        final Account stored = account.id.isEmpty
            ? account.copyWith(id: LedgerIds.generate(now: _now))
            : account;
        await _store.put(LedgerCollections.accounts, _accountRow(stored));
        _notify();
        return stored;
      });

  @override
  Future<Result<Account?>> accountByTail(String? tail, {AccountType? type}) =>
      _guard(() => _accountByTail(Account.normalizeTail(tail), type: type));

  Future<Account?> _accountByTail(String? normalizedTail, {AccountType? type}) async {
    // An empty tail would match every account, which is how a message about
    // someone else's bank ends up attached to the user's salary account.
    if (normalizedTail == null || normalizedTail.isEmpty) return null;
    final List<StoredRow> rows = await _store.query(
      LedgerCollections.accounts,
      StoreQuery(
        conditions: <StoreCondition>[
          StoreCondition.eq('tail', normalizedTail),
          if (type != null) StoreCondition.eq('type', type.wire),
        ],
        orderBy: 'sort_order',
      ),
    );
    if (rows.isEmpty) return null;
    return Account.fromJson(rows.first.doc);
  }

  Future<Account?> _accountById(String id) async {
    final StoredRow? row = await _store.get(LedgerCollections.accounts, id);
    return row == null ? null : Account.fromJson(row.doc);
  }

  @override
  Future<Result<void>> deleteAccount(String id) => _guard(() async {
        await _store.delete(LedgerCollections.accounts, id);
        _notify();
      });

  // --- bills --------------------------------------------------------------

  @override
  Future<Result<List<Bill>>> bills({
    Set<BillStatus>? statuses,
    DateTime? dueBefore,
    int limit = 100,
  }) =>
      _guard(() => _readBills(statuses: statuses, dueBefore: dueBefore, limit: limit));

  @override
  Stream<List<Bill>> watchBills({Set<BillStatus>? statuses}) =>
      _watch(() => _readBills(statuses: statuses), const <Bill>[]);

  Future<List<Bill>> _readBills({
    Set<BillStatus>? statuses,
    DateTime? dueBefore,
    int limit = 100,
  }) async {
    final List<StoredRow> rows = await _store.query(
      LedgerCollections.bills,
      StoreQuery(
        conditions: <StoreCondition>[
          if (statuses != null && statuses.isNotEmpty)
            StoreCondition(
              'status',
              StoreOp.isIn,
              <String>[for (final BillStatus s in statuses) s.wire],
            ),
          if (dueBefore != null)
            StoreCondition('due_date', StoreOp.lt, jMillis(dueBefore)),
        ],
        orderBy: 'due_date',
        limit: limit,
      ),
    );
    return <Bill>[for (final StoredRow row in rows) Bill.fromJson(row.doc)];
  }

  @override
  Future<Result<Bill>> upsertBill(Bill bill) =>
      _guard(() => _store.transaction(() async {
            final DateTime now = _now;
            final String cycleKey = Fingerprints.billCycle(
              billerKey: bill.merchantName ?? bill.issuer ?? bill.name,
              consumerRef: bill.cardTail ?? bill.accountTail,
              accountTail: bill.accountTail,
              cycleDate: bill.dueDate,
            );
            // A reminder is re-sent three to five times for one bill. They all
            // have to land on the same row, or the user gets four cards for
            // one electricity bill.
            final List<StoredRow> sameCycle = await _store.query(
              LedgerCollections.bills,
              StoreQuery(
                conditions: <StoreCondition>[StoreCondition.eq('cycle_key', cycleKey)],
                limit: 1,
              ),
            );
            String id = bill.id.isEmpty ? LedgerIds.generate(now: now) : bill.id;
            Bill merged = bill;
            if (sameCycle.isNotEmpty) {
              final Bill existing = Bill.fromJson(sameCycle.first.doc);
              id = existing.id;
              merged = existing.copyWith(
                name: bill.name,
                dueDate: bill.dueDate,
                amountDue: bill.amountDue,
                minimumDue: bill.minimumDue,
                status: bill.status,
                accountId: bill.accountId,
                accountTail: bill.accountTail,
                cardTail: bill.cardTail,
                merchantName: bill.merchantName,
                categoryPath: bill.categoryPath,
                issuer: bill.issuer,
                sourceMessageId: bill.sourceMessageId,
                isRecurring: bill.isRecurring,
              );
            }
            final int paid = await _paidPaiseFor(id);
            final Bill stored = merged.copyWith(
              id: id,
              status: BillLifecycle.statusFor(merged, paidPaise: paid, now: now),
              updatedAt: now,
            );
            await _store.put(
              LedgerCollections.bills,
              _billRow(stored, paidPaise: paid, cycleKey: cycleKey),
            );
            _notify();
            return stored;
          }));

  @override
  Future<Result<void>> markBillPaid({required String billId, required String txnId}) =>
      _guard(() => _store.transaction(() async {
            final StoredRow? billRow = await _store.get(LedgerCollections.bills, billId);
            final StoredRow? txnRow =
                await _store.get(LedgerCollections.transactions, txnId);
            if (billRow == null || txnRow == null) {
              throw _NotFound('Both the bill and the transaction must exist.');
            }
            final Bill bill = Bill.fromJson(billRow.doc);
            final Transaction txn = _txnFrom(txnRow);
            final int already = await _paidPaiseFor(billId);
            final int due = bill.amountDue?.abs.paise ?? txn.amount.abs.paise;
            final int remaining = due - already;
            await _applyBillPayment(
              BillMatch(
                bill: bill,
                txn: txn,
                score: 1,
                tag: BillMatchTag.full,
                appliedPaise: remaining > 0 && remaining < txn.amount.abs.paise
                    ? remaining
                    : txn.amount.abs.paise,
                reason: 'You linked this payment',
              ),
              byUser: true,
            );
            _notify();
          }));

  @override
  Future<Result<void>> deleteBill(String id) =>
      _guard(() => _store.transaction(() async {
            await _store.delete(LedgerCollections.bills, id);
            await _store.deleteWhere(
              LedgerCollections.billPayments,
              StoreQuery(
                conditions: <StoreCondition>[StoreCondition.eq('bill_id', id)],
              ),
            );
            _notify();
          }));

  /// Re-derives the status of every bill this transaction touches. Called
  /// after an edit, because changing an amount can turn a full payment into a
  /// partial one.
  Future<void> _refreshBillsFor(Transaction txn) async {
    final String? billId = txn.billId;
    if (billId == null) return;
    final StoredRow? row = await _store.get(LedgerCollections.bills, billId);
    if (row == null) return;
    final Bill bill = Bill.fromJson(row.doc);
    final int paid = await _paidPaiseFor(billId);
    final DateTime now = _now;
    await _store.put(
      LedgerCollections.bills,
      _billRow(
        bill.copyWith(
          status: BillLifecycle.statusFor(bill, paidPaise: paid, now: now),
          updatedAt: now,
        ),
        paidPaise: paid,
      ),
    );
  }

  /// Every payment applied to [billId], newest first.
  Future<Result<List<BillPayment>>> billPayments(String billId) => _guard(() async {
        final List<StoredRow> rows = await _store.query(
          LedgerCollections.billPayments,
          StoreQuery(
            conditions: <StoreCondition>[StoreCondition.eq('bill_id', billId)],
          ),
        );
        return <BillPayment>[
          for (final StoredRow row in rows) BillPayment.fromJson(row.doc),
        ];
      });

  /// How much of [billId] is still owed.
  Future<Result<Money>> billRemaining(String billId) => _guard(() async {
        final StoredRow? row = await _store.get(LedgerCollections.bills, billId);
        if (row == null) throw _NotFound('No bill $billId');
        return BillLifecycle.remaining(
          Bill.fromJson(row.doc),
          paidPaise: await _paidPaiseFor(billId),
        );
      });

  // --- user rules ---------------------------------------------------------

  @override
  Future<Result<List<UserRule>>> userRules({bool includeDisabled = false}) =>
      _guard(() => _readUserRules(includeDisabled: includeDisabled));

  @override
  Stream<List<UserRule>> watchUserRules() =>
      _watch(() => _readUserRules(includeDisabled: false), const <UserRule>[]);

  Future<List<UserRule>> _readUserRules({required bool includeDisabled}) async {
    final List<StoredRow> rows = await _store.query(
      LedgerCollections.userRules,
      StoreQuery(
        conditions: <StoreCondition>[
          if (!includeDisabled) const StoreCondition.eq('enabled', 1),
        ],
        orderBy: 'priority',
        descending: true,
      ),
    );
    return <UserRule>[for (final StoredRow row in rows) UserRule.fromJson(row.doc)];
  }

  @override
  Future<Result<UserRule>> upsertUserRule(UserRule rule) => _guard(() async {
        final UserRule stored = rule.id.isEmpty
            ? UserRule(
                id: LedgerIds.generate(now: _now),
                match: rule.match,
                pattern: rule.pattern,
                categoryPath: rule.categoryPath,
                kind: rule.kind,
                createdAt: rule.createdAt,
                merchantName: rule.merchantName,
                priority: rule.priority,
                enabled: rule.enabled,
                applyToExisting: rule.applyToExisting,
                updatedAt: _now,
                hitCount: rule.hitCount,
              )
            : rule;
        await _store.put(LedgerCollections.userRules, _userRuleRow(stored));
        _notify();
        return stored;
      });

  @override
  Future<Result<void>> deleteUserRule(String id) => _guard(() async {
        await _store.delete(LedgerCollections.userRules, id);
        _notify();
      });

  // --- postings, balances, reconciliation ---------------------------------

  /// The signed postings of one transaction. Two or more, always summing to
  /// zero.
  Future<Result<List<Posting>>> postingsFor(String txnId) => _guard(() async {
        final List<StoredRow> rows = await _store.query(
          LedgerCollections.postings,
          StoreQuery(
            conditions: <StoreCondition>[StoreCondition.eq('txn_id', txnId)],
          ),
        );
        return <Posting>[for (final StoredRow row in rows) Posting.fromJson(row.doc)];
      });

  /// The balance of an account as the ledger computes it, from postings.
  ///
  /// This is the number that gets compared against what the bank said. A
  /// disagreement is not an error state - it is the app noticing that it
  /// missed a message.
  Future<Result<Money>> computedBalance(String accountId, {DateTime? asOf}) =>
      _guard(() async {
        final List<Posting> postings = await _postingsForAccount(accountId, to: asOf);
        return PostingEngine.balanceOf(accountId, postings, asOf: asOf);
      });

  Future<List<Posting>> _postingsForAccount(
    String accountId, {
    DateTime? from,
    DateTime? to,
  }) async {
    final List<StoredRow> rows = await _store.query(
      LedgerCollections.postings,
      StoreQuery(
        conditions: <StoreCondition>[
          StoreCondition.eq('account_id', accountId),
          if (from != null) StoreCondition('occurred_at', StoreOp.gte, jMillis(from)),
          if (to != null) StoreCondition('occurred_at', StoreOp.lte, jMillis(to)),
        ],
        orderBy: 'occurred_at',
      ),
    );
    return <Posting>[for (final StoredRow row in rows) Posting.fromJson(row.doc)];
  }

  /// Stores a balance the bank stated. Never overwrites, never corrects the
  /// ledger by itself - it is evidence, not an instruction.
  Future<Result<BalanceAssertion>> recordBalanceAssertion({
    required String accountId,
    required AssertionKind kind,
    required Money stated,
    required DateTime asOf,
    int precedence = 1,
    bool trusted = true,
    String? txnId,
    String? rawMessageId,
  }) =>
      _guard(() async {
        final DateTime now = _now;
        final Account? account = await _accountById(accountId);
        final BalanceAssertion? assertion = ReconciliationEngine.normalize(
          // Deterministic, so the same SMS delivered to both SIMs stores one
          // assertion rather than two.
          id: LedgerIds.hashParts(<Object?>[
            accountId,
            kind.wire,
            stated.paise,
            jMillis(asOf),
          ]),
          accountId: accountId,
          kind: kind,
          statedPaise: stated.abs.paise,
          asOf: asOf,
          now: now,
          creditLimitPaise: account?.creditLimit?.paise,
          precedence: precedence,
          trusted: trusted,
          txnId: txnId,
          rawMessageId: rawMessageId,
        );
        if (assertion == null) {
          // A credit limit is configuration, not a balance. Store it where it
          // belongs and say so.
          if (account != null) {
            await _store.put(
              LedgerCollections.accounts,
              _accountRow(account.copyWith(creditLimit: stated.abs, updatedAt: now)),
            );
          }
          throw _Invalid('A credit limit is not a balance; it updates the account.');
        }
        await _store.put(
          LedgerCollections.balanceSnapshots,
          _assertionRow(assertion),
        );
        if (account != null && !assertion.basisUnknown) {
          await _store.put(
            LedgerCollections.accounts,
            _accountRow(
              account.copyWith(
                balance: Money(assertion.ledgerPaise),
                balanceAsOf: asOf,
                updatedAt: now,
              ),
            ),
          );
        }
        _notify();
        return assertion;
      });

  /// Compares every pair of balances the bank stated against the postings
  /// between them, and records the gaps.
  ///
  /// Returns the windows, including the clean ones, so the UI can say "we
  /// verified nine of the eleven months we read".
  Future<Result<List<ReconWindow>>> reconcileAccount(
    String accountId, {
    DateTime? from,
    DateTime? to,
  }) =>
      _guard(() => _store.transaction(() async {
            final DateTime now = _now;
            final List<StoredRow> rows = await _store.query(
              LedgerCollections.balanceSnapshots,
              StoreQuery(
                conditions: <StoreCondition>[
                  StoreCondition.eq('account_id', accountId),
                  if (from != null) StoreCondition('as_of', StoreOp.gte, jMillis(from)),
                  if (to != null) StoreCondition('as_of', StoreOp.lte, jMillis(to)),
                ],
                orderBy: 'as_of',
                thenBy: 'precedence',
              ),
            );
            final List<BalanceAssertion> assertions = <BalanceAssertion>[
              for (final StoredRow row in rows) BalanceAssertion.fromJson(row.doc),
            ];
            final List<Posting> postings = await _postingsForAccount(accountId);
            final List<ReconWindow> windows = ReconciliationEngine.reconcile(
              accountId: accountId,
              assertions: assertions,
              postings: postings,
            );

            final Account? account = await _accountById(accountId);
            final List<QuarantinedAmount> quarantined = await _quarantinedAmounts();
            for (final ReconWindow window in windows) {
              if (window.verdict != ReconVerdict.drift) continue;
              final DriftEvent event = ReconciliationEngine.eventFor(
                window,
                now: now,
                hypotheses: ReconciliationEngine.hypotheses(
                  window,
                  quarantined: quarantined,
                  expected: await _expectedCharges(accountId),
                  accountIsSavings: account?.type != AccountType.creditCard,
                ),
              );
              final StoredRow? existing =
                  await _store.get(LedgerCollections.driftEvents, event.id);
              if (existing != null &&
                  DriftEvent.fromJson(existing.doc).state != DriftState.open) {
                continue;
              }
              await _store.put(LedgerCollections.driftEvents, _driftRow(event));
            }
            _notify();
            return windows;
          }));

  /// The gaps the app has not explained yet.
  Future<Result<List<DriftEvent>>> driftEvents({
    String? accountId,
    bool onlyOpen = true,
  }) =>
      _guard(() async {
        final List<StoredRow> rows = await _store.query(
          LedgerCollections.driftEvents,
          StoreQuery(
            conditions: <StoreCondition>[
              if (accountId != null) StoreCondition.eq('account_id', accountId),
              if (onlyOpen) StoreCondition.eq('state', DriftState.open.wire),
            ],
            orderBy: 'window_start',
            descending: true,
          ),
        );
        return <DriftEvent>[
          for (final StoredRow row in rows) DriftEvent.fromJson(row.doc),
        ];
      });

  /// "Not sure - ignore." Posts the gap to the plug account, where it can
  /// never reach a category or a budget, and stays visible.
  ///
  /// This is the only write the app makes to force its own books to balance,
  /// it goes to equity, and it is reversible.
  Future<Result<Transaction>> plugDriftEvent(String eventId) =>
      _guard(() => _store.transaction(() async {
            final StoredRow? row =
                await _store.get(LedgerCollections.driftEvents, eventId);
            if (row == null) throw _NotFound('No drift event $eventId');
            final DriftEvent event = DriftEvent.fromJson(row.doc);
            final DateTime now = _now;
            final int paise = event.driftPaise;
            final String txnId = LedgerIds.generate(now: now);
            final Transaction adjustment = Transaction(
              id: txnId,
              amount: Money(paise.abs()),
              direction: paise < 0 ? TxnDirection.debit : TxnDirection.credit,
              occurredAt: event.windowEnd,
              bookingDate: jDateKey(event.windowEnd.toLocal()),
              kind: CategoryKind.transfer,
              categoryPath: TransferPaths.selfTransfer,
              createdAt: now,
              updatedAt: now,
              status: TxnStatus.posted,
              source: TxnSource.derived,
              accountId: event.accountId,
              note: 'Unexplained difference against your bank',
              confidence: 0,
              categorySource: CategorySource.unknown,
              categoryExplanation:
                  'We could not explain this difference, so it is parked here '
                  'rather than counted as spending.',
              isExcludedFromTotals: true,
            );
            await _store.put(LedgerCollections.transactions, _txnRow(adjustment));
            // Written by hand rather than through the posting engine: the plug
            // must land on EQUITY, which no category path maps to.
            await _store.putAll(LedgerCollections.postings, <StoredRow>[
              _postingRow(
                Posting(
                  id: '$txnId:0',
                  txnId: txnId,
                  accountId: event.accountId,
                  accountClass: AccountClass.asset,
                  amountPaise: paise,
                  occurredAt: event.windowEnd,
                  bookingDate: adjustment.bookingDate,
                ),
              ),
              _postingRow(
                Posting(
                  id: '$txnId:1',
                  txnId: txnId,
                  accountId: LedgerAccounts.unreconciled,
                  accountClass: AccountClass.equity,
                  amountPaise: -paise,
                  occurredAt: event.windowEnd,
                  bookingDate: adjustment.bookingDate,
                  leg: PostingLeg.dest,
                ),
              ),
            ]);
            await _store.put(
              LedgerCollections.driftEvents,
              _driftRow(
                event.copyWith(
                  state: DriftState.resolvedPlug,
                  resolvedTxnId: txnId,
                  resolvedAt: now,
                ),
              ),
            );
            _notify();
            return adjustment;
          }));

  /// Marks a gap explained by a transaction the user added or confirmed.
  Future<Result<void>> resolveDriftEvent(String eventId, {String? txnId}) =>
      _guard(() => _store.transaction(() async {
            final StoredRow? row =
                await _store.get(LedgerCollections.driftEvents, eventId);
            if (row == null) throw _NotFound('No drift event $eventId');
            final DriftEvent event = DriftEvent.fromJson(row.doc);
            await _store.put(
              LedgerCollections.driftEvents,
              _driftRow(
                event.copyWith(
                  state: txnId == null ? DriftState.ignored : DriftState.resolvedTxn,
                  resolvedTxnId: txnId,
                  resolvedAt: _now,
                ),
              ),
            );
            _notify();
          }));

  /// Records a message the parser could not read, with whatever amount could
  /// be salvaged from it.
  ///
  /// This is what turns the parser's long tail into something measurable: when
  /// a balance gap matches one of these exactly, the app can say "we got a
  /// message we could not read, and it was this much".
  Future<Result<void>> quarantineMessage({
    required String rawMessageId,
    required String reason,
    Money? amount,
    DateTime? receivedAt,
  }) =>
      _guard(() async {
        final DateTime when = receivedAt ?? _now;
        await _store.put(
          LedgerCollections.quarantinedMessages,
          StoredRow(
            id: rawMessageId,
            index: <String, Object?>{
              'raw_message_id': rawMessageId,
              'received_at': jMillis(when),
              'amount_paise': amount?.abs.paise,
              'reason': reason,
              'resolved': 0,
            },
            doc: <String, dynamic>{
              'rawMessageId': rawMessageId,
              'reason': reason,
              'amountPaise': amount?.abs.paise,
              'receivedAt': jMillis(when),
            },
          ),
        );
        _notify();
      });

  Future<List<QuarantinedAmount>> _quarantinedAmounts() async {
    final List<StoredRow> rows = await _store.query(
      LedgerCollections.quarantinedMessages,
      StoreQuery(
        conditions: <StoreCondition>[
          const StoreCondition.eq('resolved', 0),
          const StoreCondition('amount_paise', StoreOp.isNotNull),
        ],
      ),
    );
    return <QuarantinedAmount>[
      for (final StoredRow row in rows)
        QuarantinedAmount(
          rawMessageId: jString(row.doc['rawMessageId']),
          amountPaise: jInt(row.doc['amountPaise']),
          receivedAt: jDate(row.doc['receivedAt']),
        ),
    ];
  }

  Future<List<ExpectedCharge>> _expectedCharges(String accountId) async {
    final List<StoredRow> rows = await _store.query(
      LedgerCollections.recurringSeries,
      StoreQuery(
        conditions: <StoreCondition>[StoreCondition.eq('account_id', accountId)],
      ),
    );
    final List<ExpectedCharge> out = <ExpectedCharge>[];
    for (final StoredRow row in rows) {
      final RecurringSeries series = RecurringSeries.fromJson(row.doc);
      final DateTime? next = series.nextExpected;
      if (next == null) continue;
      out.add(
        ExpectedCharge(
          seriesId: series.id,
          label: series.label,
          amountPaise: series.amountCenterPaise,
          expectedAt: next,
          tolerancePaise: series.amountMadPaise * 2,
          categoryPath: series.categoryPath,
        ),
      );
    }
    return out;
  }

  // --- recurring ----------------------------------------------------------

  /// Re-derives every recurring series from the user's own history and stores
  /// the result.
  Future<Result<List<RecurringSeries>>> refreshRecurringSeries({
    Set<String> knownBillerMerchants = const <String>{},
  }) =>
      _guard(() => _store.transaction(() async {
            final DateTime now = _now;
            final List<StoredRow> rows = await _store.query(
              LedgerCollections.transactions,
              StoreQuery(
                conditions: <StoreCondition>[
                  StoreCondition(
                    'booking_date',
                    StoreOp.gte,
                    jDateKey(
                      now
                          .subtract(const Duration(days: RecurringDetector.historyDays))
                          .toLocal(),
                    ),
                  ),
                  const StoreCondition.eq('is_excluded', 0),
                ],
                orderBy: 'booking_date',
              ),
            );
            final List<RecurringSeries> detected = RecurringDetector.detect(
              <Transaction>[for (final StoredRow row in rows) _txnFrom(row)],
              now: now,
              knownBillerMerchants: knownBillerMerchants,
            );
            for (final RecurringSeries series in detected) {
              final StoredRow? existing =
                  await _store.get(LedgerCollections.recurringSeries, series.id);
              // A series the user confirmed keeps its confirmation, and a
              // mandate-created series is never downgraded by inference.
              final bool confirmed = existing != null &&
                  RecurringSeries.fromJson(existing.doc).userConfirmed;
              await _store.put(
                LedgerCollections.recurringSeries,
                _seriesRow(series.copyWith(userConfirmed: confirmed ? true : null)),
              );
            }
            _notify();
            return detected;
          }));

  Future<Result<List<RecurringSeries>>> recurringSeries({
    Set<SeriesState>? states,
  }) =>
      _guard(() async {
        final List<StoredRow> rows = await _store.query(
          LedgerCollections.recurringSeries,
          StoreQuery(
            conditions: <StoreCondition>[
              if (states != null && states.isNotEmpty)
                StoreCondition(
                  'state',
                  StoreOp.isIn,
                  <String>[for (final SeriesState s in states) s.wire],
                ),
            ],
            orderBy: 'next_expected',
          ),
        );
        return <RecurringSeries>[
          for (final StoredRow row in rows) RecurringSeries.fromJson(row.doc),
        ];
      });

  /// Creates a confirmed series from a mandate or pre-debit notice, which is
  /// ground truth about the future and needs no history at all.
  Future<Result<RecurringSeries>> upsertSeries(RecurringSeries series) =>
      _guard(() async {
        await _store.put(LedgerCollections.recurringSeries, _seriesRow(series));
        _notify();
        return series;
      });

  // --- export / import / wipe ---------------------------------------------

  @override
  Future<Result<Map<String, dynamic>>> exportAll() => _guard(() async {
        final Map<String, dynamic> collections = <String, dynamic>{};
        for (final String name in LedgerCollections.exportable) {
          final List<StoredRow> rows = await _store.query(name);
          collections[name] = <Map<String, dynamic>>[
            for (final StoredRow row in rows)
              if (name == LedgerCollections.rawMessages)
                _redactBody(row.doc)
              else
                row.doc,
          ];
        }
        return <String, dynamic>{
          'format': exportFormat,
          'schemaVersion': LedgerSchema.version,
          'exportedAt': jMillis(_now),
          // Stated in the document itself so a restore cannot be surprised:
          // the backup carries every transaction, and no message text.
          'containsMessageBodies': false,
          'collections': collections,
        };
      });

  @override
  Future<Result<void>> importAll(Map<String, dynamic> document) =>
      _guard(() async {
        if (jString(document['format']) != exportFormat) {
          throw _Invalid('This file was not produced by this app.');
        }
        final Object? raw = document['collections'];
        if (raw is! Map) {
          throw _Invalid('The backup has no collections to restore.');
        }
        final Map<String, dynamic> collections = jMap(raw);
        for (final String name in collections.keys) {
          if (LedgerSchema.collection(name) == null) {
            throw _Invalid('The backup contains an unknown section "$name".');
          }
        }
        // Validated fully BEFORE anything is touched, so a bad file leaves the
        // existing ledger exactly as it was.
        await _store.transaction(() async {
          await _store.wipe();
          for (final String name in LedgerCollections.exportable) {
            final List<Map<String, dynamic>> docs = jMapList(collections[name]);
            if (docs.isEmpty) continue;
            await _store.putAll(
              name,
              <StoredRow>[for (final Map<String, dynamic> doc in docs) _rowFor(name, doc)],
            );
          }
          await _putMeta(LedgerMetaKeys.schemaVersion, LedgerSchema.version);
        });
        _notify();
      });

  @override
  Future<Result<void>> wipe() => _guard(() async {
        await _store.wipe();
        await _putMeta(LedgerMetaKeys.schemaVersion, LedgerSchema.version);
        await _seedSystemAccounts(_now);
        _notify();
      });

  /// Identifies a backup as ours. A file without it is refused rather than
  /// half-applied.
  static const String exportFormat = 'money-ledger/export/1';

  Map<String, dynamic> _redactBody(Map<String, dynamic> doc) {
    final Map<String, dynamic> copy = Map<String, dynamic>.of(doc);
    // A backup goes to a file the user picks, which may well be a cloud
    // folder. Transactions restore perfectly without the message text, so the
    // text does not travel.
    copy['body'] = '';
    return copy;
  }

  StoredRow _rowFor(String collection, Map<String, dynamic> doc) {
    switch (collection) {
      case LedgerCollections.accounts:
        return _accountRow(Account.fromJson(doc));
      case LedgerCollections.transactions:
        return _txnRow(Transaction.fromJson(doc));
      case LedgerCollections.postings:
        return _postingRow(Posting.fromJson(doc));
      case LedgerCollections.rawMessages:
        return _rawRow(RawMessage.fromJson(doc));
      case LedgerCollections.userRules:
        return _userRuleRow(UserRule.fromJson(doc));
      case LedgerCollections.bills:
        return _billRow(Bill.fromJson(doc), paidPaise: jInt(doc['amountPaidPaise']));
      case LedgerCollections.billPayments:
        return _billPaymentRow(BillPayment.fromJson(doc));
      case LedgerCollections.recurringSeries:
        return _seriesRow(RecurringSeries.fromJson(doc));
      case LedgerCollections.balanceSnapshots:
        return _assertionRow(BalanceAssertion.fromJson(doc));
      case LedgerCollections.driftEvents:
        return _driftRow(DriftEvent.fromJson(doc));
      default:
        return StoredRow(
          id: jString(doc['id'], fallback: LedgerIds.generate()),
          index: const <String, Object?>{},
          doc: doc,
        );
    }
  }

  Future<void> _putMeta(String key, Object value) => _store.put(
        LedgerCollections.meta,
        StoredRow(
          id: key,
          index: const <String, Object?>{},
          doc: <String, dynamic>{'value': value},
        ),
      );

  // --- row mapping --------------------------------------------------------

  StoredRow _txnRow(Transaction txn) {
    final StringBuffer search = StringBuffer()
      ..write(txn.merchantName ?? '')
      ..write(' ')
      ..write(txn.merchantRaw ?? '')
      ..write(' ')
      ..write(txn.note ?? '')
      ..write(' ')
      ..write(txn.ref ?? '')
      ..write(' ')
      ..write(txn.vpa ?? '');
    return StoredRow(
      id: txn.id,
      index: <String, Object?>{
        'occurred_at': jMillis(txn.occurredAt),
        'booking_date': txn.bookingDate,
        'status': txn.status.wire,
        'kind': txn.kind.wire,
        'direction': txn.direction.wire,
        'channel': txn.channel.wire,
        'category_path': txn.categoryPath,
        'account_id': txn.accountId,
        'account_tail': Account.normalizeTail(txn.accountTail),
        'card_tail': Account.normalizeTail(txn.cardTail),
        'merchant_name': txn.merchantName,
        'ref': txn.ref,
        'amount_paise': txn.amount.abs.paise,
        // Denormalised so a spend total is an index range scan and never has
        // to evaluate four columns per row.
        'counts_spend': txn.countsAsSpend ? 1 : 0,
        'counts_income': txn.countsAsIncome ? 1 : 0,
        'is_excluded': txn.isExcludedFromTotals ? 1 : 0,
        'transfer_group_id': txn.transferGroupId,
        'reversal_of_id': txn.reversalOfId,
        'bill_id': txn.billId,
        'series_id': null,
        'raw_message_id': txn.rawMessageId,
        'fingerprint': Fingerprints.transaction(txn),
        'search': search.toString().toLowerCase().trim(),
      },
      doc: txn.toJson(),
    );
  }

  Transaction _txnFrom(StoredRow row) => Transaction.fromJson(row.doc);

  StoredRow _rawRow(RawMessage message) => StoredRow(
        id: message.id,
        index: <String, Object?>{
          'received_at': jMillis(message.receivedAt),
          'received_minute': Fingerprints.receivedMinute(message.receivedAt),
          'sender_header': message.senderHeader,
          'body_hash': message.bodyHash,
          'provider_id': message.providerId,
          'parse_state': message.parseState.wire,
          'parser_version': message.parserVersion,
          'txn_id': message.txnId,
          'has_body': message.body.isEmpty ? 0 : 1,
        },
        doc: message.toJson(),
      );

  StoredRow _postingRow(Posting posting) => StoredRow(
        id: posting.id,
        index: <String, Object?>{
          'txn_id': posting.txnId,
          'account_id': posting.accountId,
          'account_class': posting.accountClass.wire,
          'amount_paise': posting.amountPaise,
          'occurred_at': jMillis(posting.occurredAt),
          'booking_date': posting.bookingDate,
          'leg': posting.leg.wire,
        },
        doc: posting.toJson(),
      );

  StoredRow _accountRow(Account account) => StoredRow(
        id: account.id,
        index: <String, Object?>{
          'type': account.type.wire,
          'tail': Account.normalizeTail(account.tail),
          'institution_id': account.institutionId,
          'is_archived': account.isArchived ? 1 : 0,
          'is_tracked': account.isTracked ? 1 : 0,
          'sort_order': account.sortOrder,
        },
        doc: account.toJson(),
      );

  StoredRow _userRuleRow(UserRule rule) => StoredRow(
        id: rule.id,
        index: <String, Object?>{
          'enabled': rule.enabled ? 1 : 0,
          'priority': rule.priority,
          'match_kind': rule.match.wire,
          'pattern': rule.pattern,
        },
        doc: rule.toJson(),
      );

  StoredRow _billRow(Bill bill, {required int paidPaise, String? cycleKey}) {
    final Map<String, dynamic> doc = bill.toJson();
    // Derived, and stored alongside the model so a restore does not have to
    // re-run the matcher to know what is still owed.
    doc['amountPaidPaise'] = paidPaise;
    return StoredRow(
      id: bill.id,
      index: <String, Object?>{
        'status': bill.status.wire,
        'due_date': jMillis(bill.dueDate),
        'account_id': bill.accountId,
        'account_tail': Account.normalizeTail(bill.accountTail),
        'card_tail': Account.normalizeTail(bill.cardTail),
        'merchant_name': bill.merchantName,
        'cycle_key': cycleKey ??
            Fingerprints.billCycle(
              billerKey: bill.merchantName ?? bill.issuer ?? bill.name,
              consumerRef: bill.cardTail ?? bill.accountTail,
              accountTail: bill.accountTail,
              cycleDate: bill.dueDate,
            ),
        'paid_txn_id': bill.paidTxnId,
        'amount_due_paise': bill.amountDue?.abs.paise,
        'amount_paid_paise': paidPaise,
      },
      doc: doc,
    );
  }

  StoredRow _billPaymentRow(BillPayment payment) => StoredRow(
        id: payment.id,
        index: <String, Object?>{
          'bill_id': payment.billId,
          'txn_id': payment.txnId,
          'applied_paise': payment.appliedPaise,
          'confidence': (payment.confidence * 100).round(),
        },
        doc: payment.toJson(),
      );

  StoredRow _seriesRow(RecurringSeries series) => StoredRow(
        id: series.id,
        index: <String, Object?>{
          'group_key': series.groupKey,
          'account_id': series.accountId,
          'merchant_name': series.merchantName,
          'state': series.state.wire,
          'next_expected':
              series.nextExpected == null ? null : jMillis(series.nextExpected!),
        },
        doc: series.toJson(),
      );

  StoredRow _assertionRow(BalanceAssertion assertion) => StoredRow(
        id: assertion.id,
        index: <String, Object?>{
          'account_id': assertion.accountId,
          'as_of': jMillis(assertion.asOf),
          'precedence': assertion.precedence,
          'kind': assertion.kind.wire,
          'stated_paise': assertion.statedPaise,
          'ledger_paise': assertion.ledgerPaise,
          'trusted': assertion.trusted ? 1 : 0,
          'txn_id': assertion.txnId,
          'raw_message_id': assertion.rawMessageId,
        },
        doc: assertion.toJson(),
      );

  StoredRow _driftRow(DriftEvent event) => StoredRow(
        id: event.id,
        index: <String, Object?>{
          'account_id': event.accountId,
          'state': event.state.wire,
          'window_start': jMillis(event.windowStart),
          'window_end': jMillis(event.windowEnd),
          'drift_paise': event.driftPaise,
          'window_key': event.windowKey,
        },
        doc: event.toJson(),
      );

  // --- plumbing -----------------------------------------------------------

  void _notify() {
    if (!_changes.isClosed) _changes.add(null);
  }

  /// Emits once on listen, then on every change. Never emits an error: a
  /// stream that can fail would make every screen that watches it need error
  /// handling for a database that is already open.
  Stream<T> _watch<T>(Future<T> Function() read, T fallback) {
    late StreamController<T> controller;
    StreamSubscription<void>? subscription;
    T last = fallback;
    Future<void> emit() async {
      try {
        last = await read();
      } catch (_) {
        // Keep the previous value rather than tearing down the screen.
      }
      if (!controller.isClosed) controller.add(last);
    }

    controller = StreamController<T>(
      onListen: () {
        subscription = _changes.stream.listen((_) => emit());
        emit();
      },
      onCancel: () async {
        await subscription?.cancel();
        subscription = null;
      },
    );
    return controller.stream;
  }

  Future<Result<T>> _guard<T>(Future<T> Function() body) async {
    try {
      return Ok<T>(await body());
    } on _Invalid catch (e) {
      return Err<T>(AppError.invalidArgument(e.message));
    } on _NotFound catch (e) {
      return Err<T>(AppError.notFound(e.message));
    } catch (e, stack) {
      return Err<T>(
        AppError(
          ErrorCodes.database,
          // Never interpolates a row's contents: an error message must not
          // become a place where SMS text leaks into a log.
          'The local database could not complete the operation.',
          cause: e,
          stackTrace: stack,
        ),
      );
    }
  }
}

class _Bucket {
  _Bucket(this.kind);

  final CategoryKind kind;
  int totalPaise = 0;
  int count = 0;

  void add(int paise) {
    totalPaise += paise;
    count++;
  }
}

class _Invalid implements Exception {
  _Invalid(this.message);

  final String message;

  @override
  String toString() => message;
}

class _NotFound implements Exception {
  _NotFound(this.message);

  final String message;

  @override
  String toString() => message;
}
