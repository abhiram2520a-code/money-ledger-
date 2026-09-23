import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/contracts/contracts.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:ledger/ui/widgets/widgets.dart';

import 'transactions_controller.dart';

/// One transaction, with its evidence.
///
/// This screen is the answer to the structural weakness of an SMS parser: it
/// will sometimes be wrong. A wrong answer the user can see the reasoning for
/// is a fixable mistake; the same wrong answer with no explanation is an
/// untrustworthy black box. Same error rate, completely different product.
///
/// So the screen shows the source message verbatim, the rule that read it, how
/// sure the app was, and why the category was chosen - and puts a one-tap fix
/// next to all of it. The fix becomes a standing rule, so the correction is
/// worth making once.
class TransactionDetailScreen extends ConsumerWidget {
  const TransactionDetailScreen({required this.transactionId, super.key});

  final String transactionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<TransactionDetail> detail =
        ref.watch(transactionDetailProvider(transactionId));
    final List<CategoryDef> taxonomy = ref.watch(taxonomyProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('Transaction')),
      body: detail.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (Object error, StackTrace stack) => ErrorState(
          message: describeError(error),
          onRetry: () => ref.invalidate(transactionDetailProvider(transactionId)),
        ),
        data: (TransactionDetail data) => _Body(detail: data, taxonomy: taxonomy),
      ),
    );
  }
}

class _Body extends ConsumerWidget {
  const _Body({required this.detail, required this.taxonomy});

  final TransactionDetail detail;
  final List<CategoryDef> taxonomy;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Transaction txn = detail.transaction;

