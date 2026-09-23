/// The spine: one message in, one decision out.
///
/// Every message the app ever sees - the live broadcast receiver, the
/// first-run inbox backfill, a later catch-up scan - goes through
/// [IngestPipeline.ingestOne]. There is exactly one implementation of "what
/// happens to an SMS", so the live path and the backfill path cannot drift
/// apart and quietly produce different ledgers from the same inbox.
///
/// The stages, in order:
///
///   persist raw  ->  parse (trust gate lives inside the parser)
///                ->  dedup (one money event, however many SMS reported it)
///                ->  categorise
///                ->  post transaction / upsert bill
///                ->  record what happened to the message
///
/// Three properties this file exists to guarantee:
///
/// * **Nothing is invented.** An ambiguous parse is quarantined and shown to
///   the user, never booked at a guessed amount.
/// * **Nothing is booked twice.** Message-level duplication is the
///   repository's `saveRawMessage`; event-level duplication (the bank's alert
///   and the UPI app's alert about one payment) is [DedupIndex]; and
///   `postTransaction` has its own fingerprint as the last line of defence.
/// * **Nothing leaves the device.** There is no network client in this file's
///   imports and there never may be. `RawMessage.body` is passed to the
///   categoriser for matching and is never logged, never copied into an
///   error, and never attached to an outcome.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../categorize/cascade_categorizer.dart';
import '../contracts/contracts.dart';
import '../core/result.dart';
import '../data/ledger_repository_impl.dart';
import '../models/models.dart';
import '../parser/dedup.dart';

/// What the pipeline did with one message.
enum IngestDisposition {
  /// A transaction was written.
  posted('posted'),

  /// A bill reminder was recorded. Deliberately not a transaction: booking
  /// the reminder and then the real debit is how an EMI gets counted twice.
  billRecorded('bill_recorded'),

  /// This exact message was already in the database.
  duplicateMessage('duplicate_message'),

  /// A different message about money already booked - the bank's alert and
  /// the UPI app's alert about one payment.
  duplicateEvent('duplicate_event'),

  /// An OTP, a promo, a failed payment, a balance alert, a pre-debit notice.
  rejected('rejected'),

  /// A message from a registered sender that no rule matched. Kept, so a
  /// later rules pack can re-parse it.
  noRuleMatched('no_rule_matched'),

  /// The sender did not normalise to a financial header.
  untrustedSender('untrusted_sender'),

  /// Parsed, but the fields contradict each other or the amount could not be
  /// read with confidence. Held for the user rather than guessed.
  quarantined('quarantined'),

  /// The database refused the write. The message is kept and can be retried.
  failed('failed');

  const IngestDisposition(this.wire);

  final String wire;

  /// True when this message produced something the user can see in the ledger.
  bool get createdEntry =>
      this == IngestDisposition.posted || this == IngestDisposition.billRecorded;
}

/// One message's journey, with no message text in it.
@immutable
class IngestOutcome {
  const IngestOutcome({
    required this.rawMessageId,
    required this.disposition,
    this.transactionId,
    this.billId,
    this.linkedToId,
    this.needsReview = false,
    this.ruleId,
    this.reason = '',
    this.occurredAt,
    this.error,
  });

  /// The id the repository stored this message under, which is the existing
  /// row's id when it turned out to be a duplicate.
  final String rawMessageId;

  final IngestDisposition disposition;
  final String? transactionId;
  final String? billId;

  /// The transaction this one was merged into, reverses, or pairs with.
  final String? linkedToId;

  /// True when the transaction landed in the Uncategorized queue or the parse
  /// confidence was low enough to want a human.
  final bool needsReview;

  final String? ruleId;

  /// A short, content-free note. Never contains message text.
  final String reason;

  /// When the money actually moved, for the "covers March to September" line.
  /// Null when this message produced no ledger entry.
  final DateTime? occurredAt;

  final AppError? error;

  bool get isPosted => disposition == IngestDisposition.posted;
}

