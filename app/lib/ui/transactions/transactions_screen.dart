import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:ledger/ui/widgets/widgets.dart';

import 'day_header.dart';
import 'filter_sheet.dart';
import 'transaction_detail_screen.dart';
import 'transactions_controller.dart';

/// The full ledger: searchable, filterable, grouped by day, paged.
///
/// Paging is offset-based and triggered by proximity to the end of the list
/// rather than by a "load more" button, so a long scroll never stalls. The list
/// holds at most the pages the user has actually scrolled through.
class TransactionsScreen extends ConsumerStatefulWidget {
  const TransactionsScreen({super.key});

  @override
  ConsumerState<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends ConsumerState<TransactionsScreen> {
  final ScrollController _scroll = ScrollController();
  final TextEditingController _search = TextEditingController();
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _search.text = ref.read(txnFilterProvider).search;
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll
      ..removeListener(_onScroll)
      ..dispose();
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final double remaining = _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 600) {
      unawaited(ref.read(transactionListProvider.notifier).loadMore());
    }
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    // A query per keystroke would hammer the database on a cheap phone; a short
    // pause after typing stops is indistinguishable from instant.
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      ref.read(txnFilterProvider.notifier).setSearch(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AsyncValue<TxnListState> listing = ref.watch(transactionListProvider);
    final TxnFilter filter = ref.watch(txnFilterProvider);
    final List<CategoryDef> taxonomy = ref.watch(taxonomyProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Transactions'),
        actions: <Widget>[
          IconButton(
            onPressed: () => _openFilters(filter, taxonomy),
            tooltip: 'Filter',
            icon: Badge(
              isLabelVisible: filter.activeCount > 0,
              label: Text('${filter.activeCount}'),
              child: const Icon(Icons.tune),
            ),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(64),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              Insets.page,
              0,
              Insets.page,
              Insets.md,
            ),
            child: TextField(
              controller: _search,
              onChanged: _onSearchChanged,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search merchant, note or reference',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _search,
                  builder: (BuildContext context, TextEditingValue value, Widget? _) {
                    if (value.text.isEmpty) return const SizedBox.shrink();
                    return IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Clear search',
                      onPressed: () {
                        _search.clear();
                        _onSearchChanged('');
                      },
                    );
                  },
                ),
                filled: true,
                border: const OutlineInputBorder(
                  borderRadius: Radii.fieldBorder,
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: Insets.sm),
              ),
            ),
          ),
        ),
      ),
      body: listing.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => ErrorState(
          message: describeError(error),
          onRetry: () => ref.invalidate(transactionListProvider),
        ),
        data: (TxnListState data) => _List(
          data: data,
          taxonomy: taxonomy,
          scroll: _scroll,
          now: ref.watch(clockProvider)(),
          onRefresh: () => ref.read(transactionListProvider.notifier).refresh(),
          onClearFilter: filter.isActive
              ? () {
                  _search.clear();
                  ref.read(txnFilterProvider.notifier).clear();
                }
              : null,
          onOpen: (Transaction txn) => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (BuildContext context) =>
                  TransactionDetailScreen(transactionId: txn.id),
            ),
          ),
          onQuickCategorize: (Transaction txn) => _quickCategorize(txn, taxonomy),
        ),
      ),
    );
  }

  Future<void> _openFilters(TxnFilter filter, List<CategoryDef> taxonomy) async {
    final List<Account> accounts =
        ref.read(accountsProvider).valueOrNull ?? const <Account>[];
    final TxnFilter? next = await showFilterSheet(
      context,
      current: filter,
      taxonomy: taxonomy,
      accounts: accounts,
      now: ref.read(clockProvider)(),
    );
    if (next == null || !mounted) return;
    _search.text = next.search;
    ref.read(txnFilterProvider.notifier).replace(next);
  }

  /// One tap to fix a category, and the fix becomes a standing rule whenever
  /// there is a merchant to hang it on. That is what makes the Uncategorized
  /// queue shrink instead of asking the same question every month.
  Future<void> _quickCategorize(Transaction txn, List<CategoryDef> taxonomy) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String merchant = (txn.merchantName ?? txn.merchantRaw ?? '').trim();
    final CategoryPick? pick = await showCategoryPicker(
      context,
      taxonomy: taxonomy,
      title: merchant.isEmpty ? 'Choose a category' : 'Where does $merchant go?',
      subtitle: 'Nothing is guessed, and nothing leaves this phone.',
      currentPath: txn.isUncategorized ? null : txn.categoryPath,
    );
    if (pick == null) return;
    final bool remember = merchant.isNotEmpty;
    final String? failure = await applyCategory(
      ref,
      transaction: txn,
      categoryPath: pick.path,
      kind: pick.kind,
      createUserRule: remember,
    );
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failure ??
              (remember
                  ? 'Saved. $merchant will go here from now on.'
                  : 'Saved.'),
        ),
      ),
    );
  }
}

