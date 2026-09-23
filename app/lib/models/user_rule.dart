import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'json.dart';

/// A categorisation rule the user created on this device.
///
/// This is the answer to "unknown merchant": the app asks, the user picks a
/// category once, and a [UserRule] makes every future message from that
/// merchant land in the right place. User rules outrank the shipped merchant
/// dictionary, and a rules-pack update never overwrites them.
@immutable
class UserRule {
  const UserRule({
    required this.id,
    required this.match,
    required this.pattern,
    required this.categoryPath,
    required this.kind,
    required this.createdAt,
    this.merchantName,
    this.priority = 100,
    this.enabled = true,
    this.applyToExisting = true,
    this.updatedAt,
    this.hitCount = 0,
  });

  factory UserRule.fromJson(Map<String, dynamic> json) => UserRule(
        id: jString(json['id']),
        match: UserRuleMatch.fromWire(jStringOrNull(json['match'])),
        pattern: jString(json['pattern']),
        categoryPath: jString(json['categoryPath']),
        kind: CategoryKind.fromWire(jStringOrNull(json['kind'])),
        createdAt: jDate(json['createdAt']),
        merchantName: jStringOrNull(json['merchantName']),
        priority: jInt(json['priority'], fallback: 100),
        enabled: jBool(json['enabled'], fallback: true),
        applyToExisting: jBool(json['applyToExisting'], fallback: true),
        updatedAt: jDateOrNull(json['updatedAt']),
        hitCount: jInt(json['hitCount']),
      );

  final String id;

  final UserRuleMatch match;

  /// The string to match, already normalised the same way the categoriser
  /// normalises merchant strings (upper case, punctuation collapsed). Never a
  /// regex: user-authored regexes are a support burden and a way to hang the
  /// parser.
  final String pattern;

  /// `'<category>/<subcategory>'` this rule assigns.
  final String categoryPath;

  /// The kind of [categoryPath], carried so a rule can declare a transfer or
  /// investment without a taxonomy lookup.
  final CategoryKind kind;

  final DateTime createdAt;

  /// Display name to show for matches, e.g. `My landlord`.
  final String? merchantName;

  /// Higher wins. Ties break on [createdAt] descending, so the newest decision
  /// a user made is the one that applies.
  final int priority;

  final bool enabled;

  /// Re-categorise transactions already in the ledger when the rule is
  /// created. The user expects "always put this in Rent" to fix the past too.
  final bool applyToExisting;

  final DateTime? updatedAt;

  /// How many transactions this rule has categorised. Shown in settings so
  /// dead rules can be found and removed.
  final int hitCount;

  /// Whether this rule applies. [merchantNormalized], [vpa] and [sender] must
  /// already be normalised by the caller; [body] is matched case-insensitively.
  ///
  /// Returns false when disabled, so callers need no extra guard.
  bool matches({
    String? merchantNormalized,
    String? vpa,
    String? sender,
    String? body,
  }) {
    if (!enabled || pattern.isEmpty) return false;
    final needle = pattern.toUpperCase();
    switch (match) {
      case UserRuleMatch.merchantExact:
        return merchantNormalized != null && merchantNormalized.toUpperCase() == needle;
      case UserRuleMatch.merchantContains:
        return merchantNormalized != null &&
            merchantNormalized.toUpperCase().contains(needle);
      case UserRuleMatch.vpaExact:
        return vpa != null && vpa.toUpperCase() == needle;
      case UserRuleMatch.vpaPrefix:
        return vpa != null && vpa.toUpperCase().startsWith(needle);
      case UserRuleMatch.senderExact:
        return sender != null && sender.toUpperCase() == needle;
      case UserRuleMatch.bodyContains:
        return body != null && body.toUpperCase().contains(needle);
    }
  }

  /// The sentence shown in the UI when this rule decides a category.
  String get explanation => switch (match) {
        UserRuleMatch.merchantExact ||
        UserRuleMatch.merchantContains =>
          'Your rule: merchant contains "$pattern"',
        UserRuleMatch.vpaExact || UserRuleMatch.vpaPrefix => 'Your rule: UPI ID "$pattern"',
        UserRuleMatch.senderExact => 'Your rule: messages from $pattern',
        UserRuleMatch.bodyContains => 'Your rule: message mentions "$pattern"',
      };

  UserRule copyWith({
    String? id,
    UserRuleMatch? match,
    String? pattern,
    String? categoryPath,
    CategoryKind? kind,
    DateTime? createdAt,
    String? merchantName,
    int? priority,
    bool? enabled,
    bool? applyToExisting,
    DateTime? updatedAt,
    int? hitCount,
  }) {
    return UserRule(
      id: id ?? this.id,
      match: match ?? this.match,
      pattern: pattern ?? this.pattern,
      categoryPath: categoryPath ?? this.categoryPath,
      kind: kind ?? this.kind,
      createdAt: createdAt ?? this.createdAt,
      merchantName: merchantName ?? this.merchantName,
      priority: priority ?? this.priority,
      enabled: enabled ?? this.enabled,
      applyToExisting: applyToExisting ?? this.applyToExisting,
      updatedAt: updatedAt ?? this.updatedAt,
      hitCount: hitCount ?? this.hitCount,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'match': match.wire,
        'pattern': pattern,
        'categoryPath': categoryPath,
        'kind': kind.wire,
        'createdAt': jMillis(createdAt),
        'merchantName': merchantName,
        'priority': priority,
        'enabled': enabled,
        'applyToExisting': applyToExisting,
        'updatedAt': updatedAt == null ? null : jMillis(updatedAt!),
        'hitCount': hitCount,
      };

  @override
  String toString() => 'UserRule($id, ${match.wire}:"$pattern" -> $categoryPath)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is UserRule &&
          other.id == id &&
          other.match == match &&
          other.pattern == pattern &&
          other.categoryPath == categoryPath &&
          other.kind == kind &&
          jTimeEquals(other.createdAt, createdAt) &&
          other.merchantName == merchantName &&
          other.priority == priority &&
          other.enabled == enabled &&
          other.applyToExisting == applyToExisting &&
          jTimeEquals(other.updatedAt, updatedAt) &&
          other.hitCount == hitCount;

  @override
  int get hashCode => Object.hashAll(<Object?>[
        id,
        match,
        pattern,
        categoryPath,
        kind,
        jTimeHash(createdAt),
        merchantName,
        priority,
        enabled,
        applyToExisting,
        jTimeHash(updatedAt),
        hitCount,
      ]);
}
