import '../core/result.dart';
import '../models/models.dart';

/// Supplies the [RuleSet] that the parser and categoriser run on.
///
/// The offline contract, which every implementation must honour:
/// * [loadBundled] reads `assets/rules/*.json` from inside the APK. It
///   performs NO network I/O and cannot fail for network reasons. The app is
///   fully functional on a device that never has a connection.
/// * [current] is available immediately after [load] and is never empty on a
///   healthy build.
/// * [checkForUpdate] is the ONLY method that touches the network, is always
///   optional, and returns `Ok(null)` when there is nothing new. Being offline
///   is `Err` with `ErrorCodes.offline`, which callers treat as routine and
///   never surface as an error state.
/// * A downloaded pack is adopted only when it validates AND its version is
///   strictly greater than the current one. A pack that fails validation is
///   discarded and the previous rules stay in force - a bad server response
///   can never break parsing on the device.
abstract interface class RulesProvider {
  /// The rules in force. `RuleSet.empty` before [load] completes.
  RuleSet get current;

  /// Shorthand for `current.version`.
  int get version;

  /// Emits every time the rules in force change: once after [load], and again
  /// after a successful [applyUpdate]. Emits the current value on listen.
  Stream<RuleSet> get changes;

  /// Loads the rules to use now: the cached downloaded pack when it is valid
  /// and newer, otherwise the bundled one.
  ///
  /// Never performs network I/O, so it is safe on the startup path. Fails with
  /// `ErrorCodes.corruptRules` only if the BUNDLED assets are unreadable,
  /// which is a broken build, not a runtime condition.
  Future<Result<RuleSet>> load();

  /// Reads the pack compiled into the APK, ignoring any cached download.
  /// The recovery path when a downloaded pack misbehaves.
  Future<Result<RuleSet>> loadBundled();

  /// Asks the config server whether a newer pack exists.
  ///
  /// Returns `Ok(null)` when the server has nothing newer. Fails with
  /// `ErrorCodes.offline` with no connection, `ErrorCodes.timeout` past
  /// [timeout], and `ErrorCodes.corruptRules` when the response does not
  /// validate. None of these change the rules in force.
  ///
  /// Sends no user data: no transactions, no message text, no device id, no
  /// identifier of any kind. The request carries the current rules version and
  /// the app version, and nothing else.
  Future<Result<RuleSet?>> checkForUpdate({
    Duration timeout = const Duration(seconds: 10),
  });

  /// Validates [rules], persists them and makes them current, emitting on
  /// [changes].
  ///
  /// Fails with `ErrorCodes.corruptRules` when a pattern does not compile, a
  /// merchant points at a category that does not exist, or the version is not
  /// greater than [version] - the same checks `tools/validate_rules.dart` runs
  /// in CI, repeated on-device because the server is not trusted.
  Future<Result<void>> applyUpdate(RuleSet rules);

  /// Discards any downloaded pack and reverts to the bundled one.
  Future<Result<RuleSet>> resetToBundled();
}