class _List extends StatelessWidget {
  const _List({
    required this.data,
    required this.taxonomy,
    required this.scroll,
    required this.now,
    required this.onRefresh,
    required this.onOpen,
    required this.onQuickCategorize,
    this.onClearFilter,
  });

  final TxnListState data;
  final List<CategoryDef> taxonomy;
  final ScrollController scroll;
  final DateTime now;
  final Future<void> Function() onRefresh;
  final void Function(Transaction txn) onOpen;
  final void Function(Transaction txn) onQuickCategorize;
  final VoidCallback? onClearFilter;

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) {
      return RefreshIndicator(
        onRefresh: onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: <Widget>[
            SizedBox(height: MediaQuery.sizeOf(context).height * 0.15),
            EmptyState(
              icon: data.filter.isActive ? Icons.filter_alt_off_outlined : Icons.receipt_long_outlined,
              title: data.filter.isActive ? 'Nothing matches' : 'No transactions yet',
              message: data.filter.isActive
                  ? 'No transaction in the ledger matches this filter. Try widening '
                      'the dates or clearing a condition.'
                  : 'Transactions appear here as bank and UPI messages arrive. '
                      'Nothing has been recorded on this phone yet.',
              actionLabel: onClearFilter == null ? null : 'Clear filter',
              onAction: onClearFilter,
            ),
          ],
        ),
      );
    }

    final List<_Row> rows = _buildRows(data.items, now);
    final int footerCount = data.hasMore || data.pageError != null ? 1 : 0;

    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView.builder(
        controller: scroll,
        padding: Pads.scrollTail,
        itemCount: rows.length + footerCount,
        itemBuilder: (BuildContext context, int index) {
          if (index >= rows.length) {
            return _Footer(error: data.pageError);
          }
          final _Row row = rows[index];
          return switch (row) {
            _HeaderRow(:final String label, :final Money total) =>
              DayHeader(label: label, total: total),
            _TxnRow(:final Transaction txn) => TransactionRow(
                transaction: txn,
                taxonomy: taxonomy,
                onTap: () => onOpen(txn),
                // A long press is the shortcut for the one thing a user does
                // repeatedly in this list: name an unknown merchant.
                onLongPress: () => onQuickCategorize(txn),
              ),
          };
        },
      ),
    );
  }

  /// Flattens the page into headers and rows once per build, rather than
  /// grouping inside the item builder where it would run per visible row.
  static List<_Row> _buildRows(List<Transaction> items, DateTime now) {
    final List<_Row> rows = <_Row>[];
    String? currentKey;
    int headerIndex = -1;
    final List<Money> dayTotals = <Money>[];

    for (final Transaction txn in items) {
      if (txn.bookingDate != currentKey) {
        if (headerIndex >= 0) {
          rows[headerIndex] = _HeaderRow(
            label: (rows[headerIndex] as _HeaderRow).label,
            total: Money.sum(dayTotals),
          );
          dayTotals.clear();
        }
        currentKey = txn.bookingDate;
        final DateTime? day = Fmt.parseBookingDate(txn.bookingDate);
        rows.add(_HeaderRow(
          label: day == null
              ? txn.bookingDate
              : Fmt.dayHeading(day, now: now),
          total: Money.zero,
        ));
        headerIndex = rows.length - 1;
      }
      if (txn.countsAsSpend) dayTotals.add(txn.amount);
      rows.add(_TxnRow(txn));
    }

    if (headerIndex >= 0) {
      rows[headerIndex] = _HeaderRow(
        label: (rows[headerIndex] as _HeaderRow).label,
        total: Money.sum(dayTotals),
      );
    }
    return rows;
  }
}

class _Footer extends StatelessWidget {
  const _Footer({this.error});

  final String? error;

  @override
  Widget build(BuildContext context) {
    final String? message = error;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Insets.xxl),
      child: Center(
        child: message == null
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(
                message,
                style: context.texts.bodySmall?.copyWith(
                  color: context.colors.error,
                ),
                textAlign: TextAlign.center,
              ),
      ),
    );
  }
}

sealed class _Row {
  const _Row();
}

class _HeaderRow extends _Row {
  const _HeaderRow({required this.label, required this.total});

  final String label;
  final Money total;
}

class _TxnRow extends _Row {
  const _TxnRow(this.txn);

  final Transaction txn;
}
