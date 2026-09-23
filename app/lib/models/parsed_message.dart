import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'json.dart';
import 'money.dart';

/// The result of turning one raw SMS into fields. Purely what the message
/// said - no categorisation, no account matching, no ledger semantics.
///
/// A [ParsedMessage] exists only when a rule matched and an amount was found.
/// Failures and deliberate rejections are `ParseOutcome`s instead, so an
/// absent amount can never masquerade as a zero-rupee transaction.
@immutable
class ParsedMessage {
  const ParsedMessage({
    required this.amount,
    required this.direction,
    required this.occurredAt,
    required this.channel,
    required this.ruleId,
    required this.ruleVersion,
    required this.confidence,
    this.txnType = TxnType.transaction,
    this.datePrecision = DatePrecision.receivedFallback,
    this.accountTail,
    this.cardTail,
    this.merchantRaw,
    this.vpa,
    this.ref,
    this.balance,
    this.issuer,
    this.rawMessageId,
    this.forcedCategoryPath,
    this.dueDate,
  });

  factory ParsedMessage.fromJson(Map<String, dynamic> json) => ParsedMessage(
        amount: Money.fromJson(json['amount']),
        direction: TxnDirection.fromWire(jStringOrNull(json['direction'])) ??
            TxnDirection.debit,
        occurredAt: jDate(json['occurredAt']),
        channel: TxnChannel.fromWire(jStringOrNull(json['channel'])),
        ruleId: jString(json['ruleId']),
        ruleVersion: jInt(json['ruleVersion']),
        confidence: jDouble(json['confidence']),
        txnType: TxnType.fromWire(jStringOrNull(json['txnType'])),
        datePrecision: DatePrecision.fromWire(jStringOrNull(json['datePrecision'])),
        accountTail: jStringOrNull(json['accountTail']),
        cardTail: jStringOrNull(json['cardTail']),
        merchantRaw: jStringOrNull(json['merchantRaw']),
        vpa: jStringOrNull(json['vpa']),
        ref: jStringOrNull(json['ref']),
        balance: json['balance'] == null ? null : Money.fromJson(json['balance']),
        issuer: jStringOrNull(json['issuer']),
        rawMessageId: jStringOrNull(json['rawMessageId']),
        forcedCategoryPath: jStringOrNull(json['forcedCategoryPath']),
        dueDate: jDateOrNull(json['dueDate']),
      );

  /// Always a positive magnitude. The sign lives in [direction].
  final Money amount;

  final TxnDirection direction;

  /// When the money moved, as stated by the message. Falls back to the message
  /// receipt time, in which case [datePrecision] says so.
  final DateTime occurredAt;

  final TxnChannel channel;

  /// The `id` of the rule in `parser_rules.json` that produced this. Stored on
  /// the transaction so a rules update can re-parse exactly the messages whose
  /// rule changed.
  final String ruleId;

  /// The `version` of the rules pack that rule came from.
  final int ruleVersion;

  /// 0.0 - 1.0. Below the review threshold the transaction is created with
  /// `TxnStatus.needsReview` rather than counted silently.
  final double confidence;

  /// Whether this is a settled transaction, a bill reminder, a balance alert,
  /// a promo or an OTP. Only `TxnType.createsLedgerEntry` values ever reach the
  /// ledger.
  final TxnType txnType;

  final DatePrecision datePrecision;

  /// Last digits of the bank account, e.g. `1234` from `A/c XX1234`.
  final String? accountTail;

  /// Last digits of the card, when the message names one. A card debit and the
  /// later bill payment from the bank account are two different accounts;
  /// keeping both tails is what stops the bill being counted twice.
  final String? cardTail;

  /// The merchant / counterparty string exactly as the message wrote it
  /// (`SWIGGYUPI`, `RAZ*SampleFood`, `EAZYDINE0000000`). Normalisation and
  /// lookup are the categoriser's job, not the parser's.
  final String? merchantRaw;

  /// Full VPA when present, e.g. `swiggy@axisbank`. The handle alone
  /// (`@okaxis`) identifies the payment app, never the merchant.
  final String? vpa;

  /// UPI RRN / UTR / IMPS ref / card auth code. The only stable identity of a
  /// money EVENT as opposed to a message, and therefore the key that
  /// distinguishes a duplicate delivery from two genuine payments of the same
  /// amount minutes apart.
  final String? ref;

  /// `Avl Bal` when the message carried one. Ground truth for reconciliation;
  /// never itself a transaction amount.
  final Money? balance;

  /// Display name of the bank or app, from the matching rule.
  final String? issuer;