/// Running totals for a batch. Every number here is a real count of real work,
/// which is what lets the import screen show honest progress.
@immutable
class IngestReport {
  const IngestReport({
    this.scanned = 0,
    this.candidates = 0,
    this.posted = 0,
    this.bills = 0,
    this.duplicates = 0,
    this.rejected = 0,
    this.noRuleMatched = 0,
    this.quarantined = 0,
    this.failed = 0,
    this.needsReview = 0,
    this.oldest,
    this.newest,
  });

  /// Inbox rows the reader looked at, including the ones it dropped before
  /// the body was ever kept.
  final int scanned;

  /// Messages that reached the parser.
  final int candidates;

  final int posted;
  final int bills;
  final int duplicates;
  final int rejected;
  final int noRuleMatched;
  final int quarantined;
  final int failed;

  /// Of [posted], how many need the user to say something.
  final int needsReview;

  /// The span the transactions actually covered.
  final DateTime? oldest;
  final DateTime? newest;

  IngestReport copyWith({
    int? scanned,
    int? candidates,
    int? posted,
    int? bills,
    int? duplicates,
    int? rejected,
    int? noRuleMatched,
    int? quarantined,
    int? failed,
    int? needsReview,
    DateTime? oldest,
    DateTime? newest,
  }) {
    return IngestReport(
      scanned: scanned ?? this.scanned,
      candidates: candidates ?? this.candidates,
      posted: posted ?? this.posted,
      bills: bills ?? this.bills,
      duplicates: duplicates ?? this.duplicates,
      rejected: rejected ?? this.rejected,
      noRuleMatched: noRuleMatched ?? this.noRuleMatched,
      quarantined: quarantined ?? this.quarantined,
      failed: failed ?? this.failed,
      needsReview: needsReview ?? this.needsReview,
      oldest: oldest ?? this.oldest,
      newest: newest ?? this.newest,
    );
  }

  /// Folds one outcome in. [occurredAt] widens the covered span.
  IngestReport withOutcome(IngestOutcome outcome, {DateTime? occurredAt}) {
    DateTime? low = oldest;
    DateTime? high = newest;
    if (occurredAt != null) {
      if (low == null || occurredAt.isBefore(low)) low = occurredAt;
      if (high == null || occurredAt.isAfter(high)) high = occurredAt;
    }
    return IngestReport(
      scanned: scanned,
      candidates: candidates +
          (outcome.disposition == IngestDisposition.duplicateMessage ? 0 : 1),
      posted: posted + (outcome.disposition == IngestDisposition.posted ? 1 : 0),
      bills: bills + (outcome.disposition == IngestDisposition.billRecorded ? 1 : 0),
      duplicates: duplicates +
          (outcome.disposition == IngestDisposition.duplicateMessage ||
                  outcome.disposition == IngestDisposition.duplicateEvent
              ? 1
              : 0),
      rejected: rejected +
          (outcome.disposition == IngestDisposition.rejected ||
                  outcome.disposition == IngestDisposition.untrustedSender
              ? 1
              : 0),
      noRuleMatched: noRuleMatched +
          (outcome.disposition == IngestDisposition.noRuleMatched ? 1 : 0),
      quarantined:
          quarantined + (outcome.disposition == IngestDisposition.quarantined ? 1 : 0),
      failed: failed + (outcome.disposition == IngestDisposition.failed ? 1 : 0),
      needsReview: needsReview + (outcome.needsReview ? 1 : 0),
      oldest: low,
      newest: high,
    );
  }

  IngestReport withScanned(int extra) => copyWith(scanned: scanned + extra);
}

/// The one implementation of "what happens to an SMS".
class IngestPipeline {
  IngestPipeline({
    required this._repository,
    required this._parser,
    required this._categorizer,
    DedupIndex? dedupIndex,
    DateTime Function()? clock,
  })  : _dedup = dedupIndex ?? DedupIndex(),
        _clock = clock ?? DateTime.now;

  final LedgerRepository _repository;
  final SmsParser _parser;
  final Categorizer _categorizer;
  final DedupIndex _dedup;
  final DateTime Function() _clock;

  final StreamController<IngestOutcome> _outcomes =
      StreamController<IngestOutcome>.broadcast();

  StreamSubscription<RawMessage>? _live;

