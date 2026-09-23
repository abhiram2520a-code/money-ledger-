import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'json.dart';
import 'money.dart';

/// Something that is due to be paid: a credit-card statement, an electricity
/// bill, a NACH mandate, an EMI instalment.
///
/// A bill is NOT a transaction. A reminder ("Rs 8,450 will be debited on
/// 05/10") is a promise about the future; booking it and then booking the
/// actual debit is how EMIs get counted twice. The bill is created from the
/// reminder and later linked to the real transaction via [paidTxnId].
///
/// A credit-card bill payment is additionally a TRANSFER, never an expense:
/// the card spends were already counted when each one happened.
@immutable
class Bill {
  const Bill({
    required this.id,
    required this.name,
    required this.dueDate,
    required this.createdAt,
    required this.updatedAt,
    this.amountDue,
    this.minimumDue,
    this.status = BillStatus.upcoming,
    this.accountId,
    this.accountTail,
    this.cardTail,
    this.merchantName,
    this.categoryPath,
    this.kind = CategoryKind.expense,
    this.issuer,
    this.sourceMessageId,
    this.paidTxnId,
    this.paidAt,
    this.isRecurring = false,
    this.notifyDaysBefore = 2,
  });

  factory Bill.fromJson(Map<String, dynamic> json) => Bill(
        id: jString(json['id']),
        name: jString(json['name']),
        dueDate: jDate(json['dueDate']),
        createdAt: jDate(json['createdAt']),
        updatedAt: jDate(json['updatedAt']),
        amountDue: json['amountDue'] == null ? null : Money.fromJson(json['amountDue']),
        minimumDue:
            json['minimumDue'] == null ? null : Money.fromJson(json['minimumDue']),
        status: BillStatus.fromWire(jStringOrNull(json['status'])),
        accountId: jStringOrNull(json['accountId']),
        accountTail: jStringOrNull(json['accountTail']),
        cardTail: jStringOrNull(json['cardTail']),
        merchantName: jStringOrNull(json['merchantName']),
        categoryPath: jStringOrNull(json['categoryPath']),
        kind: CategoryKind.fromWire(jStringOrNull(json['kind'])),
        issuer: jStringOrNull(json['issuer']),
        sourceMessageId: jStringOrNull(json['sourceMessageId']),
        paidTxnId: jStringOrNull(json['paidTxnId']),
        paidAt: jDateOrNull(json['paidAt']),
        isRecurring: jBool(json['isRecurring']),
        notifyDaysBefore: jInt(json['notifyDaysBefore'], fallback: 2),
      );

  final String id;

  /// What the user sees: `HDFC Card 4455`, `BESCOM electricity`.
  final String name;

  final DateTime dueDate;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// `null` when the reminder did not state an amount.
  final Money? amountDue;

  /// Credit cards: the minimum amount due. Never used as the bill amount.
  final Money? minimumDue;

  final BillStatus status;

  final String? accountId;
  final String? accountTail;

  /// Set for a credit-card statement, so the payment can be recognised as a
  /// transfer to that card rather than as spending.
  final String? cardTail;

  final String? merchantName;

  /// Category the eventual payment should take. For a credit-card bill this is
  /// a transfer path, which is what stops the double count.
  final String? categoryPath;

  final CategoryKind kind;

  final String? issuer;

  /// The `RawMessage.id` of the reminder this came from.
  final String? sourceMessageId;

  /// The transaction that settled this bill, once matched.
  final String? paidTxnId;

  final DateTime? paidAt;

  /// True for a bill that recurs monthly (card statement, rent, subscription).
  final bool isRecurring;

  /// How many days ahead to remind, locally. No push, no server.
  final int notifyDaysBefore;

  bool get isPaid => status == BillStatus.paid || paidTxnId != null;

  /// Days from [now] to [dueDate]; negative when overdue. Both are compared as
  /// LOCAL calendar days, so a due date stored as UTC midnight does not read
  /// as "yesterday" to a user in IST.
  int daysUntilDue(DateTime now) {
    final d = dueDate.toLocal();
    final n = now.toLocal();
    final due = DateTime(d.year, d.month, d.day);
    final today = DateTime(n.year, n.month, n.day);
    return due.difference(today).inDays;
  }

