/// End-to-end proof that the wiring holds.
///
/// Everything here runs against the REAL pack in `../rules/`, the real parser,
/// the real categoriser and the real repository logic - only the SQLite file
/// is swapped for [MemoryLedgerStore], so these tests need no device.
///
/// What they are actually defending:
///
/// * the modules built in parallel compose into a working pipeline at all;
/// * the same SMS arriving live and again in an inbox backfill produces ONE
///   transaction and ONE spend total, which is the failure the user cannot
///   see and therefore the one worth a test;
/// * a bill reminder never becomes a transaction;
/// * an OTP that quotes an amount never becomes money.
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ledger/categorize/categorize.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/data/data.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/parser/parsing.dart';
import 'package:ledger/pipeline/ingest_pipeline.dart';

void main() {
  late RuleSet rules;
  late LedgerRepositoryImpl repository;
  late RuleBasedSmsParser parser;
  late CascadeCategorizer categorizer;
  late IngestPipeline pipeline;

  final DateTime now = DateTime(2026, 9, 20, 12);

  setUp(() async {
    rules = _loadShippedRules();

    repository = LedgerRepositoryImpl(
      store: MemoryLedgerStore(),
      clock: () => now,
      knownCategoryPaths: rules.categoryPaths,
    );
    expect((await repository.init()).isOk, isTrue);

    parser = RuleBasedSmsParser();
    expect((await parser.load(rules)).isOk, isTrue,
        reason: 'the shipped pack must compile');

    categorizer = CascadeCategorizer();
    expect((await categorizer.load(rules)).isOk, isTrue);

    pipeline = IngestPipeline(
      repository: repository,
      parser: parser,
      categorizer: categorizer,
      clock: () => now,
    );
  });

  tearDown(() async {
    await pipeline.dispose();
    await repository.close();
  });

  test('the shipped pack books a plain UPI debit', () async {
    final IngestOutcome outcome = await pipeline.ingestOne(
      _sms(
        id: 'm1',
        sender: 'VM-HDFCBK-S',
        body: 'Rs.450.00 debited from A/C XX1234 to SWIGGY on 18-09-26. '
            'Ref no 401234567890. Not you? Call 18002586161',
        at: DateTime(2026, 9, 18, 13, 5),
      ),
    );

    expect(outcome.disposition, IngestDisposition.posted,
        reason: outcome.reason);
    expect(outcome.transactionId, isNotNull);

    final Transaction txn =
        (await repository.transactionById(outcome.transactionId!)).valueOrNull!;
    expect(txn.amount, const Money(45000));
    expect(txn.direction, TxnDirection.debit);
    expect(txn.accountTail, '1234');
    expect(txn.countsAsSpend, isTrue);
  });

  test('the same SMS live and again in a backfill is one transaction',
      () async {
    // Identical body, identical sender, but a different locally generated id
    // and a different ingest source - exactly what happens when the receiver
    // caught it and the inbox scan finds it again an hour later.
    const String body = 'Rs.450.00 debited from A/C XX1234 to SWIGGY '
        'on 18-09-26. Ref no 401234567890.';
    final DateTime at = DateTime(2026, 9, 18, 13, 5);

    final IngestOutcome live = await pipeline.ingestOne(
      _sms(id: 'live-1', sender: 'VM-HDFCBK-S', body: body, at: at),
    );
    expect(live.disposition, IngestDisposition.posted, reason: live.reason);

    final IngestReport backfill = await pipeline.ingestBatch(<RawMessage>[
      _sms(
        id: 'backfill-1',
        sender: 'VM-HDFCBK-S',
        body: body,
        at: at,
        source: IngestSource.smsBackfill,
        providerId: 991,
      ),
    ]);

    expect(backfill.posted, 0, reason: 'the second copy must not be booked');
    expect(backfill.duplicates, 1);

    final Money total = (await repository.totalSpend(
      from: DateTime(2026, 9),
      to: DateTime(2026, 10),
    ))
        .valueOrNull!;
    expect(total, const Money(45000),
        reason: 'one payment, one entry in the spend total');
  });

  test('two genuine payments of the same amount stay two', () async {
    // The other half of the dedup contract. Different references, so these are
    // two events however alike they look.
    final IngestOutcome first = await pipeline.ingestOne(
      _sms(
        id: 'a',
        sender: 'VM-HDFCBK-S',
        body: 'Rs.50.00 debited from A/C XX1234 to CHAI POINT on 18-09-26. '
            'Ref no 111111111111.',
        at: DateTime(2026, 9, 18, 9),
      ),
    );
    final IngestOutcome second = await pipeline.ingestOne(
      _sms(
        id: 'b',
        sender: 'VM-HDFCBK-S',
        body: 'Rs.50.00 debited from A/C XX1234 to CHAI POINT on 18-09-26. '
            'Ref no 222222222222.',
        at: DateTime(2026, 9, 18, 16),
      ),
    );

    expect(first.disposition, IngestDisposition.posted, reason: first.reason);
    expect(second.disposition, IngestDisposition.posted, reason: second.reason);

    final Money total = (await repository.totalSpend(
      from: DateTime(2026, 9),
      to: DateTime(2026, 10),
    ))
        .valueOrNull!;
    expect(total, const Money(10000));
  });

  test('an ATM withdrawal is a transfer to cash, not spending', () async {
    final IngestOutcome outcome = await pipeline.ingestOne(
      _sms(
        id: 'atm',
        sender: 'AD-SBIINB-S',
        body: 'Rs.5000.00 withdrawn at ATM from A/C X1234 on 18-09-26. '
            'Avl Bal Rs.20000.00',
        at: DateTime(2026, 9, 18, 19),
      ),
    );

    expect(outcome.disposition, IngestDisposition.posted, reason: outcome.reason);
    final Transaction txn =
        (await repository.transactionById(outcome.transactionId!)).valueOrNull!;
    expect(txn.kind, CategoryKind.transfer);
    expect(txn.countsAsSpend, isFalse,
        reason: 'money moved from the bank to the wallet, it was not spent');

    final Money total = (await repository.totalSpend(
      from: DateTime(2026, 9),
      to: DateTime(2026, 10),
    ))
        .valueOrNull!;
    expect(total, Money.zero);
  });

  test('a bill reminder becomes a bill, never a transaction', () async {
    final IngestOutcome outcome = await pipeline.ingestOne(
      _sms(
        id: 'bill',
        sender: 'VD-BESCOM-S',
        body: 'Your electricity bill of Rs.2340.00 for consumer 1234 is '
            'due on 05-10-26. Pay to avoid disconnection.',
        at: DateTime(2026, 9, 25, 8),
      ),
    );

    expect(outcome.disposition, IngestDisposition.billRecorded,
        reason: outcome.reason);
    expect(outcome.transactionId, isNull);

    final List<Bill> bills = (await repository.bills()).valueOrNull!;
    expect(bills, hasLength(1));
    expect(bills.single.amountDue, const Money(234000));

    final List<Transaction> txns =
        (await repository.transactions(const TxnQuery())).valueOrNull!;
    expect(txns, isEmpty,
        reason: 'a promise about the future is not money that moved');
  });

  test('an OTP quoting an amount never becomes money', () async {
    final IngestOutcome outcome = await pipeline.ingestOne(
      _sms(
        id: 'otp',
        sender: 'VM-HDFCBK-S',
        body: '123456 is your OTP for a transaction of Rs.4500.00 on card '
            'XX1234 at AMAZON. Do not share it with anyone.',
        at: DateTime(2026, 9, 18, 20),
      ),
    );

    expect(outcome.disposition, IngestDisposition.rejected, reason: outcome.reason);
    final List<Transaction> txns =
        (await repository.transactions(const TxnQuery())).valueOrNull!;
    expect(txns, isEmpty);
  });

  test('a personal SMS that reached us anyway is never parsed', () async {
    // The platform gate drops numeric senders before a body is ever copied.
    // This is the belt: a message with no normalised header cannot be parsed
    // even if it reaches Dart.
    final IngestOutcome outcome = await pipeline.ingestOne(
      RawMessage(
        id: 'personal',
        senderRaw: '+919876543210',
        body: 'hey i sent you Rs.450 for the swiggy order, check',
        receivedAt: DateTime(2026, 9, 18, 21),
        source: IngestSource.smsRealtime,
        bodyHash: 'personal-hash',
      ),
    );

    expect(outcome.disposition, IngestDisposition.untrustedSender);
    final List<Transaction> txns =
        (await repository.transactions(const TxnQuery())).valueOrNull!;
    expect(txns, isEmpty);
  });

  test('an unrecognised template is kept, so a later pack can re-parse it',
      () async {
    final IngestOutcome outcome = await pipeline.ingestOne(
      _sms(
        id: 'unknown',
        sender: 'AX-KOTAKB-S',
        body: 'Thank you for banking with us. Your recent activity summary '
            'is now available in the app.',
        at: DateTime(2026, 9, 18, 22),
      ),
    );

    expect(
      outcome.disposition,
      anyOf(IngestDisposition.noRuleMatched, IngestDisposition.rejected),
      reason: outcome.reason,
    );

    final RawMessage kept =
        (await repository.rawMessageById(outcome.rawMessageId)).valueOrNull!;
    expect(kept.parseState.isReparseCandidate || kept.parseState == ParseState.rejectedPromo,
        isTrue);
  });
}

