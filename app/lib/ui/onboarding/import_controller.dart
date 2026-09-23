import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/di.dart';
import 'package:ledger/pipeline/ingest_pipeline.dart';
import 'package:ledger/ui/theme/theme.dart';

import 'onboarding_store.dart';

/// Where a historical import has got to.
enum ImportPhase {
  /// Nothing has been asked for yet.
  idle,

  /// Reading the inbox. Counters are climbing.
  running,

  /// Finished on its own.
  done,

  /// The user pressed Stop. Everything already imported is kept.
  cancelled,

  /// Something went wrong. Everything already imported is kept.
  failed,
}

/// Live progress of the first-run inbox scan.
///
/// Every number here is real and comes from the pipeline, not from a timer. A
/// fake progress bar is the fastest way to teach a user that this app's numbers
/// cannot be trusted, and this app's whole proposition is that they can.
@immutable
class ImportProgress {
  const ImportProgress({
    this.phase = ImportPhase.idle,
    this.scanned = 0,
    this.candidates = 0,
    this.found = 0,
    this.needsReview = 0,
    this.duplicates = 0,
    this.oldest,
    this.newest,
    this.error,
  });

  final ImportPhase phase;

  /// Messages the reader looked at, including the ones it rejected.
  final int scanned;

  /// Messages that came back from the sender allowlist and got as far as the
  /// parser.
  final int candidates;

  /// Transactions written to the ledger.
  final int found;

  /// Of [found], how many landed in the Uncategorized queue.
  final int needsReview;

  /// Messages already in the database from an earlier run.
  final int duplicates;

  /// The span the import actually covered, for the summary line.
  final DateTime? oldest;
  final DateTime? newest;

  /// Set only when [phase] is [ImportPhase.failed].
  final String? error;

  bool get isRunning => phase == ImportPhase.running;

  bool get isFinished =>
      phase == ImportPhase.done ||
      phase == ImportPhase.cancelled ||
      phase == ImportPhase.failed;

  /// True when the inbox turned out to hold almost nothing - a new phone, a
  /// restored device, an RCS-heavy user. Worth saying out loud instead of
  /// presenting a blank ledger as the product.
  bool get isThinInbox => phase == ImportPhase.done && found == 0 && candidates < 20;

  ImportProgress copyWith({
    ImportPhase? phase,
    int? scanned,
    int? candidates,
    int? found,
    int? needsReview,
    int? duplicates,
    DateTime? oldest,
    DateTime? newest,
    String? error,
  }) {
    return ImportProgress(
      phase: phase ?? this.phase,
      scanned: scanned ?? this.scanned,
      candidates: candidates ?? this.candidates,
      found: found ?? this.found,
      needsReview: needsReview ?? this.needsReview,
      duplicates: duplicates ?? this.duplicates,
      oldest: oldest ?? this.oldest,
      newest: newest ?? this.newest,
      error: error ?? this.error,
    );
  }
}

/// Runs the first-run inbox scan against the contract interfaces and nothing
/// else: read a page of messages, store them, parse them, categorise them, post
/// the transactions, record what happened to each message.
///
/// It is deliberately page-at-a-time and interruptible. On a 20,000-message
/// inbox the user must be able to press Stop and keep whatever has landed so
/// far, and the ledger they see afterwards must be the real one.
class ImportController extends Notifier<ImportProgress> {
  bool _stopRequested = false;
  bool _disposed = false;

  /// How far back a first run reaches. Six months is enough for trend lines and
  /// recurring detection, and caps the worst case on a very old phone.
  static const Duration defaultWindow = Duration(days: 180);

  /// Messages fetched per page.
  static const int pageSize = 200;

  @override
  ImportProgress build() {
    ref.onDispose(() {
      _disposed = true;
      _stopRequested = true;
    });
    return const ImportProgress();
  }

  /// Asks the import to stop at the next page boundary. Everything already
  /// written stays written.
  void cancel() => _stopRequested = true;

  /// Clears a finished run so the screen can be shown again from scratch.
  void reset() {
    _stopRequested = false;
    _emit(const ImportProgress());
  }

  /// Scans the inbox and fills the ledger. Safe to call twice: a second call
  /// while a scan is running is ignored.
  ///
  /// Every message goes through [IngestPipeline], which is the same code the
  /// live SMS receiver runs. That is deliberate and load-bearing: a second
  /// copy of "what happens to an SMS" living in this file is how the ledger
  /// you get from a backfill stops matching the ledger you get live.
  Future<void> start({Duration window = defaultWindow}) async {
    if (state.isRunning) return;
    _stopRequested = false;
    _emit(const ImportProgress(phase: ImportPhase.running));

    final MessageSource source = ref.read(messageSourceProvider);
    final IngestPipeline pipeline = ref.read(ingestPipelineProvider);
    final DateTime Function() clock = ref.read(clockProvider);
    final DateTime since = clock().subtract(window);

    final Result<IngestReport> done = await pipeline.backfillFrom(
      source,
      since: since,
      pageSize: pageSize,
      onProgress: (IngestReport report) =>
          _emit(_progressFrom(report, ImportPhase.running)),
      isCancelled: () => _stopRequested || _disposed,
    );

    if (_disposed) return;

    switch (done) {
      case Err<IngestReport>(error: final AppError error):
        // Everything already imported is kept: the pipeline commits per
        // message, so a failure halfway through a 20,000-message inbox costs
        // the remainder, not the work.
        _fail(error.message);
      case Ok<IngestReport>(value: final IngestReport report):
        _emit(_progressFrom(
          report,
          _stopRequested ? ImportPhase.cancelled : ImportPhase.done,
        ));
        if (!_stopRequested) {
          await ref.read(onboardingStoreProvider).setLastImportAt(clock());
        }
    }
  }

  /// The pipeline's counters, in the words this screen uses.
  ImportProgress _progressFrom(IngestReport report, ImportPhase phase) {
    return ImportProgress(
      phase: phase,
      scanned: report.scanned,
      candidates: report.candidates,
      // Bills are things the user will see too, so they count as found.
      found: report.posted + report.bills,
      needsReview: report.needsReview,
      duplicates: report.duplicates,
      oldest: report.oldest,
      newest: report.newest,
    );
  }

  void _fail(String message) =>
      _emit(state.copyWith(phase: ImportPhase.failed, error: message));

  void _emit(ImportProgress next) {
    if (_disposed) return;
    state = next;
  }
}

final NotifierProvider<ImportController, ImportProgress> importControllerProvider =
    NotifierProvider<ImportController, ImportProgress>(ImportController.new);
