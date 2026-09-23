import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:ledger/ui/widgets/widgets.dart';

import 'categories_controller.dart';
import 'category_detail_screen.dart';
import 'rules_tab.dart';

/// Where the money went, and what the app has learned.
///
/// Two tabs because they answer the two questions a user brings here. The
/// first is "what did I spend on?" - the taxonomy with this month's totals
/// against it. The second is "why did it think that?" - the rules the app has
/// learned from this user, every one of them editable and deletable.
class CategoriesScreen extends ConsumerWidget {
  const CategoriesScreen({super.key});

  static const String routeName = '/categories';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Categories'),
          bottom: const TabBar(
            tabs: <Widget>[
              Tab(text: 'Spending'),
              Tab(text: 'My rules'),
            ],
          ),
        ),
        body: const TabBarView(
          children: <Widget>[
            _SpendingTab(),
            RulesTab(),
          ],
        ),
      ),
    );
  }
}

class _SpendingTab extends ConsumerWidget {
  const _SpendingTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<SpendBucket>> spend = ref.watch(categorySpendProvider);
    final List<CategoryRollup> rollups = ref.watch(categoryRollupsProvider);
    final List<CategoryDef> taxonomy = ref.watch(taxonomyProvider);

    return Column(
      children: <Widget>[
        const _MonthStrip(),
        const Divider(height: 1),
        Expanded(
          child: spend.when(
            loading: () => const SkeletonList(count: 6),
            error: (Object error, StackTrace _) => ErrorState(
              message: 'The category totals could not be calculated. Your '
                  'transactions are unaffected.',
              onRetry: () => ref.invalidate(categorySpendProvider),
            ),
            data: (List<SpendBucket> buckets) {
              if (taxonomy.isEmpty) {
                return const EmptyState(
                  icon: Icons.rule_folder_outlined,
                  title: 'The category list has not loaded',
                  message: 'The app ships with its categories built in, so '
                      'this should only ever be momentary.',
                );
              }
              return _RollupList(rollups: rollups, taxonomy: taxonomy);
            },
          ),
        ),
      ],
    );
  }
}

