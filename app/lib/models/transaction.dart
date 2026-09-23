import 'package:flutter/foundation.dart';

import 'category_result.dart';
import 'enums.dart';
import 'json.dart';
import 'money.dart';
import 'parsed_message.dart';

/// One row of the ledger: a money event, categorised, ready to be counted.
///
/// [amount] is a positive magnitude and [direction] carries the sign, so no
/// code path can accidentally add a debit to a credit. Whether a row counts as
/// spending is decided by [kind] alone - see [countsAsSpend].
@immutable
class Transaction {
  const Transaction({
    required this.id,
    required this.amount,
    required this.direction,
    required this.occurredAt,
    required this.bookingDate,
    required this.kind,
    required this.categoryPath,
    required this.createdAt,
    required this.updatedAt,
    this.status = TxnStatus.posted,
    this.channel = TxnChannel.unknown,
    this.source = TxnSource.sms,
    this.datePrecision = DatePrecision.receivedFallback,
    this.merchantName,
    this.merchantRaw,
    this.accountId,
    this.accountTail,
    this.cardTail,
    this.vpa,
    this.ref,
    this.note,
    this.balanceAfter,
    this.rawMessageId,
    this.ruleId,
    this.ruleVersion,
    this.confidence = 1.0,
    this.categorySource = CategorySource.manual,
    this.categoryExplanation = '',
    this.transferGroupId,
    this.reversalOfId,
    this.billId,
    this.isExcludedFromTotals = false,
    this.editedFields = const <String>{},
  });

  /// Builds a ledger row from a parse plus a categorisation. The one place
  /// those two halves are joined, so every module produces identical rows.
  ///
  /// [id] must be caller-supplied (sortable and unique); this model never
  /// generates ids, because id generation is a repository concern.
  factory Transaction.fromParse({
    required String id,
    required ParsedMessage parsed,
    required CategoryResult category,
    required DateTime now,
    String? accountId,
    TxnSource source = TxnSource.sms,
  }) {
    final confidence = parsed.confidence * (category.isUncategorized ? 1.0 : category.confidence);
    return Transaction(
      id: id,
      amount: parsed.amount.abs,
      direction: parsed.direction,
      occurredAt: parsed.occurredAt,
      // Local, not UTC: see jDateKey. A 00:30 IST payment belongs to that day.
      bookingDate: jDateKey(parsed.occurredAt.toLocal()),
      kind: category.kind,
      categoryPath: category.categoryPath,
      createdAt: now,
      updatedAt: now,
      status: parsed.needsReview || category.isUncategorized
          ? TxnStatus.needsReview
          : TxnStatus.posted,
      channel: parsed.channel,
      source: source,
      datePrecision: parsed.datePrecision,
      merchantName: category.merchantName,
      merchantRaw: parsed.merchantRaw,
      accountId: accountId,
      accountTail: parsed.accountTail,
      cardTail: parsed.cardTail,
      vpa: parsed.vpa,
      ref: parsed.ref,
      balanceAfter: parsed.balance,
      rawMessageId: parsed.rawMessageId,
      ruleId: parsed.ruleId,
      ruleVersion: parsed.ruleVersion,
      confidence: confidence,
      categorySource: category.source,
      categoryExplanation: category.explanation,
    );
  }

