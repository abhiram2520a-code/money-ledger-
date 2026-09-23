/// The composition root: the one place that knows which concrete class sits
/// behind each contract.
///
/// Everything above this file talks to `MessageSource`, `SmsParser`,
/// `Categorizer`, `LedgerRepository` and `RulesProvider`, and to nothing else.
/// That is what makes the whole app testable with no device, and it is what
/// makes the privacy claim checkable: there is exactly one implementation that
/// touches Android (`AndroidMessageSource`) and exactly one that can open a
/// socket (`AssetRulesProvider`), and both are named here.
///
/// ## Startup order, and why it is this order
///
/// 1. **Rules.** Bundled from `assets/rules/`, so this step cannot fail for
///    network reasons and cannot wait on one. Everything else needs the
///    taxonomy.
/// 2. **Repository**, constructed with `RuleSet.categoryPaths`, so a category
///    that is not in the taxonomy is refused at the door rather than
///    poisoning a rollup months later.
/// 3. **Parser** and **categoriser**, compiled against that same pack.
/// 4. **Message source**, which is inert until the user grants permission.
/// 5. **Pipeline**, which joins them.
///
/// Step 1 is the answer to "does this work without the config server": yes.
/// Nothing in this sequence makes a request, and `checkForUpdate()` is the
/// only method in the app that could.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'categorize/categorize.dart';
import 'contracts/contracts.dart';
import 'core/result.dart';
import 'data/data.dart';
import 'data/drift_store.dart';
import 'models/models.dart';
import 'native/native.dart';
import 'parser/parsing.dart';
import 'pipeline/ingest_pipeline.dart';
import 'rules/asset_rules_provider.dart';
import 'ui/onboarding/onboarding_store.dart';
import 'ui/theme/theme.dart';

/// Everything the app needs, already wired and already loaded.
class AppDependencies {
  AppDependencies({
    required this.rules,
    required this.repository,
    required this.parser,
    required this.categorizer,
    required this.messageSource,
    required this.pipeline,
    this.warnings = const <String>[],
  });

  final RulesProvider rules;
  final LedgerRepository repository;
  final SmsParser parser;
  final Categorizer categorizer;
  final MessageSource messageSource;
  final IngestPipeline pipeline;

  /// Non-fatal problems worth telling the user about once - a downloaded pack
  /// that had to be thrown away, user rules pointing at a category a newer
  /// pack removed. Never a reason to refuse to start.
  final List<String> warnings;

  StreamSubscription<RuleSet>? _ruleWatch;

  /// The overrides for the root `ProviderScope`.
  List<Override> get overrides => <Override>[
        ledgerRepositoryProvider.overrideWithValue(repository),
        messageSourceProvider.overrideWithValue(messageSource),
        smsParserProvider.overrideWithValue(parser),
        categorizerProvider.overrideWithValue(categorizer),
        rulesSourceProvider.overrideWithValue(rules),
        ingestPipelineProvider.overrideWithValue(pipeline),
      ];

  /// Keeps the parser and categoriser in step with the rules in force, so
  /// applying an update in Settings takes effect without a restart.
  void watchRuleChanges() {
    _ruleWatch ??= rules.changes.listen((RuleSet set) async {
      await parser.load(set);
      final Result<List<UserRule>> stored = await repository.userRules();
      await categorizer.load(
        set,
        userRules: stored.getOrElse(const <UserRule>[]),
      );
    });
  }

  Future<void> dispose() async {
    await _ruleWatch?.cancel();
    _ruleWatch = null;
    await pipeline.dispose();
    await messageSource.dispose();
    await repository.close();
  }
}

/// Builds and loads everything. Call once, from `main`, after
/// `WidgetsFlutterBinding.ensureInitialized()`.
///
/// Fails only for reasons that make the app genuinely unusable: a rules pack
/// missing from the build, or a database that will not open. Being offline is
/// not one of them and never can be.
Future<Result<AppDependencies>> bootstrapAppDependencies({
  RulesProvider? rulesProvider,
  LedgerStore? store,
  MessageSource? messageSource,
  DateTime Function()? clock,
}) async {
  final List<String> warnings = <String>[];
  final DateTime Function() now = clock ?? DateTime.now;

  // --- 1. rules: bundled, offline, cannot wait on a server -----------------
  final RulesProvider rules = rulesProvider ?? AssetRulesProvider(clock: now);
  final Result<RuleSet> loaded = await rules.load();
  if (loaded case Err<RuleSet>(error: final AppError error)) {
    return Err<AppDependencies>(error);
  }
  final RuleSet ruleSet = loaded.valueOrNull!;
  if (ruleSet.origin == RulesOrigin.remote) {
    warnings.add('Using downloaded rules, version ${ruleSet.version}.');
  }

  // --- 2. database ---------------------------------------------------------
  final LedgerRepositoryImpl repository = LedgerRepositoryImpl(
    store: store ?? DriftLedgerStore.openFile(),
    clock: now,
    knownCategoryPaths: ruleSet.categoryPaths,
  );
  final Result<void> opened = await repository.init();
  if (opened case Err<void>(error: final AppError error)) {
    return Err<AppDependencies>(error);
  }

  // --- 3. parser and categoriser, on that same pack ------------------------
  final RuleBasedSmsParser parser = RuleBasedSmsParser();
  final Result<void> parserLoaded = await parser.load(ruleSet);
  if (parserLoaded case Err<void>(error: final AppError error)) {
    return Err<AppDependencies>(error);
  }
  for (final String warning in parser.loader.current.warnings) {
    warnings.add(warning);
  }

  final Result<List<UserRule>> storedRules = await repository.userRules();
  final CascadeCategorizer categorizer = CascadeCategorizer(
    // A card bill is a transfer only when the app already counted the swipes.
    // When the card is invisible to this phone the bill is the only evidence
    // the money was spent, and calling it a transfer would under-count.
    isCardTracked: null,
  );
  final Result<void> categorizerLoaded = await categorizer.load(
    ruleSet,
    userRules: storedRules.getOrElse(const <UserRule>[]),
  );
  if (categorizerLoaded case Err<void>(error: final AppError error)) {
    return Err<AppDependencies>(error);
  }
  if (categorizer.orphanedUserRules.isNotEmpty) {
    warnings.add(
      '${categorizer.orphanedUserRules.length} of your rules point at a '
      'category this version no longer has. They are kept, but not applied.',
    );
  }

  // --- 4. the platform, and only the platform ------------------------------
  //
  // No `senderAllow` is passed, deliberately. The gate that matters is
  // structural and already runs in `MessageGate.kt`: any numeric sender is
  // rejected before the body is copied anywhere, which drops 100% of
  // person-to-person SMS at the platform boundary. Deciding which *header* is
  // a bank belongs to `rules/parser_rules.json`, so it can change without a
  // new APK - and `ParserRuleDef.issuer` is a display name ("Generic Bank"),
  // not a header, so building an allowlist out of it here would silently
  // reject every message in the inbox.
  final MessageSource source = messageSource ?? AndroidMessageSource();

  // --- 5. the spine --------------------------------------------------------
  final IngestPipeline pipeline = IngestPipeline(
    repository: repository,
    parser: parser,
    categorizer: categorizer,
    clock: now,
  );

  final AppDependencies deps = AppDependencies(
    rules: rules,
    repository: repository,
    parser: parser,
    categorizer: categorizer,
    messageSource: source,
    pipeline: pipeline,
    warnings: List<String>.unmodifiable(warnings),
  );
  deps.watchRuleChanges();
  return Ok<AppDependencies>(deps);
}

