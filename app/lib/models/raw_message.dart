import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'json.dart';

/// One ingested message, exactly as it arrived, plus what the pipeline has
/// decided about it.
///
/// PRIVACY: [body] is the only field in the app that holds message text. It
/// never leaves the device, is never logged, and is never sent to the config
/// server. Anything that crosses a process or network boundary carries
/// [bodyHash] instead.
@immutable
class RawMessage {
  const RawMessage({
    required this.id,
    required this.senderRaw,
    required this.body,
    required this.receivedAt,
    required this.source,
    this.senderHeader,
    this.bodyHash = '',
    this.simSlot,
    this.providerId,
    this.parseState = ParseState.pending,
    this.parserVersion,
    this.ruleId,
    this.txnId,
    this.parseReason,
  });

  factory RawMessage.fromJson(Map<String, dynamic> json) => RawMessage(
        id: jString(json['id']),
        senderRaw: jString(json['senderRaw']),
        body: jString(json['body']),
        receivedAt: jDate(json['receivedAt']),
        source: IngestSource.fromWire(jStringOrNull(json['source'])),
        senderHeader: jStringOrNull(json['senderHeader']),
        bodyHash: jString(json['bodyHash']),
        simSlot: jIntOrNull(json['simSlot']),
        providerId: jIntOrNull(json['providerId']),
        parseState: ParseState.fromWire(jStringOrNull(json['parseState'])),
        parserVersion: jIntOrNull(json['parserVersion']),
        ruleId: jStringOrNull(json['ruleId']),
        txnId: jStringOrNull(json['txnId']),
        parseReason: jStringOrNull(json['parseReason']),
      );

  /// Locally generated, sortable, unique. Never a provider id.
  final String id;

  /// The sender exactly as the platform reported it, e.g. `AX-HDFCBK-S`.
  final String senderRaw;

  /// The message text. See the privacy note on the class.
  final String body;

  final DateTime receivedAt;

  final IngestSource source;

  /// [senderRaw] with the telco routing prefix and the TCCCPR category suffix
  /// removed and upper-cased, e.g. `HDFCBK`. `null` means the sender could not
  /// be normalised to a known financial header, which is a hard reject for
  /// parsing.
  final String? senderHeader;

  /// SHA-256 over the normalised body. The dedupe key, and the only form of
  /// the message that may be logged.
  final String bodyHash;

  /// Dual-SIM slot, when the platform reports one.
  final int? simSlot;

  /// `content://sms/_id` when the message came from the inbox backfill. The
  /// authoritative tiebreak when the same message arrives both live and in a
  /// backfill.
  final int? providerId;

  final ParseState parseState;

  /// The rules-pack version that produced [parseState]. A sweep re-parses rows
  /// whose version is older than the current pack.
  final int? parserVersion;

  /// The rule that matched, if any.
  final String? ruleId;

  /// The transaction this message produced, if any.
  final String? txnId;

  /// Short machine-ish note explaining a non-parsed state, e.g.
  /// `reject:\bOTP\b`. Never contains message text.
  final String? parseReason;

  bool get hasTrustedSender => senderHeader != null && senderHeader!.isNotEmpty;

  RawMessage copyWith({
    String? id,
    String? senderRaw,
    String? body,
    DateTime? receivedAt,
    IngestSource? source,
    String? senderHeader,
    String? bodyHash,
    int? simSlot,
    int? providerId,
    ParseState? parseState,
    int? parserVersion,
    String? ruleId,
    String? txnId,
    String? parseReason,
  }) {
    return RawMessage(
      id: id ?? this.id,
      senderRaw: senderRaw ?? this.senderRaw,
      body: body ?? this.body,
      receivedAt: receivedAt ?? this.receivedAt,
      source: source ?? this.source,
      senderHeader: senderHeader ?? this.senderHeader,
      bodyHash: bodyHash ?? this.bodyHash,
      simSlot: simSlot ?? this.simSlot,
      providerId: providerId ?? this.providerId,
      parseState: parseState ?? this.parseState,
      parserVersion: parserVersion ?? this.parserVersion,
      ruleId: ruleId ?? this.ruleId,
      txnId: txnId ?? this.txnId,
      parseReason: parseReason ?? this.parseReason,
    );
  }

  /// Includes [body]. Only ever used for on-device storage - never for a
  /// network payload.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'senderRaw': senderRaw,
        'body': body,
        'receivedAt': jMillis(receivedAt),
        'source': source.wire,
        'senderHeader': senderHeader,
        'bodyHash': bodyHash,
        'simSlot': simSlot,
        'providerId': providerId,
        'parseState': parseState.wire,
        'parserVersion': parserVersion,
        'ruleId': ruleId,
        'txnId': txnId,
        'parseReason': parseReason,
      };

  @override
  String toString() => 'RawMessage($id, $senderHeader, ${parseState.wire})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RawMessage &&
          other.id == id &&
          other.senderRaw == senderRaw &&
          other.body == body &&
          jTimeEquals(other.receivedAt, receivedAt) &&
          other.source == source &&
          other.senderHeader == senderHeader &&
          other.bodyHash == bodyHash &&
          other.simSlot == simSlot &&
          other.providerId == providerId &&
          other.parseState == parseState &&
          other.parserVersion == parserVersion &&
          other.ruleId == ruleId &&
          other.txnId == txnId &&
          other.parseReason == parseReason;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        id,
        senderRaw,
        body,
        jTimeHash(receivedAt),
        source,
        senderHeader,
        bodyHash,
        simSlot,
        providerId,
        parseState,
        parserVersion,
        ruleId,
        txnId,
        parseReason,
      ]);
}