  factory Transaction.fromJson(Map<String, dynamic> json) => Transaction(
        id: jString(json['id']),
        amount: Money.fromJson(json['amount']),
        direction:
            TxnDirection.fromWire(jStringOrNull(json['direction'])) ?? TxnDirection.debit,
        occurredAt: jDate(json['occurredAt']),
        bookingDate: jString(json['bookingDate']),
        kind: CategoryKind.fromWire(jStringOrNull(json['kind'])),
        categoryPath: jString(json['categoryPath'], fallback: CategoryResult.uncategorizedPath),
        createdAt: jDate(json['createdAt']),
        updatedAt: jDate(json['updatedAt']),
        status: TxnStatus.fromWire(jStringOrNull(json['status'])),
        channel: TxnChannel.fromWire(jStringOrNull(json['channel'])),
        source: TxnSource.fromWire(jStringOrNull(json['source'])),
        datePrecision: DatePrecision.fromWire(jStringOrNull(json['datePrecision'])),
        merchantName: jStringOrNull(json['merchantName']),
        merchantRaw: jStringOrNull(json['merchantRaw']),
        accountId: jStringOrNull(json['accountId']),
        accountTail: jStringOrNull(json['accountTail']),
        cardTail: jStringOrNull(json['cardTail']),
        vpa: jStringOrNull(json['vpa']),
        ref: jStringOrNull(json['ref']),
        note: jStringOrNull(json['note']),
        balanceAfter:
            json['balanceAfter'] == null ? null : Money.fromJson(json['balanceAfter']),
        rawMessageId: jStringOrNull(json['rawMessageId']),
        ruleId: jStringOrNull(json['ruleId']),
        ruleVersion: jIntOrNull(json['ruleVersion']),
        confidence: jDouble(json['confidence'], fallback: 1),
        categorySource: CategorySource.fromWire(jStringOrNull(json['categorySource'])),
        categoryExplanation: jString(json['categoryExplanation']),
        transferGroupId: jStringOrNull(json['transferGroupId']),
        reversalOfId: jStringOrNull(json['reversalOfId']),
        billId: jStringOrNull(json['billId']),
        isExcludedFromTotals: jBool(json['isExcludedFromTotals']),
        editedFields: jStringList(json['editedFields']).toSet(),
      );

  /// Sortable, unique, generated on this device.
  final String id;

  /// Positive magnitude. The sign lives in [direction].
  final Money amount;

  final TxnDirection direction;

  final DateTime occurredAt;

  /// `'YYYY-MM-DD'` in the user's LOCAL zone, denormalised from [occurredAt]
  /// so month and day grouping need no date arithmetic in SQL. Build it with
  /// `jDateKey(occurredAt.toLocal())` and never from a UTC value.
  final String bookingDate;

  /// The kind of [categoryPath]. Duplicated onto the row on purpose: a spend
  /// total must never need a join to be correct.
  final CategoryKind kind;

  /// `'<category>/<subcategory>'`, or `CategoryResult.uncategorizedPath`.
  final String categoryPath;

  final DateTime createdAt;
  final DateTime updatedAt;

  final TxnStatus status;
  final TxnChannel channel;
  final TxnSource source;
  final DatePrecision datePrecision;

  /// Resolved display name, e.g. `Swiggy`.
  final String? merchantName;

  /// The untouched merchant string from the message, kept so a later rules
  /// pack can re-categorise without re-reading the SMS.
  final String? merchantRaw;

  /// The [Account] this row belongs to, once matched by tail.
  final String? accountId;

  final String? accountTail;

  /// Set when the money moved on a card. A card spend and the later bank debit
  /// that pays the card bill are different accounts; that is what keeps the
  /// bill payment from double-counting the spend.
  final String? cardTail;

  final String? vpa;

  /// UPI RRN / UTR / auth code. The event identity used for de-duplication.
  final String? ref;

  /// Free text the user added.
  final String? note;

  /// `Avl Bal` reported by the message that created this row.
  final Money? balanceAfter;

  final String? rawMessageId;
  final String? ruleId;
  final int? ruleVersion;

  /// 0.0 - 1.0, parse confidence combined with categorisation confidence.
  final double confidence;

  final CategorySource categorySource;

  /// The sentence shown in the UI explaining the category.
  final String categoryExplanation;

  /// Pairs the two sides of one self-transfer or credit-card bill payment, so
  /// the pair is reported once and counted as spend zero times.
  final String? transferGroupId;

  /// Set on a refund or reversal, pointing at the transaction it undoes.
  final String? reversalOfId;

  /// Set when this row settled a [Bill].
  final String? billId;

  /// User override: keep the row but leave it out of every total.
  final bool isExcludedFromTotals;

