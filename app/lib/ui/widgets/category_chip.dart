import 'package:flutter/material.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

import 'taxonomy_lookup.dart';

/// A compact, tappable pill naming a category.
///
/// Complements `CategoryAvatar` from the theme layer: the avatar is the glyph
/// in a list row, this is the label you can press to change the category.
///
/// When the category is a transfer or an investment the pill says so, because
/// the single most confusing thing an Indian expense tracker does is quietly
/// leave a payment out of the spend total. Here the reason is on the pill.
class CategoryChip extends StatelessWidget {
  const CategoryChip({
    required this.categoryPath,
    required this.taxonomy,
    super.key,
    this.onTap,
    this.selected = false,
    this.showKind = true,
    this.dense = false,
  });

  final String categoryPath;
  final List<CategoryDef> taxonomy;
  final VoidCallback? onTap;
  final bool selected;

  /// Append `not spending` for transfers and investments.
  final bool showKind;

  final bool dense;

  @override
  Widget build(BuildContext context) {
    final LedgerPalette palette = context.palette;
    final ColorScheme colors = context.colors;
    final bool isUnknown = categoryPath == CategoryResult.uncategorizedPath ||
        categoryDefOf(categoryPath, taxonomy) == null;
    final CategoryKind? kind = kindOfPath(categoryPath, taxonomy);
    final Color base = isUnknown
        ? palette.attention
        : CategoryLabels.color(categoryPath, taxonomy) ??
            palette.forKind(kind ?? CategoryKind.expense);

    final bool notSpending =
        showKind && kind != null && (kind == CategoryKind.transfer || kind == CategoryKind.investment);
    final String label = shortCategoryLabel(categoryPath, taxonomy);

    return Material(
      color: selected ? colors.secondaryContainer : base.withValues(alpha: 0.12),
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? colors.primary : Colors.transparent,
          width: selected ? 1.5 : 0,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: dense ? Insets.sm : Insets.md,
            vertical: dense ? Insets.xs : Insets.sm - 2,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(
                CategoryIcons.forPath(categoryPath, taxonomy),
                size: dense ? 13 : 15,
                color: base,
              ),
              const SizedBox(width: Insets.xs + 1),
              Flexible(
                child: Text(
                  notSpending ? '$label · not spending' : label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: (dense ? context.texts.labelSmall : context.texts.labelMedium)
                      ?.copyWith(
                    color: selected ? colors.onSecondaryContainer : colors.onSurface,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (onTap != null) ...<Widget>[
                const SizedBox(width: Insets.xs),
                Icon(
                  Icons.expand_more,
                  size: dense ? 13 : 15,
                  color: colors.onSurfaceVariant,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
