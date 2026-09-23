import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'json.dart';

/// One merchant in the shipped dictionary.
///
/// Mirrors an element of `merchants` in `rules/merchants.json` exactly, so
/// [fromJson] reads that file unchanged and [toJson] writes it back in the
/// same shape:
/// ```json
/// { "name": "Swiggy",
///   "category": "food_dining/food_delivery",
///   "aliases": ["SWIGGY", "SWIGGYUPI", "BUNDLTECH"],
///   "vpa": ["swiggy@", "swiggyupi@"] }
/// ```
@immutable
class MerchantEntry {
  const MerchantEntry({
    required this.name,
    required this.categoryPath,
    this.aliases = const <String>[],
    this.vpaPrefixes = const <String>[],
    this.isBiller = false,
    this.billerType,
    this.icon,
    this.origin = RulesOrigin.bundled,
  });

  /// Reads the on-disk shape. Note the JSON keys `category` and `vpa`, which
  /// differ from the Dart field names on purpose - the file is the contract.
  factory MerchantEntry.fromJson(Map<String, dynamic> json) => MerchantEntry(
        name: jString(json['name']),
        categoryPath: jString(json['category'], fallback: 'uncategorized'),
        aliases: jStringList(json['aliases']),
        vpaPrefixes: jStringList(json['vpa']),
        isBiller: jBool(json['is_biller']),
        billerType: jStringOrNull(json['biller_type']),
        icon: jStringOrNull(json['icon']),
        origin: RulesOrigin.fromWire(jStringOrNull(json['origin'])),
      );

  /// Display name: `Swiggy`.
  final String name;

  /// `'<category>/<subcategory>'`. Validated against `categories.json` by
  /// `tools/validate_rules.dart`.
  final String categoryPath;

  /// Every surface form seen in real SMS - `SWIGGY`, `SWIGGYUPI`,
  /// `BUNDLTECH`. Aliases are unique across the whole file; two merchants
  /// claiming one alias is a validator failure, because the winner would
  /// otherwise depend on file order.
  final List<String> aliases;

  /// Full VPA prefixes such as `swiggy@`. A bare handle (`@okaxis`) names the
  /// payment app, not the merchant, and must never appear here.
  final List<String> vpaPrefixes;

  /// True for utilities, insurers, card issuers and other billers, whose
  /// messages produce bills as well as transactions.
  final bool isBiller;

  /// `ELECTRICITY`, `DTH`, `CREDIT_CARD`, ... when [isBiller].
  final String? billerType;

  /// Material icon name.
  final String? icon;

  final RulesOrigin origin;

  /// Exact alias match against an already-normalised merchant string.
  /// Case-insensitive; the caller is expected to have upper-cased and stripped
  /// punctuation already.
  bool matchesAlias(String normalizedMerchant) {
    if (normalizedMerchant.isEmpty) return false;
    final needle = normalizedMerchant.toUpperCase();
    for (final a in aliases) {
      if (a.toUpperCase() == needle) return true;
    }
    return false;
  }

  /// Token-containment match - weaker than [matchesAlias], and the caller
  /// should record the lower confidence.
  bool containsAlias(String normalizedMerchant) {
    if (normalizedMerchant.isEmpty) return false;
    final haystack = normalizedMerchant.toUpperCase();
    for (final a in aliases) {
      final needle = a.toUpperCase();
      if (needle.length >= 4 && haystack.contains(needle)) return true;
    }
    return false;
  }

  /// VPA prefix match, e.g. `swiggy@axisbank` against `swiggy@`.
  bool matchesVpa(String? vpa) {
    if (vpa == null || vpa.isEmpty) return false;
    final needle = vpa.toLowerCase();
    for (final p in vpaPrefixes) {
      if (needle.startsWith(p.toLowerCase())) return true;
    }
    return false;
  }

  MerchantEntry copyWith({
    String? name,
    String? categoryPath,
    List<String>? aliases,
    List<String>? vpaPrefixes,
    bool? isBiller,
    String? billerType,
    String? icon,
    RulesOrigin? origin,
  }) {
    return MerchantEntry(
      name: name ?? this.name,
      categoryPath: categoryPath ?? this.categoryPath,
      aliases: aliases ?? this.aliases,
      vpaPrefixes: vpaPrefixes ?? this.vpaPrefixes,
      isBiller: isBiller ?? this.isBiller,
      billerType: billerType ?? this.billerType,
      icon: icon ?? this.icon,
      origin: origin ?? this.origin,
    );
  }

  /// Writes the `rules/merchants.json` shape, so a round trip through this
  /// model leaves the file byte-compatible with the validator.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'category': categoryPath,
        if (aliases.isNotEmpty) 'aliases': aliases,
        if (vpaPrefixes.isNotEmpty) 'vpa': vpaPrefixes,
        if (isBiller) 'is_biller': true,
        if (billerType != null) 'biller_type': billerType,
        if (icon != null) 'icon': icon,
      };

  @override
  String toString() => 'MerchantEntry($name -> $categoryPath, ${aliases.length} aliases)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MerchantEntry &&
          other.name == name &&
          other.categoryPath == categoryPath &&
          listEquals(other.aliases, aliases) &&
          listEquals(other.vpaPrefixes, vpaPrefixes) &&
          other.isBiller == isBiller &&
          other.billerType == billerType &&
          other.icon == icon &&
          other.origin == origin;

  @override
  int get hashCode => Object.hash(
        name,
        categoryPath,
        Object.hashAll(aliases),
        Object.hashAll(vpaPrefixes),
        isBiller,
        billerType,
        icon,
        origin,
      );
}