  /// Names of fields the user edited by hand. A re-parse after a rules update
  /// must never overwrite a field listed here.
  final Set<String> editedFields;

  /// The ONLY predicate a spend total may use.
  bool get countsAsSpend =>
      kind.countsAsSpend &&
      direction.isDebit &&
      status.countsInTotals &&
      !isExcludedFromTotals;

  bool get countsAsIncome =>
      kind.countsAsIncome &&
      direction.isCredit &&
      status.countsInTotals &&
      !isExcludedFromTotals;

  /// Money moved between things the user owns. Reported, never counted.
  bool get isNetZero => kind.isNetZero;

  bool get isUncategorized => categoryPath == CategoryResult.uncategorizedPath;

  bool get needsReview => status == TxnStatus.needsReview;

  /// Signed paise for arithmetic that needs a direction: debits negative.
  int get signedPaise => direction.isDebit ? -amount.paise : amount.paise;

  /// True when the user edited [field] and a re-parse must leave it alone.
  bool isFieldLocked(String field) => editedFields.contains(field);

  /// Applies a new categorisation, refusing to clobber a user's own choice.
  Transaction withCategory(CategoryResult category, {required DateTime now}) {
    if (categorySource.isUserAuthored || isFieldLocked('categoryPath')) return this;
    return copyWith(
      categoryPath: category.categoryPath,
      kind: category.kind,
      categorySource: category.source,
      categoryExplanation: category.explanation,
      merchantName: category.merchantName,
      updatedAt: now,
    );
  }

  /// Records a manual edit so later re-parses respect it.
  Transaction markEdited(Iterable<String> fields, {required DateTime now}) => copyWith(
        editedFields: <String>{...editedFields, ...fields},
        updatedAt: now,
      );

