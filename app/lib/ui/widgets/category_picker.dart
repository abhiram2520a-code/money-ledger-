import 'package:flutter/material.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

import 'taxonomy_lookup.dart';

/// What the user chose in the picker.
@immutable
class CategoryPick {
  const CategoryPick(this.path, this.kind);

  /// `'<category>/<subcategory>'`, guaranteed to exist in the taxonomy that
  /// was passed in - the picker only ever offers real paths, so a pick can
  /// always be stored without a second validity check.
  final String path;

  /// The kind of [path], carried so a caller never has to look it up and can
  /// never accidentally book a transfer as spending.
  final CategoryKind kind;

  bool get countsAsSpend => kind.countsAsSpend;

  @override
  String toString() => 'CategoryPick($path, ${kind.wire})';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CategoryPick && other.path == path && other.kind == kind;

  @override
  int get hashCode => Object.hash(path, kind);
}

/// Opens the category picker and resolves with the user's choice, or `null` if
/// they dismissed it.
///
/// Built for speed, because this sheet is the price of never guessing: the
/// whole taxonomy is on one scrolling surface, so a choice is a scroll and a
/// tap rather than a drill-down and a back button. Typing filters across both
/// category and subcategory names.
Future<CategoryPick?> showCategoryPicker(
  BuildContext context, {
  required List<CategoryDef> taxonomy,
  String? title,
  String? subtitle,
  String? currentPath,
  List<String> suggestions = const <String>[],
}) {
  return showModalBottomSheet<CategoryPick>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (BuildContext sheetContext) => _CategoryPickerSheet(
      taxonomy: taxonomy,
      title: title ?? 'Choose a category',
      subtitle: subtitle,
      currentPath: currentPath,
      suggestions: suggestions,
    ),
  );
}

class _CategoryPickerSheet extends StatefulWidget {
  const _CategoryPickerSheet({
    required this.taxonomy,
    required this.title,
    required this.subtitle,
    required this.currentPath,
    required this.suggestions,
  });

  final List<CategoryDef> taxonomy;
  final String title;
  final String? subtitle;
  final String? currentPath;
  final List<String> suggestions;

  @override
  State<_CategoryPickerSheet> createState() => _CategoryPickerSheetState();
}

