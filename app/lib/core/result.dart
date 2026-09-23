import 'package:flutter/foundation.dart';

/// Stable, machine-readable error codes.
///
/// Module boundaries in this app never throw. Every fallible operation returns
/// a [Result], and every failure carries one of these codes so callers branch
/// on the code instead of string-matching a message.
abstract final class ErrorCodes {
  static const String unknown = 'unknown';
  static const String io = 'io';
  static const String database = 'database';
  static const String notFound = 'not_found';
  static const String invalidArgument = 'invalid_argument';
  static const String parseFailed = 'parse_failed';
  static const String permissionDenied = 'permission_denied';
  static const String unsupportedPlatform = 'unsupported_platform';
  static const String network = 'network';
  static const String offline = 'offline';
  static const String timeout = 'timeout';
  static const String conflict = 'conflict';
  static const String corruptRules = 'corrupt_rules';
  static const String cancelled = 'cancelled';
  static const String stateError = 'state_error';
}

/// A failure value. Never thrown across a module boundary - it is returned
/// inside an [Err].
@immutable
class AppError {
  const AppError(
    this.code,
    this.message, {
    this.cause,
    this.stackTrace,
    this.details,
  });

  /// One of [ErrorCodes]. Callers branch on this, not on [message].
  final String code;

  /// Developer-facing sentence. Never contains raw SMS text (it would leak
  /// message content into logs).
  final String message;

  /// The originating exception, when there was one.
  final Object? cause;

  final StackTrace? stackTrace;

  /// Optional structured context, e.g. `{'ruleId': 'hdfc_upi_debit'}`.
  final Map<String, Object?>? details;

  factory AppError.unknown(String message, {Object? cause, StackTrace? stackTrace}) =>
      AppError(ErrorCodes.unknown, message, cause: cause, stackTrace: stackTrace);

  factory AppError.io(String message, {Object? cause, StackTrace? stackTrace}) =>
      AppError(ErrorCodes.io, message, cause: cause, stackTrace: stackTrace);

  factory AppError.database(String message, {Object? cause, StackTrace? stackTrace}) =>
      AppError(ErrorCodes.database, message, cause: cause, stackTrace: stackTrace);

  factory AppError.notFound(String message) => AppError(ErrorCodes.notFound, message);

  factory AppError.invalidArgument(String message, {Map<String, Object?>? details}) =>
      AppError(ErrorCodes.invalidArgument, message, details: details);

  factory AppError.parseFailed(String message, {Map<String, Object?>? details}) =>
      AppError(ErrorCodes.parseFailed, message, details: details);

  factory AppError.permissionDenied(String message) =>
      AppError(ErrorCodes.permissionDenied, message);

  factory AppError.unsupportedPlatform(String message) =>
      AppError(ErrorCodes.unsupportedPlatform, message);

  factory AppError.network(String message, {Object? cause}) =>
      AppError(ErrorCodes.network, message, cause: cause);

  /// The device has no usable connection. Every caller must treat this as a
  /// normal, expected state: the app is offline-first and loses no
  /// functionality when it happens.
  factory AppError.offline([String message = 'No network connection']) =>
      AppError(ErrorCodes.offline, message);

  factory AppError.timeout(String message) => AppError(ErrorCodes.timeout, message);

  factory AppError.conflict(String message) => AppError(ErrorCodes.conflict, message);

  factory AppError.corruptRules(String message, {Object? cause}) =>
      AppError(ErrorCodes.corruptRules, message, cause: cause);

  factory AppError.cancelled([String message = 'Cancelled']) =>
      AppError(ErrorCodes.cancelled, message);

  factory AppError.stateError(String message) => AppError(ErrorCodes.stateError, message);

  factory AppError.fromJson(Map<String, dynamic> json) => AppError(
        (json['code'] as String?) ?? ErrorCodes.unknown,
        (json['message'] as String?) ?? '',
        details: (json['details'] as Map<Object?, Object?>?)?.cast<String, Object?>(),
      );

  bool get isOffline => code == ErrorCodes.offline;

  bool get isNotFound => code == ErrorCodes.notFound;

  AppError copyWith({
    String? code,
    String? message,
    Object? cause,
    StackTrace? stackTrace,
    Map<String, Object?>? details,
  }) {
    return AppError(
      code ?? this.code,
      message ?? this.message,
      cause: cause ?? this.cause,
      stackTrace: stackTrace ?? this.stackTrace,
      details: details ?? this.details,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'code': code,
        'message': message,
        if (details != null) 'details': details,
      };

  @override
  String toString() => 'AppError($code): $message${cause == null ? '' : ' <- $cause'}';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppError && other.code == code && other.message == message;

  @override
  int get hashCode => Object.hash(code, message);
}

/// The return type of every fallible operation that crosses a module boundary.
///
/// [Result] is sealed, so switching is exhaustive:
/// ```dart
/// switch (await repo.transactionById(id)) {
///   case Ok(value: final txn): render(txn);
///   case Err(error: final e):  showError(e);
/// }
/// ```
@immutable
sealed class Result<T> {
  const Result();