/// A message that has already passed the platform's sender gate, which is
/// where `senderHeader` comes from on a real device.
RawMessage _sms({
  required String id,
  required String sender,
  required String body,
  required DateTime at,
  IngestSource source = IngestSource.smsRealtime,
  int? providerId,
}) {
  return RawMessage(
    id: id,
    senderRaw: sender,
    body: body,
    receivedAt: at,
    source: source,
    senderHeader: _normalizeHeader(sender),
    // The real hash comes from MessageGate.kt. Any stable function of the body
    // will do here, and it must be a function of the body alone: that is what
    // makes the live copy and the backfill copy collide.
    bodyHash: 'h${body.hashCode}',
    providerId: providerId,
  );
}

/// `VM-HDFCBK-S` -> `HDFCBK`, the same shape `MessageGate.senderHeader()`
/// produces.
String? _normalizeHeader(String raw) {
  final List<String> parts = raw.toUpperCase().split('-');
  if (parts.length < 2) return null;
  final String principal = parts[1];
  return RegExp(r'^[A-Z]{4,8}$').hasMatch(principal) ? principal : null;
}

RuleSet _loadShippedRules() {
  Map<String, dynamic> read(String name) {
    for (final String dir in <String>['../rules', 'assets/rules']) {
      final File file = File('$dir/$name');
      if (file.existsSync()) {
        return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      }
    }
    throw StateError('Could not find $name in ../rules or assets/rules');
  }

  return RuleSet.fromDocuments(
    parserRules: read('parser_rules.json'),
    categories: read('categories.json'),
    merchants: read('merchants.json'),
    loadedAt: DateTime(2026, 9, 20),
  );
}
