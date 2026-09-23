import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../contracts/contracts.dart';
import '../core/result.dart';
import '../models/models.dart';

/// The Android implementation of [MessageSource], over the platform channels
/// served by `LedgerPlugin.kt`.
///
/// It is the only file in `lib/` that talks to the platform, and it performs no
/// network I/O of any kind - there is no URL, no client and no socket below
/// this line. Everything the app does with a message happens on the device.
///
/// ## What "works in the background" actually means here
///
/// Live capture is a manifest-registered `BroadcastReceiver`, so Android starts
/// the process to receive an SMS even when the app has been swiped away. It
/// writes to an on-disk spool, and this class drains that spool the moment it
/// starts listening - so messages that arrived while no Flutter engine existed
/// still arrive, in order, on [incoming].
///
/// What live capture CANNOT survive is the package being force-stopped, either
/// by the user or by an OEM battery manager (Xiaomi autostart, Oppo/Realme
/// startup manager, Vivo background power). On those devices the receiver goes
/// quiet with no callback and no error. That is why [backfill] exists and why
/// it must be run on launch: the phone's own inbox is the source of truth and
/// the live path is only a latency optimisation. `SmsReceiver.kt` documents the
/// four process states in full.
class AndroidMessageSource implements MessageSource {
  AndroidMessageSource({
    MethodChannel? methodChannel,
    EventChannel? liveChannel,
    EventChannel? backfillChannel,
    this.senderAllow,
  })  : _methods = methodChannel ?? const MethodChannel(methodChannelName),
        _live = liveChannel ?? const EventChannel(liveChannelName),
        _backfill = backfillChannel ?? const EventChannel(backfillChannelName);

  static const String methodChannelName = 'com.vivekapps.ledger/methods';
  static const String liveChannelName = 'com.vivekapps.ledger/live';
  static const String backfillChannelName = 'com.vivekapps.ledger/backfill';

  /// The largest page [backfill] will ask the platform for, mirroring
  /// `SmsBackfill.MAX_LIMIT`.
  static const int maxPageSize = 2000;

  final MethodChannel _methods;
  final EventChannel _live;
  final EventChannel _backfill;

  /// An optional second gate, on top of the structural one the platform
  /// applies. The native side rejects every numeric sender, which removes all
  /// person-to-person SMS; this lets the caller additionally require that the
  /// header is one `rules/parser_rules.json` knows about, without this file
  /// having to depend on the rules module.
  final bool Function(String senderHeader)? senderAllow;

  final StreamController<RawMessage> _incoming =
      StreamController<RawMessage>.broadcast();

  StreamSubscription<dynamic>? _liveSubscription;
  bool _started = false;
  bool _disposed = false;
  int _droppedEvents = 0;

  /// How many platform events were unreadable or failed the sender gate since
  /// launch. Surfaced for diagnostics only; never an error, because a stream
  /// that dies takes the user's transactions with it.
  int get droppedEventCount => _droppedEvents;

  @override
  Stream<RawMessage> get incoming => _incoming.stream;

  // --------------------------------------------------------------- platform

