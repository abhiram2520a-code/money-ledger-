/// The seam between the UI and everything else.
///
/// Every screen in this app talks to the four contract interfaces and nothing
/// else. The platform layer (drift repository, SMS reader, parser, rules
/// loader) is injected by overriding the providers below in the
/// [ProviderScope] that wraps the app:
///
/// ```dart
/// runApp(ProviderScope(
///   overrides: <Override>[
///     ledgerRepositoryProvider.overrideWithValue(driftRepository),
///     messageSourceProvider.overrideWithValue(androidSmsSource),
///     smsParserProvider.overrideWithValue(parser),
///     categorizerProvider.overrideWithValue(categorizer),
///     rulesSourceProvider.overrideWithValue(rules),
///   ],
///   child: const LedgerApp(),
/// ));
/// ```
///
/// Unoverridden they throw a readable error rather than returning a stub. A
/// silent no-op implementation would make a wiring mistake look like an empty
/// database, and "the ledger is empty" is the one lie this app must never tell.
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';

/// Thrown when a screen is built without the platform layer wired in.
UnsupportedError _notWired(String provider) => UnsupportedError(
      'The UI asked for $provider but it was never overridden. Override it in '
      'the root ProviderScope - see lib/ui/theme/app_dependencies.dart.',
    );

/// The local database. The only place transactions live.
final Provider<LedgerRepository> ledgerRepositoryProvider =
    Provider<LedgerRepository>((Ref ref) => throw _notWired('ledgerRepositoryProvider'));

/// The platform SMS reader. The only interface in the app that touches the OS.
final Provider<MessageSource> messageSourceProvider =
    Provider<MessageSource>((Ref ref) => throw _notWired('messageSourceProvider'));

/// The on-device SMS parser.
final Provider<SmsParser> smsParserProvider =
    Provider<SmsParser>((Ref ref) => throw _notWired('smsParserProvider'));

/// The on-device categoriser.
final Provider<Categorizer> categorizerProvider =
    Provider<Categorizer>((Ref ref) => throw _notWired('categorizerProvider'));

/// The rules pack loader. Bundled first, network only for later updates.
final Provider<RulesProvider> rulesSourceProvider =
    Provider<RulesProvider>((Ref ref) => throw _notWired('rulesSourceProvider'));

/// Injectable clock. Screens never call `DateTime.now()` directly so that a
/// widget test can pin "today" and assert on `Today` / `Yesterday` headings.
final Provider<DateTime Function()> clockProvider =
    Provider<DateTime Function()>((Ref ref) => DateTime.now);

/// The live rules pack: the currently loaded one, then every replacement.
final StreamProvider<RuleSet> ruleSetProvider = StreamProvider<RuleSet>((Ref ref) async* {
  final RulesProvider rules = ref.watch(rulesSourceProvider);
  yield rules.current;
  yield* rules.changes;
});

/// The category taxonomy, sorted the way `categories.json` declares it.
///
/// Empty while the pack is still loading, and empty is a legitimate state: the
/// screens fall back to humanised category paths rather than blocking.
final Provider<List<CategoryDef>> taxonomyProvider = Provider<List<CategoryDef>>((Ref ref) {
  final RuleSet? set = ref.watch(ruleSetProvider).valueOrNull;
  if (set == null || set.categories.isEmpty) return const <CategoryDef>[];
  final List<CategoryDef> sorted = List<CategoryDef>.of(set.categories);
  sorted.sort((CategoryDef a, CategoryDef b) {
    final int byOrder = a.sortOrder.compareTo(b.sortOrder);
    return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
  });
  return List<CategoryDef>.unmodifiable(sorted);
});

/// How many transactions are waiting for the user to name them. Drives the
/// badge on the dashboard and the filter shortcut in the list.
final StreamProvider<int> uncategorizedCountProvider = StreamProvider<int>(
  (Ref ref) => ref.watch(ledgerRepositoryProvider).watchUncategorizedCount(),
);

/// A monotonically increasing tick that changes whenever ANY transaction is
/// written, so a screen can rebuild without subscribing to the whole ledger.
///
/// It rides on `watchTransactions` with a limit of one row, which is the
/// cheapest live query the repository offers.
final StreamProvider<int> ledgerTickProvider = StreamProvider<int>((Ref ref) async* {
  final LedgerRepository repo = ref.watch(ledgerRepositoryProvider);
  int tick = 0;
  await for (final List<Transaction> _
      in repo.watchTransactions(const TxnQuery(limit: 1))) {
    yield tick++;
  }
});

/// Accounts the ledger has learned about, for the account filter.
final StreamProvider<List<Account>> accountsProvider = StreamProvider<List<Account>>(
  (Ref ref) => ref.watch(ledgerRepositoryProvider).watchAccounts(),
);

/// The user's own categorisation rules, for the "why" panel on a transaction.
final StreamProvider<List<UserRule>> userRulesProvider = StreamProvider<List<UserRule>>(
  (Ref ref) => ref.watch(ledgerRepositoryProvider).watchUserRules(),
);

/// A failure a screen can show verbatim.
///
/// The repository speaks `Result`/`AppError`; Riverpod's `AsyncValue` speaks
/// exceptions. This is the one adapter between them, so no screen has to invent
/// its own wording for "something went wrong".
class LedgerUiException implements Exception {
  const LedgerUiException(this.message, {this.code});

  final String message;
  final String? code;

  @override
  String toString() => message;
}

/// Unwraps a [Result] for use inside a provider body, turning a failure into a
/// [LedgerUiException] that `AsyncValue.error` will carry to the screen.
T unwrap<T>(Result<T> result) => result.fold<T>(
      (T value) => value,
      (AppError error) => throw LedgerUiException(error.message, code: error.code),
    );

/// The sentence a screen puts in front of the user for a thrown error.
String describeError(Object error) => switch (error) {
      LedgerUiException(:final String message) => message,
      AppError(:final String message) => message,
      _ => 'Unexpected error: $error',
    };
