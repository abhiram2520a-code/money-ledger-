/// The local ledger: the database, the double-entry engine, and everything
/// that decides what a number the user sees actually means.
///
/// ```dart
/// import 'package:ledger/data/data.dart';
/// ```
///
/// `drift_store.dart` is deliberately NOT exported here. It is the only file
/// that imports drift, and keeping it out of the barrel means the ledger
/// logic - and every test of it - compiles and runs without a database
/// library or a native SQLite binary. The app's composition root imports it
/// directly:
///
/// ```dart
/// import 'package:ledger/data/drift_store.dart';
///
/// final repository = LedgerRepositoryImpl(store: DriftLedgerStore.openFile());
/// await repository.init();
/// ```
///
/// ## The one rule everything here exists to enforce
///
/// A credit-card spend is an expense. The bank debit that later pays that
/// card's bill is a transfer. Under [PostingEngine] the second one produces no
/// posting against an expense account at all, so it is arithmetically
/// incapable of entering a spend total - no issuer-name list, no payee
/// heuristic, nothing to break when a bank changes its SMS template. The same
/// structure covers self-transfers, ATM withdrawals, wallet top-ups and SIPs.
library;

export 'bill_matching.dart';
export 'encryption.dart';
export 'fingerprints.dart';
export 'ids.dart';
export 'ledger_repository_impl.dart';
export 'ledger_store.dart';
export 'memory_store.dart';
export 'postings.dart';
export 'recurring.dart';
export 'reconciliation.dart';
export 'schema.dart';
export 'transfer_matching.dart';