  /// Success.
  const factory Result.ok(T value) = Ok<T>;

  /// Failure.
  const factory Result.err(AppError error) = Err<T>;

  /// Runs [body], converting any thrown object into an [Err]. Use this at the
  /// edge of a module that calls throwing third-party code (sqlite, dart:io,
  /// json decoding) so nothing escapes as an exception.
  static Result<T> guard<T>(
    T Function() body, {
    String code = ErrorCodes.unknown,
    String? message,
  }) {
    try {
      return Ok<T>(body());
    } catch (e, st) {
      return Err<T>(AppError(code, message ?? e.toString(), cause: e, stackTrace: st));
    }
  }

  /// Async twin of [guard].
  static Future<Result<T>> guardAsync<T>(
    Future<T> Function() body, {
    String code = ErrorCodes.unknown,
    String? message,
  }) async {
    try {
      return Ok<T>(await body());
    } catch (e, st) {
      return Err<T>(AppError(code, message ?? e.toString(), cause: e, stackTrace: st));
    }
  }

  /// Turns a list of results into a result of a list, failing on the first
  /// [Err].
  static Result<List<T>> collect<T>(Iterable<Result<T>> results) {
    final out = <T>[];
    for (final r in results) {
      switch (r) {
        case Ok<T>(value: final v):
          out.add(v);
        case Err<T>(error: final e):
          return Err<List<T>>(e);
      }
    }
    return Ok<List<T>>(out);
  }

  bool get isOk => this is Ok<T>;

  bool get isErr => this is Err<T>;

  /// The value on success, `null` on failure. Ambiguous for `Result<T?>` -
  /// pattern match there instead.
  T? get valueOrNull => switch (this) {
        Ok<T>(value: final v) => v,
        Err<T>() => null,
      };

  AppError? get errorOrNull => switch (this) {
        Ok<T>() => null,
        Err<T>(error: final e) => e,
      };

  /// Value on success, [fallback] on failure.
  T getOrElse(T fallback) => switch (this) {
        Ok<T>(value: final v) => v,
        Err<T>() => fallback,
      };

  /// Value on success, `orElse(error)` on failure.
  T getOrCompute(T Function(AppError error) orElse) => switch (this) {
        Ok<T>(value: final v) => v,
        Err<T>(error: final e) => orElse(e),
      };

  /// Collapses both branches into one value.
  R fold<R>(R Function(T value) onOkValue, R Function(AppError error) onErrValue) =>
      switch (this) {
        Ok<T>(value: final v) => onOkValue(v),
        Err<T>(error: final e) => onErrValue(e),
      };

  /// Transforms the success value, propagating failure untouched.
  Result<R> map<R>(R Function(T value) transform) => switch (this) {
        Ok<T>(value: final v) => Ok<R>(transform(v)),
        Err<T>(error: final e) => Err<R>(e),
      };

  /// Chains another fallible step.
  Result<R> flatMap<R>(Result<R> Function(T value) transform) => switch (this) {
        Ok<T>(value: final v) => transform(v),
        Err<T>(error: final e) => Err<R>(e),
      };

  /// Transforms the failure, leaving success untouched.
  Result<T> mapError(AppError Function(AppError error) transform) => switch (this) {
        Ok<T>() => this,
        Err<T>(error: final e) => Err<T>(transform(e)),
      };

  /// Side effect on success. Returns `this` so calls chain.
  Result<T> onOk(void Function(T value) action) {
    if (this case Ok<T>(value: final v)) {
      action(v);
    }
    return this;
  }

  /// Side effect on failure. Returns `this` so calls chain.
  Result<T> onErr(void Function(AppError error) action) {
    if (this case Err<T>(error: final e)) {
      action(e);
    }
    return this;
  }
}

final class Ok<T> extends Result<T> {
  const Ok(this.value);

  final T value;

  @override
  String toString() => 'Ok($value)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Ok<T> && other.value == value;

  @override
  int get hashCode => Object.hash(Ok<T>, value);
}

final class Err<T> extends Result<T> {
  const Err(this.error);

  final AppError error;

  /// Re-types a failure so it can be returned from a function with a different
  /// success type: `return failure.cast<Transaction>();`
  Err<R> cast<R>() => Err<R>(error);

  @override
  String toString() => 'Err($error)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Err<T> && other.error == error;

  @override
  int get hashCode => Object.hash(Err<T>, error);
}

/// The success value for operations that return nothing: `return okVoid;`
const Result<void> okVoid = Ok<void>(null);

extension FutureResultX<T> on Future<Result<T>> {
  /// `await repo.load().mapValue((v) => v.length)`
  Future<Result<R>> mapValue<R>(R Function(T value) transform) async =>
      (await this).map(transform);

  Future<T> getOrElseAsync(T fallback) async => (await this).getOrElse(fallback);
}
