/// Lookups over the loaded taxonomy that `CategoryLabels` in
/// `lib/ui/theme/formatting.dart` does not cover.
///
/// All of them are total: an unknown path gets a sensible answer instead of an
/// exception, because a rules pack can be replaced under a screen that is
/// already showing a path from the older one.
library;

import 'package:ledger/models/models.dart';

/// The [CategoryDef] a path belongs to, or `null` when the taxonomy does not
/// define it.
CategoryDef? categoryDefOf(String categoryPath, List<CategoryDef> taxonomy) {
  if (categoryPath.isEmpty) return null;
  final (String categoryId, _) = CategoryDef.splitPath(categoryPath);
  for (final CategoryDef def in taxonomy) {
    if (def.id == categoryId) return def;
  }
  return null;
}

/// The kind of a path, or `null` when the path is not in the taxonomy.
///
/// `null` means "do not count", never "expense". Treating an unknown path as
/// spending is how a transfer ends up inflating a spend total.
CategoryKind? kindOfPath(String categoryPath, List<CategoryDef> taxonomy) =>
    categoryDefOf(categoryPath, taxonomy)?.kind;

/// The subcategory name alone: `Food Delivery`. Falls back to the category
/// name for a bare path, and to a humanised id for an unknown one.
String shortCategoryLabel(String categoryPath, List<CategoryDef> taxonomy) {
  if (categoryPath.isEmpty || categoryPath == CategoryResult.uncategorizedPath) {
    return 'Uncategorized';
  }
  final (String categoryId, String? subId) = CategoryDef.splitPath(categoryPath);
  final CategoryDef? def = categoryDefOf(categoryPath, taxonomy);
  if (def == null) return _humanizeId(subId ?? categoryId);
  if (subId == null) return def.name;
  return def.subcategory(subId)?.name ?? _humanizeId(subId);
}

/// Every `'<category>/<subcategory>'` path the taxonomy defines, in the order
/// the pack declares them.
List<String> allCategoryPaths(List<CategoryDef> taxonomy) => <String>[
      for (final CategoryDef def in taxonomy) ...def.paths,
    ];

/// `true` when the taxonomy defines this exact path. The guard every write
/// path uses before storing a category, so a stale pick can never persist a
/// path the categoriser would later refuse.
bool isKnownCategoryPath(String categoryPath, List<CategoryDef> taxonomy) {
  final (String categoryId, String? subId) = CategoryDef.splitPath(categoryPath);
  if (subId == null) return false;
  for (final CategoryDef def in taxonomy) {
    if (def.id == categoryId) return def.subcategory(subId) != null;
  }
  return false;
}

String _humanizeId(String id) {
  if (id.isEmpty) return 'Other';
  return id
      .split(RegExp(r'[_\-/]+'))
      .where((String w) => w.isNotEmpty)
      .map((String w) => '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
