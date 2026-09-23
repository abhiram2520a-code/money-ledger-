import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'json.dart';
import 'money.dart';

/// A bank account, card, wallet or cash pocket the user owns.
///
/// Accounts are what make transfers work. Money moving between two accounts in
/// this table is the user's own money: a credit-card bill payment, a
/// self-transfer, an ATM withdrawal and a wallet top-up all move between
/// accounts and none of them is spending. Without first-class accounts every
/// one of those is booked twice.
@immutable
class Account {
  const Account({
    required this.id,
    required this.type,
    required this.displayName,
    required this.createdAt,
    required this.updatedAt,
    this.institution,
    this.institutionId,
    this.tail,
    this.currency = Money.inr,
    this.balance,
    this.balanceAsOf,
    this.creditLimit,
    this.statementDay,
    this.dueDayOffset,
    this.isArchived = false,
    this.isTracked = true,
    this.icon,
    this.colorValue,
    this.sortOrder = 0,
  });

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: jString(json['id']),
        type: AccountType.fromWire(jStringOrNull(json['type'])),
        displayName: jString(json['displayName']),
        createdAt: jDate(json['createdAt']),
        updatedAt: jDate(json['updatedAt']),
        institution: jStringOrNull(json['institution']),
        institutionId: jStringOrNull(json['institutionId']),
        tail: jStringOrNull(json['tail']),
        currency: jString(json['currency'], fallback: Money.inr),
        balance: json['balance'] == null ? null : Money.fromJson(json['balance']),
        balanceAsOf: jDateOrNull(json['balanceAsOf']),
        creditLimit:
            json['creditLimit'] == null ? null : Money.fromJson(json['creditLimit']),
        statementDay: jIntOrNull(json['statementDay']),
        dueDayOffset: jIntOrNull(json['dueDayOffset']),
        isArchived: jBool(json['isArchived']),
        isTracked: jBool(json['isTracked'], fallback: true),
        icon: jStringOrNull(json['icon']),
        colorValue: jIntOrNull(json['colorValue']),
        sortOrder: jInt(json['sortOrder']),
      );

  final String id;

  final AccountType type;

  /// What the user sees: `HDFC Savings 1234`.
  final String displayName;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// Display name of the bank or issuer: `HDFC Bank`.
  final String? institution;

  /// Stable issuer key used by the rules pack: `HDFC`.
  final String? institutionId;

  /// Normalised last digits as they appear in SMS, e.g. `1234`. This is how a
  /// parsed message is matched to an account, so it is stored without the
  /// `XX`/`x` prefix banks vary on.
  final String? tail;

  final String currency;

  /// Last known balance. Ground truth from `Avl Bal` in an SMS, not a running
  /// total the app computed - those disagree, and the bank is right.
  final Money? balance;

  final DateTime? balanceAsOf;

  /// Credit cards only.
  final Money? creditLimit;

  /// Day of month the statement is generated (1-31). Credit cards only.
  final int? statementDay;

  /// Days after the statement that payment is due. Credit cards only.
  final int? dueDayOffset;

  final bool isArchived;

  /// False for a placeholder account the app inferred but the user has not
  /// confirmed. Untracked accounts still anchor transfers, but are hidden from
  /// the accounts screen.
  final bool isTracked;

  /// Material icon name, matching the convention in `rules/categories.json`.
  final String? icon;

  /// ARGB int, so this model stays free of `dart:ui`.
  final int? colorValue;

  final int sortOrder;

  /// A balance on a liability is money owed, so a debit increases it.
  bool get isLiability => type.isLiability;

  /// Available credit, when both numbers are known.
  Money? get availableCredit {
    final limit = creditLimit;
    final used = balance;
    if (limit == null || used == null) return null;
    return Money(limit.paise - used.paise.abs(), currency: currency);
  }

  /// Both tails present and equal, after stripping the `XX`/`x`/`*` masking
  /// characters banks use inconsistently.
  bool matchesTail(String? candidate) {
    final mine = normalizeTail(tail);
    final theirs = normalizeTail(candidate);
    if (mine == null || theirs == null) return false;
    return mine == theirs;
  }

  /// `XX1234`, `xx1234`, `**1234`, `A/c 1234` -> `1234`. `null` when there are
  /// no digits to compare, because matching on an empty tail would attach
  /// every message to every account.
  static String? normalizeTail(String? raw) {
    if (raw == null) return null;
    final digits = raw.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    return digits.length <= 6 ? digits : digits.substring(digits.length - 6);
  }

  Account copyWith({
    String? id,
    AccountType? type,
    String? displayName,
    DateTime? createdAt,
    DateTime? updatedAt,
    String? institution,
    String? institutionId,
    String? tail,
    String? currency,
    Money? balance,
    DateTime? balanceAsOf,
    Money? creditLimit,
    int? statementDay,
    int? dueDayOffset,
    bool? isArchived,
    bool? isTracked,
    String? icon,
    int? colorValue,
    int? sortOrder,
  }) {
    return Account(
      id: id ?? this.id,
      type: type ?? this.type,
      displayName: displayName ?? this.displayName,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      institution: institution ?? this.institution,
      institutionId: institutionId ?? this.institutionId,
      tail: tail ?? this.tail,
      currency: currency ?? this.currency,
      balance: balance ?? this.balance,
      balanceAsOf: balanceAsOf ?? this.balanceAsOf,
      creditLimit: creditLimit ?? this.creditLimit,
      statementDay: statementDay ?? this.statementDay,
      dueDayOffset: dueDayOffset ?? this.dueDayOffset,
      isArchived: isArchived ?? this.isArchived,
      isTracked: isTracked ?? this.isTracked,
      icon: icon ?? this.icon,
      colorValue: colorValue ?? this.colorValue,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'type': type.wire,
        'displayName': displayName,
        'createdAt': jMillis(createdAt),
        'updatedAt': jMillis(updatedAt),
        'institution': institution,
        'institutionId': institutionId,
        'tail': tail,
        'currency': currency,
        'balance': balance?.toJson(),
        'balanceAsOf': balanceAsOf == null ? null : jMillis(balanceAsOf!),
        'creditLimit': creditLimit?.toJson(),
        'statementDay': statementDay,
        'dueDayOffset': dueDayOffset,
        'isArchived': isArchived,
        'isTracked': isTracked,
        'icon': icon,
        'colorValue': colorValue,
        'sortOrder': sortOrder,
      };

  @override
  String toString() => 'Account($id, ${type.wire}, $displayName, tail=$tail)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Account &&
          other.id == id &&
          other.type == type &&
          other.displayName == displayName &&
          jTimeEquals(other.createdAt, createdAt) &&
          jTimeEquals(other.updatedAt, updatedAt) &&
          other.institution == institution &&
          other.institutionId == institutionId &&
          other.tail == tail &&
          other.currency == currency &&
          other.balance == balance &&
          jTimeEquals(other.balanceAsOf, balanceAsOf) &&
          other.creditLimit == creditLimit &&
          other.statementDay == statementDay &&
          other.dueDayOffset == dueDayOffset &&
          other.isArchived == isArchived &&
          other.isTracked == isTracked &&
          other.icon == icon &&
          other.colorValue == colorValue &&
          other.sortOrder == sortOrder;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        id,
        type,
        displayName,
        jTimeHash(createdAt),
        jTimeHash(updatedAt),
        institution,
        institutionId,
        tail,
        currency,
        balance,
        jTimeHash(balanceAsOf),
        creditLimit,
        statementDay,
        dueDayOffset,
        isArchived,
        isTracked,
        icon,
        colorValue,
        sortOrder,
      ]);
}