    return ListView(
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
              _Headline(transaction: txn, taxonomy: taxonomy),
              const SizedBox(height: Insets.xl),
              _CategoryCard(
                transaction: txn,
                taxonomy: taxonomy,
                matchedRule: detail.matchedRule,
                onChange: () => _recategorize(context, ref, txn),
              ),
              const SizedBox(height: Insets.lg),
              _SourceCard(transaction: txn, rawMessage: detail.rawMessage),
              const SizedBox(height: Insets.lg),
              _FactsCard(transaction: txn),
              const SizedBox(height: Insets.lg),
              SectionCard(
                title: 'Counting',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _countingExplanation(txn),
                      style: context.texts.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                    SwitchListTile.adaptive(
                      value: txn.isExcludedFromTotals,
                      onChanged: (bool value) => _setExcluded(context, ref, txn, value),
                      title: const Text('Leave out of totals'),
                      subtitle: const Text(
                        'Keeps the row in the ledger but takes it out of the '
                        'monthly spend.',
                      ),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: Insets.xl),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(
                    Icons.lock_outline,
                    size: 14,
                    color: context.colors.onSurfaceVariant,
                  ),
                  const SizedBox(width: Insets.xs),
                  Flexible(
                    child: Text(
                      'Read and parsed on this phone. Never sent anywhere.',
                      style: context.texts.bodySmall?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  static String _countingExplanation(Transaction txn) {
    if (txn.isExcludedFromTotals) {
      return 'You have excluded this, so it is in no total.';
    }
    return switch (txn.kind) {
      CategoryKind.expense => txn.direction.isDebit
          ? 'Counted as spending on ${txn.bookingDate}.'
          : 'A credit against an expense category. It is shown, but it does not '
              'count as income.',
      CategoryKind.income => 'Counted as income.',
      CategoryKind.transfer =>
        'Money moved between your own accounts, so it is shown but never counted '
            'as spending. This is what stops a credit-card bill payment from '
            'double-counting the card spend.',
      CategoryKind.investment =>
        'Money moved into an investment. Still yours, so it is shown but not '
            'counted as spending.',
    };
  }

  Future<void> _recategorize(
    BuildContext context,
    WidgetRef ref,
    Transaction txn,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final String merchant = (txn.merchantName ?? txn.merchantRaw ?? '').trim();
    final CategoryPick? pick = await showCategoryPicker(
      context,
      taxonomy: taxonomy,
      title: merchant.isEmpty ? 'Choose a category' : 'Where does $merchant go?',
      subtitle: 'Your choice wins over anything the app works out later.',
      currentPath: txn.isUncategorized ? null : txn.categoryPath,
    );
    if (pick == null) return;

    // The rule is the point. Correcting one row helps once; correcting the
    // merchant means the question is never asked again, and past rows move too.
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

  Future<void> _setExcluded(
    BuildContext context,
    WidgetRef ref,
    Transaction txn,
    bool excluded,
  ) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final DateTime now = ref.read(clockProvider)();
    final LedgerRepository repo = ref.read(ledgerRepositoryProvider);
    final Transaction updated = txn
        .copyWith(isExcludedFromTotals: excluded)
        .markEdited(<String>['isExcludedFromTotals'], now: now);
    final Result<Transaction> result = await repo.updateTransaction(updated);
    if (result.isErr) {
      messenger.showSnackBar(
        SnackBar(content: Text(result.errorOrNull?.message ?? 'Could not save that.')),
      );
      return;
    }
    ref.invalidate(transactionDetailProvider(txn.id));
  }
}

class _Headline extends StatelessWidget {
  const _Headline({required this.transaction, required this.taxonomy});

  final Transaction transaction;
  final List<CategoryDef> taxonomy;

  @override
  Widget build(BuildContext context) {
    final Transaction txn = transaction;
    return Column(
      children: <Widget>[
        CategoryAvatar(
          categoryPath: txn.categoryPath,
          taxonomy: taxonomy,
          size: 56,
          highlight: txn.isUncategorized,
        ),
        const SizedBox(height: Insets.md),
        Text(
          TransactionRow.titleOf(txn, taxonomy),
          style: context.texts.titleLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: Insets.xs),
        AmountText(
          amount: txn.amount,
          direction: txn.direction,
          kind: txn.kind,
          style: context.texts.displaySmall,
          muted: txn.isNetZero || txn.isExcludedFromTotals,
        ),
        const SizedBox(height: Insets.sm),
        Text(
          Fmt.dateTime(txn.occurredAt),
          style: context.texts.bodyMedium?.copyWith(
            color: context.colors.onSurfaceVariant,
          ),
        ),
        if (txn.datePrecision != DatePrecision.dateTime)
          Padding(
            padding: const EdgeInsets.only(top: Insets.xs),
            child: Text(
              switch (txn.datePrecision) {
                DatePrecision.date => 'The message gave a date but no time.',
                DatePrecision.inferredYear =>
                  'The message gave no year, so it was taken from when the '
                      'message arrived.',
                DatePrecision.receivedFallback =>
                  'The message gave no date, so the time it arrived was used.',
                DatePrecision.dateTime => '',
              },
              style: context.texts.bodySmall?.copyWith(
                color: context.colors.onSurfaceVariant,
              ),
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}

class _CategoryCard extends StatelessWidget {
  const _CategoryCard({
    required this.transaction,
    required this.taxonomy,
    required this.matchedRule,
    required this.onChange,
  });

  final Transaction transaction;
  final List<CategoryDef> taxonomy;
  final UserRule? matchedRule;
  final VoidCallback onChange;

  @override
  Widget build(BuildContext context) {
    final Transaction txn = transaction;
    final UserRule? rule = matchedRule;
    return SectionCard(
      title: 'Why this category',
      trailing: TextButton(
        onPressed: onChange,
        child: Text(txn.isUncategorized ? 'Choose' : 'Change'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Align(
            alignment: Alignment.centerLeft,
            child: CategoryChip(
              categoryPath: txn.categoryPath,
              taxonomy: taxonomy,
              onTap: onChange,
            ),
          ),
          const SizedBox(height: Insets.md),
          CategoryExplanation(
            explanation: Fmt.categorySource(txn.categorySource),
            source: txn.categorySource,
          ),
          if (txn.categoryExplanation.isNotEmpty) ...<Widget>[
            const SizedBox(height: Insets.xs),
            CategoryExplanation(explanation: txn.categoryExplanation),
          ],
          if (rule != null) ...<Widget>[
            const SizedBox(height: Insets.xs),
            CategoryExplanation(
              explanation: rule.explanation,
              source: CategorySource.userRule,
            ),
          ],
          const SizedBox(height: Insets.md),
          ConfidenceIndicator(confidence: txn.confidence),
          if (txn.isUncategorized)
            Padding(
              padding: const EdgeInsets.only(top: Insets.md),
              child: AttentionBanner(
                title: 'Waiting for you',
                message: 'Nothing in the built-in merchant list matched this, and '
                    'the app will not guess. Pick a category once and it will '
                    'remember.',
                icon: Icons.help_outline,
                actionLabel: 'Choose a category',
                onAction: onChange,
              ),
            ),
        ],
      ),
    );
  }
}

/// The source SMS, plus which rule read it.
class _SourceCard extends StatelessWidget {
  const _SourceCard({required this.transaction, required this.rawMessage});

  final Transaction transaction;
  final RawMessage? rawMessage;

  @override
  Widget build(BuildContext context) {
    final RawMessage? raw = rawMessage;
    final String? ruleId = transaction.ruleId;
    return SectionCard(
      title: 'Where this came from',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (raw != null)
            SourceSmsCard(message: raw)
          else if (transaction.source == TxnSource.manual)
            const SourceSmsUnavailable.manual()
          else
            const SourceSmsUnavailable.purged(),
          if (ruleId != null) ...<Widget>[
            const SizedBox(height: Insets.md),
            Text(
              'Read by rule $ruleId'
              '${transaction.ruleVersion == null ? '' : ' from rules pack v${transaction.ruleVersion}'}'
              '.',
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

class _FactsCard extends StatelessWidget {
  const _FactsCard({required this.transaction});

  final Transaction transaction;

  @override
  Widget build(BuildContext context) {
    final Transaction txn = transaction;
    final Money? balance = txn.balanceAfter;
    final List<(String, String)> facts = <(String, String)>[
      ('How', Fmt.channel(txn.channel)),
      ('Direction', txn.direction.isDebit ? 'Money out' : 'Money in'),
      ('Status', Fmt.status(txn.status)),
      if (txn.accountTail != null) ('Account', Fmt.maskedTail(txn.accountTail)),
      if (txn.cardTail != null) ('Card', Fmt.maskedTail(txn.cardTail)),
      if (txn.vpa != null) ('UPI ID', txn.vpa!),
      if (txn.ref != null) ('Reference', txn.ref!),
      if (balance != null) ('Balance after', Fmt.money(balance)),
      if (txn.note != null) ('Note', txn.note!),
    ];

    return SectionCard(
      title: 'Details',
      child: Column(
        children: <Widget>[
          for (final (String label, String value) in facts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: Insets.xs),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(
                    width: 110,
                    child: Text(
                      label,
                      style: context.texts.bodyMedium?.copyWith(
                        color: context.colors.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(value, style: context.texts.bodyMedium),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