  /// Note: passing `null` keeps the current value. To clear a nullable field,
  /// construct a new [Transaction].
  Transaction copyWith({
    String? id,
    Money? amount,
    TxnDirection? direction,
    DateTime? occurredAt,
    String? bookingDate,
    CategoryKind? kind,
    String? categoryPath,
    DateTime? createdAt,
    DateTime? updatedAt,
    TxnStatus? status,
    TxnChannel? channel,
    TxnSource? source,
    DatePrecision? datePrecision,
    String? merchantName,
    String? merchantRaw,
    String? accountId,
    String? accountTail,
    String? cardTail,
    String? vpa,
    String? ref,
    String? note,
    Money? balanceAfter,
    String? rawMessageId,
    String? ruleId,
    int? ruleVersion,
    double? confidence,
    CategorySource? categorySource,
    String? categoryExplanation,
    String? transferGroupId,
    String? reversalOfId,
    String? billId,
    bool? isExcludedFromTotals,
    Set<String>? editedFields,
  }) {
    return Transaction(
      id: id ?? this.id,
      amount: amount ?? this.amount,
      direction: direction ?? this.direction,
      occurredAt: occurredAt ?? this.occurredAt,
      bookingDate: bookingDate ?? this.bookingDate,
      kind: kind ?? this.kind,
      categoryPath: categoryPath ?? this.categoryPath,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      status: status ?? this.status,
      channel: channel ?? this.channel,
      source: source ?? this.source,
      datePrecision: datePrecision ?? this.datePrecision,
      merchantName: merchantName ?? this.merchantName,
      merchantRaw: merchantRaw ?? this.merchantRaw,
      accountId: accountId ?? this.accountId,
      accountTail: accountTail ?? this.accountTail,
      cardTail: cardTail ?? this.cardTail,
      vpa: vpa ?? this.vpa,
      ref: ref ?? this.ref,
      note: note ?? this.note,
      balanceAfter: balanceAfter ?? this.balanceAfter,
      rawMessageId: rawMessageId ?? this.rawMessageId,
      ruleId: ruleId ?? this.ruleId,
      ruleVersion: ruleVersion ?? this.ruleVersion,
      confidence: confidence ?? this.confidence,
      categorySource: categorySource ?? this.categorySource,
      categoryExplanation: categoryExplanation ?? this.categoryExplanation,
      transferGroupId: transferGroupId ?? this.transferGroupId,
      reversalOfId: reversalOfId ?? this.reversalOfId,
      billId: billId ?? this.billId,
      isExcludedFromTotals: isExcludedFromTotals ?? this.isExcludedFromTotals,
      editedFields: editedFields ?? this.editedFields,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'amount': amount.toJson(),
        'direction': direction.wire,
        'occurredAt': jMillis(occurredAt),
        'bookingDate': bookingDate,
        'kind': kind.wire,
        'categoryPath': categoryPath,
        'createdAt': jMillis(createdAt),
        'updatedAt': jMillis(updatedAt),
        'status': status.wire,
        'channel': channel.wire,
        'source': source.wire,
        'datePrecision': datePrecision.wire,
        'merchantName': merchantName,
        'merchantRaw': merchantRaw,
        'accountId': accountId,
        'accountTail': accountTail,
        'cardTail': cardTail,
        'vpa': vpa,
        'ref': ref,
        'note': note,
        'balanceAfter': balanceAfter?.toJson(),
        'rawMessageId': rawMessageId,
        'ruleId': ruleId,
        'ruleVersion': ruleVersion,
        'confidence': confidence,
        'categorySource': categorySource.wire,
        'categoryExplanation': categoryExplanation,
        'transferGroupId': transferGroupId,
        'reversalOfId': reversalOfId,
        'billId': billId,
        'isExcludedFromTotals': isExcludedFromTotals,
        'editedFields': editedFields.toList(growable: false),
      };

  @override
  String toString() =>
      'Transaction($id, ${amount.format()} ${direction.wire}, $categoryPath, '
      '${kind.wire}, ${status.wire}, $bookingDate)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Transaction &&
          other.id == id &&
          other.amount == amount &&
          other.direction == direction &&
          jTimeEquals(other.occurredAt, occurredAt) &&
          other.bookingDate == bookingDate &&
          other.kind == kind &&
          other.categoryPath == categoryPath &&
          jTimeEquals(other.createdAt, createdAt) &&
          jTimeEquals(other.updatedAt, updatedAt) &&
          other.status == status &&
          other.channel == channel &&
          other.source == source &&
          other.datePrecision == datePrecision &&
          other.merchantName == merchantName &&
          other.merchantRaw == merchantRaw &&
          other.accountId == accountId &&
          other.accountTail == accountTail &&
          other.cardTail == cardTail &&
          other.vpa == vpa &&
          other.ref == ref &&
          other.note == note &&
          other.balanceAfter == balanceAfter &&
          other.rawMessageId == rawMessageId &&
          other.ruleId == ruleId &&
          other.ruleVersion == ruleVersion &&
          other.confidence == confidence &&
          other.categorySource == categorySource &&
          other.categoryExplanation == categoryExplanation &&
          other.transferGroupId == transferGroupId &&
          other.reversalOfId == reversalOfId &&
          other.billId == billId &&
          other.isExcludedFromTotals == isExcludedFromTotals &&
          setEquals(other.editedFields, editedFields);

  @override
  int get hashCode => Object.hashAll(<Object?>[
        id,
        amount,
        direction,
        jTimeHash(occurredAt),
        bookingDate,
        kind,
        categoryPath,
        jTimeHash(createdAt),
        jTimeHash(updatedAt),
        status,
        channel,
        source,
        datePrecision,
        merchantName,
        merchantRaw,
        accountId,
        accountTail,
        cardTail,
        vpa,
        ref,
        note,
        balanceAfter,
        rawMessageId,
        ruleId,
        ruleVersion,
        confidence,
        categorySource,
        categoryExplanation,
        transferGroupId,
        reversalOfId,
        billId,
        isExcludedFromTotals,
        Object.hashAllUnordered(editedFields),
      ]);
}
