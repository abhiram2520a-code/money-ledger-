/// The interfaces the modules implement, so each can be built and tested
/// independently:
///
/// ```dart
/// import 'package:ledger/contracts/contracts.dart';
/// ```
///
/// The pipeline is a straight line, and each arrow is one of these interfaces:
///
///   MessageSource -> RawMessage
///        -> SmsParser (needs RulesProvider) -> ParseOutcome / ParsedMessage
///        -> Categorizer (needs RulesProvider) -> CategoryResult
///        -> LedgerRepository -> Transaction
///
/// Two properties hold across all of them:
/// * No method throws. Failures are `Result` values carrying an `ErrorCodes`
///   code.
/// * Only `MessageSource` touches the platform and only
///   `RulesProvider.checkForUpdate` touches the network. Everything else runs
///   offline, on-device, forever.
library;

export 'categorizer.dart';
export 'ledger_repository.dart';
export 'message_source.dart';
export 'rules_provider.dart';
export 'sms_parser.dart';
