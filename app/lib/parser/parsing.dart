/// The SMS parsing engine. One import gives you the whole module:
///
/// ```dart
/// import 'package:ledger/parser/parsing.dart';
/// ```
///
/// The pipeline, in order:
///
///   normalizeBody        collapse newlines, strip zero-width characters
///   TrustGate.screen     registered sender? OTP / promo / failed / balance?
///   RuleBasedSmsParser   first matching rule by priority, then fields
///   DedupIndex           one economic event, however many SMS reported it
///
/// `RuleLoader` holds the pack in force and guarantees there is always one:
/// a malformed or newer-schema download is salvaged or discarded, never
/// adopted, so a device that never reaches the config server keeps parsing
/// with the pack bundled in the APK.
library;

export 'dedup.dart';
export 'normalize.dart';
export 'parser.dart';
export 'rule_loader.dart';
export 'trust_gate.dart';