  @override
  Future<bool> isSupported() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return false;
    }
    try {
      return await _methods.invokeMethod<bool>('isSupported') ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }

  @override
  Future<Result<PermissionState>> permissionStatus() async {
    if (!await isSupported()) {
      return const Ok<PermissionState>(PermissionState.unsupported);
    }
    return _invoke<String>('hasPermissions').then(
      (Result<String> r) => r.map(PermissionState.fromWire),
    );
  }

  @override
  Future<Result<PermissionState>> requestPermission() async {
    if (!await isSupported()) {
      return const Ok<PermissionState>(PermissionState.unsupported);
    }
    final Result<String> wire = await _invoke<String>('requestPermissions');
    // Denial is a normal answer, not a failure. Only a channel-level problem
    // reaches the caller as an Err.
    return wire.map(PermissionState.fromWire);
  }

  /// Sends the user to this app's system settings page, for the
  /// `permanentlyDenied` case where the OS will no longer show a prompt.
  Future<Result<bool>> openSystemSettings() => _invoke<bool>('openAppSettings');

  // ------------------------------------------------------------------- live

  @override
  Future<Result<void>> start() async {
    if (_disposed) {
      return Result<void>.err(
        AppError.stateError('MessageSource was disposed'),
      );
    }
    if (_started) {
      return okVoid;
    }
    if (!await isSupported()) {
      return Result<void>.err(
        AppError.unsupportedPlatform('SMS ingestion is Android only'),
      );
    }

    final Result<PermissionState> status = await permissionStatus();
    switch (status) {
      case Err<PermissionState>(error: final AppError e):
        return Err<void>(e);
      case Ok<PermissionState>(value: final PermissionState state):
        if (!state.isGranted) {
          return Result<void>.err(
            AppError.permissionDenied('SMS permission is ${state.wire}'),
          );
        }
    }

    final Result<bool> enabled = await _invoke<bool>('startLive');
    if (enabled case Err<bool>(error: final AppError e)) {
      return Err<void>(e);
    }

    // Listening is what triggers the native spool drain, so anything that
    // arrived while the app was dead is delivered here, oldest first.
    _liveSubscription = _live.receiveBroadcastStream().listen(
      _onLiveEvent,
      onError: _onLiveError,
      cancelOnError: false,
    );
    _started = true;
    return okVoid;
  }

  @override
  Future<Result<void>> stop() async {
    if (!_started) {
      return okVoid;
    }
    _started = false;
    await _liveSubscription?.cancel();
    _liveSubscription = null;
    if (_disposed) {
      return okVoid;
    }
    final Result<bool> stopped = await _invoke<bool>('stopLive');
    if (stopped case Err<bool>(error: final AppError e)) {
      return Err<void>(e);
    }
    return okVoid;
  }

  /// Whether the native receiver component is currently enabled. Survives
  /// reboots, because [stop] disables the component rather than ignoring it.
  Future<Result<bool>> isLiveEnabled() => _invoke<bool>('isLiveEnabled');

  /// Messages captured while nothing was listening, still waiting on disk.
  Future<Result<int>> pendingLiveCount() => _invoke<int>('pendingLiveCount');

  void _onLiveEvent(dynamic event) {
    final RawMessage? message = _messageFrom(event, IngestSource.smsRealtime);
    if (message == null) {
      _droppedEvents++;
      return;
    }
    if (_incoming.isClosed) {
      return;
    }
    _incoming.add(message);
  }

  void _onLiveError(Object error, StackTrace stackTrace) {
    // The contract says this stream never errors. A receiver that dies takes
    // the user's spending with it, so a platform hiccup is counted, not
    // propagated, and the subscription stays alive (cancelOnError: false).
    _droppedEvents++;
  }

  // --------------------------------------------------------------- backfill

  @override
  Future<Result<MessageBatch>> backfill({
    DateTime? since,
    DateTime? until,
    int limit = 200,
    String? pageToken,
  }) async {
    if (_disposed) {
      return Result<MessageBatch>.err(
        AppError.stateError('MessageSource was disposed'),
      );
    }
    if (!await isSupported()) {
      return Result<MessageBatch>.err(
        AppError.unsupportedPlatform('SMS ingestion is Android only'),
      );
    }
    if (limit <= 0) {
      return Result<MessageBatch>.err(
        AppError.invalidArgument('limit must be positive, got $limit'),
      );
    }

    final Result<Map<String, dynamic>> page =
        await _invokeMap('backfillPage', <String, dynamic>{
      'since': since == null ? null : jMillis(since),
      'until': until == null ? null : jMillis(until),
      'limit': limit.clamp(1, maxPageSize),
      'pageToken': pageToken,
    });

    return page.map((Map<String, dynamic> raw) {
      final List<RawMessage> messages =
          _messagesFrom(raw['messages'], IngestSource.smsBackfill);
      final Object? token = raw['nextPageToken'];
      return MessageBatch(
        messages: messages,
        nextPageToken: token is String && token.isNotEmpty ? token : null,
        scannedCount: jInt(raw['scannedCount']),
      );
    });
  }

  /// Runs a whole-inbox import inside an Android foreground service, so it
  /// survives the user leaving the app, and reports progress as it goes.
  ///
  /// This is the UI-facing import. [backfill] remains the contract API and the
  /// right choice for a short catch-up scan on launch.
  ///
  /// The returned stream closes when the import finishes, is cancelled, or the
  /// service gives up because nothing was listening. Every [BackfillProgress]
  /// carries [BackfillProgress.nextPageToken]: persist it, and an interrupted
  /// import resumes instead of restarting.
  Stream<BackfillProgress> importHistory({
    DateTime? since,
    DateTime? until,
    int pageSize = 200,
  }) {
    late StreamController<BackfillProgress> controller;
    StreamSubscription<dynamic>? subscription;

    Future<void> startService() async {
      final Result<bool> started =
          await _invoke<bool>('startBackfill', <String, dynamic>{
        'since': since == null ? null : jMillis(since),
        'until': until == null ? null : jMillis(until),
        'pageSize': pageSize.clamp(1, maxPageSize),
      });
      switch (started) {
        case Err<bool>(error: final AppError e):
          controller.add(BackfillProgress._error(e));
          await controller.close();
        case Ok<bool>(value: final bool ok):
          if (!ok) {
            controller.add(
              BackfillProgress._error(
                AppError.stateError(
                  'Android refused to start the import service. It can only '
                  'be started while the app is in the foreground.',
                ),
              ),
            );
            await controller.close();
          }
      }
    }

    controller = StreamController<BackfillProgress>(
      onListen: () {
        subscription = _backfill.receiveBroadcastStream().listen(
          (dynamic event) {
            final BackfillProgress? progress = _progressFrom(event);
            if (progress == null) {
              return;
            }
            controller.add(progress);
            if (progress.isTerminal) {
              unawaited(controller.close());
            }
          },
          onError: (Object error, StackTrace stackTrace) {
            controller.add(
              BackfillProgress._error(AppError.io('Import stream failed: $error')),
            );
            unawaited(controller.close());
          },
          cancelOnError: false,
        );
        // Started only after the sink exists, so the service never scans into
        // a void and gives up waiting for a listener.
        unawaited(startService());
      },
      onCancel: () async {
        await subscription?.cancel();
        subscription = null;
      },
    );

    return controller.stream;
  }

  /// Stops a running import, whether it was started by [importHistory] or is a
  /// [backfill] page still reading the cursor.
  Future<Result<bool>> cancelImport() => _invoke<bool>('cancelBackfill');

  /// Whether the foreground import service is scanning right now.
  Future<Result<bool>> isImportRunning() => _invoke<bool>('isBackfillRunning');

  // ---------------------------------------------------------------- disposal

  /// Releases the live subscription and closes [incoming].
  ///
  /// Deliberately does NOT disable the native receiver: disposing a page or
  /// rebuilding the object graph must not switch off the user's SMS tracking
  /// until the next manual launch. Use [stop] for that, and only from an
  /// explicit user action.
  @override
  Future<void> dispose() async {
    if (_disposed) {
      return;
    }
    _disposed = true;
    _started = false;
    try {
      await _liveSubscription?.cancel();
    } on PlatformException {
      // The engine is already going away; nothing left to release.
    }
    _liveSubscription = null;
    if (!_incoming.isClosed) {
      await _incoming.close();
    }
  }

  // ----------------------------------------------------------------- codecs

  Future<Result<T>> _invoke<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      final T? value = await _methods.invokeMethod<T>(method, args);
      if (value == null) {
        return Result<T>.err(
          AppError(ErrorCodes.stateError, '$method returned nothing'),
        );
      }
      return Ok<T>(value);
    } on MissingPluginException {
      return Result<T>.err(
        AppError.unsupportedPlatform('$method is not available on this platform'),
      );
    } on PlatformException catch (e, st) {
      return Result<T>.err(_platformError(method, e, st));
    }
  }

  Future<Result<Map<String, dynamic>>> _invokeMap(
    String method,
    Map<String, dynamic> args,
  ) async {
    try {
      final Map<String, dynamic>? value =
          await _methods.invokeMapMethod<String, dynamic>(method, args);
      if (value == null) {
        return Result<Map<String, dynamic>>.err(
          AppError(ErrorCodes.stateError, '$method returned nothing'),
        );
      }
      return Ok<Map<String, dynamic>>(value);
    } on MissingPluginException {
      return Result<Map<String, dynamic>>.err(
        AppError.unsupportedPlatform('$method is not available on this platform'),
      );
    } on PlatformException catch (e, st) {
      return Result<Map<String, dynamic>>.err(_platformError(method, e, st));
    }
  }

  /// Maps the plugin's error codes onto [ErrorCodes]. The platform message is
  /// safe to carry: the native side never puts message text in one.
  AppError _platformError(String method, PlatformException e, StackTrace st) {
    final String message = e.message ?? method;
    switch (e.code) {
      case 'permission_denied':
        return AppError.permissionDenied(message);
      case 'cancelled':
        return AppError.cancelled(message);
      case 'io':
        return AppError.io(message, cause: e, stackTrace: st);
      case 'conflict':
        return AppError.conflict(message);
      case 'state_error':
        return AppError.stateError(message);
      default:
        return AppError(ErrorCodes.unknown, message, cause: e, stackTrace: st);
    }
  }

  List<RawMessage> _messagesFrom(Object? raw, IngestSource source) {
    if (raw is! Iterable) {
      return const <RawMessage>[];
    }
    final List<RawMessage> out = <RawMessage>[];
    for (final Object? element in raw) {
      final RawMessage? message = _messageFrom(element, source);
      if (message == null) {
        _droppedEvents++;
        continue;
      }
      out.add(message);
    }
    return out;
  }

  /// Turns a platform map into a [RawMessage], or null when it is unreadable
  /// or fails the sender gate. Total: it never throws.
  RawMessage? _messageFrom(Object? raw, IngestSource fallbackSource) {
    if (raw is! Map) {
      return null;
    }
    final Map<String, dynamic> map = jMap(raw);

    final String header = jString(map['senderHeader']);
    if (header.isEmpty) {
      // The native gate should have dropped this already. Belt and braces:
      // an untrusted sender must never reach storage.
      return null;
    }
    final bool Function(String)? allow = senderAllow;
    if (allow != null && !allow(header)) {
      return null;
    }

    final String body = jString(map['body']);
    if (body.isEmpty) {
      return null;
    }
    final String id = jString(map['id']);
    if (id.isEmpty) {
      return null;
    }

    return RawMessage(
      id: id,
      senderRaw: jString(map['senderRaw']),
      body: body,
      receivedAt: jDate(map['receivedAt']),
      source: IngestSource.fromWire(jStringOrNull(map['source']) ?? fallbackSource.wire),
      senderHeader: header,
      bodyHash: jString(map['bodyHash']),
      simSlot: jIntOrNull(map['simSlot']),
      providerId: jIntOrNull(map['providerId']),
    );
  }

  BackfillProgress? _progressFrom(Object? raw) {
    if (raw is! Map) {
      return null;
    }
    final Map<String, dynamic> map = jMap(raw);
    final BackfillPhase? phase = BackfillPhase._fromWire(jStringOrNull(map['event']));
    if (phase == null) {
      return null;
    }
    if (phase == BackfillPhase.error) {
      return BackfillProgress._error(
        AppError(
          jStringOrNull(map['code']) ?? ErrorCodes.unknown,
          jStringOrNull(map['message']) ?? 'Import failed',
        ),
      );
    }
    final Object? token = map['nextPageToken'];
    return BackfillProgress(
      phase: phase,
      messages: _messagesFrom(map['messages'], IngestSource.smsBackfill),
      nextPageToken: token is String && token.isNotEmpty ? token : null,
      scanned: jInt(map['scanned']),
      kept: jInt(map['kept']),
      total: jIntOrNull(map['total']),
    );
  }
}