class _CategoryPickerSheetState extends State<_CategoryPickerSheet> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  bool _matches(CategoryDef category, SubcategoryDef sub) {
    if (_query.isEmpty) return true;
    final String q = _query.toLowerCase();
    return category.name.toLowerCase().contains(q) ||
        sub.name.toLowerCase().contains(q) ||
        category.id.contains(q) ||
        sub.id.contains(q);
  }

  void _pick(String path) {
    final CategoryKind? kind = kindOfPath(path, widget.taxonomy);
    if (kind == null) return;
    Navigator.of(context).pop(CategoryPick(path, kind));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.taxonomy.isEmpty) return const _TaxonomyNotLoaded();

    final List<String> suggestions = <String>{
      for (final String p in widget.suggestions)
        if (isKnownCategoryPath(p, widget.taxonomy)) p,
    }.take(6).toList(growable: false);

    final List<CategoryDef> visible = <CategoryDef>[
      for (final CategoryDef c in widget.taxonomy)
        if (c.subcategories.any((SubcategoryDef s) => _matches(c, s))) c,
    ];

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.78,
      minChildSize: 0.45,
      maxChildSize: 0.95,
      builder: (BuildContext context, ScrollController controller) {
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(
                  Insets.xl, 0, Insets.xl, Insets.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(widget.title, style: context.texts.titleLarge),
                  if (widget.subtitle != null) ...<Widget>[
                    const SizedBox(height: Insets.xxs),
                    Text(
                      widget.subtitle!,
                      style: context.texts.bodyMedium
                          ?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                  ],
                  const SizedBox(height: Insets.md),
                  TextField(
                    controller: _search,
                    textInputAction: TextInputAction.search,
                    onChanged: (String v) => setState(() => _query = v.trim()),
                    decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search, size: 20),
                      hintText: 'Search categories',
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear, size: 18),
                              onPressed: () {
                                _search.clear();
                                setState(() => _query = '');
                              },
                            ),
                      border: const OutlineInputBorder(
                          borderRadius: Radii.fieldBorder),
                    ),
                  ),
                ],
              ),
            ),
            if (suggestions.isNotEmpty && _query.isEmpty)
              _SuggestionRow(
                taxonomy: widget.taxonomy,
                paths: suggestions,
                currentPath: widget.currentPath,
                onPick: _pick,
              ),
            Expanded(
              child: visible.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(Insets.xxl),
                        child: Text(
                          'Nothing matches "$_query".',
                          style: context.texts.bodyMedium
                              ?.copyWith(color: context.colors.onSurfaceVariant),
                        ),
                      ),
                    )
                  : ListView.builder(
                      controller: controller,
                      padding: const EdgeInsets.fromLTRB(
                          Insets.lg, Insets.xs, Insets.lg, Insets.xxxl),
                      itemCount: visible.length,
                      itemBuilder: (BuildContext context, int i) => _CategoryGroup(
                        taxonomy: widget.taxonomy,
                        category: visible[i],
                        currentPath: widget.currentPath,
                        isVisible: (SubcategoryDef s) => _matches(visible[i], s),
                        onPick: _pick,
                      ),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _TaxonomyNotLoaded extends StatelessWidget {
  const _TaxonomyNotLoaded();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Insets.xxl, 0, Insets.xxl, Insets.xxxl),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.rule_folder_outlined,
              size: 40, color: context.colors.onSurfaceVariant),
          const SizedBox(height: Insets.md),
          Text('The category list has not loaded yet',
              style: context.texts.titleMedium, textAlign: TextAlign.center),
          const SizedBox(height: Insets.xs + 2),
          Text(
            'Close this and try again in a moment. If it keeps happening, '
            'Settings has a button to reset to the rules built into the app.',
            textAlign: TextAlign.center,
            style: context.texts.bodySmall
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.taxonomy,
    required this.paths,
    required this.currentPath,
    required this.onPick,
  });

  final List<CategoryDef> taxonomy;
  final List<String> paths;
  final String? currentPath;
  final void Function(String path) onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(
              Insets.xl, Insets.xs, Insets.xl, Insets.xs + 2),
          child: Text(
            'You used these recently',
            style: context.texts.labelMedium
                ?.copyWith(color: context.colors.onSurfaceVariant),
          ),
        ),
        SizedBox(
          height: 40,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: Insets.xl),
            itemCount: paths.length,
            separatorBuilder: (BuildContext _, int _) =>
                const SizedBox(width: Insets.sm),
            itemBuilder: (BuildContext context, int i) {
              final String path = paths[i];
              return ActionChip(
                avatar: Icon(CategoryIcons.forPath(path, taxonomy), size: 16),
                label: Text(shortCategoryLabel(path, taxonomy)),
                onPressed: () => onPick(path),
                backgroundColor:
                    path == currentPath ? context.colors.secondaryContainer : null,
              );
            },
          ),
        ),
        const SizedBox(height: Insets.sm),
      ],
    );
  }
}

class _CategoryGroup extends StatelessWidget {
  const _CategoryGroup({
    required this.taxonomy,
    required this.category,
    required this.currentPath,
    required this.isVisible,
    required this.onPick,
  });

  final List<CategoryDef> taxonomy;
  final CategoryDef category;
  final String? currentPath;
  final bool Function(SubcategoryDef sub) isVisible;
  final void Function(String path) onPick;

  @override
  Widget build(BuildContext context) {
    final Color accent = CategoryLabels.color(category.id, taxonomy) ??
        context.palette.forKind(category.kind);
    final List<SubcategoryDef> subs =
        category.subcategories.where(isVisible).toList(growable: false);
    if (subs.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.xl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(CategoryIcons.forName(category.icon), size: 18, color: accent),
              const SizedBox(width: Insets.sm),
              Flexible(
                child: Text(
                  category.name,
                  overflow: TextOverflow.ellipsis,
                  style: context.texts.titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (category.kind == CategoryKind.transfer ||
                  category.kind == CategoryKind.investment) ...<Widget>[
                const SizedBox(width: Insets.sm),
                const MetaChip(label: 'not spending'),
              ],
            ],
          ),
          const SizedBox(height: Insets.sm),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: <Widget>[
              for (final SubcategoryDef sub in subs)
                _SubChip(
                  label: sub.name,
                  accent: accent,
                  selected: currentPath == category.pathFor(sub.id),
                  onTap: () => onPick(category.pathFor(sub.id)),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SubChip extends StatelessWidget {
  const _SubChip({
    required this.label,
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final Color accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? context.colors.secondaryContainer
          : accent.withValues(alpha: 0.10),
      shape: StadiumBorder(
        side: BorderSide(
          color: selected ? accent : context.colors.outlineVariant,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
              horizontal: Insets.md + 2, vertical: Insets.sm + 1),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (selected) ...<Widget>[
                Icon(Icons.check, size: 15, color: accent),
                const SizedBox(width: Insets.xs + 1),
              ],
              Text(
                label,
                style: context.texts.bodyMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
