/// The categorisation engine: which of the user's categories a parsed message
/// belongs to, and why.
///
/// ```dart
/// import 'package:ledger/categorize/categorize.dart';
///
/// final categorizer = CascadeCategorizer();
/// await categorizer.load(ruleSet, userRules: storedRules);
/// final result = categorizer.categorize(parsed);
/// ```
///
/// Everything in here is on-device, synchronous and total. There is no
/// network call, no model download and no cloud lookup, so the engine behaves
/// exactly the same on a phone in flight mode as on a phone with a config
/// server reachable - the only thing the server ever supplies is a newer
/// `rules/` pack.
library;

export 'cascade_categorizer.dart';
export 'channel_signals.dart';
export 'merchant_index.dart';
export 'merchant_normalizer.dart';
export 'user_rules.dart';
export 'vpa_heuristics.dart';
