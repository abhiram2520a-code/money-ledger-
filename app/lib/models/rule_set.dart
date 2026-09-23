import 'package:flutter/foundation.dart';

import 'category_def.dart';
import 'enums.dart';
import 'json.dart';
import 'merchant_entry.dart';
import 'parser_rule_def.dart';

/// Everything the parser and the categoriser need, loaded as one unit.
///
/// A rule set is assembled from the three files in `rules/`, which are
/// bundled into the APK at `assets/rules/` so the app is fully functional on
/// first launch with no network, forever. The config server only ever supplies
/// a NEWER set; it is never required and the app must never wait on it.
@immutable
class RuleSet {
  const RuleSet({
    required this.version,
    required this.rules,
    required this.categories,
    required this.merchants,
    this.rejectPatterns = const <String>[],
    this.debitWords = const <String>[],
    this.creditWords = const <String>[],
    this.origin = RulesOrigin.bundled,
    this.loadedAt,
  });

  /// Builds from the three decoded documents, exactly as they sit in
  /// `assets/rules/`.
  factory RuleSet.fromDocuments({
    required Map<String, dynamic> parserRules,
    required Map<String, dynamic> categories,
    required Map<String, dynamic> merchants,
    RulesOrigin origin = RulesOrigin.bundled,
    DateTime? loadedAt,
  }) {
    final directionWords = jMap(parserRules['direction_words']);
    return RuleSet(
      version: jInt(parserRules['version']),
      rules: jMapList(parserRules['rules'])
          .map(ParserRuleDef.fromJson)
          .toList(growable: false),
      categories: CategoryDef.listFromJson(categories),
      merchants: jMapList(merchants['merchants'])
          .map(MerchantEntry.fromJson)
          .toList(growable: false),
      rejectPatterns: jStringList(jMap(parserRules['reject_patterns'])['patterns']),
      debitWords: jStringList(directionWords['debit']),
      creditWords: jStringList(directionWords['credit']),
      origin: origin,
      loadedAt: loadedAt,
    );
  }

  factory RuleSet.fromJson(Map<String, dynamic> json) => RuleSet(
        version: jInt(json['version']),
        rules:
            jMapList(json['rules']).map(ParserRuleDef.fromJson).toList(growable: false),
        categories:
            jMapList(json['categories']).map(CategoryDef.fromJson).toList(growable: false),
        merchants: jMapList(json['merchants'])
            .map(MerchantEntry.fromJson)
            .toList(growable: false),
        rejectPatterns: jStringList(json['rejectPatterns']),
        debitWords: jStringList(json['debitWords']),
        creditWords: jStringList(json['creditWords']),
        origin: RulesOrigin.fromWire(jStringOrNull(json['origin'])),
        loadedAt: jDateOrNull(json['loadedAt']),
      );

  /// The `version` of `parser_rules.json`. A downloaded set replaces the
  /// bundled one only when this is strictly greater.
  final int version;

  /// Sorted by the loader, descending by [ParserRuleDef.priority] then by id.
  final List<ParserRuleDef> rules;

  final List<CategoryDef> categories;

  final List<MerchantEntry> merchants;

  /// Checked BEFORE any rule. A body matching one of these never reaches the
  /// parser, whatever header it carries. This is what stops an OTP that quotes
  /// an amount, and a "spend 5000 and get cashback" promo, from inventing
  /// money the user never spent.
  final List<String> rejectPatterns;

  /// Words that mean money left the account, for rules whose `direction` is
  /// `infer`.
  final List<String> debitWords;

  /// Words that mean money arrived.
  final List<String> creditWords;

  final RulesOrigin origin;

  final DateTime? loadedAt;

  /// An empty set. Loading this would parse nothing, so treat it as a failure
  /// state rather than a usable default.
  static const RuleSet empty = RuleSet(
    version: 0,
    rules: <ParserRuleDef>[],
    categories: <CategoryDef>[],
    merchants: <MerchantEntry>[],
  );

  bool get isEmpty => rules.isEmpty || categories.isEmpty;

  /// Every valid `'<category>/<subcategory>'` path.
  Set<String> get categoryPaths {
    final out = <String>{};
    for (final c in categories) {
      out.addAll(c.paths);
    }
    return out;
  }

  CategoryDef? categoryById(String id) {
    for (final c in categories) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// The kind of a `'<category>/<subcategory>'` path, or `null` when the path
  /// is not in this taxonomy. Callers must treat `null` as "do not count",
  /// never as "expense".
  CategoryKind? kindOfPath(String categoryPath) {
    final (categoryId, _) = CategoryDef.splitPath(categoryPath);
    return categoryById(categoryId)?.kind;
  }

  /// Rules ordered the way the parser must try them: highest priority first,
  /// then by id so the result is deterministic.
  List<ParserRuleDef> get orderedRules {
    final sorted = List<ParserRuleDef>.of(rules);
    sorted.sort((a, b) {
      final byPriority = b.priority.compareTo(a.priority);
      return byPriority != 0 ? byPriority : a.id.compareTo(b.id);
    });
    return List<ParserRuleDef>.unmodifiable(sorted);
  }

  RuleSet copyWith({
    int? version,
    List<ParserRuleDef>? rules,
    List<CategoryDef>? categories,
    List<MerchantEntry>? merchants,
    List<String>? rejectPatterns,
    List<String>? debitWords,
    List<String>? creditWords,
    RulesOrigin? origin,
    DateTime? loadedAt,
  }) {
    return RuleSet(
      version: version ?? this.version,
      rules: rules ?? this.rules,
      categories: categories ?? this.categories,
      merchants: merchants ?? this.merchants,
      rejectPatterns: rejectPatterns ?? this.rejectPatterns,
      debitWords: debitWords ?? this.debitWords,
      creditWords: creditWords ?? this.creditWords,
      origin: origin ?? this.origin,
      loadedAt: loadedAt ?? this.loadedAt,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'version': version,
        'rules': rules.map((r) => r.toJson()).toList(growable: false),
        'categories': categories.map((c) => c.toJson()).toList(growable: false),
        'merchants': merchants.map((m) => m.toJson()).toList(growable: false),
        'rejectPatterns': rejectPatterns,
        'debitWords': debitWords,
        'creditWords': creditWords,
        'origin': origin.wire,
        'loadedAt': loadedAt == null ? null : jMillis(loadedAt!),
      };

  @override
  String toString() => 'RuleSet(v$version, ${origin.wire}, ${rules.length} rules, '
      '${categories.length} categories, ${merchants.length} merchants)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RuleSet &&
          other.version == version &&
          listEquals(other.rules, rules) &&
          listEquals(other.categories, categories) &&
          listEquals(other.merchants, merchants) &&
          listEquals(other.rejectPatterns, rejectPatterns) &&
          listEquals(other.debitWords, debitWords) &&
          listEquals(other.creditWords, creditWords) &&
          other.origin == origin &&
          jTimeEquals(other.loadedAt, loadedAt);

  @override
  int get hashCode => Object.hash(
        version,
        Object.hashAll(rules),
        Object.hashAll(categories),
        Object.hashAll(merchants),
        Object.hashAll(rejectPatterns),
        Object.hashAll(debitWords),
        Object.hashAll(creditWords),
        origin,
        jTimeHash(loadedAt),
      );
}
