import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:ledger/ui/transactions/transactions_controller.dart';

import 'category_donut.dart';
import 'dashboard_controller.dart';
import 'home_shell.dart';

/// The month view: what came in, what went out, where it went, and what is
/// still waiting to be named.
///
/// Every number on this screen is a rollup the repository computed with
/// `Transaction.countsAsSpend`, so transfers, investments and credit-card bill
/// payments never inflate the headline. That restraint is the whole reason the
/// headline is believable.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<MonthSummary> summary = ref.watch(currentMonthSummaryProvider);
    final DateTime month = ref.watch(selectedMonthProvider);
    final SelectedMonth months = ref.read(selectedMonthProvider.notifier);
    final int uncategorized = ref.watch(uncategorizedCountProvider).valueOrNull ?? 0;
    final List<CategoryDef> taxonomy = ref.watch(taxonomyProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Ledger'),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(52),
          child: _MonthStrip(
            month: month,
            canGoForward: months.canGoForward,
            onPrevious: months.previous,
            onNext: months.next,
          ),
        ),
      ),
      body: summary.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => ErrorState(
          message: describeError(error),
          onRetry: () => ref.invalidate(monthSummaryProvider),
        ),
        data: (MonthSummary data) => ListView(
          padding: const EdgeInsets.fromLTRB(
            Insets.page,
            Insets.lg,
            Insets.page,
            Insets.huge,
          ),
          children: <Widget>[
            ContentWidth(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  if (uncategorized > 0) ...<Widget>[
                    AttentionBanner(
                      title: Fmt.plural(
                        uncategorized,
                        'transaction needs a category',
                        'transactions need a category',
                      ),
                      message: 'The app will not guess. One tap each, and it '
                          'remembers the merchant for good.',
                      icon: Icons.help_outline,
                      actionLabel: 'Review them',
                      onAction: () => _openUncategorized(ref),
                    ),
                    const SizedBox(height: Insets.lg),
                  ],
                  _SummaryCard(summary: data),
                  const SizedBox(height: Insets.lg),
                  _BreakdownCard(
                    summary: data,
                    taxonomy: taxonomy,
                    onSlice: (DonutSlice slice) =>
                        _openCategory(ref, data.range, slice.categoryPath),
                  ),
                  const SizedBox(height: Insets.lg),
                  _MerchantsCard(summary: data),
                  const SizedBox(height: Insets.lg),
                  OutlinedButton.icon(
                    onPressed: () => _openMonth(ref, data.range),
                    icon: const Icon(Icons.list_alt_outlined),
                    label: const Text('See every transaction this month'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The review queue is its own tab, built for answering many at once, so the
  /// banner sends the user there rather than to a filtered ledger.
  void _openUncategorized(WidgetRef ref) {
    ref.read(homeTabProvider.notifier).state = HomeTab.review;
  }

  void _openMonth(WidgetRef ref, MonthRange range) {
    ref.read(txnFilterProvider.notifier).replace(
          TxnFilter(from: range.from, to: range.to),
        );
    ref.read(homeTabProvider.notifier).state = HomeTab.transactions;
  }

  void _openCategory(WidgetRef ref, MonthRange range, String? categoryPath) {
    if (categoryPath == null) return;
    ref.read(txnFilterProvider.notifier).replace(
          TxnFilter(
            from: range.from,
            to: range.to,
            categoryPaths: <String>{categoryPath},
          ),
        );
    ref.read(homeTabProvider.notifier).state = HomeTab.transactions;
  }
}

class _MonthStrip extends StatelessWidget {
  const _MonthStrip({
    required this.month,
    required this.canGoForward,
    required this.onPrevious,
    required this.onNext,
  });

  final DateTime month;
  final bool canGoForward;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.sm),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          IconButton(
            onPressed: onPrevious,
            tooltip: 'Previous month',
            icon: const Icon(Icons.chevron_left),
          ),
          SizedBox(
            width: 180,
            child: Text(
              Fmt.month(month),
              style: context.texts.titleMedium,
              textAlign: TextAlign.center,
            ),
          ),
          IconButton(
            onPressed: canGoForward ? onNext : null,
            tooltip: 'Next month',
            icon: const Icon(Icons.chevron_right),
          ),
        ],
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});

  final MonthSummary summary;

  @override
  Widget build(BuildContext context) {
    final LedgerPalette palette = context.palette;
    final bool positive = !summary.net.isNegative;
    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Spent',
            style: context.texts.labelLarge?.copyWith(
              color: context.colors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: Insets.xxs),
          Text(
            Fmt.moneyWhole(summary.spent),
            style: AppTheme.tabular(context.texts.displaySmall)
                .copyWith(color: palette.expense),
          ),
          const SizedBox(height: Insets.lg),
          Row(
            children: <Widget>[
              Expanded(
                child: _Figure(
                  label: 'Received',
                  value: Fmt.moneyWhole(summary.income),
                  color: palette.income,
                ),
              ),
              Expanded(
                child: _Figure(
                  label: positive ? 'Left over' : 'Short by',
                  value: Fmt.moneyWhole(summary.net.abs),
                  color: positive ? palette.income : palette.expense,
                ),
              ),
            ],
          ),
          if (!summary.transferred.isZero || !summary.invested.isZero) ...<Widget>[
            const SizedBox(height: Insets.lg),
            const Divider(height: 1),
            const SizedBox(height: Insets.md),
            Wrap(
              spacing: Insets.sm,
              runSpacing: Insets.sm,
              children: <Widget>[
                if (!summary.transferred.isZero)
                  MetaChip(
                    icon: Icons.swap_horiz,
                    label: '${Fmt.moneyWhole(summary.transferred)} moved between '
                        'your accounts',
                    tone: palette.transfer,
                  ),
                if (!summary.invested.isZero)
                  MetaChip(
                    icon: Icons.trending_up,
                    label: '${Fmt.moneyWhole(summary.invested)} invested',
                    tone: palette.investment,
                  ),
              ],
            ),
            const SizedBox(height: Insets.sm),
            Text(
              'Neither is counted as spending - it is still your money.',
              style: context.texts.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, required this.color});

  final String label;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: context.texts.labelMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: Insets.xxs),
        Text(
          value,
          style: AppTheme.tabular(context.texts.titleLarge).copyWith(color: color),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

class _BreakdownCard extends StatelessWidget {
  const _BreakdownCard({
    required this.summary,
    required this.taxonomy,
    required this.onSlice,
  });

  final MonthSummary summary;
  final List<CategoryDef> taxonomy;
  final void Function(DonutSlice slice) onSlice;

  /// Slices beyond this are folded into "Everything else", so the ring stays
  /// readable and the legend stays a glance rather than a list.
  static const int maxSlices = 6;

  @override
  Widget build(BuildContext context) {
    final LedgerPalette palette = context.palette;
    final List<SpendBucket> buckets = summary.byCategory
        .where((SpendBucket b) => b.total.paise != 0)
        .toList(growable: false);

    if (buckets.isEmpty) {
      return SectionCard(
        title: 'Where it went',
        child: EmptyState(
          icon: Icons.donut_large_outlined,
          title: 'Nothing spent yet',
          message: summary.isEmpty
              ? 'No transactions were recorded in ${Fmt.month(summary.range.from)}.'
              : 'There was activity this month, but none of it counted as '
                  'spending.',
          compact: true,
        ),
      );
    }

    final List<DonutSlice> slices = <DonutSlice>[];
    for (int i = 0; i < buckets.length && i < maxSlices; i++) {
      final SpendBucket bucket = buckets[i];
      slices.add(DonutSlice(
        label: bucket.label ?? CategoryLabels.topLevel(bucket.key, taxonomy),
        amount: bucket.total,
        color: CategoryLabels.color(bucket.key, taxonomy) ?? palette.seriesAt(i),
        categoryPath: bucket.key,
      ));
    }
    if (buckets.length > maxSlices) {
      slices.add(DonutSlice(
        label: 'Everything else',
        amount: Money.sum(
          buckets.sublist(maxSlices).map((SpendBucket b) => b.total),
        ),
        color: palette.chartTrack,
      ));
    }

    return SectionCard(
      title: 'Where it went',
      child: Column(
        children: <Widget>[
          Center(
            child: CategoryDonut(slices: slices, total: summary.spent),
          ),
          const SizedBox(height: Insets.lg),
          DonutLegend(
            slices: slices,
            total: summary.spent,
            onTap: (DonutSlice slice) {
              if (slice.categoryPath != null) onSlice(slice);
            },
          ),
        ],
      ),
    );
  }
}

class _MerchantsCard extends StatelessWidget {
  const _MerchantsCard({required this.summary});

  final MonthSummary summary;

  @override
  Widget build(BuildContext context) {
    final List<SpendBucket> merchants = summary.topMerchants
        .where((SpendBucket b) => b.total.paise != 0)
        .toList(growable: false);

    if (merchants.isEmpty) {
      return SectionCard(
        title: 'Top merchants',
        child: EmptyState(
          icon: Icons.storefront_outlined,
          title: 'No merchants yet',
          message: 'Merchants appear here once there are transactions to rank.',
          compact: true,
        ),
      );
    }

    final int topPaise = merchants.first.total.paise.abs();
    return SectionCard(
      title: 'Top merchants',
      child: Column(
        children: <Widget>[
          for (final SpendBucket merchant in merchants)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.sm),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          merchant.label ?? merchant.key,
                          style: context.texts.bodyMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: Insets.sm),
                      Text(
                        Fmt.moneyWhole(merchant.total),
                        style: AppTheme.tabular(context.texts.bodyMedium),
                      ),
                    ],
                  ),
                  const SizedBox(height: Insets.xs),
                  ClipRRect(
                    borderRadius: Radii.pill,
                    child: LinearProgressIndicator(
                      value: topPaise == 0
                          ? 0
                          : merchant.total.paise.abs() / topPaise,
                      minHeight: 4,
                    ),
                  ),
                  const SizedBox(height: Insets.xxs),
                  Text(
                    Fmt.plural(merchant.count, 'transaction', 'transactions'),
                    style: context.texts.labelSmall?.copyWith(
                      color: context.colors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
