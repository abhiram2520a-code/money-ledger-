import 'package:flutter/foundation.dart';

import '../core/result.dart';
import '../models/models.dart';

/// One page of a historical backfill.
@immutable
class MessageBatch {
  const MessageBatch({
    required this.messages,
    this.nextPageToken,
    this.scannedCount = 0,
  });

  /// The messages in this page, oldest first.
  final List<RawMessage> messages;

  /// Opaque token to pass to the next `backfill` call. `null` means this was
  /// the last page.
  final String? nextPageToken;

  /// How many inbox rows were examined to produce [messages]. Larger than
  /// `messages.length` because non-financial senders are dropped before the
  /// body is ever kept.
  final int scannedCount;

  bool get hasMore => nextPageToken != null;
}

/// Ingestion of raw messages from the device.
///
/// This is the ONLY interface that touches the platform. Everything below it
/// works on [RawMessage] values and is testable with no device.
///
/// PRIVACY CONTRACT, binding on every implementation:
/// * A message whose sender does not normalise to a known financial header is
///   dropped BEFORE its body is persisted. Personal SMS never reach storage.
/// * Message bodies never leave the device, are never logged and are never
///   attached to an error.
/// * Nothing here performs network I/O. An implementation that does is wrong.
abstract interface class MessageSource {
  /// Whether this platform can supply messages at all. False on iOS and
  /// desktop, where the app still works from manually entered transactions.
  ///
  /// Never fails.
  Future<bool> isSupported();

  /// The current permission state, without prompting the user.
  ///
  /// Returns `PermissionState.unsupported` when [isSupported] is false.
  /// Fails with `ErrorCodes.unsupportedPlatform` only if the platform channel
  /// itself is unavailable.
  Future<Result<PermissionState>> permissionStatus();

  /// Prompts the user, and resolves once they answer.
  ///
  /// Returns `PermissionState.permanentlyDenied` when the OS will no longer
  /// show a prompt; the caller must then send the user to system settings
  /// instead of asking again. Never throws on denial - denial is a normal
  /// result, not an error.
  Future<Result<PermissionState>> requestPermission();

  /// Live messages, as they arrive.
  ///
  /// Emits only messages that passed the sender gate. The stream is
  /// broadcast-safe for multiple listeners, never emits an error (failures are
  /// swallowed and counted, because a crashed receiver silently loses the
  /// user's transactions), and stays open until [dispose].
  ///
  /// Emits nothing until [start] has completed successfully.
  Stream<RawMessage> get incoming;

  /// Begins delivering to [incoming].
  ///
  /// Idempotent: calling it twice is a no-op. Fails with
  /// `ErrorCodes.permissionDenied` when the permission is not granted.
  Future<Result<void>> start();

  /// Stops delivering to [incoming]. Idempotent. [incoming] stays open.
  Future<Result<void>> stop();

  /// Reads historical messages out of the device inbox, one page at a time.
  ///
  /// * [since] / [until] bound the receipt time; `null` means unbounded.
  /// * [limit] caps the messages RETURNED in this page (default 200). The
  ///   implementation may scan many more rows to fill it.
  /// * [pageToken] continues a previous call; pass `MessageBatch.nextPageToken`
  ///   and nothing else, and start with `null`.
  ///
  /// Pages are ordered oldest first so a partial backfill can be resumed
  /// without gaps. Fails with `ErrorCodes.permissionDenied` without the read
  /// permission, and with `ErrorCodes.io` if the content provider errors.
  /// Never fails merely because a page is empty.
  Future<Result<MessageBatch>> backfill({
    DateTime? since,
    DateTime? until,
    int limit = 200,
    String? pageToken,
  });

  /// Releases platform resources and closes [incoming]. Idempotent. The
  /// instance is unusable afterwards.
  Future<void> dispose();
}
