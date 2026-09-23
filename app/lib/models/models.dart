/// The shared data layer. Every module imports this one file:
///
/// ```dart
/// import 'package:ledger/models/models.dart';
/// ```
///
/// Two rules hold the whole app together:
///
/// 1. Money is an integer count of PAISE ([Money]). Never a double.
/// 2. Only `CategoryKind.expense` is spending. Transfers and investments move
///    the user's own money and are excluded from every spend total.
library;

export 'account.dart';
export 'bill.dart';
export 'category_def.dart';
export 'category_result.dart';
export 'enums.dart';
export 'json.dart';
export 'merchant_entry.dart';
export 'money.dart';
export 'parse_outcome.dart';
export 'parsed_message.dart';
export 'parser_rule_def.dart';
export 'raw_message.dart';
export 'rule_set.dart';
export 'transaction.dart';
export 'user_rule.dart';
