import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:ledger/ui/widgets/widgets.dart';

import 'categories_controller.dart';

/// One category, broken into its subcategories and then into the actual
/// transactions.
///
/// The point of the screen is that a total can always be taken apart. A number
/// the user cannot drill into is a number they have to take on faith, and an
/// expense tracker that asks for faith gets uninstalled.
class CategoryDetailScreen extends ConsumerStatefulWidget {
  const CategoryDetailScreen({
    required this.categoryId,
    required this.month,
    super.key,
  });

  final String categoryId;
  final MonthRange month;

  @override
  ConsumerState<CategoryDetailScreen> createState() =>
      _CategoryDetailScreenState();
}

class _CategoryDetailScreenState extends ConsumerState<CategoryDetailScreen> {
  String? _subcategoryPath;

  @override
  Widget build(BuildContext context) {
    final List<CategoryDef> taxonomy = ref.watch(taxonomyProvider);
    final List<CategoryRollup> rollups = ref.watch(categoryRollupsProvider);
    final CategoryRollup? rollup = _find(rollups, widget.categoryId);
    final CategoryDef? def = categoryDefOf(widget.categoryId, taxonomy);

    final AsyncValue<List<Transaction>> feed = ref.watch(
      categoryFeedProvider(
        CategoryFeedArgs(
          categoryId: widget.categoryId,
          month: widget.month,
          subcategoryPath: _subcategoryPath,
        ),
      ),
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(def?.name ?? CategoryLabels.topLevel(widget.categoryId, taxonomy)),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(24),
          child: Padding(
            padding: const EdgeInsets.only(bottom: Insets.sm),
            child: Text(
              Fmt.month(widget.month.from),
              style: context.texts.labelMedium
                  ?.copyWith(color: context.colors.onSurfaceVariant),
            ),
          ),
        ),
      ),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.only(bottom: Insets.huge),
          children: <Widget>[
            if (rollup != null) _Summary(rollup: rollup, taxonomy: taxonomy),
            if (def != null && def.subcategories.isNotEmpty)
              _SubcategoryFilter(
                def: def,
                rollup: rollup,
                selected: _subcategoryPath,
                onSelect: (String? path) =>
                    setState(() => _subcategoryPath = path),
              ),
            const Divider(height: Insets.xxl),
            feed.when(
              loading: () => const SkeletonList(count: 5),
              error: (Object _, StackTrace _) => const ErrorState(
                message: 'These transactions could not be read from the local '
                    'database.',
              ),
              data: (List<Transaction> transactions) {
                if (transactions.isEmpty) {
                  return EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: 'Nothing here in ${Fmt.month(widget.month.from)}',
                    message: _subcategoryPath == null
                        ? 'No transaction was filed under this category in '
                            'this month.'
                        : 'Nothing in this subcategory. Tap "All" above to see '
                            'the whole category.',
                    compact: true,
                  );
                }
                return Column(
                  children: <Widget>[
                    for (final Transaction txn in transactions)
                      TransactionRow(
                        key: ValueKey<String>(txn.id),
                        transaction: txn,
                        taxonomy: taxonomy,
                        showCategory: _subcategoryPath == null,
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  static CategoryRollup? _find(List<CategoryRollup> rollups, String id) {
    for (final CategoryRollup r in rollups) {
      if (r.categoryId == id) return r;
    }
    return null;
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.rollup, required this.taxonomy});

  final CategoryRollup rollup;
  final List<CategoryDef> taxonomy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Insets.lg, Insets.lg, Insets.lg, Insets.sm),
      child: Row(
        children: <Widget>[
          CategoryAvatar(
            categoryPath: rollup.categoryId,
            taxonomy: taxonomy,
            size: 48,
          ),
          const SizedBox(width: Insets.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                AmountText(
                  amount: rollup.total,
                  kind: rollup.kind,
                  showSign: false,
                  muted: !rollup.countsAsSpend,
                  style: context.texts.headlineSmall,
                ),
                const SizedBox(height: Insets.xxs),
                Text(
                  rollup.countsAsSpend
                      ? Fmt.plural(rollup.count, 'transaction', 'transactions')
                      : '${Fmt.plural(rollup.count, 'transaction', 'transactions')} '
                          '· not counted as spending',
                  style: context.texts.bodySmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SubcategoryFilter extends StatelessWidget {
  const _SubcategoryFilter({
    required this.def,
    required this.rollup,
    required this.selected,
    required this.onSelect,
  });

  final CategoryDef def;
  final CategoryRollup? rollup;
  final String? selected;
  final ValueChanged<String?> onSelect;

  Money _totalFor(String path) {
    for (final SpendBucket bucket in rollup?.subtotals ?? const <SpendBucket>[]) {
      if (bucket.key == path) return bucket.total;
    }
    return Money.zero;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
      child: Wrap(
        spacing: Insets.sm,
        runSpacing: Insets.sm,
        children: <Widget>[
          ChoiceChip(
            label: const Text('All'),
            selected: selected == null,
            onSelected: (bool _) => onSelect(null),
          ),
          for (final SubcategoryDef sub in def.subcategories)
            Builder(
              builder: (BuildContext context) {
                final String path = def.pathFor(sub.id);
                final Money total = _totalFor(path);
                return ChoiceChip(
                  label: Text(
                    total.isZero
                        ? sub.name
                        : '${sub.name}  ${Fmt.moneyCompact(total)}',
                  ),
                  selected: selected == path,
                  onSelected: (bool on) => onSelect(on ? path : null),
                );
              },
            ),
        ],
      ),
    );
  }
}
