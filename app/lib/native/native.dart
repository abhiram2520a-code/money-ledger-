/// The platform layer. One import:
///
/// ```dart
/// import 'package:ledger/native/native.dart';
/// ```
///
/// This is the only part of `lib/` that talks to Android, and it implements
/// exactly one contract, [MessageSource]. Everything above it works on
/// `RawMessage` values and runs with no device at all.
///
/// It performs no network I/O. The app ingests, parses, categorises and
/// reports with the config server permanently unreachable; the server only
/// ever ships a newer `rules/` pack.
library;

export 'message_source.dart';