/// Where a running import has got to.
enum BackfillPhase {
  /// The service is up and the inbox has been sized.
  started('started'),

  /// One page of gated messages is attached.
  page('page'),

  /// The whole range was read.
  completed('completed'),

  /// The user (or [AndroidMessageSource.cancelImport]) stopped it.
  cancelled('cancelled'),

  /// The service gave up because nothing was listening. Resume from the last
  /// `nextPageToken`.
  detached('detached'),

  /// The import failed. See [BackfillProgress.error].
  error('error');

  const BackfillPhase(this.wire);

  final String wire;

  static BackfillPhase? _fromWire(String? wire) {
    for (final BackfillPhase phase in BackfillPhase.values) {
      if (phase.wire == wire) {
        return phase;
      }
    }
    return null;
  }

  bool get isTerminal =>
      this == BackfillPhase.completed ||
      this == BackfillPhase.cancelled ||
      this == BackfillPhase.detached ||
      this == BackfillPhase.error;
}

/// One progress event from [AndroidMessageSource.importHistory].
@immutable
class BackfillProgress {
  const BackfillProgress({
    required this.phase,
    this.messages = const <RawMessage>[],
    this.nextPageToken,
    this.scanned = 0,
    this.kept = 0,
    this.total,
    this.error,
  });

  factory BackfillProgress._error(AppError error) =>
      BackfillProgress(phase: BackfillPhase.error, error: error);

  final BackfillPhase phase;

  /// The gated messages in this page. Empty for every non-[BackfillPhase.page]
  /// event.
  final List<RawMessage> messages;

  /// Persist this on every event: an import interrupted by a process death
  /// resumes from here instead of rescanning the inbox.
  final String? nextPageToken;

  /// Inbox rows examined so far, including the personal SMS that were counted
  /// and discarded without their text being read.
  final int scanned;

  /// Gated messages produced so far.
  final int kept;

  /// Rows in range, when the provider would tell us. Null means the UI must
  /// show indeterminate progress - some OEM ROMs refuse the count query.
  final int? total;

  final AppError? error;

  bool get isTerminal => phase.isTerminal;

  /// 0.0 to 1.0, or null when [total] is unknown.
  double? get fraction {
    final int? denominator = total;
    if (denominator == null || denominator <= 0) {
      return null;
    }
    return (scanned / denominator).clamp(0.0, 1.0).toDouble();
  }

  @override
  String toString() =>
      'BackfillProgress(${phase.wire}, scanned: $scanned, kept: $kept)';
}
