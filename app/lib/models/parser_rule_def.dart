import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'json.dart';

/// One rule from the `rules` array of `rules/parser_rules.json`.
///
/// Rules are DATA, never compiled-in code. Bank SMS formats change without
/// notice; as data a fix ships in minutes through the config server and the
/// app re-parses the affected messages locally. Until such an update arrives
/// (or if it never does, because the user is offline forever) the bundled pack
/// in `assets/rules/` is used and the app is fully functional.
///
/// The regexes use named capture groups. The recognised names are exactly:
/// `amount`, `direction_word`, `date`, `account_tail`, `card_tail`,
/// `merchant`, `vpa`, `ref`, `balance`. Every `body_pattern` must contain
/// `(?<amount>` - `tools/validate_rules.dart` fails the build otherwise,
/// because a rule that cannot find the amount can only produce a broken entry.
@immutable
class ParserRuleDef {
  const ParserRuleDef({
    required this.id,
    required this.senderPattern,
    required this.bodyPattern,
    required this.direction,
    this.issuer = '',
    this.channel = TxnChannel.unknown,
    this.txnType = TxnType.transaction,
    this.priority = 0,
    this.dateFormats = const <String>[],
    this.forcedCategoryPath,
    this.comment,
  });

  factory ParserRuleDef.fromJson(Map<String, dynamic> json) => ParserRuleDef(
        id: jString(json['id']),
        senderPattern: jString(json['sender_pattern']),
        bodyPattern: jString(json['body_pattern']),
        direction: jString(json['direction'], fallback: directionInferWire),
        issuer: jString(json['issuer']),
        channel: TxnChannel.fromWire(jStringOrNull(json['channel'])),
        txnType: TxnType.fromWire(jStringOrNull(json['txn_type'])),
        priority: jInt(json['priority']),
        dateFormats: jStringList(json['date_formats']),
        forcedCategoryPath: jStringOrNull(json['forced_category']),
        comment: jStringOrNull(json['_comment']),
      );

  /// Stable, never reused. Written onto every transaction this rule produces,
  /// so a later pack can re-parse exactly the affected rows.
  final String id;

  /// Matched against the NORMALISED TRAI sender header.
  final String senderPattern;

  /// Matched case-insensitively against the message body.
  final String bodyPattern;

  /// `'debit'`, `'credit'`, or [directionInferWire] to read the
  /// `direction_word` group. Kept as a String because `'infer'` is not a
  /// [TxnDirection] - see [resolvedDirection].
  final String direction;

  /// Display name of the bank or app.
  final String issuer;

  final TxnChannel channel;

  /// Only `TxnType.createsLedgerEntry` values ever reach the ledger. Rules with
  /// `otp`, `promo` or `balance_info` exist precisely so those messages are
  /// classified instead of guessed at.
  final TxnType txnType;

  /// Higher wins. Rules are tried in descending priority and the first whose
  /// sender AND body both match wins; ties break on [id] for determinism.
  final int priority;

  /// Ordered patterns tried against the `date` group.
  final List<String> dateFormats;

  /// Forces a category regardless of merchant, e.g. an ATM rule forcing a
  /// transfer path. Validated against `categories.json`.
  final String? forcedCategoryPath;

  final String? comment;

  /// The fixed direction, or `null` when the rule defers to `direction_word`.
  TxnDirection? get resolvedDirection => TxnDirection.fromWire(direction);

  bool get infersDirection => resolvedDirection == null;

  ParserRuleDef copyWith({
    String? id,
    String? senderPattern,
    String? bodyPattern,
    String? direction,
    String? issuer,
    TxnChannel? channel,
    TxnType? txnType,
    int? priority,
    List<String>? dateFormats,
    String? forcedCategoryPath,
    String? comment,
  }) {
    return ParserRuleDef(
      id: id ?? this.id,
      senderPattern: senderPattern ?? this.senderPattern,
      bodyPattern: bodyPattern ?? this.bodyPattern,
      direction: direction ?? this.direction,
      issuer: issuer ?? this.issuer,
      channel: channel ?? this.channel,
      txnType: txnType ?? this.txnType,
      priority: priority ?? this.priority,
      dateFormats: dateFormats ?? this.dateFormats,
      forcedCategoryPath: forcedCategoryPath ?? this.forcedCategoryPath,
      comment: comment ?? this.comment,
    );
  }

  /// Writes the `rules/parser_rules.json` shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'issuer': issuer,
        'sender_pattern': senderPattern,
        'body_pattern': bodyPattern,
        'direction': direction,
        'channel': channel.wire,
        'txn_type': txnType.wire,
        'priority': priority,
        if (dateFormats.isNotEmpty) 'date_formats': dateFormats,
        if (forcedCategoryPath != null) 'forced_category': forcedCategoryPath,
        if (comment != null) '_comment': comment,
      };

  @override
  String toString() => 'ParserRuleDef($id, ${channel.wire}, p$priority)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParserRuleDef &&
          other.id == id &&
          other.senderPattern == senderPattern &&
          other.bodyPattern == bodyPattern &&
          other.direction == direction &&
          other.issuer == issuer &&
          other.channel == channel &&
          other.txnType == txnType &&
          other.priority == priority &&
          listEquals(other.dateFormats, dateFormats) &&
          other.forcedCategoryPath == forcedCategoryPath &&
          other.comment == comment;

  @override
  int get hashCode => Object.hash(
        id,
        senderPattern,
        bodyPattern,
        direction,
        issuer,
        channel,
        txnType,
        priority,
        Object.hashAll(dateFormats),
        forcedCategoryPath,
        comment,
      );
}