  /// The `RawMessage.id` this came from.
  final String? rawMessageId;

  /// A `forced_category` declared on the matching rule (an ATM rule forcing
  /// `transfer/cash_withdrawal`, for example). The categoriser honours it
  /// before consulting the merchant dictionary.
  final String? forcedCategoryPath;

  /// For `TxnType.billReminder` and `TxnType.preDebitNotice`: the date the
  /// money is due to move. Never the transaction date.
  final DateTime? dueDate;

  /// A transaction is only posted silently at or above this confidence.
  static const double reviewThreshold = 0.70;

  bool get needsReview => confidence < reviewThreshold;

  /// True when the message named a card rather than a bank account.
  bool get isCardTransaction => cardTail != null && cardTail!.isNotEmpty;

  ParsedMessage copyWith({
    Money? amount,
    TxnDirection? direction,
    DateTime? occurredAt,
    TxnChannel? channel,
    String? ruleId,
    int? ruleVersion,
    double? confidence,
    TxnType? txnType,
    DatePrecision? datePrecision,
    String? accountTail,
    String? cardTail,
    String? merchantRaw,
    String? vpa,
    String? ref,
    Money? balance,
    String? issuer,
    String? rawMessageId,
    String? forcedCategoryPath,
    DateTime? dueDate,
  }) {
    return ParsedMessage(
      amount: amount ?? this.amount,
      direction: direction ?? this.direction,
      occurredAt: occurredAt ?? this.occurredAt,
      channel: channel ?? this.channel,
      ruleId: ruleId ?? this.ruleId,
      ruleVersion: ruleVersion ?? this.ruleVersion,
      confidence: confidence ?? this.confidence,
      txnType: txnType ?? this.txnType,
      datePrecision: datePrecision ?? this.datePrecision,
      accountTail: accountTail ?? this.accountTail,
      cardTail: cardTail ?? this.cardTail,
      merchantRaw: merchantRaw ?? this.merchantRaw,
      vpa: vpa ?? this.vpa,
      ref: ref ?? this.ref,
      balance: balance ?? this.balance,
      issuer: issuer ?? this.issuer,
      rawMessageId: rawMessageId ?? this.rawMessageId,
      forcedCategoryPath: forcedCategoryPath ?? this.forcedCategoryPath,
      dueDate: dueDate ?? this.dueDate,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'amount': amount.toJson(),
        'direction': direction.wire,
        'occurredAt': jMillis(occurredAt),
        'channel': channel.wire,
        'ruleId': ruleId,
        'ruleVersion': ruleVersion,
        'confidence': confidence,
        'txnType': txnType.wire,
        'datePrecision': datePrecision.wire,
        'accountTail': accountTail,
        'cardTail': cardTail,
        'merchantRaw': merchantRaw,
        'vpa': vpa,
        'ref': ref,
        'balance': balance?.toJson(),
        'issuer': issuer,
        'rawMessageId': rawMessageId,
        'forcedCategoryPath': forcedCategoryPath,
        'dueDate': dueDate == null ? null : jMillis(dueDate!),
      };

  @override
  String toString() =>
      'ParsedMessage(${amount.format()} ${direction.wire} ${channel.wire} '
      '${merchantRaw ?? vpa ?? '-'} rule=$ruleId conf=$confidence)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ParsedMessage &&
          other.amount == amount &&
          other.direction == direction &&
          jTimeEquals(other.occurredAt, occurredAt) &&
          other.channel == channel &&
          other.ruleId == ruleId &&
          other.ruleVersion == ruleVersion &&
          other.confidence == confidence &&
          other.txnType == txnType &&
          other.datePrecision == datePrecision &&
          other.accountTail == accountTail &&
          other.cardTail == cardTail &&
          other.merchantRaw == merchantRaw &&
          other.vpa == vpa &&
          other.ref == ref &&
          other.balance == balance &&
          other.issuer == issuer &&
          other.rawMessageId == rawMessageId &&
          other.forcedCategoryPath == forcedCategoryPath &&
          jTimeEquals(other.dueDate, dueDate);

  @override
  int get hashCode => Object.hashAll(<Object?>[
        amount,
        direction,
        jTimeHash(occurredAt),
        channel,
        ruleId,
        ruleVersion,
        confidence,
        txnType,
        datePrecision,
        accountTail,
        cardTail,
        merchantRaw,
        vpa,
        ref,
        balance,
        issuer,
        rawMessageId,
        forcedCategoryPath,
        jTimeHash(dueDate),
      ]);
}
