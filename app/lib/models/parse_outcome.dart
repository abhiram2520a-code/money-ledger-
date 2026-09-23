import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'json.dart';
import 'parsed_message.dart';

/// What the parser did with one message.
///
/// Rejecting an OTP or a promo is a SUCCESSFUL parse, not an error, so the
/// parser returns this instead of `Result<ParsedMessage>`. Errors are reserved
/// for the parser genuinely failing (a corrupt rules pack).
@immutable
class ParseOutcome {
  const ParseOutcome({
    required this.status,
    this.message,
    this.classifiedAs = TxnType.unknown,
    this.ruleId,
    this.reason = '',
    this.partialFields = const <String, String>{},
  });

  /// A rule matched and produced fields.
  factory ParseOutcome.parsed(ParsedMessage message) => ParseOutcome(
        status: ParseStatus.parsed,
        message: message,
        classifiedAs: message.txnType,
        ruleId: message.ruleId,
      );

  /// The message is deliberately not a transaction. [reason] is a short,
  /// content-free note such as `reject:\bOTP\b` or `rule:hdfc_promo`.
  factory ParseOutcome.rejected(TxnType classifiedAs, String reason, {String? ruleId}) =>
      ParseOutcome(
        status: ParseStatus.rejected,
        classifiedAs: classifiedAs,
        reason: reason,
        ruleId: ruleId,
      );

  /// Trusted sender, no rule matched the body. These queue up and are exactly
  /// the corpus the next rules pack is written against.
  factory ParseOutcome.noRuleMatched({String reason = ''}) =>
      ParseOutcome(status: ParseStatus.noRuleMatched, reason: reason);

  /// A rule matched but the fields contradict each other. Never posted
  /// silently; [partialFields] is what the UI shows when asking the user.
  factory ParseOutcome.ambiguous(
    String reason, {
    String? ruleId,
    Map<String, String> partialFields = const <String, String>{},
  }) =>
      ParseOutcome(
        status: ParseStatus.ambiguous,
        reason: reason,
        ruleId: ruleId,
        partialFields: partialFields,
      );

  /// The sender is not a known financial sender (a 10-digit number, an unknown
  /// shortcode). The body is discarded without being parsed.
  factory ParseOutcome.untrustedSender({String reason = 'sender not in registry'}) =>
      ParseOutcome(status: ParseStatus.untrustedSender, reason: reason);

  factory ParseOutcome.fromJson(Map<String, dynamic> json) => ParseOutcome(
        status: ParseStatus.fromWire(jStringOrNull(json['status'])),
        message: json['message'] == null
            ? null
            : ParsedMessage.fromJson(jMap(json['message'])),
        classifiedAs: TxnType.fromWire(jStringOrNull(json['classifiedAs'])),
        ruleId: jStringOrNull(json['ruleId']),
        reason: jString(json['reason']),
        partialFields: jMap(json['partialFields'])
            .map((String k, Object? v) => MapEntry<String, String>(k, jString(v))),
      );

  final ParseStatus status;

  /// Non-null if and only if [status] is `ParseStatus.parsed`.
  final ParsedMessage? message;

  /// What the message turned out to be, including for rejections.
  final TxnType classifiedAs;

  /// The rule involved, when one was.
  final String? ruleId;

  /// Short, content-free explanation. Safe to store and to show in a debug
  /// screen; never contains message text.
  final String reason;

  /// Whatever could be extracted from an ambiguous message, for the review UI.
  final Map<String, String> partialFields;

  bool get isParsed => status == ParseStatus.parsed && message != null;

  /// The state this outcome writes back onto the `RawMessage`.
  ParseState get resultingState => switch (status) {
        ParseStatus.parsed => ParseState.parsed,
        ParseStatus.rejected => switch (classifiedAs) {
            TxnType.otp => ParseState.rejectedOtp,
            TxnType.promo => ParseState.rejectedPromo,
            _ => ParseState.rejectedNonFinancial,
          },
        ParseStatus.noRuleMatched => ParseState.noRuleMatched,
        ParseStatus.ambiguous => ParseState.quarantined,
        ParseStatus.untrustedSender => ParseState.quarantined,
      };

  Map<String, dynamic> toJson() => <String, dynamic>{
        'status': status.wire,
        'message': message?.toJson(),
        'classifiedAs': classifiedAs.wire,
        'ruleId': ruleId,
        'reason': reason,
        'partialFields': partialFields,
      };

  ParseOutcome copyWith({
    ParseStatus? status,
    ParsedMessage? message,
    TxnType? classifiedAs,
    String? ruleId,
    String? reason,
    Map<String, String>? partialFields,
  }) {
    return ParseOutcome(
      status: status ?? this.status,
      message: message ?? this.message,
      classifiedAs: classifiedAs ?? this.classifiedAs,
      ruleId: ruleId ?? this.ruleId,
      reason: reason ?? this.reason,
      partialFields: partialFields ?? this.partialFields,
    );
  }

  @override
  String toString() => 'ParseOutcome(${status.wire}, ${classifiedAs.wire}, $reason)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParseOutcome &&
          other.status == status &&
          other.message == message &&
          other.classifiedAs == classifiedAs &&
          other.ruleId == ruleId &&
          other.reason == reason &&
          mapEquals(other.partialFields, partialFields);

  @override
  int get hashCode => Object.hash(
        status,
        message,
        classifiedAs,
        ruleId,
        reason,
        Object.hashAllUnordered(partialFields.entries.map((e) => Object.hash(e.key, e.value))),
      );
}
