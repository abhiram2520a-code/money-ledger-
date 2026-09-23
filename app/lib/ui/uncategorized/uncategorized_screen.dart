import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:ledger/core/result.dart';
import 'package:ledger/models/models.dart';
import 'package:ledger/ui/theme/theme.dart';
import 'package:ledger/ui/widgets/widgets.dart';

import 'review_controller.dart';
import 'review_queue.dart';

/// The review queue.
///
/// This screen exists because of a promise: the app never guesses a merchant
/// and never sends a message to a server to find out. The cost of that promise
/// is that some payments arrive unnamed, and this screen is where the user and
/// the app settle them together.
///
/// It is built to be cleared, not endured:
/// * repeated payees collapse into one card, so one tap files five payments;
/// * every card carries the SMS it came from, so the user decides from the
///   same evidence the parser had;
/// * a choice is remembered as a rule, so the queue shrinks permanently;
/// * the rule can be swept over older transactions, but only when asked.
class UncategorizedScreen extends ConsumerWidget {
  const UncategorizedScreen({super.key});

  static const String routeName = '/review';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final AsyncValue<List<Transaction>> queue = ref.watch(uncategorizedQueueProvider);
    final List<PayeeGroup> groups = ref.watch(payeeGroupsProvider);
    final bool remember = ref.watch(rememberChoicesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Review'),
        actions: <Widget>[
          PopupMenuButton<String>(
            tooltip: 'Options',
            onSelected: (String value) {
              if (value == 'remember') {
                ref.read(rememberChoicesProvider.notifier).state = !remember;
              }
            },
            itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
              CheckedPopupMenuItem<String>(
                value: 'remember',
                checked: remember,
                child: const Text('Remember my choices'),
              ),
            ],
          ),
        ],
      ),
      body: queue.when(
        loading: () => const SkeletonList(count: 4),
        error: (Object error, StackTrace _) => ErrorState(
          message: 'The review queue could not be read from the local '
              'database. Your transactions are still there.',
          onRetry: () => ref.invalidate(uncategorizedQueueProvider),
        ),
        data: (List<Transaction> transactions) {
          if (transactions.isEmpty) return const _QueueCleared();
          return ContentWidth(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(
                  Insets.lg, Insets.md, Insets.lg, Insets.huge),
              itemCount: groups.length + 1,
              itemBuilder: (BuildContext context, int i) {
                if (i == 0) {
                  return _QueueHeader(
                    transactionCount: transactions.length,
                    payeeCount: groups.length,
                    remember: remember,
                  );
                }
                final PayeeGroup group = groups[i - 1];
                return Padding(
                  key: ValueKey<String>(group.key),
                  padding: const EdgeInsets.only(bottom: Insets.md),
                  child: PayeeReviewCard(group: group),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

/// What the screen says when there is nothing to review.
///
/// Not a celebration and not a void: it states the true situation, including
/// the case the user is most likely to actually be in on day one - no bank
/// messages read yet.
class _QueueCleared extends StatelessWidget {
  const _QueueCleared();

  @override
  Widget build(BuildContext context) {
    return const EmptyState(
      icon: Icons.inbox_outlined,
      title: 'Nothing to review',
      message: 'Every transaction the app has read has a category. New ones '
          'only land here when the app does not recognise the payee - it asks '
          'rather than guessing.',
    );
  }
}

class _QueueHeader extends StatelessWidget {
  const _QueueHeader({
    required this.transactionCount,
    required this.payeeCount,
    required this.remember,
  });

  final int transactionCount;
  final int payeeCount;
  final bool remember;

  @override
  Widget build(BuildContext context) {
    final String payees = Fmt.plural(payeeCount, 'payee', 'payees');
    final String txns =
        Fmt.plural(transactionCount, 'transaction', 'transactions');
    return Padding(
      padding: const EdgeInsets.only(bottom: Insets.md),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AttentionBanner(
            icon: Icons.help_outline,
            title: '$txns from $payees',
            message: payeeCount < transactionCount
                ? 'Filing a payee once files every payment from them.'
                : 'Pick a category and the app will not ask again.',
          ),
          if (!remember) ...<Widget>[
            const SizedBox(height: Insets.sm),
            Row(
              children: <Widget>[
                Icon(Icons.info_outline,
                    size: 14, color: context.colors.onSurfaceVariant),
                const SizedBox(width: Insets.xs + 2),
                Expanded(
                  child: Text(
                    'Remembering is off, so these choices apply only to the '
                    'transactions shown here.',
                    style: context.texts.bodySmall
                        ?.copyWith(color: context.colors.onSurfaceVariant),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// One payee, and everything the user needs to decide about it.
class PayeeReviewCard extends ConsumerStatefulWidget {
  const PayeeReviewCard({required this.group, super.key});

  final PayeeGroup group;

  @override
  ConsumerState<PayeeReviewCard> createState() => _PayeeReviewCardState();
}

class _PayeeReviewCardState extends ConsumerState<PayeeReviewCard> {
  bool _showAll = false;

  PayeeGroup get _group => widget.group;

  Transaction get _sample => _group.transactions.first;

  Future<void> _pickAndApply(CategoryPick? pick) async {
    if (pick == null) return;
    final bool remember = ref.read(rememberChoicesProvider);
    final ReviewController controller = ref.read(reviewControllerProvider.notifier);

    final ReviewApplyResult result = await controller.applyToGroup(
      group: _group,
      pick: pick,
      remember: remember,
    );
    if (!mounted) return;

    if (!result.isOk && result.categorized == 0) {
      _snack(_errorSentence(result.error));
      return;
    }

    final List<String> label = <String>[
      Fmt.plural(result.categorized, 'transaction', 'transactions'),
      'filed under',
    ];
    final String taxonomyLabel = CategoryLabels.label(
      pick.path,
      ref.read(taxonomyProvider),
    );
    final StringBuffer message = StringBuffer('${label.join(' ')} $taxonomyLabel');
    if (result.ruleCreated) {
      message.write('. The app will remember ${_group.label}.');
    } else if (remember && !_group.canMakeRule) {
      message.write('. There is nothing to key a rule on, so this one is a '
          'one-off.');
    }
    if (result.error != null) {
      message.write(' The rule could not be saved: ${_errorSentence(result.error)}');
    }

    final List<String> past = result.pastCandidateIds;
    _snack(
      message.toString(),
      actionLabel: past.isEmpty
          ? null
          : 'Fix ${past.length} older',
      onAction: past.isEmpty ? null : () => _applyToPast(past, pick),
    );
  }

  Future<void> _applyToPast(List<String> ids, CategoryPick pick) async {
    final int changed =
        await ref.read(reviewControllerProvider.notifier).applyToIds(ids, pick);
    if (!mounted) return;
    _snack(changed == 0
        ? 'Nothing changed - those transactions had already been edited by hand.'
        : '${Fmt.plural(changed, 'older transaction', 'older transactions')} '
            'updated.');
  }

  Future<void> _openPicker() async {
    final CategoryPick? pick = await showCategoryPicker(
      context,
      taxonomy: ref.read(taxonomyProvider),
      title: _group.label,
      subtitle: _group.isSingle
          ? 'One payment of ${Fmt.money(_sample.amount)}'
          : '${_group.count} payments, ${Fmt.money(_group.total)} in total',
      suggestions: ref.read(recentCategoryPathsProvider),
    );
    await _pickAndApply(pick);
  }

  Future<void> _discard() async {
    final ReviewController controller = ref.read(reviewControllerProvider.notifier);
    int removed = 0;
    for (final Transaction txn in _group.transactions) {
      final Result<void> result = await controller.discard(txn.id);
      if (result.isOk) removed++;
    }
    if (!mounted) return;
    _snack(removed == 0
        ? 'Could not remove these. Nothing was changed.'
        : '${Fmt.plural(removed, 'transaction', 'transactions')} removed from '
            'your totals. The original messages are kept.');
  }

  Future<void> _exclude() async {
    final ReviewController controller = ref.read(reviewControllerProvider.notifier);
    int done = 0;
    for (final Transaction txn in _group.transactions) {
      final Result<void> result = await controller.excludeFromTotals(txn);
      if (result.isOk) done++;
    }
    if (!mounted) return;
    _snack(done == 0
        ? 'Could not update these. Nothing was changed.'
        : '${Fmt.plural(done, 'transaction', 'transactions')} kept, but left '
            'out of your spend totals.');
  }

  void _snack(String message, {String? actionLabel, VoidCallback? onAction}) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        duration: Duration(seconds: onAction == null ? 4 : 8),
        action: actionLabel == null || onAction == null
            ? null
            : SnackBarAction(label: actionLabel, onPressed: onAction),
      ),
    );
  }

  static String _errorSentence(AppError? error) {
    if (error == null) return 'Something went wrong.';
    return switch (error.code) {
      ErrorCodes.database => 'The local database refused the change.',
      ErrorCodes.invalidArgument =>
        'That category is not in the current rules pack.',
      _ => error.message.isEmpty ? 'Something went wrong.' : error.message,
    };
  }

  @override
  Widget build(BuildContext context) {
    final List<CategoryDef> taxonomy = ref.watch(taxonomyProvider);
    final List<String> suggestions = ref.watch(recentCategoryPathsProvider);
    final bool busy = ref.watch(reviewControllerProvider);
    final List<Transaction> shown =
        _showAll ? _group.transactions : _group.transactions.take(1).toList();

    return SectionCard(
      padding: const EdgeInsets.all(Insets.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _CardHeader(
            group: _group,
            onDiscard: busy ? null : _discard,
            onExclude: busy ? null : _exclude,
          ),
          const SizedBox(height: Insets.md),
          for (final Transaction txn in shown) ...<Widget>[
            _TransactionEvidence(transaction: txn, showAmount: !_group.isSingle),
            const SizedBox(height: Insets.sm),
          ],
          if (_group.count > 1)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => setState(() => _showAll = !_showAll),
                icon: Icon(_showAll ? Icons.expand_less : Icons.expand_more, size: 18),
                label: Text(_showAll
                    ? 'Show less'
                    : 'Show all ${_group.count} payments'),
              ),
            ),
          const SizedBox(height: Insets.sm),
          Text(
            _group.isSingle
                ? 'Where does this belong?'
                : 'Where do these ${_group.count} belong?',
            style: context.texts.titleSmall?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: Insets.sm),
          Wrap(
            spacing: Insets.sm,
            runSpacing: Insets.sm,
            children: <Widget>[
              for (final String path in suggestions.take(4))
                CategoryChip(
                  categoryPath: path,
                  taxonomy: taxonomy,
                  onTap: busy
                      ? null
                      : () => _pickAndApply(
                            CategoryPick(
                              path,
                              kindOfPath(path, taxonomy) ?? CategoryKind.expense,
                            ),
                          ),
                ),
              ActionChip(
                avatar: const Icon(Icons.apps, size: 16),
                label: Text(suggestions.isEmpty ? 'Choose a category' : 'All categories'),
                onPressed: busy ? null : _openPicker,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CardHeader extends StatelessWidget {
  const _CardHeader({
    required this.group,
    required this.onDiscard,
    required this.onExclude,
  });

  final PayeeGroup group;
  final VoidCallback? onDiscard;
  final VoidCallback? onExclude;

  @override
  Widget build(BuildContext context) {
    final Transaction sample = group.transactions.first;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                group.label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.texts.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: Insets.xxs),
              Text(
                group.isSingle
                    ? Fmt.dateTime(sample.occurredAt)
                    : '${group.count} payments · '
                        '${Fmt.date(group.transactions.first.occurredAt)} to '
                        '${Fmt.date(group.transactions.last.occurredAt)}',
                style: context.texts.bodySmall
                    ?.copyWith(color: context.colors.onSurfaceVariant),
              ),
              if (group.vpa != null && group.vpa!.isNotEmpty) ...<Widget>[
                const SizedBox(height: Insets.xs),
                MetaChip(label: group.vpa!, icon: Icons.alternate_email),
              ],
            ],
          ),
        ),
        const SizedBox(width: Insets.sm),
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            AmountText(
              amount: group.total,
              direction: sample.direction,
              showSign: false,
              style: context.texts.titleMedium,
            ),
            PopupMenuButton<String>(
              tooltip: 'More',
              padding: EdgeInsets.zero,
              onSelected: (String value) {
                if (value == 'discard') onDiscard?.call();
                if (value == 'exclude') onExclude?.call();
              },
              itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
                const PopupMenuItem<String>(
                  value: 'exclude',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.visibility_off_outlined),
                    title: Text('Keep, but leave out of totals'),
                  ),
                ),
                const PopupMenuItem<String>(
                  value: 'discard',
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.block_outlined),
                    title: Text('Not a real transaction'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ],
    );
  }
}

/// One transaction inside a card: the amount, and the message it came from.
class _TransactionEvidence extends ConsumerWidget {
  const _TransactionEvidence({required this.transaction, required this.showAmount});

  final Transaction transaction;
  final bool showAmount;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final String? rawId = transaction.rawMessageId;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (showAmount) ...<Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  Fmt.dateTime(transaction.occurredAt),
                  style: context.texts.bodySmall
                      ?.copyWith(color: context.colors.onSurfaceVariant),
                ),
              ),
              AmountText(
                amount: transaction.amount,
                direction: transaction.direction,
                style: context.texts.bodyMedium,
              ),
            ],
          ),
          const SizedBox(height: Insets.xs),
        ],
        if (rawId == null)
          const SourceSmsUnavailable.manual()
        else
          ref.watch(rawMessageProvider(rawId)).when(
                loading: () => const Padding(
                  padding: EdgeInsets.symmetric(vertical: Insets.sm),
                  child: SkeletonBox(height: 44, radius: 12),
                ),
                error: (Object _, StackTrace _) => const SourceSmsUnavailable(
                  reason: 'The original message could not be read just now.',
                ),
                data: (RawMessage? message) => message == null
                    ? const SourceSmsUnavailable.purged()
                    : SourceSmsCard(message: message),
              ),
      ],
    );
  }
}