/// The month the totals are for, with the two arrows that change it.
class _MonthStrip extends ConsumerWidget {
  const _MonthStrip();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final MonthRange month = ref.watch(categoriesMonthProvider);
    final DateTime now = ref.watch(clockProvider)();
    final bool atCurrentMonth = month.containsNow(now);
    final AsyncValue<Money> total = ref.watch(categoriesMonthSpendProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(
          Insets.sm, Insets.sm, Insets.sm, Insets.md),
      child: Row(
        children: <Widget>[
          IconButton(
            tooltip: 'Previous month',
            icon: const Icon(Icons.chevron_left),
            onPressed: () => ref.read(categoriesMonthProvider.notifier).state =
                month.previous,
          ),
          Expanded(
            child: Column(
              children: <Widget>[
                Text(
                  Fmt.month(month.from),
                  style: context.texts.titleMedium
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
                const SizedBox(height: Insets.xxs),
                total.when(
                  loading: () => const SkeletonBox(width: 110, height: 13),
                  error: (Object _, StackTrace _) => Text(
                    'Total unavailable',
                    style: context.texts.bodySmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                  data: (Money value) => Text(
                    '${Fmt.moneyWhole(value)} spent',
                    style: context.texts.bodySmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: atCurrentMonth ? 'This is the current month' : 'Next month',
            icon: const Icon(Icons.chevron_right),
            onPressed: atCurrentMonth
                ? null
                : () => ref.read(categoriesMonthProvider.notifier).state =
                    month.next,
          ),
        ],
      ),
    );
  }
}

class _RollupList extends StatelessWidget {
  const _RollupList({required this.rollups, required this.taxonomy});

  final List<CategoryRollup> rollups;
  final List<CategoryDef> taxonomy;

  @override
  Widget build(BuildContext context) {
    final List<CategoryRollup> used =
        rollups.where((CategoryRollup r) => !r.isEmpty).toList(growable: false);
    final List<CategoryRollup> unused =
        rollups.where((CategoryRollup r) => r.isEmpty).toList(growable: false);

    final Money spendTotal = Money.sum(
      used.where((CategoryRollup r) => r.countsAsSpend).map((CategoryRollup r) => r.total),
    );

    return ContentWidth(
      child: ListView(
        padding: const EdgeInsets.only(bottom: Insets.huge),
        children: <Widget>[
          if (used.isEmpty)
            const EmptyState(
              icon: Icons.insights_outlined,
              title: 'Nothing recorded this month',
              message: 'Categories with activity show up here with their '
                  'totals. Browse the full list below to see what the app '
                  'can recognise.',
              compact: true,
            )
          else
            for (final CategoryRollup rollup in used)
              _RollupRow(
                rollup: rollup,
                taxonomy: taxonomy,
                spendTotal: spendTotal,
              ),
          if (unused.isNotEmpty)
            _UnusedCategories(rollups: unused, taxonomy: taxonomy),
        ],
      ),
    );
  }
}

class _RollupRow extends ConsumerWidget {
  const _RollupRow({
    required this.rollup,
    required this.taxonomy,
    required this.spendTotal,
  });

  final CategoryRollup rollup;
  final List<CategoryDef> taxonomy;
  final Money spendTotal;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final double share = rollup.countsAsSpend && spendTotal.paise > 0
        ? (rollup.total.paise / spendTotal.paise).clamp(0.0, 1.0)
        : 0.0;
    final Color accent = CategoryLabels.color(rollup.categoryId, taxonomy) ??
        context.palette.forKind(rollup.kind);

    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => CategoryDetailScreen(
            categoryId: rollup.categoryId,
            month: ref.read(categoriesMonthProvider),
          ),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: Insets.lg, vertical: Insets.md),
        child: Row(
          children: <Widget>[
            CategoryAvatar(categoryPath: rollup.categoryId, taxonomy: taxonomy),
            const SizedBox(width: Insets.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          rollup.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: context.texts.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      AmountText(
                        amount: rollup.total,
                        kind: rollup.kind,
                        showSign: false,
                        muted: !rollup.countsAsSpend,
                        style: context.texts.bodyLarge
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                  const SizedBox(height: Insets.xs),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: share,
                      minHeight: 5,
                      backgroundColor: context.palette.chartTrack,
                      valueColor: AlwaysStoppedAnimation<Color>(accent),
                    ),
                  ),
                  const SizedBox(height: Insets.xs),
                  Text(
                    <String>[
                      Fmt.plural(rollup.count, 'transaction', 'transactions'),
                      if (rollup.countsAsSpend && spendTotal.paise > 0)
                        '${(share * 100).round()}% of spending'
                      else if (!rollup.countsAsSpend)
                        'not counted as spending',
                    ].join(' · '),
                    style: context.texts.bodySmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Insets.xs),
            Icon(Icons.chevron_right, color: context.colors.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}

/// The rest of the taxonomy, so the screen is a browser and not just a report.
class _UnusedCategories extends ConsumerStatefulWidget {
  const _UnusedCategories({required this.rollups, required this.taxonomy});

  final List<CategoryRollup> rollups;
  final List<CategoryDef> taxonomy;

  @override
  ConsumerState<_UnusedCategories> createState() => _UnusedCategoriesState();
}

class _UnusedCategoriesState extends ConsumerState<_UnusedCategories> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Divider(height: Insets.xxl),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: Insets.lg),
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.sm),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      'Nothing this month in '
                      '${Fmt.plural(widget.rollups.length, 'category', 'categories')}',
                      style: context.texts.labelLarge
                          ?.copyWith(color: context.colors.onSurfaceVariant),
                    ),
                  ),
                  Icon(_open ? Icons.expand_less : Icons.expand_more,
                      color: context.colors.onSurfaceVariant),
                ],
              ),
            ),
          ),
        ),
        if (_open)
          Padding(
            padding: const EdgeInsets.fromLTRB(
                Insets.lg, 0, Insets.lg, Insets.lg),
            child: Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.sm,
              children: <Widget>[
                for (final CategoryRollup rollup in widget.rollups)
                  CategoryChip(
                    categoryPath: rollup.categoryId,
                    taxonomy: widget.taxonomy,
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (BuildContext _) => CategoryDetailScreen(
                          categoryId: rollup.categoryId,
                          month: ref.read(categoriesMonthProvider),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