  /// Serialises ingestion. The live receiver and a running backfill both call
  /// in; interleaving them would let two copies of one payment pass the
  /// deduplicator side by side, each seeing an index that does not yet
  /// contain the other.
  Future<void> _queue = Future<void>.value();

  bool _disposed = false;

  /// Every decision, as it is made. Broadcast, and it never carries message
  /// text.
  Stream<IngestOutcome> get outcomes => _outcomes.stream;

  /// The dedup window, exposed for diagnostics.
  DedupIndex get dedupIndex => _dedup;

  /// True once [dispose] has run.
  bool get isDisposed => _disposed;

  // ------------------------------------------------------------- live path

  /// Subscribes to a [MessageSource]'s live stream.
  ///
  /// Idempotent: a second call replaces the first subscription rather than
  /// ingesting everything twice. The stream never errors by contract, so
  /// there is no error handler to write - a receiver that died silently is
  /// what [backfillFrom] exists to repair.
  Future<void> attach(Stream<RawMessage> incoming) async {
    if (_disposed) return;
    await _live?.cancel();
    _live = incoming.listen((RawMessage message) {
      // Fire and forget onto the serial queue: the platform stream must not
      // be back-pressured by a database write.
      unawaited(ingestOne(message));
    });
  }

  /// Stops consuming the live stream. The pipeline stays usable for backfill.
  Future<void> detach() async {
    await _live?.cancel();
    _live = null;
  }

  // --------------------------------------------------------- backfill path

  /// Pages a [MessageSource]'s inbox through the pipeline.
  ///
  /// Page-at-a-time and interruptible by design: on a 20,000-message inbox
  /// the user must be able to stop and keep everything already written.
  ///
  /// [onProgress] fires after every page and periodically inside one, so the
  /// counters on screen are real rather than a timer pretending to be one.
  Future<Result<IngestReport>> backfillFrom(
    MessageSource source, {
    DateTime? since,
    DateTime? until,
    int pageSize = 200,
    void Function(IngestReport report)? onProgress,
    bool Function()? isCancelled,
  }) async {
    IngestReport report = const IngestReport();
    String? pageToken;

    while (true) {
      if (_disposed || (isCancelled?.call() ?? false)) break;

      final Result<MessageBatch> page = await source.backfill(
        since: since,
        until: until,
        limit: pageSize,
        pageToken: pageToken,
      );
      if (page case Err<MessageBatch>(error: final AppError error)) {
        // Everything already written stays written; the caller gets both the
        // failure and the work done so far via the report on the error.
        return Result<IngestReport>.err(
          error.copyWith(details: <String, Object?>{
            ...?error.details,
            'postedBeforeFailure': report.posted,
          }),
        );
      }

      final MessageBatch batch = page.valueOrNull!;
      report = report.withScanned(batch.scannedCount);
      onProgress?.call(report);

      report = await ingestBatch(
        batch.messages,
        into: report,
        onProgress: onProgress,
        isCancelled: isCancelled,
      );

      pageToken = batch.nextPageToken;
      if (pageToken == null) break;
    }

    return Ok<IngestReport>(report);
  }

