import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';

/// A half-open month `[from, to)` in local time, which is the window every
/// rollup on the dashboard is computed over.
///
/// Local, not UTC, deliberately: a payment at 00:30 IST belongs to that day in
/// the user's life, and `Transaction.bookingDate` is built the same way.
@immutable
class MonthRange {
  const MonthRange(this.from, this.to);

  factory MonthRange.of(DateTime month) => MonthRange(
        DateTime(month.year, month.month),
        DateTime(month.year, month.month + 1),
      );

  final DateTime from;
  final DateTime to;

  bool contains(DateTime at) {
    final DateTime local = at.toLocal();
    return !local.isBefore(from) && local.isBefore(to);
  }

  @override
  bool operator ==(Object other) =>
      other is MonthRange &&
      other.from.isAtSameMomentAs(from) &&
      other.to.isAtSameMomentAs(to);

  @override
  int get hashCode => Object.hash(from.millisecondsSinceEpoch, to.millisecondsSinceEpoch);

  @override
  String toString() => 'MonthRange($from -> $to)';
}

/// Which month the dashboard is showing. Starts on the current one and never
/// walks past it - there is no spending in the future to look at.
class SelectedMonth extends Notifier<DateTime> {
  @override
  DateTime build() {
    final DateTime now = ref.watch(clockProvider)();
    return DateTime(now.year, now.month);
  }

  DateTime get _thisMonth {
    final DateTime now = ref.read(clockProvider)();
    return DateTime(now.year, now.month);
  }

  bool get canGoForward => state.isBefore(_thisMonth);

  void previous() => state = DateTime(state.year, state.month - 1);

  void next() {
    final DateTime candidate = DateTime(state.year, state.month + 1);
    if (candidate.isAfter(_thisMonth)) return;
    state = candidate;
  }

  void jumpTo(DateTime month) {
    final DateTime candidate = DateTime(month.year, month.month);
    state = candidate.isAfter(_thisMonth) ? _thisMonth : candidate;
  }

  void today() => state = _thisMonth;
}

final NotifierProvider<SelectedMonth, DateTime> selectedMonthProvider =
    NotifierProvider<SelectedMonth, DateTime>(SelectedMonth.new);

final Provider<MonthRange> selectedRangeProvider = Provider<MonthRange>(
  (Ref ref) => MonthRange.of(ref.watch(selectedMonthProvider)),
);

/// Everything the dashboard shows for one month.
@immutable
class MonthSummary {
  const MonthSummary({
    required this.range,
    required this.spent,
    required this.income,
    required this.byCategory,
    required this.topMerchants,
    required this.transferred,
    required this.invested,
    required this.transactionCount,
  });

  const MonthSummary.empty(this.range)
      : spent = Money.zero,
        income = Money.zero,
        transferred = Money.zero,
        invested = Money.zero,
        byCategory = const <SpendBucket>[],
        topMerchants = const <SpendBucket>[],
        transactionCount = 0;

  final MonthRange range;

  /// Expense debits only. Transfers, investments and card bill payments are
  /// never in here - that is the whole point of `Transaction.countsAsSpend`.
  final Money spent;

  final Money income;

  /// Money moved between the user's own accounts. Reported, never counted as
  /// spending, so a credit-card bill payment does not double-count the swipes.
  final Money transferred;

  /// Money moved into investments. Also the user's own money.
  final Money invested;

  final List<SpendBucket> byCategory;
  final List<SpendBucket> topMerchants;
  final int transactionCount;

  /// Income minus spend. Transfers and investments are excluded by
  /// construction, so this is the month's real change in position.
  Money get net => income - spent;

  bool get isEmpty => transactionCount == 0;
}

/// The month rollup, recomputed whenever the month's ledger changes.
///
/// `watchTotalSpend` is used purely as the change signal: the repository emits
/// it immediately and again on every write, which is exactly when the rest of
/// the rollup needs redoing.
final monthSummaryProvider =
    StreamProvider.family<MonthSummary, MonthRange>((Ref ref, MonthRange range) async* {
  final LedgerRepository repo = ref.watch(ledgerRepositoryProvider);
  await for (final Money spent in repo.watchTotalSpend(from: range.from, to: range.to)) {
    yield await _buildSummary(repo, range, spent);
  }
});

/// The summary for the month the user is currently looking at.
final Provider<AsyncValue<MonthSummary>> currentMonthSummaryProvider =
    Provider<AsyncValue<MonthSummary>>(
  (Ref ref) => ref.watch(monthSummaryProvider(ref.watch(selectedRangeProvider))),
);

Future<MonthSummary> _buildSummary(
  LedgerRepository repo,
  MonthRange range,
  Money spent,
) async {
  final List<Object> results = await Future.wait<Object>(<Future<Object>>[
    repo.totalIncome(from: range.from, to: range.to),
    repo.spendByCategory(from: range.from, to: range.to),
    repo.spendByMerchant(from: range.from, to: range.to, limit: 5),
    repo.transactions(TxnQuery(
      from: range.from,
      to: range.to,
      // A month of a heavy user's ledger, with headroom. Bounded on purpose:
      // the dashboard must not degrade as the ledger grows for years.
      limit: 2000,
      includeExcluded: true,
    )),
  ]);

  final Money income = unwrap(results[0] as Result<Money>);
  final List<SpendBucket> byCategory = unwrap(results[1] as Result<List<SpendBucket>>);
  final List<SpendBucket> merchants = unwrap(results[2] as Result<List<SpendBucket>>);
  final List<Transaction> all = unwrap(results[3] as Result<List<Transaction>>);

  // Transfers and investments are summed here rather than asked of the
  // repository, whose rollups only ever report spend and income. They are shown
  // so the month adds up for the user, and counted in nothing.
  final List<Money> transfers = <Money>[];
  final List<Money> investments = <Money>[];
  for (final Transaction txn in all) {
    if (!txn.status.countsInTotals || txn.direction.isCredit) continue;
    switch (txn.kind) {
      case CategoryKind.transfer:
        transfers.add(txn.amount);
      case CategoryKind.investment:
        investments.add(txn.amount);
      case CategoryKind.expense:
      case CategoryKind.income:
        break;
    }
  }

  return MonthSummary(
    range: range,
    spent: spent,
    income: income,
    byCategory: byCategory,
    topMerchants: merchants,
    transferred: Money.sum(transfers),
    invested: Money.sum(investments),
    transactionCount: all.length,
  );
}
