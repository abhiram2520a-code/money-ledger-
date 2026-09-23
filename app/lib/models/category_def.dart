import 'package:flutter/foundation.dart';

import 'enums.dart';
import 'json.dart';

/// A leaf of the taxonomy. `{ "id": "food_delivery", "name": "Food Delivery" }`
@immutable
class SubcategoryDef {
  const SubcategoryDef({required this.id, required this.name, this.icon});

  factory SubcategoryDef.fromJson(Map<String, dynamic> json) => SubcategoryDef(
        id: jString(json['id']),
        name: jString(json['name']),
        icon: jStringOrNull(json['icon']),
      );

  final String id;
  final String name;
  final String? icon;

  SubcategoryDef copyWith({String? id, String? name, String? icon}) =>
      SubcategoryDef(id: id ?? this.id, name: name ?? this.name, icon: icon ?? this.icon);

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        if (icon != null) 'icon': icon,
      };

  @override
  String toString() => 'SubcategoryDef($id)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SubcategoryDef && other.id == id && other.name == name && other.icon == icon;

  @override
  int get hashCode => Object.hash(id, name, icon);
}

/// One top-level category from `rules/categories.json`.
///
/// [kind] is the load-bearing field: only `CategoryKind.expense` counts as
/// spending. Transfers and investments are the user's own money moving and are
/// excluded from every spend total.
@immutable
class CategoryDef {
  const CategoryDef({
    required this.id,
    required this.name,
    required this.kind,
    this.icon,
    this.colorHex,
    this.subcategories = const <SubcategoryDef>[],
    this.sortOrder = 0,
  });

  factory CategoryDef.fromJson(Map<String, dynamic> json) => CategoryDef(
        id: jString(json['id']),
        name: jString(json['name']),
        kind: CategoryKind.fromWire(jStringOrNull(json['kind'])),
        icon: jStringOrNull(json['icon']),
        colorHex: jStringOrNull(json['color']),
        subcategories: jMapList(json['subcategories'])
            .map(SubcategoryDef.fromJson)
            .toList(growable: false),
        sortOrder: jInt(json['sort_order']),
      );

  /// Reads the whole `categories.json` document.
  static List<CategoryDef> listFromJson(Map<String, dynamic> json) =>
      jMapList(json['categories']).map(CategoryDef.fromJson).toList(growable: false);

  final String id;
  final String name;
  final CategoryKind kind;

  /// Material icon name, e.g. `restaurant`.
  final String? icon;

  /// `#F2994A`. Kept as text so this model stays free of `dart:ui`; use
  /// [colorValue] for an ARGB int.
  final String? colorHex;

  final List<SubcategoryDef> subcategories;

  final int sortOrder;

  /// Only expense categories count toward spending.
  bool get countsAsSpend => kind.countsAsSpend;

  /// `'food_dining/food_delivery'` for a subcategory of this category.
  String pathFor(String subcategoryId) => '$id/$subcategoryId';

  /// Every `'<id>/<subId>'` this category defines.
  List<String> get paths =>
      subcategories.map((s) => pathFor(s.id)).toList(growable: false);

  SubcategoryDef? subcategory(String subcategoryId) {
    for (final s in subcategories) {
      if (s.id == subcategoryId) return s;
    }
    return null;
  }

  /// [colorHex] as an ARGB int, opaque. `null` when unparseable.
  int? get colorValue {
    final hex = colorHex?.replaceAll('#', '').trim();
    if (hex == null || (hex.length != 6 && hex.length != 8)) return null;
    final value = int.tryParse(hex, radix: 16);
    if (value == null) return null;
    return hex.length == 6 ? 0xFF000000 | value : value;
  }

  /// Splits `'food_dining/food_delivery'` into its two ids. The second is
  /// `null` for a bare category path.
  static (String categoryId, String? subcategoryId) splitPath(String path) {
    final i = path.indexOf('/');
    if (i < 0) return (path, null);
    return (path.substring(0, i), path.substring(i + 1));
  }

  CategoryDef copyWith({
    String? id,
    String? name,
    CategoryKind? kind,
    String? icon,
    String? colorHex,
    List<SubcategoryDef>? subcategories,
    int? sortOrder,
  }) {
    return CategoryDef(
      id: id ?? this.id,
      name: name ?? this.name,
      kind: kind ?? this.kind,
      icon: icon ?? this.icon,
      colorHex: colorHex ?? this.colorHex,
      subcategories: subcategories ?? this.subcategories,
      sortOrder: sortOrder ?? this.sortOrder,
    );
  }

  /// Writes the `rules/categories.json` shape.
  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'name': name,
        'kind': kind.wire,
        if (icon != null) 'icon': icon,
        if (colorHex != null) 'color': colorHex,
        'subcategories': subcategories.map((s) => s.toJson()).toList(growable: false),
        if (sortOrder != 0) 'sort_order': sortOrder,
      };

  @override
  String toString() => 'CategoryDef($id, ${kind.wire}, ${subcategories.length} subs)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CategoryDef &&
          other.id == id &&
          other.name == name &&
          other.kind == kind &&
          other.icon == icon &&
          other.colorHex == colorHex &&
          listEquals(other.subcategories, subcategories) &&
          other.sortOrder == sortOrder;

  @override
  int get hashCode => Object.hash(
        id,
        name,
        kind,
        icon,
        colorHex,
        Object.hashAll(subcategories),
        sortOrder,
      );
}