  /// Ingests a page of messages, storing them in one atomic write first.
  Future<IngestReport> ingestBatch(
    List<RawMessage> messages, {
    IngestReport into = const IngestReport(),
    void Function(IngestReport report)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (messages.isEmpty) return into;

    return _serialize(() async {
      IngestReport report = into;

      final Result<List<IngestReceipt>> stored =
          await _repository.saveRawMessages(messages);
      final List<IngestReceipt>? receipts = stored.valueOrNull;
      // A receipt list that does not line up with the input would be a
      // repository bug. Rather than drop the page, fall back to per-message
      // saves, which have the same de-duplication.
      final bool aligned = receipts != null && receipts.length == messages.length;

      for (int i = 0; i < messages.length; i++) {
        if (_disposed || (isCancelled?.call() ?? false)) break;
        final RawMessage message = messages[i];

        IngestReceipt? receipt = aligned ? receipts[i] : null;
        if (receipt == null) {
          final Result<IngestReceipt> one =
              await _repository.saveRawMessage(message);
          receipt = one.valueOrNull;
          if (receipt == null) {
            final IngestOutcome failure = IngestOutcome(
              rawMessageId: message.id,
              disposition: IngestDisposition.failed,
              reason: 'save_failed',
              error: one.errorOrNull,
            );
            report = report.withOutcome(failure);
            _emit(failure);
            continue;
          }
        }

        final IngestOutcome outcome = await _process(message, receipt);
        report = report.withOutcome(outcome, occurredAt: outcome.occurredAt);
        _emit(outcome);

        // Hand the frame back regularly so Stop stays responsive and the
        // counters animate on a cheap phone.
        if (i % 25 == 24) {
          onProgress?.call(report);
          await Future<void>.delayed(Duration.zero);
        }
      }

      onProgress?.call(report);
      return report;
    });
  }

  /// The single entry point. One message, one decision.
  Future<IngestOutcome> ingestOne(RawMessage message) {
    return _serialize(() async {
      final Result<IngestReceipt> stored = await _repository.saveRawMessage(message);
      switch (stored) {
        case Err<IngestReceipt>(error: final AppError error):
          final IngestOutcome outcome = IngestOutcome(
            rawMessageId: message.id,
            disposition: IngestDisposition.failed,
            reason: 'save_failed',
            error: error,
          );
          _emit(outcome);
          return outcome;
        case Ok<IngestReceipt>(value: final IngestReceipt receipt):
          final IngestOutcome outcome = await _process(message, receipt);
          _emit(outcome);
          return outcome;
      }
    });
  }

  // ----------------------------------------------------------------- stages

  Future<IngestOutcome> _process(RawMessage message, IngestReceipt receipt) async {
    final String id = receipt.id;

    if (receipt.isDuplicate) {
      return IngestOutcome(
        rawMessageId: id,
        disposition: IngestDisposition.duplicateMessage,
        linkedToId: receipt.mergedIntoId,
        reason: 'already_ingested',
      );
    }

    final DateTime now = _clock();
    // The parser owns the trust gate and the reject patterns, and it is total:
    // a hostile body produces a ParseOutcome, never an exception.
    final ParseOutcome parse = _parser.parse(message, now: now);

    if (!parse.isParsed || parse.message == null) {
      return _recordNonEntry(id, message, parse);
    }

    final ParsedMessage parsed = parse.message!;

    if (parsed.txnType == TxnType.billReminder) {
      return _recordBill(id, message, parse, parsed, now);
    }
    if (!parsed.txnType.createsLedgerEntry) {
      return _recordNonEntry(id, message, parse);
    }

    // --- one money event, however many messages announced it ---------------
    final DedupCandidate candidate =
        DedupCandidate.fromParsed(parsed, message, id: id);
    final DedupResult dedup = _dedup.classify(candidate);

    if (dedup.collapses) {
      _dedup.remember(candidate);
      await _repository.updateParseState(
        id,
        state: ParseState.parsed,
        parserVersion: _parser.rulesVersion,
        ruleId: parse.ruleId,
        txnId: dedup.matchId,
        reason: dedup.reason,
      );
      return IngestOutcome(
        rawMessageId: id,
        disposition: IngestDisposition.duplicateEvent,
        linkedToId: dedup.matchId,
        ruleId: parse.ruleId,
        reason: dedup.reason,
      );
    }

    // --- whose money was this ---------------------------------------------
    final CategoryResult category = _categorize(parsed, message);
    await _ensureAccount(parsed, now);

    // An empty id lets the repository mint one seeded from occurredAt, which
    // is what keeps the timeline's keyset paging stable.
    final Transaction draft = Transaction.fromParse(
      id: '',
      parsed: parsed,
      category: category,
      now: now,
    );

    final Result<Transaction> posted = await _repository.postTransaction(draft);
    if (posted case Err<Transaction>(error: final AppError error)) {
      await _repository.updateParseState(
        id,
        state: ParseState.quarantined,
        parserVersion: _parser.rulesVersion,
        ruleId: parse.ruleId,
        reason: 'post_failed',
      );
      return IngestOutcome(
        rawMessageId: id,
        disposition: IngestDisposition.failed,
        ruleId: parse.ruleId,
        reason: 'post_failed',
        error: error,
      );
    }

    final Transaction saved = posted.valueOrNull!;
    // Remember under the transaction id, so a later message that matches this
    // event can be linked to a row that actually exists.
    _dedup.remember(DedupCandidate.fromParsed(parsed, message, id: saved.id));

    String? linkedTo;
    if (dedup.links && dedup.matchId != null) {
      linkedTo = dedup.matchId;
      switch (dedup.relation) {
        case DedupRelation.reversalOf:
          await _repository.linkReversal(txnId: saved.id, reversesId: linkedTo!);
        case DedupRelation.transferLeg:
          await _repository.linkTransfer(saved.id, linkedTo!);
        case DedupRelation.unique:
        case DedupRelation.duplicateDelivery:
        case DedupRelation.sameEvent:
        case DedupRelation.followUp:
          linkedTo = null;
      }
    }

    await _repository.updateParseState(
      id,
      state: ParseState.parsed,
      parserVersion: _parser.rulesVersion,
      ruleId: parse.ruleId,
      txnId: saved.id,
      reason: parse.reason.isEmpty ? null : parse.reason,
    );

    return IngestOutcome(
      rawMessageId: id,
      disposition: IngestDisposition.posted,
      transactionId: saved.id,
      linkedToId: linkedTo,
      needsReview: saved.isUncategorized || saved.needsReview,
      ruleId: parse.ruleId,
      reason: category.source.wire,
      occurredAt: saved.occurredAt,
    );
  }

  /// A message that will not become a transaction: an OTP, a promo, a failed
  /// payment, a pre-debit notice, an unknown template, or something the
  /// parser refused to guess at.
  Future<IngestOutcome> _recordNonEntry(
    String id,
    RawMessage message,
    ParseOutcome parse,
  ) async {
    final ParseState state = parse.resultingState;

    await _repository.updateParseState(
      id,
      state: state,
      parserVersion: _parser.rulesVersion,
      ruleId: parse.ruleId,
      reason: parse.reason.isEmpty ? null : parse.reason,
    );

    // Held, visibly, rather than booked at a guessed amount. The user is shown
    // the message and asked; silently under-counting is the one failure they
    // cannot detect.
    //
    // The quarantine table is beyond the `LedgerRepository` contract - it is
    // also what reconciliation ranks its hypotheses against - so a repository
    // that does not offer it still ingests correctly, just without that
    // cross-check. `updateParseState` above has already recorded the state.
    final LedgerRepository repo = _repository;
    if (parse.status == ParseStatus.ambiguous && repo is LedgerRepositoryImpl) {
      await repo.quarantineMessage(
        rawMessageId: id,
        reason: parse.reason.isEmpty ? 'ambiguous' : parse.reason,
        amount: Money.tryParse(parse.partialFields['amount']),
        receivedAt: message.receivedAt,
      );
    }

    return IngestOutcome(
      rawMessageId: id,
      disposition: switch (parse.status) {
        ParseStatus.untrustedSender => IngestDisposition.untrustedSender,
        ParseStatus.noRuleMatched => IngestDisposition.noRuleMatched,
        ParseStatus.ambiguous => IngestDisposition.quarantined,
        ParseStatus.rejected => IngestDisposition.rejected,
        // A parsed message whose type creates no ledger entry - a balance
        // alert, a pre-debit notice.
        ParseStatus.parsed => IngestDisposition.rejected,
      },
      ruleId: parse.ruleId,
      reason: parse.reason,
    );
  }

  /// A promise about the future. Recorded as a [Bill], never as a
  /// transaction: booking the reminder and then the real debit is exactly how
  /// an EMI ends up counted twice.
  Future<IngestOutcome> _recordBill(
    String id,
    RawMessage message,
    ParseOutcome parse,
    ParsedMessage parsed,
    DateTime now,
  ) async {
    final CategoryResult category = _categorize(parsed, message);
    final String name = category.merchantName ??
        parsed.merchantRaw ??
        parsed.issuer ??
        message.senderHeader ??
        'Bill';

    final Result<Bill> upserted = await _repository.upsertBill(
      Bill(
        // Empty: the repository folds a re-sent reminder onto the row it
        // already has, keyed by biller and cycle.
        id: '',
        name: name,
        dueDate: parsed.dueDate ?? parsed.occurredAt,
        createdAt: now,
        updatedAt: now,
        amountDue: parsed.amount,
        accountTail: parsed.accountTail,
        cardTail: parsed.cardTail,
        merchantName: category.merchantName ?? parsed.merchantRaw,
        categoryPath: category.isUncategorized ? null : category.categoryPath,
        kind: category.isUncategorized ? CategoryKind.expense : category.kind,
        issuer: parsed.issuer ?? message.senderHeader,
        sourceMessageId: id,
        isRecurring: true,
      ),
    );

    await _repository.updateParseState(
      id,
      state: ParseState.parsed,
      parserVersion: _parser.rulesVersion,
      ruleId: parse.ruleId,
      reason: 'bill_reminder',
    );

    if (upserted case Err<Bill>(error: final AppError error)) {
      return IngestOutcome(
        rawMessageId: id,
        disposition: IngestDisposition.failed,
        ruleId: parse.ruleId,
        reason: 'bill_upsert_failed',
        error: error,
      );
    }

    return IngestOutcome(
      rawMessageId: id,
      disposition: IngestDisposition.billRecorded,
      billId: upserted.valueOrNull?.id,
      ruleId: parse.ruleId,
      reason: 'bill_reminder',
    );
  }

  /// Uses the richer entry point where the categoriser offers one, so that
  /// `bodyContains` and `senderExact` rules the user wrote can actually fire.
  ///
  /// The body is used for matching inside that call and nowhere else: it is
  /// not stored by the categoriser, not logged, and not part of the result.
  CategoryResult _categorize(ParsedMessage parsed, RawMessage message) {
    final Categorizer categorizer = _categorizer;
    if (categorizer is CascadeCategorizer) {
      return categorizer.categorizeMessage(
        parsed,
        senderHeader: message.senderHeader,
        body: message.body,
      );
    }
    return categorizer.categorize(parsed);
  }

  /// Creates the account a transaction names, the first time it is seen.
  ///
  /// Without this the account filter stays permanently empty: the repository
  /// resolves a tail to an existing account but never invents one, and
  /// nothing else in the app has the tail to hand.
  Future<void> _ensureAccount(ParsedMessage parsed, DateTime now) async {
    final bool isCard = parsed.cardTail != null;
    final String? tail = Account.normalizeTail(parsed.cardTail ?? parsed.accountTail);
    if (tail == null) return;

    final AccountType type = isCard ? AccountType.creditCard : AccountType.savings;
    final Result<Account?> existing =
        await _repository.accountByTail(tail, type: type);
    if (existing.valueOrNull != null) return;
    // Do not create a second account for a tail some other type already claims.
    if ((await _repository.accountByTail(tail)).valueOrNull != null) return;

    final String issuer = parsed.issuer ?? '';
    await _repository.upsertAccount(
      Account(
        id: '',
        type: type,
        displayName: issuer.isEmpty
            ? '${isCard ? 'Card' : 'Account'} ...$tail'
            : '$issuer ${isCard ? 'card' : ''} ...$tail'.replaceAll('  ', ' '),
        createdAt: now,
        updatedAt: now,
        institution: issuer.isEmpty ? null : issuer,
        tail: tail,
      ),
    );
  }

  // ---------------------------------------------------------------- plumbing

  void _emit(IngestOutcome outcome) {
    if (!_outcomes.isClosed) _outcomes.add(outcome);
  }

  /// Runs [body] after everything already queued, so ingestion is strictly
  /// serial even when the live receiver fires mid-backfill.
  Future<T> _serialize<T>(Future<T> Function() body) {
    final Completer<T> done = Completer<T>();
    _queue = _queue.then((_) async {
      try {
        done.complete(await body());
      } on Object catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }

  Future<void> dispose() async {
    _disposed = true;
    await detach();
    await _outcomes.close();
  }
}