// ---------------------------------------------------------------- providers

/// The ingest pipeline. Overridden in the root scope; unoverridden it throws
/// rather than silently doing nothing, because "no transactions appeared" is
/// the one failure this app must never present as an empty ledger.
final Provider<IngestPipeline> ingestPipelineProvider = Provider<IngestPipeline>(
  (Ref ref) => throw UnsupportedError(
    'ingestPipelineProvider was never overridden. Override it in the root '
    'ProviderScope - see lib/di.dart.',
  ),
);

/// Starts live SMS capture and runs a catch-up scan of the inbox.
///
/// Both paths go through the same [IngestPipeline], so a message caught live
/// and the same message found later in the inbox reach identical code and
/// cannot produce two different ledgers.
class IngestService {
  IngestService(this._ref);

  final Ref _ref;

  bool _attached = false;
  bool _catchingUp = false;

  /// How far back a catch-up scan reaches when the app has never imported.
  /// Six months is enough for trend lines and recurring detection, and caps
  /// the worst case on an old phone with a huge inbox.
  static const Duration coldWindow = Duration(days: 180);

  /// Overlap on an incremental scan, because a message that arrived while the
  /// app was being killed can land either side of the recorded boundary.
  static const Duration catchUpOverlap = Duration(days: 2);

  /// Attaches the live stream and, if permission is granted, catches up on
  /// anything the receiver missed.
  ///
  /// Safe to call on every launch and safe to call twice. Does nothing at all
  /// without SMS permission - the app is fully usable that way, on manually
  /// entered transactions.
  Future<void> startIfPermitted() async {
    final MessageSource source = _ref.read(messageSourceProvider);
    if (!await source.isSupported()) return;

    final Result<PermissionState> status = await source.permissionStatus();
    if (!(status.valueOrNull?.isGranted ?? false)) return;

    await attachLive(source);
    await catchUp(source);
  }

  /// Subscribes the pipeline to live messages. Idempotent.
  Future<void> attachLive(MessageSource source) async {
    if (_attached) return;
    final IngestPipeline pipeline = _ref.read(ingestPipelineProvider);
    await pipeline.attach(source.incoming);
    _attached = true;
    await source.start();
  }

  /// Scans the inbox for anything the live receiver did not get.
  ///
  /// This is not belt-and-braces. A manifest receiver goes silent with no
  /// callback and no error when an OEM battery manager force-stops the
  /// package, which is the normal state of affairs on several large Android
  /// brands. The phone's own inbox is the source of truth; live capture is a
  /// latency optimisation on top of it.
  Future<IngestReport?> catchUp(MessageSource source) async {
    if (_catchingUp) return null;
    _catchingUp = true;
    try {
      final OnboardingStore onboarding = _ref.read(onboardingStoreProvider);
      final DateTime? last = await onboarding.lastImportAt();
      final DateTime nowAt = _ref.read(clockProvider)();
      final DateTime since = last == null
          ? nowAt.subtract(coldWindow)
          : last.subtract(catchUpOverlap);

      final Result<IngestReport> done = await _ref
          .read(ingestPipelineProvider)
          .backfillFrom(source, since: since);

      if (done.isOk) {
        await onboarding.setLastImportAt(nowAt);
        return done.valueOrNull;
      }
      // A failed scan is not worth interrupting the user for: the ledger they
      // already have is intact and the next launch tries again.
      debugPrint('Catch-up scan did not complete: ${done.errorOrNull?.code}');
      return null;
    } finally {
      _catchingUp = false;
    }
  }
}

final Provider<IngestService> ingestServiceProvider =
    Provider<IngestService>(IngestService.new);