  /// [status] recomputed against [now]. Paid and skipped bills are left alone.
  BillStatus statusAt(DateTime now) {
    if (isPaid) return BillStatus.paid;
    if (status == BillStatus.skipped) return BillStatus.skipped;
    final days = daysUntilDue(now);
    if (days < 0) return BillStatus.overdue;
    if (days <= notifyDaysBefore) return BillStatus.due;
    return BillStatus.upcoming;
  }

  Bill copyWith({
    String? id,
    String? name,
    DateTime? dueDate,
    DateTime? createdAt,
    DateTime? updatedAt,
    Money? amountDue,
    Money? minimumDue,
    BillStatus? status,
    String? accountId,
    String? accountTail,
    String? cardTail,
    String? merchantName,
    String? categoryPath,
    CategoryKind? kind,
    String? issuer,
    String? sourceMessageId,
    String? paidTxnId,
    DateTime? paidAt,
    bool? isRecurring,
    int? notifyDaysBefore,
  }) {
    return Bill(
      id: id ?? this.id,
      name: name ?? this.name,
      dueDate: dueDate ?? this.dueDate,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      amountDue: amountDue ?? this.amountDue,
      minimumDue: minimumDue ?? this.minimumDue,
      status: status ?? this.status,
      accountId: accountId ?? this.accountId,
      accountTail: accountTail ?? this.accountTail,
      cardTail: cardTail ?? this.cardTail,
      merchantName: merchantName ?? this.merchantName,
      categoryPath: categoryPath ?? this.categoryPath,
      kind: kind ?? this.kind,
      issuer: issuer ?? this.issuer,
      sourceMessageId: sourceMessageId ?? this.sourceMessageId,
      paidTxnId: paidTxnId ?? this.paidTxnId,
      paidAt: paidAt ?? this.paidAt,
      isRecurring: isRecurring ?? this.isRecurring,
      notifyDaysBefore: notifyDaysBefore ?? this.notifyDaysBefore,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'dueDate': jMillis(dueDate),
        'createdAt': jMillis(createdAt),
        'updatedAt': jMillis(updatedAt),
        'amountDue': amountDue?.toJson(),
        'minimumDue': minimumDue?.toJson(),
        'status': status.wire,
        'accountId': accountId,
        'accountTail': accountTail,
        'cardTail': cardTail,
        'merchantName': merchantName,
        'categoryPath': categoryPath,
        'kind': kind.wire,
        'issuer': issuer,
        'sourceMessageId': sourceMessageId,
        'paidTxnId': paidTxnId,
        'paidAt': paidAt == null ? null : jMillis(paidAt!),
        'isRecurring': isRecurring,
        'notifyDaysBefore': notifyDaysBefore,
      };

  @override
  String toString() => 'Bill($id, $name, due=$dueDate, ${status.wire})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Bill &&
          other.id == id &&
          other.name == name &&
          jTimeEquals(other.dueDate, dueDate) &&
          jTimeEquals(other.createdAt, createdAt) &&
          jTimeEquals(other.updatedAt, updatedAt) &&
          other.amountDue == amountDue &&
          other.minimumDue == minimumDue &&
          other.status == status &&
          other.accountId == accountId &&
          other.accountTail == accountTail &&
          other.cardTail == cardTail &&
          other.merchantName == merchantName &&
          other.categoryPath == categoryPath &&
          other.kind == kind &&
          other.issuer == issuer &&
          other.sourceMessageId == sourceMessageId &&
          other.paidTxnId == paidTxnId &&
          jTimeEquals(other.paidAt, paidAt) &&
          other.isRecurring == isRecurring &&
          other.notifyDaysBefore == notifyDaysBefore;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        id,
        name,
        jTimeHash(dueDate),
        jTimeHash(createdAt),
        jTimeHash(updatedAt),
        amountDue,
        minimumDue,
        status,
        accountId,
        accountTail,
        cardTail,
        merchantName,
        categoryPath,
        kind,
        issuer,
        sourceMessageId,
        paidTxnId,
        jTimeHash(paidAt),
        isRecurring,
        notifyDaysBefore,
      ]);
}
