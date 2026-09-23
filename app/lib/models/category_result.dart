import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'json.dart';

/// The categoriser's verdict on one parsed message, plus the reason for it.
///
/// [explanation] is a real sentence shown in the UI - "Matched merchant
/// SWIGGYUPI" - because a category the user cannot explain is a category the
/// user cannot trust or correct.
@immutable
class CategoryResult {
  const CategoryResult({
    required this.categoryPath,
    required this.kind,
    required this.confidence,
    required this.source,
    required this.explanation,
    this.merchantName,
    this.matchedOn,
  });

  /// Nothing matched. The transaction goes to the Uncategorized queue and the
  /// app ASKS the user. It never guesses, and it never calls the cloud.
  factory CategoryResult.uncategorized({
    String explanation = 'No matching merchant - tap to choose a category',
  }) =>
      CategoryResult(
        categoryPath: uncategorizedPath,
        kind: CategoryKind.expense,
        confidence: 0,
        source: CategorySource.unknown,
        explanation: explanation,
      );

  /// The user chose this by hand. Highest confidence, and reparsing must never
  /// overwrite it.
  factory CategoryResult.manual(String categoryPath, CategoryKind kind) => CategoryResult(
        categoryPath: categoryPath,
        kind: kind,
        confidence: 1,
        source: CategorySource.manual,
        explanation: 'You set this category',
      );

  factory CategoryResult.fromJson(Map<String, dynamic> json) => CategoryResult(
        categoryPath: jString(json['categoryPath'], fallback: uncategorizedPath),
        kind: CategoryKind.fromWire(jStringOrNull(json['kind'])),
        confidence: jDouble(json['confidence']),
        source: CategorySource.fromWire(jStringOrNull(json['source'])),
        explanation: jString(json['explanation']),
        merchantName: jStringOrNull(json['merchantName']),
        matchedOn: jStringOrNull(json['matchedOn']),
      );

  /// `'<category>/<subcategory>'`, matching `rules/categories.json`, e.g.
  /// `food_dining/food_delivery`. [uncategorizedPath] when unknown.
  final String categoryPath;

  /// The kind of the category at [categoryPath]. Carried here so callers can
  /// exclude transfers and investments from spend without a second lookup.
  final CategoryKind kind;

  /// 0.0 - 1.0. Dictionary hits are [dictionaryConfidence], token-containment
  /// hits [tokenConfidence]; anything below [autoApplyThreshold] is shown as
  /// "please confirm" rather than applied silently.
  final double confidence;

  final CategorySource source;

  /// One human sentence, shown verbatim in the UI.
  final String explanation;

  /// Display name of the merchant that matched, when one did ("Swiggy").
  final String? merchantName;

  /// The exact string that matched, for the explanation and for debugging
  /// ("SWIGGYUPI", "swiggy@").
  final String? matchedOn;

  static const String uncategorizedPath = 'uncategorized';
  static const double dictionaryConfidence = 0.95;
  static const double tokenConfidence = 0.75;
  static const double autoApplyThreshold = 0.70;

  bool get isUncategorized =>
      categoryPath == uncategorizedPath || source == CategorySource.unknown;

  /// True when the category may be applied without asking.
  bool get canAutoApply => !isUncategorized && confidence >= autoApplyThreshold;

  /// The category id (the part before the slash).
  String get categoryId =>
      categoryPath.contains('/') ? categoryPath.split('/').first : categoryPath;

  /// The subcategory id, or `null` for a bare category path.
  String? get subcategoryId =>
      categoryPath.contains('/') ? categoryPath.split('/').last : null;

  CategoryResult copyWith({
    String? categoryPath,
    CategoryKind? kind,
    double? confidence,
    CategorySource? source,
    String? explanation,
    String? merchantName,
    String? matchedOn,
  }) {
    return CategoryResult(
      categoryPath: categoryPath ?? this.categoryPath,
      kind: kind ?? this.kind,
      confidence: confidence ?? this.confidence,
      source: source ?? this.source,
      explanation: explanation ?? this.explanation,
      merchantName: merchantName ?? this.merchantName,
      matchedOn: matchedOn ?? this.matchedOn,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'categoryPath': categoryPath,
        'kind': kind.wire,
        'confidence': confidence,
        'source': source.wire,
        'explanation': explanation,
        'merchantName': merchantName,
        'matchedOn': matchedOn,
      };

  @override
  String toString() =>
      'CategoryResult($categoryPath, ${kind.wire}, ${source.wire}, $confidence)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CategoryResult &&
          other.categoryPath == categoryPath &&
          other.kind == kind &&
          other.confidence == confidence &&
          other.source == source &&
          other.explanation == explanation &&
          other.merchantName == merchantName &&
          other.matchedOn == matchedOn;

  @override
  int get hashCode => Object.hash(
        categoryPath,
        kind,
        confidence,
        source,
        explanation,
        merchantName,
        matchedOn,
      );
}
